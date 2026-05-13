# SerialPort.ahk — AutoHotkey v2 serial COM port library

A pure AHK v2 class for communicating with serial COM ports using no external libraries — just raw Win32 API calls via `DllCall`.

---

## How it works

Windows exposes COM ports as file handles, the same way it handles files on disk. To open a port you call `CreateFile()` with the port name, then use `ReadFile()` and `WriteFile()` to exchange data, and `CloseHandle()` to release it. Because it's a file handle, only one process can hold it open at a time.

Before any data can flow, two Win32 structures need to be configured:

- **DCB (Device Control Block)** — a 28-byte structure that tells the driver the baud rate, data bits, parity, and stop bits to use. You fetch the current one with `GetCommState()`, update the relevant fields, and write it back with `SetCommState()`.
- **COMMTIMEOUTS** — a 20-byte structure that controls how long `ReadFile()` blocks before giving up. Without this, a read call would hang forever waiting for data that may never arrive. The `ReadIntervalTimeout` field is especially useful — it makes `ReadFile()` return as soon as there's been a gap of N milliseconds between incoming bytes, which naturally collects a full burst of data in one call.

---

## What's included

| Method / Property | Description |
|---|---|
| `Write(str)` | Send a UTF-8 encoded string |
| `WriteBytes(arr)` | Send a raw array of byte values |
| `Read()` | Receive data as a string |
| `ReadBytes()` | Receive data as a raw byte array |
| `ReadLine()` | Read until a newline character |
| `ReadUntil(delimiter)` | Read until any character you specify |
| `Flush("rx"/"tx"/"both")` | Discard stale data from the RX/TX buffers |
| `SetBaudRate(rate)` | Change baud rate on the fly without reopening |
| `SetRTS(state)` | Toggle the RTS hardware signal line high/low |
| `SetDTR(state)` | Toggle the DTR hardware signal line high/low |
| `GetModemStatus()` | Returns CTS, DSR, Ring, and CD line states |
| `IsOpen` | `true` if the port handle is currently valid |
| `BytesAvailable` | Number of bytes waiting in the RX buffer |
| `Close()` | Release the port handle |

The handle is also closed automatically when the object goes out of scope.

---

## Usage

```ahk
port := SerialPort("COM3", 9600)

; write
port.Write("hello\n")
port.WriteBytes([0x01, 0xFF, 0x0D])

; read
if port.BytesAvailable > 0
    data := port.Read()

line := port.ReadLine()

; hardware lines
port.SetDTR(true)
port.SetRTS(false)

status := port.GetModemStatus()
if status.CTS
    MsgBox "Remote is ready"

; cleanup
port.Close()
```
