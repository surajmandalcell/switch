import Foundation
import XCTest
@testable import SwitchRPC

/// `logs/helper.log`: the age limit at start and the two-file size cap.
final class HelperLogTests: XCTestCase {
    func testDropsOldLinesAndRotatesAtTheCap() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "HelperLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "logs/helper.log")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var log = try HelperLog(url: url, now: now.addingTimeInterval(-20 * 86_400))
        log.write("rpc old id=1 1ms ok", now: now.addingTimeInterval(-20 * 86_400))
        log.write("rpc new id=2 1ms ok", now: now.addingTimeInterval(-86_400))
        log = try HelperLog(url: url, now: now)
        var text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("rpc old"), "lines past 14 days are dropped")
        XCTAssertTrue(text.contains("rpc new"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int, 0o600)

        let line = String(repeating: "x", count: 1_000)
        for _ in 0..<(HelperLog.maximumBytes / 1_000 + 10) { log.write(line, now: now) }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? Int ?? 0
        XCTAssertLessThan(size, HelperLog.maximumBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.rotated.path))
        text = try String(contentsOf: log.rotated, encoding: .utf8)
        XCTAssertTrue(text.contains("rpc new"), "the full file became helper.log.1")

        // A rotated file older than 14 days is deleted at start.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-15 * 86_400)],
                                              ofItemAtPath: log.rotated.path)
        _ = try HelperLog(url: url, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.rotated.path))
    }
}
