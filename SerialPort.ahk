#Requires AutoHotkey v2.0+


/**
 * A wrapper around the Windows Win32 serial communication API using DllCall.
 * Supports opening, configuring, reading, writing, hardware line control,
 * modem status querying, and buffer management for any COM port.
 *
 * @example
 * port := SerialPort("COM3", 9600)
 * port.Write("hello")
 * data := port.ReadLine()
 * port.Close()
 *
 * Parity values:   0=none  1=odd  2=even  3=mark  4=space
 * StopBits values: 0=1bit  1=1.5bit  2=2bit
 */
class SerialPort {

    /**
     * Opens and configures the COM port. Throws OSError on failure.
     *
     * @param {String}  port      COM port name e.g. "COM3". Ports above COM9
     *                            also work since the \\.\ prefix is added automatically.
     * @param {Integer} baudRate  Baud rate. Common values: 9600, 19200, 38400,
     *                            57600, 115200. Defaults to 9600.
     * @param {Integer} dataBits  Number of data bits per byte. Usually 8.
     *                            Range 5-8. Defaults to 8.
     * @param {Integer} parity    Parity mode. 0=none, 1=odd, 2=even, 3=mark,
     *                            4=space. Defaults to 0 (none).
     * @param {Integer} stopBits  Stop bits. 0=1 bit, 1=1.5 bits, 2=2 bits.
     *                            Defaults to 0 (1 stop bit).
     * @throws {OSError} If the port cannot be opened (e.g. in use, does not
     *                   exist, or access is denied).
     */
    __New(port, baudRate := 9600, dataBits := 8, parity := 0, stopBits := 0) {
        this.handle := DllCall("CreateFile"
            , "Str",  "\\.\" . port
            , "UInt", 0xC0000000   ; GENERIC_READ | GENERIC_WRITE
            , "UInt", 0            ; no sharing — only one process may open a COM port at a time
            , "Ptr",  0
            , "UInt", 3            ; OPEN_EXISTING — COM ports must already exist
            , "UInt", 0
            , "Ptr",  0, "Ptr")

        if this.handle = -1
            throw OSError(, , "Could not open " port)

        this._SetDCB(baudRate, dataBits, parity, stopBits)
        this._SetTimeouts()
    }

    /**
     * Whether the port handle is currently open and valid.
     * Use this to guard Read/Write calls if the port may have been closed.
     *
     * @type {Boolean}
     * @readonly
     */
    IsOpen {
        get => this.handle && this.handle != -1
    }

    /**
     * Number of bytes currently waiting in the hardware receive buffer.
     * Uses ClearCommError + COMSTAT to query the driver.
     *
     * @type {Integer}
     * @readonly
     */
    BytesAvailable {
        get {
            errors  := Buffer(4, 0)
            comstat := Buffer(12, 0)  ; COMSTAT: 4-byte flags, cbInQue, cbOutQue
            DllCall("ClearCommError", "Ptr", this.handle, "Ptr", errors, "Ptr", comstat)
            return NumGet(comstat, 4, "UInt")  ; cbInQue is at offset 4
        }
    }

    /**
     * Writes a string to the COM port encoded as UTF-8.
     *
     * @param   {String}  data  The text to send.
     * @returns {Integer}       Number of bytes actually written.
     */
    Write(data) {
        buf := Buffer(StrPut(data, "UTF-8") - 1)  ; -1 excludes the null terminator
        StrPut(data, buf, "UTF-8")
        written := Buffer(4, 0)
        DllCall("WriteFile", "Ptr", this.handle, "Ptr", buf,
            "UInt", buf.Size, "Ptr", written, "Ptr", 0)
        return NumGet(written, "UInt")
    }

    /**
     * Writes a raw array of byte values to the COM port. Use this instead of
     * Write() when working with binary protocols where the data is not text.
     *
     * @param   {Array}   arr  Array of integers in the range 0-255, e.g. [0x01, 0xFF].
     * @returns {Integer}      Number of bytes actually written.
     */
    WriteBytes(arr) {
        buf := Buffer(arr.Length, 0)
        for i, byte in arr
            NumPut("UChar", byte, buf, i - 1)
        written := Buffer(4, 0)
        DllCall("WriteFile", "Ptr", this.handle, "Ptr", buf,
            "UInt", buf.Size, "Ptr", written, "Ptr", 0)
        return NumGet(written, "UInt")
    }

    /**
     * Reads up to maxBytes from the RX buffer and returns them as a UTF-8
     * decoded string. Returns an empty string if no data arrived before the
     * read timeout (configured in _SetTimeouts, default 100ms).
     *
     * @param   {Integer} maxBytes  Maximum number of bytes to read. Defaults to 256.
     * @returns {String}            Decoded text, or "" if nothing was received.
     */
    Read(maxBytes := 256) {
        buf  := Buffer(maxBytes, 0)
        read := Buffer(4, 0)
        DllCall("ReadFile", "Ptr", this.handle, "Ptr", buf,
            "UInt", maxBytes, "Ptr", read, "Ptr", 0)
        bytesRead := NumGet(read, "UInt")
        return bytesRead > 0 ? StrGet(buf, bytesRead, "UTF-8") : ""
    }

