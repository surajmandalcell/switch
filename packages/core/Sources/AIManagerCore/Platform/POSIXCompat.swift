#if os(Windows)
import CRT
import Foundation

// Windows compile bring-up (plan unit W2). The core calls POSIX functions that the Windows C runtime
// does not have. This file gives each one a Windows definition with the same shape, so the call sites
// compile unchanged on macOS and Linux. Nothing here ports behaviour.
//
// Every stub fails: it returns -1 or nil and sets errno to ENOSYS. Call sites already treat that as
// "could not open, could not read, could not lock", which fails closed. The owner and permission
// sentinels below can never match each other, so no ownership check passes by accident.
// Each later P unit replaces its stubs with real code in `Platform/` and the C units move the call sites.
// Each stub carries a "windows-port" marker comment naming its plan unit; grep for it to count them.

typealias mode_t = UInt32
typealias uid_t = UInt32
typealias nlink_t = UInt32

let S_IFMT: mode_t = 0o170000
let S_IFREG: mode_t = 0o100000
let S_IFDIR: mode_t = 0o040000
let S_IFLNK: mode_t = 0o120000
let S_IRUSR: mode_t = 0o400
let S_IWUSR: mode_t = 0o200

let O_NOFOLLOW: Int32 = 0x10000
let O_CLOEXEC: Int32 = 0x20000
let O_NONBLOCK: Int32 = 0x40000

let LOCK_EX: Int32 = 2
let LOCK_NB: Int32 = 4
let LOCK_UN: Int32 = 8
let SIGKILL: Int32 = 9

let POLLIN: Int32 = 1

/// The fields the core reads from `struct stat`, with the Linux names. All zero or "unknown" until P1 and P4.
struct stat {
    var st_dev: UInt64 = 0
    var st_ino: UInt64 = 0
    var st_mode: mode_t = 0
    var st_nlink: nlink_t = 0
    /// Differs from `getuid()` on purpose: an unread owner never equals the process owner.
    var st_uid: uid_t = 0xFFFF_FFFF
    var st_size: Int64 = 0
    var st_atim = timespec()
    var st_mtim = timespec()
    var st_ctim = timespec()
}

struct pollfd {
    var fd: Int32
    var events: Int16
    var revents: Int16
}

@inline(never)
private func fail<T>(_ value: T) -> T {
    errno = ENOSYS
    return value
}

// windows-port: stub (P1)
func lstat(_ path: UnsafePointer<CChar>, _ info: UnsafeMutablePointer<stat>) -> Int32 { fail(-1) }

// windows-port: stub (P1)
func fstat(_ descriptor: Int32, _ info: UnsafeMutablePointer<stat>) -> Int32 { fail(-1) }

// windows-port: stub (P1)
func fchmod(_ descriptor: Int32, _ mode: mode_t) -> Int32 { fail(-1) }

// windows-port: stub (P4)
func futimens(_ descriptor: Int32, _ times: UnsafePointer<timespec>) -> Int32 { fail(-1) }

/// Never equals a `stat.st_uid` read from disk.
// windows-port: stub (P1)
func getuid() -> uid_t { 0xFFFF_FFFE }

// windows-port: stub (P1)
func open(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t = 0) -> Int32 { fail(-1) }

// windows-port: stub (P3)
@discardableResult
func flock(_ descriptor: Int32, _ operation: Int32) -> Int32 { fail(-1) }

// windows-port: stub (P6)
@discardableResult
func kill(_ pid: Int32, _ signal: Int32) -> Int32 { fail(-1) }

// windows-port: stub (P8)
func realpath(_ path: UnsafePointer<CChar>, _ resolved: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? { fail(nil) }

// windows-port: stub (P6)
func poll(_ descriptors: UnsafeMutablePointer<pollfd>, _ count: UInt32, _ milliseconds: Int32) -> Int32 { fail(-1) }

// windows-port: stub (P6)
func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { fail(-1) }

/// Plain byte search; the C runtime on Windows has no `memmem`. Real code, not a stub.
func memmem(_ haystack: UnsafeRawPointer, _ haystackLength: Int, _ needle: UnsafeRawPointer, _ needleLength: Int) -> UnsafeMutableRawPointer? {
    guard needleLength > 0 else { return UnsafeMutableRawPointer(mutating: haystack) }
    guard haystackLength >= needleLength else { return nil }
    let text = haystack.assumingMemoryBound(to: UInt8.self)
    let pattern = needle.assumingMemoryBound(to: UInt8.self)
    for start in 0...(haystackLength - needleLength) where text[start] == pattern[0] {
        if memcmp(text + start, pattern, needleLength) == 0 { return UnsafeMutableRawPointer(mutating: haystack + start) }
    }
    return nil
}

func getpid() -> Int32 { ProcessInfo.processInfo.processIdentifier }

@discardableResult
func usleep(_ microseconds: UInt32) -> Int32 {
    Thread.sleep(forTimeInterval: Double(microseconds) / 1_000_000)
    return 0
}
#endif
