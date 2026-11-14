#if os(Windows)
import CRT
import Foundation
import WinSDK

// The terminal app reads keys through termios and poll, which the Windows C runtime does not have.
// These map them onto the console: ECHO, ICANON and ISIG are the console's echo, line and processed-input modes,
// and raw mode turns on VT input and output so keys arrive and screens draw as ANSI sequences, as on POSIX.
// A descriptor that is not a console fails like a non-terminal does on POSIX.

typealias tcflag_t = UInt32
let ISIG: tcflag_t = 0o1
let ICANON: tcflag_t = 0o2
let ECHO: tcflag_t = 0o10
let TCSANOW: Int32 = 0
let VMIN = 6
let VTIME = 5
let STDIN_FILENO: Int32 = 0
let STDOUT_FILENO: Int32 = 1
let POLLIN: Int32 = 1

struct termios {
    var c_iflag: tcflag_t = 0
    var c_oflag: tcflag_t = 0
    var c_cflag: tcflag_t = 0
    var c_lflag: tcflag_t = 0
    var c_cc: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0)
    /// The console mode `tcgetattr` read, so `tcsetattr` restores the bits termios has no name for.
    var consoleMode: DWORD = 0
}

struct pollfd {
    var fd: Int32
    var events: Int16
    var revents: Int16
}

private func consoleHandle(_ descriptor: Int32) -> HANDLE? {
    let raw = _get_osfhandle(descriptor)
    guard raw != -1, let handle = HANDLE(bitPattern: raw) else { return nil }
    return handle
}

private let modeFlags: [(tcflag_t, Int32)] = [(ECHO, ENABLE_ECHO_INPUT), (ICANON, ENABLE_LINE_INPUT), (ISIG, ENABLE_PROCESSED_INPUT)]

func tcgetattr(_ descriptor: Int32, _ settings: UnsafeMutablePointer<termios>) -> Int32 {
    var mode: DWORD = 0
    guard let handle = consoleHandle(descriptor), GetConsoleMode(handle, &mode) else { return -1 }
    var result = termios()
    result.consoleMode = mode
    for (flag, bit) in modeFlags where mode & DWORD(bit) != 0 { result.c_lflag |= flag }
    settings.pointee = result
    return 0
}

@discardableResult
func tcsetattr(_ descriptor: Int32, _ action: Int32, _ settings: UnsafePointer<termios>) -> Int32 {
    guard let handle = consoleHandle(descriptor) else { return -1 }
    var mode = settings.pointee.consoleMode
    for (flag, bit) in modeFlags {
        if settings.pointee.c_lflag & flag != 0 { mode |= DWORD(bit) } else { mode &= ~DWORD(bit) }
    }
    if mode & DWORD(ENABLE_LINE_INPUT) == 0 {
        mode &= ~DWORD(ENABLE_ECHO_INPUT) // the console refuses echo without line input
        mode |= DWORD(ENABLE_VIRTUAL_TERMINAL_INPUT)
        if let output = GetStdHandle(STD_OUTPUT_HANDLE) {
            var outputMode: DWORD = 0
            if GetConsoleMode(output, &outputMode) {
                _ = SetConsoleMode(output, outputMode | DWORD(ENABLE_VIRTUAL_TERMINAL_PROCESSING))
            }
        }
    }
    return SetConsoleMode(handle, mode) ? 0 : -1
}

func cfmakeraw(_ settings: UnsafeMutablePointer<termios>) {
    settings.pointee.c_lflag &= ~(ECHO | ICANON | ISIG)
}

func isatty(_ descriptor: Int32) -> Int32 {
    var mode: DWORD = 0
    guard let handle = consoleHandle(descriptor) else { return 0 }
    return GetConsoleMode(handle, &mode) ? 1 : 0
}

/// Ready when a key press waits. Other console events (focus, mouse, key release) are dropped, so a following
/// `read` never blocks on them.
func poll(_ descriptors: UnsafeMutablePointer<pollfd>, _ count: UInt32, _ milliseconds: Int32) -> Int32 {
    guard count == 1, descriptors[0].events & Int16(POLLIN) != 0, let handle = consoleHandle(descriptors[0].fd) else { return -1 }
    descriptors[0].revents = 0
    let deadline = GetTickCount64() + UInt64(max(milliseconds, 0))
    while true {
        var record = INPUT_RECORD()
        var seen: DWORD = 0
        while PeekConsoleInputW(handle, &record, 1, &seen), seen == 1 {
            if record.EventType == WORD(KEY_EVENT), record.Event.KeyEvent.bKeyDown.boolValue, record.Event.KeyEvent.uChar.UnicodeChar != 0 {
                descriptors[0].revents = Int16(POLLIN)
                return 1
            }
            guard ReadConsoleInputW(handle, &record, 1, &seen) else { return -1 }
        }
        let left = milliseconds < 0 ? INFINITE : DWORD(deadline > GetTickCount64() ? deadline - GetTickCount64() : 0)
        if left == 0 { return 0 }
        if WaitForSingleObject(handle, left) != 0 { return 0 } // WAIT_OBJECT_0 means input arrived
    }
}

func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    guard let handle = consoleHandle(descriptor), let buffer else { return -1 }
    var done: DWORD = 0
    return ReadFile(handle, buffer, DWORD(min(count, Int(Int32.max))), &done, nil) ? Int(done) : -1
}
#endif