    /**
     * Reads up to maxBytes from the RX buffer and returns them as an array of
     * raw integer byte values (0-255). Use this instead of Read() when working
     * with binary protocols where the data should not be decoded as text.
     *
     * @param   {Integer} maxBytes  Maximum number of bytes to read. Defaults to 256.
     * @returns {Array}             Array of integers e.g. [0x01, 0x41, 0xFF].
     *                              Empty array if nothing was received.
     */
    ReadBytes(maxBytes := 256) {
        buf  := Buffer(maxBytes, 0)
        read := Buffer(4, 0)
        DllCall("ReadFile", "Ptr", this.handle, "Ptr", buf,
            "UInt", maxBytes, "Ptr", read, "Ptr", 0)
        out := []
        loop NumGet(read, "UInt")
            out.Push(NumGet(buf, A_Index - 1, "UChar"))
        return out
    }

    /**
     * Reads bytes one at a time until a newline character (0x0A) is received
     * or the timeout expires. The newline is consumed but not included in the
     * returned string. Any trailing carriage return (0x0D) is also stripped.
     *
     * @param   {Integer} timeout  Maximum milliseconds to wait for a complete
     *                             line. Defaults to 2000ms.
     * @returns {String}           The received line without the newline, or
     *                             whatever was collected if the timeout expired.
     */
    ReadLine(timeout := 2000) => this.ReadUntil("`n", timeout)

    /**
     * Reads bytes one at a time until the specified delimiter character is
     * received or the timeout expires. The delimiter is consumed but not
     * included in the returned string.
     *
     * @param   {String}  delimiter  A single character to stop reading at.
     * @param   {Integer} timeout    Maximum milliseconds to wait. Defaults to 2000ms.
     * @returns {String}             Everything received before the delimiter, or
     *                               whatever was collected if the timeout expired.
     */
    ReadUntil(delimiter, timeout := 2000) {
        result   := ""
        deadline := A_TickCount + timeout
        loop {
            if A_TickCount > deadline
                break
            if this.BytesAvailable > 0 {
                ch := this.Read(1)
                if ch = delimiter
                    break
                result .= ch
            } else {
                Sleep(10)
            }
        }
        return RTrim(result, "`r")  ; strip trailing CR for CRLF line endings
    }

    /**
     * Discards data in the RX and/or TX buffers and aborts any pending I/O
     * operations. Useful for clearing stale data after connecting or after
     * a communication error.
     *
     * @param {String} mode  Which buffer(s) to flush:
     *                         "rx"   — flush receive buffer only
     *                         "tx"   — flush transmit buffer only
     *                         "both" — flush both (default)
     */
    Flush(mode := "both") {
        ; PurgeComm flags:
        ;   PURGE_TXABORT = 0x0001  abort pending TX transfers
        ;   PURGE_RXABORT = 0x0002  abort pending RX transfers
        ;   PURGE_TXCLEAR = 0x0004  clear TX buffer
        ;   PURGE_RXCLEAR = 0x0008  clear RX buffer
        flags := 0
        if mode = "tx" || mode = "both"
            flags |= 0x0005  ; PURGE_TXABORT | PURGE_TXCLEAR
        if mode = "rx" || mode = "both"
            flags |= 0x000A  ; PURGE_RXABORT | PURGE_RXCLEAR
        DllCall("PurgeComm", "Ptr", this.handle, "UInt", flags)
    }

    /**
     * Changes the baud rate of an already-open port without closing it.
     * All other port settings (data bits, parity, stop bits) are preserved.
     *
     * @param   {Integer} rate  New baud rate, e.g. 115200.
     * @throws  {OSError}       If GetCommState or SetCommState fails.
     */
    SetBaudRate(rate) {
        dcb := Buffer(28, 0)
        NumPut("UInt", 28, dcb, 0)
        if !DllCall("GetCommState", "Ptr", this.handle, "Ptr", dcb)
            throw OSError(, , "GetCommState failed")
        NumPut("UInt", rate, dcb, 4)
        if !DllCall("SetCommState", "Ptr", this.handle, "Ptr", dcb)
            throw OSError(, , "SetCommState failed")
    }

    /**
     * Manually sets or clears the RTS (Request To Send) hardware line.
     * Only meaningful when hardware flow control is not active, since the
     * driver controls RTS automatically in that mode.
     *
     * @param {Boolean} state  True to assert RTS high, false to clear it low.
     */
    SetRTS(state) {
        ; EscapeCommFunction constants: SETRTS=3, CLRRTS=4
        DllCall("EscapeCommFunction", "Ptr", this.handle, "UInt", state ? 3 : 4)
    }

