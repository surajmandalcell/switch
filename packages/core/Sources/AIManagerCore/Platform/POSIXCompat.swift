#if os(Windows)
import CRT
import Foundation
import WinSDK

// The core calls POSIX functions that the Windows C runtime does not have. This file gives each one a
// Windows definition with the same shape, so the call sites compile unchanged on macOS and Linux.
// The bodies are Win32 code in WindowsFiles.swift. Whatever a shim cannot do the POSIX way, it refuses with
// -1 and errno, which the call sites already treat as "could not open, could not lock": it fails closed.
// An owner the shims cannot read is never reported as `getuid()`, so no ownership check passes by accident.

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

/// The fields the core reads from `struct stat`, with the Linux names. `st_dev` is the volume serial, `st_ino` the file index, `st_ctim` the change time.
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
private func fail<T>(_ value: T, _ code: Int32 = ENOSYS) -> T {
    errno = code
    return value
}

private func withInfoHandle(_ path: UnsafePointer<CChar>, followLinks: Bool, _ body: (HANDLE) -> Int32) -> Int32 {
    guard let handle = WindowsFiles.openForInfo(String(cString: path), followLinks: followLinks) else {
        return fail(-1, WindowsFiles.errnoFromLastError())
    }
    defer { CloseHandle(handle) }
    return body(handle)
}

/// Mode bits are 0o600/0o700 for an owner-only access list and 0o666/0o777 otherwise (see WindowsFiles).
func lstat(_ path: UnsafePointer<CChar>, _ info: UnsafeMutablePointer<stat>) -> Int32 {
    withInfoHandle(path, followLinks: false) { WindowsFiles.fill($0, info) ? 0 : -1 }
}

func fstat(_ descriptor: Int32, _ info: UnsafeMutablePointer<stat>) -> Int32 {
    guard let handle = WindowsFiles.handle(descriptor) else { return -1 }
    return WindowsFiles.fill(handle, info) ? 0 : -1
}

/// Only "owner only" exists on Windows: any mode without group or other bits sets the private access list.
/// Opening access up is not ported and fails.
func fchmod(_ descriptor: Int32, _ mode: mode_t) -> Int32 {
    guard mode & 0o077 == 0 else { return fail(-1) }
    guard let handle = WindowsFiles.handle(descriptor) else { return -1 }
    return WindowsFiles.makePrivate(handle: handle) ? 0 : fail(-1, EACCES)
}

/// `times[0]` is the access time, `times[1]` the modification time.
func futimens(_ descriptor: Int32, _ times: UnsafePointer<timespec>) -> Int32 {
    guard let handle = WindowsFiles.handle(descriptor) else { return -1 }
    return WindowsFiles.setTimes(handle, access: times[0], modified: times[1]) ? 0 : fail(-1, WindowsFiles.errnoFromLastError())
}

/// `lstat` and `fstat` report this as `st_uid` when the owner is this process's user.
func getuid() -> uid_t { WindowsFiles.currentUserID }

/// O_CREAT with a mode that has no group or other bits creates the file owner-only from the first byte.
/// O_NOFOLLOW refuses links with ELOOP. Handles are never inherited, so O_CLOEXEC always holds.
func open(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t = 0) -> Int32 {
    let native = WindowsFiles.native(String(cString: path))
    var access: DWORD = DWORD(READ_CONTROL)
    switch flags & (O_RDONLY | O_WRONLY | O_RDWR) {
    case O_WRONLY: access |= DWORD(GENERIC_WRITE)
    case O_RDWR: access |= DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE)
    default: access |= DWORD(GENERIC_READ)
    }
    let disposition: Int32 = switch (flags & O_CREAT != 0, flags & O_EXCL != 0, flags & O_TRUNC != 0) {
    case (true, true, _): CREATE_NEW
    case (true, false, true): CREATE_ALWAYS
    case (true, false, false): OPEN_ALWAYS
    case (false, _, true): TRUNCATE_EXISTING
    default: OPEN_EXISTING
    }
    let follow = flags & O_NOFOLLOW == 0
    func attempt(_ access: DWORD) -> HANDLE? {
        if flags & O_CREAT != 0, mode & 0o077 == 0 {
            return try? WindowsFiles.withPrivateAttributes {
                WindowsFiles.openHandle(native, access: access, followLinks: follow, disposition: DWORD(disposition), attributes: $0)
            }
        }
        return WindowsFiles.openHandle(native, access: access, followLinks: follow, disposition: DWORD(disposition))
    }
    // WRITE_DAC lets fchmod work; a file the user does not own may refuse it, so try again without.
    var handle = attempt(access | DWORD(WRITE_DAC))
    if handle == nil, GetLastError() == DWORD(ERROR_ACCESS_DENIED) { handle = attempt(access) }
    guard let handle else { return fail(-1, WindowsFiles.errnoFromLastError()) }
    if !follow {
        var file = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &file), !WindowsFiles.isLink(handle, attributes: file.dwFileAttributes) else {
            CloseHandle(handle)
            return fail(-1, ELOOP)
        }
    }
    let descriptor = _open_osfhandle(Int(bitPattern: handle), (flags & O_APPEND) | _O_BINARY)
    if descriptor < 0 { CloseHandle(handle) }
    return descriptor
}

