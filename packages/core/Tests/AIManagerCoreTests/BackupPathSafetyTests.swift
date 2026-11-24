import Foundation
import XCTest
@testable import AIManagerCore

final class BackupPathSafetyTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var set: BackupSet!
    private var engine: BackupEngine!

    override func setUpWithError() throws {
        root = testTemporaryDirectory.appending(path: UUID().uuidString).resolvingSymlinksInPath()
        let paths = ManagerPaths.environment(["AI_MANAGER_ROOT": root.path])
        let home = paths.defaultHome
        let destination = root.appending(path: "backups")
        try fm.createDirectory(at: home.appending(path: "sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: home.appending(path: "sessions/one"))
        set = BackupSet(name: "test", source: .init(id: "test", service: .codex, home: home),
                        items: [BackupItem("sessions")], destination: destination)
        engine = BackupEngine(applicationSupport: paths.applicationSupport)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    func testUnsafeSelectionsAndManifestEntriesAreRejectedBeforeRestore() async throws {
        let snapshot = try await engine.snapshot(set)
        let destination = root.appending(path: "restore")
        let manifest = snapshot.folder.appending(path: BackupEngine.manifestName)
        var invalid = ["../x", "a/../../x", "/x", "a//x"]
#if os(Windows)
        invalid += [#"..\x"#, #"C:\x"#, #"\\server\x"#, #"a\..\..\x"#, #"\x"#, #"a\c:relative"#]
#endif
        for path in invalid {
            do {
                _ = try await engine.restore(snapshot, set: set, items: [path], to: destination)
                XCTFail("Accepted selection \(path)")
            } catch BackupError.unsafe {}
        }
        for path in invalid {
            var changed = snapshot.manifest
            changed.entries[0].path = path
            try JSONEncoder().encode(changed).write(to: manifest)
            do {
                _ = try await engine.restore(snapshot, set: set, to: destination)
                XCTFail("Accepted manifest entry \(path)")
            } catch BackupError.unsafe {}
        }
        XCTAssertFalse(CoreSupport.entryExists(destination))
    }

    func testResolvedRestoreTargetStaysInChosenRoot() async throws {
        let snapshot = try await engine.snapshot(set)
        let destination = root.appending(path: "restore")
        let outside = root.appending(path: "restore-other")
        for folder in [destination, outside] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Links.create(at: destination.appending(path: "sessions"), to: outside, fileManager: fm)
        do {
            _ = try await engine.restore(snapshot, set: set, to: destination)
            XCTFail("Accepted a target outside the chosen root")
        } catch BackupError.unsafe {}
        XCTAssertFalse(CoreSupport.entryExists(outside.appending(path: "one")))
    }

    func testSelectionAndContainmentUseHostPathRules() async throws {
        let snapshot = try await engine.snapshot(set)
        let destination = root.appending(path: "restore")
        let result = try await engine.restore(snapshot, set: set, items: [#"SESSIONS\one"#], to: destination)
#if os(Windows)
        XCTAssertTrue(CoreSupport.isContained(root.appending(path: "RESTORE/child"), by: destination))
        XCTAssertEqual(result.restored, 1)
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "sessions/one")), Data("synthetic".utf8))
#else
        XCTAssertEqual(result.restored, 0)
#endif
        XCTAssertFalse(CoreSupport.isContained(root.appending(path: "restore-other"), by: destination))
    }
}
