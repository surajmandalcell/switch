#if os(Windows)
import Foundation
import WinSDK

/// Reads other processes on Windows: the process list (Toolhelp snapshot), each command line, and the environment.
/// A process this user may not read (another user's, a protected one, a 32-bit one) is skipped, never guessed.
enum WindowsProcesses {
    private typealias QueryInformation = @convention(c) (HANDLE?, Int32, UnsafeMutableRawPointer?, ULONG, UnsafeMutablePointer<ULONG>?) -> LONG
    private static let query: QueryInformation? = {
        guard let ntdll = "ntdll.dll".withCString(encodedAs: UTF16.self, { GetModuleHandleW($0) }),
              let address = GetProcAddress(ntdll, "NtQueryInformationProcess") else { return nil }
        return unsafeBitCast(address, to: QueryInformation.self)
    }()
    private static let basicInformation: Int32 = 0 // ProcessBasicInformation
    private static let commandLineInformation: Int32 = 60 // ProcessCommandLineInformation, Windows 8.1 and later

    /// Every process id with its command line split into arguments; unreadable processes are left out.
    static func list() -> [(pid: Int32, argv: [String])] {
        (snapshot() ?? []).compactMap { entry in arguments(pid: entry.pid).map { (entry.pid, $0) } }
    }

    /// Every process id with its program file name ("codex.exe"), from a Toolhelp snapshot. Nil when no snapshot.
    static func snapshot() -> [(pid: Int32, name: String)]? {
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard let snapshot, snapshot != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(snapshot) }
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var result: [(Int32, String)] = []
        var more = Process32FirstW(snapshot, &entry)
        while more {
            let pid = Int32(bitPattern: entry.th32ProcessID)
            let name = withUnsafeBytes(of: entry.szExeFile) { String(decodingCString: $0.bindMemory(to: UInt16.self).baseAddress!, as: UTF16.self) }
            if pid > 0 { result.append((pid, name)) }
            more = Process32NextW(snapshot, &entry)
        }
        return result
    }

    /// Paths of the files and folders `pid` holds open, from the system handle table.
    /// Throws when the process cannot be read, so a caller treats its writes as unknown.
    static func openPaths(pid: Int32) throws -> [URL] {
        guard let system = systemQuery,
              let process = OpenProcess(DWORD(PROCESS_DUP_HANDLE), false, DWORD(pid)) else { throw AIManagerError.writerStateUnknown }
        defer { CloseHandle(process) }
        // SYSTEM_HANDLE_INFORMATION_EX: count at 0, entries from 16, 40 bytes each:
        // object 0, process id 8, handle value 16, access 24, back trace 28, type 30, attributes 32.
        var size = 1 << 20
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        var status = system(64, buffer, ULONG(size), nil) // SystemExtendedHandleInformation
        while status == Int32(bitPattern: 0xC000_0004), size < 1 << 28 { // STATUS_INFO_LENGTH_MISMATCH
            buffer.deallocate()
            size *= 2
            buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            status = system(64, buffer, ULONG(size), nil)
        }
        guard status >= 0 else { throw AIManagerError.writerStateUnknown }
        let count = min(Int(buffer.load(as: UInt.self)), (size - 16) / 40)
        let current = GetCurrentProcess()
        var paths: [URL] = []
        for index in 0..<count {
            let entry = buffer + 16 + index * 40
            guard entry.load(fromByteOffset: 8, as: UInt.self) == UInt(pid) else { continue }
            var copy: HANDLE?
            guard DuplicateHandle(process, HANDLE(bitPattern: entry.load(fromByteOffset: 16, as: UInt.self)), current, &copy,
                                  0, false, DWORD(DUPLICATE_SAME_ACCESS)), let copy else { continue }
            defer { CloseHandle(copy) }
            // Only disk files and folders: asking a pipe or device for its name can block.
            guard GetFileType(copy) == DWORD(FILE_TYPE_DISK) else { continue }
            var name = [UInt16](repeating: 0, count: 32_768)
            let length = GetFinalPathNameByHandleW(copy, &name, DWORD(name.count), 0)
            guard length > 0, Int(length) < name.count else { continue }
            var path = String(decoding: name.prefix(Int(length)), as: UTF16.self)
            if path.hasPrefix(#"\\?\UNC\"#) { path = #"\\"# + path.dropFirst(8) }
            else if path.hasPrefix(#"\\?\"#) { path.removeFirst(4) }
            paths.append(URL(fileURLWithPath: path))
        }
        return paths
    }

    private typealias SystemQuery = @convention(c) (Int32, UnsafeMutableRawPointer?, ULONG, UnsafeMutablePointer<ULONG>?) -> LONG
    private static let systemQuery: SystemQuery? = {
        guard let ntdll = "ntdll.dll".withCString(encodedAs: UTF16.self, { GetModuleHandleW($0) }),
              let address = GetProcAddress(ntdll, "NtQuerySystemInformation") else { return nil }
        return unsafeBitCast(address, to: SystemQuery.self)
    }()

    /// The process's command line split the way the C runtime splits it, or nil when it is gone or unreadable.
    static func arguments(pid: Int32) -> [String]? {
        guard pid > 0, let query,
              let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return nil }
        defer { CloseHandle(process) }
        var exitCode: DWORD = 0
        guard GetExitCodeProcess(process, &exitCode), exitCode == 259 /* STILL_ACTIVE */ else { return nil }
        var needed: ULONG = 0
        _ = query(process, commandLineInformation, nil, 0, &needed)
        guard needed > 0, needed < 1 << 20 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(needed), alignment: 8)
        defer { buffer.deallocate() }
        guard query(process, commandLineInformation, buffer, needed, &needed) >= 0 else { return nil }
        // UNICODE_STRING: Length (bytes) at 0, Buffer pointer at 8; the text follows in the same buffer.
        let length = Int(buffer.load(as: UInt16.self)) / 2
        guard let text = buffer.load(fromByteOffset: 8, as: UnsafePointer<UInt16>?.self) else { return [] }
        let line = Array(UnsafeBufferPointer(start: text, count: length)) + [0]
        var count: Int32 = 0
        guard let parts = CommandLineToArgvW(line, &count) else { return nil }
        defer { LocalFree(parts) }
        return (0..<Int(count)).compactMap { parts[$0].map { String(decodingCString: $0, as: UTF16.self) } }
    }

    /// The process's environment as `NAME=value` strings, read from its process parameters.
    /// Only 64-bit processes; nil when the process is gone, unreadable, or 32-bit.
    static func environment(pid: Int32) -> [String]? {
        guard pid > 0, let query else { return nil }
        let access = DWORD(PROCESS_QUERY_INFORMATION) | DWORD(PROCESS_VM_READ)
        guard let process = OpenProcess(access, false, DWORD(pid)) else { return nil }
        defer { CloseHandle(process) }
        var wow64: WindowsBool = false
        guard IsWow64Process(process, &wow64), !wow64.boolValue else { return nil }
        // PROCESS_BASIC_INFORMATION: PebBaseAddress at 8. PEB: ProcessParameters at 0x20.
        // RTL_USER_PROCESS_PARAMETERS: Environment at 0x80, EnvironmentSize at 0x3F0.
        var basic = [UInt64](repeating: 0, count: 6)
        guard basic.withUnsafeMutableBytes({ query(process, basicInformation, $0.baseAddress, ULONG($0.count), nil) }) >= 0
        else { return nil }
        func read(_ address: UInt64, _ count: Int) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: count)
            var done: SIZE_T = 0
            let ok = bytes.withUnsafeMutableBytes {
                ReadProcessMemory(process, UnsafeRawPointer(bitPattern: UInt(address)), $0.baseAddress, SIZE_T(count), &done)
            }
            return ok && done == SIZE_T(count) ? bytes : nil
        }
        func word(_ address: UInt64) -> UInt64? {
            read(address, 8).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
        }
        guard basic[1] != 0, let parameters = word(basic[1] + 0x20), parameters != 0,
              let block = word(parameters + 0x80), block != 0, let size = word(parameters + 0x3F0),
              size > 0, size < 1 << 22, let bytes = read(block, Int(size)) else { return nil }
        let units = bytes.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        return units.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF16.self) }
    }
}
#endif
