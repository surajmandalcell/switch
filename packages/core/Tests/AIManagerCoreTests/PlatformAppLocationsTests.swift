import Foundation
import XCTest
@testable import AIManagerCore

/// The one-time Linux data folder move (architecture.md section 5), in a temporary folder.
final class PlatformAppLocationsTests: XCTestCase {
    var root: URL!
    var old: URL { root.appending(path: "AI Manager") }
    var new: URL { root.appending(path: "switch") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AppLocations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func write(_ folder: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appending(path: "registry.json"))
    }

    private func registry(_ folder: URL) -> String? {
        try? String(contentsOf: folder.appending(path: "registry.json"), encoding: .utf8)
    }

    func testOldOnlyMovesOnceWithMarker() throws {
        try write(old, "old")
        XCTAssertNil(try AppLocations.migrateDataRoot(from: old, to: new))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(registry(new), "old")
        XCTAssertEqual(try String(contentsOf: new.appending(path: "migrated-from"), encoding: .utf8), old.path)
        // A second start finds only the new folder and does nothing.
        XCTAssertNil(try AppLocations.migrateDataRoot(from: old, to: new))
        XCTAssertEqual(registry(new), "old")
    }

    func testNewOnlyAndNeitherDoNothing() throws {
        XCTAssertNil(try AppLocations.migrateDataRoot(from: old, to: new))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path), "nothing is created")
        try write(new, "new")
        XCTAssertNil(try AppLocations.migrateDataRoot(from: old, to: new))
        XCTAssertEqual(registry(new), "new")
    }

    func testBothExistNeverMerges() throws {
        try write(old, "old")
        try write(new, "new")
        let notice = try XCTUnwrap(try AppLocations.migrateDataRoot(from: old, to: new))
        XCTAssertTrue(notice.contains(old.path) && notice.contains(new.path), notice)
        XCTAssertEqual(registry(old), "old")
        XCTAssertEqual(registry(new), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.appending(path: "migrated-from").path))
    }

    func testCrashBetweenMarkerAndRenameFinishesNextStart() throws {
        // The marker was written, then the process died before the rename.
        try write(old, "old")
        try Data(old.path.utf8).write(to: old.appending(path: "migrated-from"))
        XCTAssertNil(try AppLocations.migrateDataRoot(from: old, to: new))
        XCTAssertEqual(registry(new), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testAnotherProcessHoldingTheOldLockStopsTheMove() throws {
        try write(old, "old")
        let held = try XCTUnwrap(try FileLock(at: old.appending(path: "manager.lock")))
        XCTAssertThrowsError(try AppLocations.migrateDataRoot(from: old, to: new))
        XCTAssertEqual(registry(old), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        withExtendedLifetime(held) {}
        XCTAssertNil(try FileLock(at: old.appending(path: "manager.lock")), "a lock is held while its object lives")
    }

    func testFileLockReleasesWithItsObject() throws {
        let url = root.appending(path: "helper.lock")
        var first = try FileLock(at: url)
        XCTAssertNotNil(first)
        XCTAssertNil(try FileLock(at: url))
        first = nil
        XCTAssertNotNil(try FileLock(at: url))
        _ = first
    }
}
