#if os(Windows)
import CRT
import Foundation
import WinSDK

// Windows file primitives behind the POSIX shapes in POSIXCompat.swift (plan units P1 to P5).
//
// Private means: the owner is the process user, and the DACL is protected (no entry inherited from the folder)
// with one entry that gives that user full control. Folders pass that entry on to new children. A private path
// that cannot be made so throws; nothing falls back to the inherited access rights of the folder.
//
// "Owner only" when checking a path that Switch did not make: no allow entry for any principal other than the
// user, the token's default owner, SYSTEM and Administrators (core-platform.md 3.1).
enum WindowsFiles {
    /// What `getuid()` returns. `lstat` and `fstat` report it as `st_uid` when the owner SID is this process's user.
    static let currentUserID: uid_t = 1000

    /// The process user SID and the default owner SID of objects this process creates.
    /// The default owner is BUILTIN\Administrators in an elevated process.
    static let identity: (user: String, defaultOwner: String)? = {
        var token: HANDLE?
        guard OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token), let token else { return nil }
        defer { CloseHandle(token) }
        func information(_ kind: TOKEN_INFORMATION_CLASS, _ read: (UnsafeMutableRawPointer) -> PSID?) -> String? {
            var size: DWORD = 0
            _ = GetTokenInformation(token, kind, nil, 0, &size)
            guard size > 0 else { return nil }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
            defer { buffer.deallocate() }
            guard GetTokenInformation(token, kind, buffer, size, &size) else { return nil }
            return sidString(read(buffer))
        }
        guard let user = information(TokenUser, { $0.load(as: TOKEN_USER.self).User.Sid }),
              let owner = information(TokenOwner, { $0.load(as: TOKEN_OWNER.self).Owner }) else { return nil }
        return (user, owner)
    }()

    private static let trustedOthers: Set<String> = ["S-1-5-18", "S-1-5-32-544"]

    static func sidString(_ sid: PSID?) -> String? {
        guard let sid else { return nil }
        var text: LPWSTR?
        guard ConvertSidToStringSidW(sid, &text), let text else { return nil }
        defer { LocalFree(text) }
        return String(decodingCString: text, as: UTF16.self)
    }

    /// Foundation hands out "/C:/x" and "C:/x"; Win32 wants "C:\x".
    static func native(_ path: String) -> String {
        var path = path
        let characters = Array(path.utf8.prefix(3))
        if characters.count == 3, characters[0] == UInt8(ascii: "/"), characters[2] == UInt8(ascii: ":") { path.removeFirst() }
        return path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Passes a native path to a Win32 call; past MAX_PATH it gets the `\\?\` form, as Foundation does.
    static func withWin32Path<T>(_ native: String, _ body: (UnsafePointer<UInt16>) -> T) -> T {
        var path = native
        if path.utf16.count >= 248, !path.hasPrefix(#"\\?\"#) {
            if path.hasPrefix(#"\\"#) { path = #"\\?\UNC\"# + path.dropFirst(2) }
            else if path.utf8.dropFirst().first == UInt8(ascii: ":") { path = #"\\?\"# + path }
        }
        return path.withCString(encodedAs: UTF16.self, body)
    }

    static func errnoFromLastError() -> Int32 {
        switch Int32(GetLastError()) {
        case ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_INVALID_NAME: ENOENT
        case ERROR_ACCESS_DENIED: EACCES
        case ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS: EEXIST
        case ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION: EBUSY
        case ERROR_INVALID_HANDLE: EBADF
        case ERROR_DIR_NOT_EMPTY: ENOTEMPTY
        default: EIO
        }
    }

    static func lastError(_ what: String, _ path: String) -> AIManagerError {
        .operationFailed("\(what) failed for \(path) (Windows error \(GetLastError())).")
    }

    // MARK: Security descriptors

    /// Runs `body` with a self-relative descriptor: owner = user, protected DACL with one inheritable full-control entry.
    static func withPrivateDescriptor<T>(_ body: (PSECURITY_DESCRIPTOR) throws -> T) throws -> T {
        guard let user = identity?.user else { throw AIManagerError.unsafePath("Could not read the Windows user.") }
        var descriptor: PSECURITY_DESCRIPTOR?
        let made = "O:\(user)D:P(A;OICI;FA;;;\(user))".withCString(encodedAs: UTF16.self) {
            ConvertStringSecurityDescriptorToSecurityDescriptorW($0, DWORD(SDDL_REVISION_1), &descriptor, nil)
        }
        guard made, let descriptor else { throw AIManagerError.unsafePath("Could not build an owner-only access list.") }
        defer { LocalFree(descriptor) }
        return try body(descriptor)
    }

    static func withPrivateAttributes<T>(_ body: (UnsafeMutablePointer<SECURITY_ATTRIBUTES>) throws -> T) throws -> T {
        try withPrivateDescriptor { descriptor in
            var attributes = SECURITY_ATTRIBUTES(
                nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: descriptor, bInheritHandle: false)
            return try body(&attributes)
        }
    }

    struct Access {
        var ownedByUser: Bool
        var ownerOnly: Bool
    }

    /// Owner and DACL of an open handle; nil when the handle lacks READ_CONTROL or the read fails.
    static func access(_ handle: HANDLE) -> Access? {
        guard let identity else { return nil }
        var owner: PSID?
        var acl: PACL?
        var descriptor: PSECURITY_DESCRIPTOR?
        let status = GetSecurityInfo(handle, SE_FILE_OBJECT,
            SECURITY_INFORMATION(OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION), &owner, nil, &acl, nil, &descriptor)
        guard status == DWORD(ERROR_SUCCESS), let descriptor else { return nil }
        defer { LocalFree(descriptor) }
        let ownerSID = sidString(owner)
        let mine: Set<String> = [identity.user, identity.defaultOwner]
        return Access(ownedByUser: ownerSID.map(mine.contains) ?? false,
                      ownerOnly: acl.map { onlyAllows(mine.union(trustedOthers), $0) } ?? false) // no DACL grants everyone
    }

    private static func onlyAllows(_ allowed: Set<String>, _ acl: PACL) -> Bool {
        var size = ACL_SIZE_INFORMATION()
        guard GetAclInformation(acl, &size, DWORD(MemoryLayout<ACL_SIZE_INFORMATION>.size), AclSizeInformation) else { return false }
        for index in 0..<size.AceCount {
            var entry: LPVOID?
            guard GetAce(acl, index, &entry), let entry else { return false }
            let header = entry.load(as: ACE_HEADER.self)
            if header.AceFlags & UInt8(INHERIT_ONLY_ACE) != 0 { continue }
            switch Int32(header.AceType) {
            case ACCESS_DENIED_ACE_TYPE: continue
            case ACCESS_ALLOWED_ACE_TYPE:
                // ACCESS_ALLOWED_ACE: header, mask, then the SID.
                let sid = entry.advanced(by: MemoryLayout<ACE_HEADER>.size + MemoryLayout<ACCESS_MASK>.size)
                guard let text = sidString(sid), allowed.contains(text) else { return false }
            default:
                return false
            }
        }
        return true
    }

    /// Sets the owner-only protected DACL on an open handle that has WRITE_DAC. The owner is left as is.
    static func makePrivate(handle: HANDLE) -> Bool {
        (try? withPrivateDescriptor { descriptor -> Bool in
            var present: WindowsBool = false
            var defaulted: WindowsBool = false
            var acl: PACL?
            guard GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted), let acl else { return false }
            return SetSecurityInfo(handle, SE_FILE_OBJECT,
                DWORD(DACL_SECURITY_INFORMATION) | DWORD(PROTECTED_DACL_SECURITY_INFORMATION),
                nil, nil, acl, nil) == DWORD(ERROR_SUCCESS)
        }) ?? false
    }

    /// Makes an existing file or folder private, then checks the result. Refuses links and foreign owners.
    static func makePrivate(path: String) throws {
        let native = native(path)
        guard let handle = openHandle(native, access: DWORD(READ_CONTROL | WRITE_DAC | FILE_READ_ATTRIBUTES), followLinks: false) else {
            throw lastError("Opening for an access change", path)
        }
        defer { CloseHandle(handle) }
        var info = stat()
        guard fill(handle, &info), info.st_mode & S_IFMT != S_IFLNK else {
            throw AIManagerError.unsafePath("private path is a link: \(path)")
        }
        guard info.st_uid == currentUserID else { throw AIManagerError.unsafePath("private path has another owner: \(path)") }
        guard makePrivate(handle: handle), access(handle)?.ownerOnly == true else {
            throw AIManagerError.unsafePath("Could not make \(path) owner-only.")
        }
    }

    // MARK: Handles and stat

    static func openHandle(_ native: String, access: DWORD, followLinks: Bool, disposition: DWORD = DWORD(OPEN_EXISTING),
                           attributes: UnsafeMutablePointer<SECURITY_ATTRIBUTES>? = nil) -> HANDLE? {
        let flags = DWORD(FILE_ATTRIBUTE_NORMAL) | DWORD(FILE_FLAG_BACKUP_SEMANTICS) | (followLinks ? 0 : DWORD(FILE_FLAG_OPEN_REPARSE_POINT))
        let handle = withWin32Path(native) {
            CreateFileW($0, access, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), attributes, disposition, flags, nil)
        }
        return handle == INVALID_HANDLE_VALUE ? nil : handle
    }

    /// Opens for metadata. Falls back to no READ_CONTROL, which reports the file as foreign and shared.
    static func openForInfo(_ path: String, followLinks: Bool) -> HANDLE? {
        let native = native(path)
        if let handle = openHandle(native, access: DWORD(READ_CONTROL | FILE_READ_ATTRIBUTES), followLinks: followLinks) { return handle }
        guard GetLastError() == DWORD(ERROR_ACCESS_DENIED) else { return nil }
        return openHandle(native, access: DWORD(FILE_READ_ATTRIBUTES), followLinks: followLinks)
    }

    /// Name surrogates are symbolic links, junctions and mount points. Other reparse points (cloud files) are data.
    static func isLink(_ handle: HANDLE, attributes: DWORD) -> Bool {
        guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 else { return false }
        var tag = FILE_ATTRIBUTE_TAG_INFO()
        guard GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &tag, DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)) else {
            return true // unknown reparse point: treat as a link so every link check refuses it
        }
        return tag.ReparseTag & 0x2000_0000 != 0
    }

    static func fill(_ handle: HANDLE, _ info: UnsafeMutablePointer<stat>) -> Bool {
        var file = BY_HANDLE_FILE_INFORMATION()
        var basic = FILE_BASIC_INFO()
        guard GetFileInformationByHandle(handle, &file),
              GetFileInformationByHandleEx(handle, FileBasicInfo, &basic, DWORD(MemoryLayout<FILE_BASIC_INFO>.size)) else {
            errno = errnoFromLastError()
            return false
        }
        let directory = file.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
        let access = access(handle)
        var result = stat()
        result.st_mode = isLink(handle, attributes: file.dwFileAttributes) ? S_IFLNK : directory ? S_IFDIR : S_IFREG
        // Mode bits only say "owner only" or not; they are what the 0o077 checks at the call sites read.
        result.st_mode |= access?.ownerOnly == true ? (directory ? 0o700 : 0o600) : (directory ? 0o777 : 0o666)
        result.st_uid = access?.ownedByUser == true ? currentUserID : 0xFFFF_FFFF
        result.st_dev = UInt64(file.dwVolumeSerialNumber)
        result.st_ino = UInt64(file.nFileIndexHigh) << 32 | UInt64(file.nFileIndexLow)
        result.st_nlink = file.nNumberOfLinks
        result.st_size = Int64(file.nFileSizeHigh) << 32 | Int64(file.nFileSizeLow)
        result.st_atim = timespec(windowsTime: basic.LastAccessTime.QuadPart)
        result.st_mtim = timespec(windowsTime: basic.LastWriteTime.QuadPart)
        result.st_ctim = timespec(windowsTime: basic.ChangeTime.QuadPart) // change time, not creation time
        info.pointee = result
        return true
    }

    static func handle(_ descriptor: Int32) -> HANDLE? {
        let raw = _get_osfhandle(descriptor)
        guard raw != -1, let handle = HANDLE(bitPattern: raw) else {
            errno = EBADF
            return nil
        }
        return handle
    }

    // MARK: Private folders and files

    /// Creates missing folders owner-only from the top down and makes the leaf owner-only.
    static func privateDirectory(_ url: URL) throws {
        let path = native(url.path)
        var missing: [String] = []
        var cursor = path
        while withWin32Path(cursor, { GetFileAttributesW($0) }) == DWORD.max { // INVALID_FILE_ATTRIBUTES
            missing.insert(cursor, at: 0)
            let parent = (cursor as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent.count < cursor.count else { break }
            cursor = parent
        }
        for folder in missing {
            let made = try withPrivateAttributes { attributes in
                withWin32Path(folder) { CreateDirectoryW($0, attributes) }
            }
            guard made || GetLastError() == DWORD(ERROR_ALREADY_EXISTS) else { throw lastError("Creating a private folder", folder) }
        }
        guard let handle = openForInfo(path, followLinks: false) else { throw lastError("Opening a private folder", path) }
        var info = stat()
        let filled = fill(handle, &info)
        CloseHandle(handle)
        guard filled, info.st_mode & S_IFMT == S_IFDIR else {
            throw AIManagerError.unsafePath("private path is not a directory: \(url.path)")
        }
        if missing.isEmpty || info.st_mode & 0o077 != 0 { try makePrivate(path: path) } // like chmod 700 on an existing folder
    }

    /// Creates `url` as a new empty owner-only file. Fails when anything is already there.
    static func createPrivateFile(_ url: URL) throws -> HANDLE {
        let path = native(url.path)
        let handle = try withPrivateAttributes { attributes in
            openHandle(path, access: DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE) | DWORD(WRITE_DAC), followLinks: false,
                       disposition: DWORD(CREATE_NEW), attributes: attributes)
        }
        guard let handle else { throw lastError("Creating a private file", url.path) }
        guard access(handle)?.ownerOnly == true else {
            CloseHandle(handle)
            _ = withWin32Path(path) { DeleteFileW($0) }
            throw AIManagerError.unsafePath("A new file did not come out owner-only: \(url.path)")
        }
        return handle
    }

    static func createEmptyPrivateFile(_ url: URL) throws {
        CloseHandle(try createPrivateFile(url))
    }

    /// Writes an owner-only temporary next to `destination` and moves it over the destination.
    /// MoveFileExW keeps the temporary's access list; ReplaceFileW would merge in the old file's.
    static func writePrivate(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let handle = try createPrivateFile(temporary)
        var ok = true
        data.withUnsafeBytes { bytes in
            var offset = 0
            while ok, offset < bytes.count {
                var written: DWORD = 0
                let chunk = DWORD(min(bytes.count - offset, 1 << 24))
                ok = WriteFile(handle, bytes.baseAddress! + offset, chunk, &written, nil) && written > 0
                offset += Int(written)
            }
        }
        ok = ok && FlushFileBuffers(handle)
        CloseHandle(handle)
        guard ok, rename(temporary.path, destination.path) == 0 else {
            let failure = lastError("Writing a private file", destination.path)
            _ = withWin32Path(native(temporary.path)) { DeleteFileW($0) }
            throw failure
        }
    }

    /// POSIX `rename`: replaces an existing file in one step on the same volume.
    static func move(_ source: String, _ destination: String, replacing: Bool) -> Bool {
        let flags = DWORD(MOVEFILE_WRITE_THROUGH) | (replacing ? DWORD(MOVEFILE_REPLACE_EXISTING) : 0)
        return withWin32Path(native(source)) { from in
            withWin32Path(native(destination)) { to in MoveFileExW(from, to, flags) }
        }
    }

    // MARK: Swap

    /// Windows has no exchange rename. The old `second` moves to a fixed aside name, `first` moves in, and the
    /// aside moves to `first`. A crash after step one leaves `second` missing; the next swap of the same path puts
    /// the aside back first. Any other leftover aside stops the swap.
    static func exchange(_ first: URL, _ second: URL) throws {
        let aside = second.deletingLastPathComponent().appending(path: ".\(second.lastPathComponent).switch-swap").path
        if CoreSupport.entryExists(URL(fileURLWithPath: aside)) {
            guard !CoreSupport.entryExists(second), move(aside, second.path, replacing: false) else {
                throw AIManagerError.unsafePath("An earlier swap of \(second.path) did not finish; \(aside) is still there.")
            }
        }
        guard CoreSupport.entryExists(first), CoreSupport.entryExists(second) else {
            errno = ENOENT
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        guard move(second.path, aside, replacing: false) else { throw lastError("Swap step 1", second.path) }
        guard move(first.path, second.path, replacing: false) else {
            let failure = lastError("Swap step 2", first.path)
            _ = move(aside, second.path, replacing: false)
            throw failure
        }
        guard move(aside, first.path, replacing: false) else {
            let failure = lastError("Swap step 3", aside)
            if move(second.path, first.path, replacing: false) { _ = move(aside, second.path, replacing: false) }
            throw failure
        }
    }

    /// A descriptor that owns a duplicate of `handle`, for POSIX-shaped readers; close it with `_close`.
    /// `FileHandle.fileDescriptor` does not exist on Windows.
    static func descriptor(duplicating handle: HANDLE) -> Int32 {
        var copy: HANDLE?
        let process = GetCurrentProcess()
        guard DuplicateHandle(process, handle, process, &copy, 0, false, DWORD(DUPLICATE_SAME_ACCESS)), let copy else { return -1 }
        let descriptor = _open_osfhandle(Int(bitPattern: copy), _O_RDONLY | _O_BINARY)
        if descriptor < 0 { CloseHandle(copy) }
        return descriptor
    }

    // MARK: Times

    static func setTimes(_ handle: HANDLE, access: timespec, modified: timespec) -> Bool {
        var access = filetime(access)
        var modified = filetime(modified)
        return SetFileTime(handle, nil, &access, &modified)
    }

    static func filetime(_ time: timespec) -> FILETIME {
        let ticks = UInt64(Int64(time.tv_sec) * 10_000_000 + Int64(time.tv_nsec) / 100 + 116_444_736_000_000_000)
        return FILETIME(dwLowDateTime: DWORD(ticks & 0xFFFF_FFFF), dwHighDateTime: DWORD(ticks >> 32))
    }
}

extension timespec {
    /// 100 ns ticks since 1601 to seconds and nanoseconds since 1970.
    init(windowsTime ticks: Int64) {
        let unix = ticks - 116_444_736_000_000_000
        let seconds = unix >= 0 ? unix / 10_000_000 : (unix - 9_999_999) / 10_000_000
        self.init(tv_sec: time_t(seconds), tv_nsec: Int32((unix - seconds * 10_000_000) * 100))
    }
}
#endif
