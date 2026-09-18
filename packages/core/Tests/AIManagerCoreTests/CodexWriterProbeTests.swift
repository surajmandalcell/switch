import Foundation
import XCTest
@testable import AIManagerCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class CodexWriterProbeTests: XCTestCase {
    func testHeldRuntimeLockScopesWritersAndTheirSharedTargets() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WriterProbe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "codex")
        let other = root.appending(path: "codex-other")
        let shared = root.appending(path: "shared")
        let helpers = home.appending(path: "tmp/arg0/codex-arg0-test")
        for directory in [helpers, other, shared] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let path = helpers.appending(path: ".lock")
        let fd = open(path.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardInput = handle
        try process.run()
        try handle.close()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let pids = [process.processIdentifier]

        XCTAssertEqual(CodexWriterProbe.check(home: home, pids: pids), .active)
        XCTAssertEqual(CodexWriterProbe.check(home: other, pids: pids), .inactive)
        XCTAssertEqual(CodexWriterProbe.check(home: shared, pids: pids), .inactive)

        let alias = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        XCTAssertEqual(CodexWriterProbe.check(home: alias, pids: pids), .active)
        let config = shared.appending(path: "config.toml")
        try Data("model = \"synthetic\"".utf8).write(to: config)
        try FileManager.default.createSymbolicLink(at: home.appending(path: "config.toml"), withDestinationURL: config)
        XCTAssertEqual(CodexWriterProbe.check(home: shared, pids: pids), .active)

        let unknown = Process()
        unknown.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unknown.arguments = ["30"]
        try unknown.run()
        defer { if unknown.isRunning { unknown.terminate() }; unknown.waitUntilExit() }
        XCTAssertEqual(CodexWriterProbe.check(home: other, pids: pids + [unknown.processIdentifier]), .unknown)
        XCTAssertEqual(CodexWriterProbe.check(home: home, pids: [unknown.processIdentifier] + pids), .active)

        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(CodexWriterProbe.check(home: home, pids: pids), .inactive)
        // The stale file alone does not establish a writer or require deleting it.
        XCTAssertEqual(CodexWriterProbe.check(home: home, pids: []), .inactive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testUnattributedProcessRemainsUnknown() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WriterUnknown-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        XCTAssertEqual(CodexWriterProbe.check(home: root, pids: [process.processIdentifier]), .unknown)
        XCTAssertEqual(CodexWriterProbe.check(home: root, pids: [Int32.max]), .inactive)
    }
}