    /**
     * Manually sets or clears the DTR (Data Terminal Ready) hardware line.
     * Some devices use DTR to detect whether the host is connected, or as a
     * reset signal (e.g. Arduino resets when DTR is toggled).
     *
     * @param {Boolean} state  True to assert DTR high, false to clear it low.
     */
    SetDTR(state) {
        ; EscapeCommFunction constants: SETDTR=5, CLRDTR=6
        DllCall("EscapeCommFunction", "Ptr", this.handle, "UInt", state ? 5 : 6)
    }

    /**
     * Reads the current state of the four incoming modem status lines.
     * These are signals driven by the remote device, not by this machine.
     *
     * @returns {{ CTS: Boolean, DSR: Boolean, Ring: Boolean, CD: Boolean }}
     *   CTS  — Clear To Send:    remote device is ready to receive data
     *   DSR  — Data Set Ready:   remote device is powered and ready
     *   Ring — Ring Indicator:   incoming call / ring signal detected
     *   CD   — Carrier Detect:   active connection/carrier is present
     */
    GetModemStatus() {
        status := Buffer(4, 0)
        DllCall("GetCommModemStatus", "Ptr", this.handle, "Ptr", status)
        flags := NumGet(status, "UInt")
        return {
            CTS:  !!(flags & 0x0010),  ; MS_CTS_ON
            DSR:  !!(flags & 0x0020),  ; MS_DSR_ON
            Ring: !!(flags & 0x0040),  ; MS_RING_ON
            CD:   !!(flags & 0x0080)   ; MS_RLSD_ON (carrier detect)
        }
    }

    /**
     * Closes the COM port handle and releases it so other processes can use it.
     * Safe to call multiple times. Also called automatically by __Delete when
     * the SerialPort object goes out of scope or is freed.
     */
    Close() {
        if this.handle && this.handle != -1 {
            DllCall("CloseHandle", "Ptr", this.handle)
            this.handle := 0
        }
    }

    ; =========================================================================
    ; Private methods — not intended to be called directly.
    ; =========================================================================

    /**
     * Reads the current DCB (Device Control Block) from the driver, updates
     * the communication parameters, and writes it back. Called once from __New.
     *
     * The DCB is a 28-byte Win32 structure controlling baud rate, byte size,
     * parity, stop bits, and flow control. Relevant offset layout:
     *   0  DCBlength (DWORD) — must be set to 28
     *   4  BaudRate  (DWORD)
     *   8  Flags     (DWORD) — packed bitfield; fBinary=1, rest 0 (no flow control)
     *   18 ByteSize  (BYTE)
     *   19 Parity    (BYTE)
     *   20 StopBits  (BYTE)
     *
     * @param {Integer} baudRate
     * @param {Integer} dataBits
     * @param {Integer} parity
     * @param {Integer} stopBits
     * @throws {OSError} If GetCommState or SetCommState fails.
     */
    _SetDCB(baudRate, dataBits, parity, stopBits) {
        dcb := Buffer(28, 0)
        NumPut("UInt", 28, dcb, 0)

        if !DllCall("GetCommState", "Ptr", this.handle, "Ptr", dcb)
            throw OSError(, , "GetCommState failed")

        NumPut("UInt",  baudRate, dcb, 4)
        NumPut("UInt",  0x01,     dcb, 8)   ; fBinary=1, no flow control
        NumPut("UChar", dataBits, dcb, 18)
        NumPut("UChar", parity,   dcb, 19)
        NumPut("UChar", stopBits, dcb, 20)

        if !DllCall("SetCommState", "Ptr", this.handle, "Ptr", dcb)
            throw OSError(, , "SetCommState failed")
    }

    /**
     * Configures the COMMTIMEOUTS structure, controlling how long ReadFile
     * and WriteFile block before returning. Called once from __New.
     *
     * The 50ms ReadIntervalTimeout means ReadFile returns once there has been
     * a 50ms gap between consecutive incoming bytes, which works well for
     * line-based or packet-based protocols.
     *
     * COMMTIMEOUTS layout (20 bytes):
     *   0  ReadIntervalTimeout         — ms gap between chars before returning
     *   4  ReadTotalTimeoutMultiplier  — multiplied by requested byte count
     *   8  ReadTotalTimeoutConstant    — added to above; total read deadline
     *   12 WriteTotalTimeoutMultiplier
     *   16 WriteTotalTimeoutConstant
     *
     * @param {Integer} readMs   Total read timeout in ms. Defaults to 100.
     * @param {Integer} writeMs  Total write timeout in ms. Defaults to 100.
     * @throws {OSError} If SetCommTimeouts fails.
     */
    _SetTimeouts(readMs := 100, writeMs := 100) {
        ct := Buffer(20, 0)
        NumPut("UInt", 50,      ct, 0)
        NumPut("UInt", 0,       ct, 4)
        NumPut("UInt", readMs,  ct, 8)
        NumPut("UInt", 0,       ct, 12)
        NumPut("UInt", writeMs, ct, 16)

        if !DllCall("SetCommTimeouts", "Ptr", this.handle, "Ptr", ct)
            throw OSError(, , "SetCommTimeouts failed")
    }

    __Delete() => this.Close()
}