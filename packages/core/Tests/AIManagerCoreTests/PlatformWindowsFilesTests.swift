#if os(Windows)
import CRT
import CSQLite
import Foundation
import WinSDK
import XCTest
@testable import AIManagerCore

/// Proves the Windows file primitives behind the POSIX shims on a real NTFS volume.
final class PlatformWindowsFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "switch-platform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func info(_ url: URL) -> AIManagerCore.stat? {
        var result = AIManagerCore.stat()
        return AIManagerCore.lstat(url.path, &result) == 0 ? result : nil
    }

    /// Reads the raw DACL: protected, and every allow entry is the process user.
    private func onlyUserEntries(_ url: URL) throws -> Bool {
        var acl: PACL?
        var descriptor: PSECURITY_DESCRIPTOR?
        let status = WindowsFiles.native(url.path).withCString(encodedAs: UTF16.self) {
            GetNamedSecurityInfoW($0, SE_FILE_OBJECT, DWORD(DACL_SECURITY_INFORMATION), nil, nil, &acl, nil, &descriptor)
        }
        XCTAssertEqual(status, DWORD(ERROR_SUCCESS))
        defer { LocalFree(descriptor) }
        var control: SECURITY_DESCRIPTOR_CONTROL = 0
        var revision: DWORD = 0
        XCTAssertTrue(GetSecurityDescriptorControl(descriptor, &control, &revision))
        guard control & SECURITY_DESCRIPTOR_CONTROL(SE_DACL_PROTECTED) != 0, let acl else { return false }
        var size = ACL_SIZE_INFORMATION()
        XCTAssertTrue(GetAclInformation(acl, &size, DWORD(MemoryLayout<ACL_SIZE_INFORMATION>.size), AclSizeInformation))
        for index in 0..<size.AceCount {
            var entry: LPVOID?
            XCTAssertTrue(GetAce(acl, index, &entry))
            let header = entry!.load(as: ACE_HEADER.self)
            guard Int32(header.AceType) == ACCESS_ALLOWED_ACE_TYPE else { return false }
            let sid = entry!.advanced(by: MemoryLayout<ACE_HEADER>.size + MemoryLayout<ACCESS_MASK>.size)
            guard WindowsFiles.sidString(sid) == WindowsFiles.identity?.user else { return false }
        }
        return size.AceCount > 0
    }

    func testPrivateDirectoryAndWriteAreOwnerOnlyWithNoInheritedEntries() throws {
        let folder = root.appending(path: "a/b")
        try CoreSupport.privateDirectory(folder, fileManager: .default)
        let file = folder.appending(path: "auth.json")
        try CoreSupport.atomicWrite(Data("{\"token\":\"synthetic\"}".utf8), to: file, fileManager: .default)
        try CoreSupport.atomicWrite(Data("{\"token\":\"second\"}".utf8), to: file, fileManager: .default)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\"token\":\"second\"}")
        for url in [root.appending(path: "a"), folder, file] {
            XCTAssertTrue(try onlyUserEntries(url), url.path)
            let mode = try XCTUnwrap(info(url)).st_mode
            XCTAssertEqual(mode & 0o077, 0, url.path)
            XCTAssertEqual(try XCTUnwrap(info(url)).st_uid, AIManagerCore.getuid())
        }
        XCTAssertEqual(try XCTUnwrap(info(file)).st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(try XCTUnwrap(info(file)).st_nlink, 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testPrivateWritePastMaxPath() throws {
        let folder = root.appending(path: String(repeating: "deep-folder-name/", count: 16))
        let file = folder.appending(path: "auth.json")
        XCTAssertGreaterThan(file.path.utf16.count, 300)
        try CoreSupport.atomicWrite(Data("{}".utf8), to: file, fileManager: .default)
        XCTAssertEqual(try XCTUnwrap(info(file)).st_mode & 0o077, 0)
        try CoreSupport.atomicWrite(Data("[]".utf8), to: file, fileManager: .default)
        XCTAssertEqual(try Data(contentsOf: file), Data("[]".utf8))
    }

    func testExistingSharedFolderIsMadePrivate() throws {
        let folder = root.appending(path: "shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertFalse(try onlyUserEntries(folder)) // inherited from the temporary folder
        try CoreSupport.privateDirectory(folder, fileManager: .default)
        XCTAssertTrue(try onlyUserEntries(folder))
    }

    func testOperationLockFileIsOwnerOnly() throws {
        let lock = root.appending(path: "op.lock")
        _ = try OperationLock(at: lock, fileManager: .default)
        XCTAssertTrue(try onlyUserEntries(lock))
    }

    func testOpenCreatesOwnerOnlyAndRefusesLinks() throws {
        let file = root.appending(path: "new.bin")
        let descriptor = AIManagerCore.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var opened = AIManagerCore.stat()
        XCTAssertEqual(AIManagerCore.fstat(descriptor, &opened), 0)
        XCTAssertEqual(opened.st_mode & 0o077, 0)
        _close(descriptor)
        XCTAssertTrue(try onlyUserEntries(file))
        XCTAssertEqual(AIManagerCore.open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600), -1)
        XCTAssertEqual(errno, EEXIST)

        let target = root.appending(path: "target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let junction = root.appending(path: "junction")
        XCTAssertEqual(try runJunction(junction, target), 0)
        XCTAssertEqual(try XCTUnwrap(info(junction)).st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(AIManagerCore.open(junction.path, O_RDONLY | O_NOFOLLOW), -1)
        XCTAssertEqual(errno, ELOOP)
        XCTAssertThrowsError(try CoreSupport.privateDirectory(junction, fileManager: .default))
        let resolved = try XCTUnwrap(AIManagerCore.realpath(junction.path, nil))
        defer { free(resolved) }
        XCTAssertEqual(URL(fileURLWithPath: String(cString: resolved)).lastPathComponent, "target")
    }

    private func runJunction(_ link: URL, _ target: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        process.arguments = ["/c", "mklink", "/J", WindowsFiles.native(link.path), WindowsFiles.native(target.path)]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testRenameReplacesAndExchangeSwapsFoldersAndFiles() throws {
        let first = root.appending(path: "staged")
        let second = root.appending(path: "live")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: first.appending(path: "id"))
        try Data("old".utf8).write(to: second.appending(path: "id"))
        try CoreSupport.exchange(first, second)
        XCTAssertEqual(try String(contentsOf: second.appending(path: "id"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: first.appending(path: "id"), encoding: .utf8), "old")

        // A swap that stopped after step one leaves `live` missing; the next swap restores it first.
        try FileManager.default.moveItem(at: second, to: root.appending(path: ".live.switch-swap"))
        try CoreSupport.exchange(first, second)
        XCTAssertEqual(try String(contentsOf: second.appending(path: "id"), encoding: .utf8), "old")
        XCTAssertFalse(CoreSupport.entryExists(root.appending(path: ".live.switch-swap")))

        let a = root.appending(path: "a.txt")
        let b = root.appending(path: "b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        XCTAssertEqual(AIManagerCore.rename(a.path, b.path), 0)
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "a")
    }

    func testFlockConflictsAcrossDescriptors() throws {
        let lock = root.appending(path: "lock")
        let first = AIManagerCore.open(lock.path, O_CREAT | O_RDWR, 0o600)
        let second = AIManagerCore.open(lock.path, O_RDWR)
        defer { _close(first); _close(second) }
        XCTAssertEqual(AIManagerCore.flock(first, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(AIManagerCore.flock(second, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(AIManagerCore.flock(first, LOCK_UN), 0)
        XCTAssertEqual(AIManagerCore.flock(second, LOCK_EX | LOCK_NB), 0)
    }

    func testOperationLockRejectsSecondHolder() throws {
        let url = root.appending(path: "state/manager.lock")
        let one = try OperationLock(at: url, fileManager: .default)
        let two = try OperationLock(at: url, fileManager: .default)
        try one.withLock {
            XCTAssertThrowsError(try two.withLock {})
        }
        XCTAssertNoThrow(try two.withLock {})
    }

    func testKillProbesAndStopsAProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\ping.exe")
        process.arguments = ["-n", "30", "127.0.0.1"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        XCTAssertEqual(AIManagerCore.kill(process.processIdentifier, 0), 0)
        XCTAssertEqual(AIManagerCore.kill(process.processIdentifier, SIGKILL), 0)
        process.waitUntilExit()
        XCTAssertEqual(AIManagerCore.kill(process.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testPollAndReadFollowAPipeToEndOfFile() throws {
        let pipe = Pipe()
        let descriptor = WindowsFiles.descriptor(duplicating: pipe.fileHandleForReading._handle)
        defer { _close(descriptor) }
        var state = AIManagerCore.pollfd(fd: descriptor, events: Int16(AIManagerCore.POLLIN), revents: 0)
        XCTAssertEqual(AIManagerCore.poll(&state, 1, 20), 0)
        try pipe.fileHandleForWriting.write(contentsOf: Data("line\n".utf8))
        XCTAssertEqual(AIManagerCore.poll(&state, 1, 1_000), 1)
        var bytes = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(AIManagerCore.read(descriptor, &bytes, bytes.count), 5)
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(AIManagerCore.poll(&state, 1, 1_000), 1)
        XCTAssertEqual(AIManagerCore.read(descriptor, &bytes, bytes.count), 0)
    }

    func testDatabaseSnapshotIsOwnerOnly() throws {
        let source = root.appending(path: "source.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE t(x); INSERT INTO t VALUES (1);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let destination = root.appending(path: "copy/snapshot.sqlite")
        try SQLiteSupport.snapshot(source: source, destination: destination)
        XCTAssertTrue(try onlyUserEntries(destination))
    }
}
#endif