/// `LockFileEx` over the whole range, like the Rust `fs2` crate that Codex locks with, so the two conflict.
@discardableResult
func flock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
    guard let handle = WindowsFiles.handle(descriptor) else { return -1 }
    var overlapped = OVERLAPPED()
    if operation & LOCK_UN != 0 {
        return UnlockFileEx(handle, 0, DWORD.max, DWORD.max, &overlapped) ? 0 : fail(-1, EINVAL)
    }
    let flags = DWORD(operation & LOCK_EX != 0 ? LOCKFILE_EXCLUSIVE_LOCK : 0)
        | DWORD(operation & LOCK_NB != 0 ? LOCKFILE_FAIL_IMMEDIATELY : 0)
    return LockFileEx(handle, flags, 0, DWORD.max, DWORD.max, &overlapped) ? 0 : fail(-1, EWOULDBLOCK)
}

/// Signal 0 tests that the process runs. Any other signal ends it with `TerminateProcess`: Windows has no SIGTERM,
/// so callers that send SIGTERM and then SIGKILL get the hard stop at the first step.
@discardableResult
func kill(_ pid: Int32, _ signal: Int32) -> Int32 {
    let rights = DWORD(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION) | (signal == 0 ? 0 : DWORD(PROCESS_TERMINATE))
    guard let process = OpenProcess(rights, false, DWORD(bitPattern: pid)) else {
        return fail(-1, GetLastError() == DWORD(ERROR_ACCESS_DENIED) ? EPERM : ESRCH)
    }
    defer { CloseHandle(process) }
    guard WaitForSingleObject(process, 0) == DWORD(WAIT_TIMEOUT) else { return fail(-1, ESRCH) }
    guard signal != 0 else { return 0 }
    return TerminateProcess(process, 1) ? 0 : fail(-1, EPERM)
}

/// The final path with links resolved, from `GetFinalPathNameByHandleW`, without the `\\?\` prefix.
/// Only the `resolved == nil` form exists; the caller frees the result.
func realpath(_ path: UnsafePointer<CChar>, _ resolved: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard resolved == nil else { return fail(nil, EINVAL) }
    guard let handle = WindowsFiles.openForInfo(String(cString: path), followLinks: true) else {
        return fail(nil, WindowsFiles.errnoFromLastError())
    }
    defer { CloseHandle(handle) }
    var buffer = [WCHAR](repeating: 0, count: 32_768)
    let length = GetFinalPathNameByHandleW(handle, &buffer, DWORD(buffer.count), DWORD(FILE_NAME_NORMALIZED | VOLUME_NAME_DOS))
    guard length > 0, Int(length) < buffer.count else { return fail(nil, WindowsFiles.errnoFromLastError()) }
    var final = String(decoding: buffer[..<Int(length)], as: UTF16.self)
    if final.hasPrefix(#"\\?\UNC\"#) { final = #"\\"# + final.dropFirst(8) } else if final.hasPrefix(#"\\?\"#) { final.removeFirst(4) }
    return _strdup(final)
}

/// Read readiness for pipes (PeekNamedPipe) and the console (a wait on its input); files are always ready.
/// A closed pipe counts as ready, so the next `read` returns 0 for end of file.
func poll(_ descriptors: UnsafeMutablePointer<pollfd>, _ count: UInt32, _ milliseconds: Int32) -> Int32 {
    let deadline = GetTickCount64() + UInt64(max(milliseconds, 0))
    while true {
        var ready: Int32 = 0
        for index in 0..<Int(count) {
            descriptors[index].revents = 0
            guard descriptors[index].events & Int16(POLLIN) != 0 else { continue }
            guard let handle = WindowsFiles.handle(descriptors[index].fd) else { return -1 }
            var available: DWORD = 0
            let isReady: Bool = switch Int32(GetFileType(handle)) {
            case FILE_TYPE_PIPE: !PeekNamedPipe(handle, nil, 0, nil, &available, nil) || available > 0
            case FILE_TYPE_CHAR: WaitForSingleObject(handle, 0) == 0 // WAIT_OBJECT_0
            default: true
            }
            if isReady {
                descriptors[index].revents = Int16(POLLIN)
                ready += 1
            }
        }
        if ready > 0 || (milliseconds >= 0 && GetTickCount64() >= deadline) { return ready }
        Sleep(5)
    }
}

/// `ReadFile` on the descriptor's handle; a broken pipe is end of file.
func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    guard let handle = WindowsFiles.handle(descriptor) else { return -1 }
    var done: DWORD = 0
    guard ReadFile(handle, buffer, DWORD(min(count, Int(Int32.max))), &done, nil) else {
        return GetLastError() == DWORD(ERROR_BROKEN_PIPE) ? 0 : fail(-1, EIO)
    }
    return Int(done)
}

/// POSIX `rename`: the UCRT one refuses an existing destination. `MoveFileExW` replaces it in one step on the same
/// volume and keeps the source's access list.
func rename(_ source: UnsafePointer<CChar>, _ destination: UnsafePointer<CChar>) -> Int32 {
    WindowsFiles.move(String(cString: source), String(cString: destination), replacing: true)
        ? 0 : fail(-1, WindowsFiles.errnoFromLastError())
}

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
