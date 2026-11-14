#if os(Windows)
import CRT
import Foundation

// Windows compile bring-up (stretch). The terminal app reads raw keys through termios and poll,
// which the Windows C runtime does not have. The plan cuts the interactive terminal app from version 1
// (architecture.md section 7); these stubs let the command-line subcommands build. Each one fails with -1,
// so the app never believes it switched the terminal into raw mode.

typealias tcflag_t = UInt32
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
}

struct pollfd {
    var fd: Int32
    var events: Int16
    var revents: Int16
}

// windows-port: stub (console, cut from version 1)
func tcgetattr(_ descriptor: Int32, _ settings: UnsafeMutablePointer<termios>) -> Int32 { -1 }

// windows-port: stub (console, cut from version 1)
@discardableResult
func tcsetattr(_ descriptor: Int32, _ action: Int32, _ settings: UnsafePointer<termios>) -> Int32 { -1 }

// windows-port: stub (console, cut from version 1)
func cfmakeraw(_ settings: UnsafeMutablePointer<termios>) {}

// windows-port: stub (console, cut from version 1)
func isatty(_ descriptor: Int32) -> Int32 { 0 }

// windows-port: stub (console, cut from version 1)
func poll(_ descriptors: UnsafeMutablePointer<pollfd>, _ count: UInt32, _ milliseconds: Int32) -> Int32 { -1 }

// windows-port: stub (console, cut from version 1)
func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { -1 }
#endif
