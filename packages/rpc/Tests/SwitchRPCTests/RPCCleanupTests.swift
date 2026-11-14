import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchRPC

/// Cleanup over the protocol: scan, review, apply to the trash, restore, and purge with a confirmation.
extension RPCRuntimeTests {
    func testCleanupScanReviewTrashRestoreAndPurge() async throws {
        let files = FileManager.default
        let releases = paths.sharedRoot.appending(path: "packages/standalone/releases")
        for (index, name) in ["0.1", "0.2", "0.3", "0.4"].enumerated() {
            let bin = releases.appending(path: "\(name)/bin")
            try CoreSupport.atomicWrite(Data("synthetic \(name)".utf8), to: bin, fileManager: files)
            let old = [FileAttributeKey.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 1_000)]
            try files.setAttributes(old, ofItemAtPath: bin.path)
            try files.setAttributes(old, ofItemAtPath: bin.deletingLastPathComponent().path)
        }
        try files.createSymbolicLink(at: paths.sharedRoot.appending(path: "packages/standalone/current"),
                                     withDestinationURL: releases.appending(path: "0.3"))
        let manager = try manager()
        _ = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let session = try session(manager: manager)

        /// Scans, reviews every old version, and moves them to the trash. Returns the trash batch id.
        func trashOldVersions(_ id: Int) async throws -> String {
            let scanned = try await call(session, id, "cleanup.scan", #"{"sourceID":"codex"}"#)
            let scan = try XCTUnwrap(result(scanned))
            let versions = try XCTUnwrap((scan["categories"] as? [[String: Any]])?.first { $0["id"] as? String == "versions" })
            let items = (versions["items"] as? [[String: Any]] ?? []).filter { $0["protectedReason"] == nil }
                .compactMap { $0["id"] as? String }
            XCTAssertFalse(items.isEmpty)
            let ids = String(data: try JSONSerialization.data(withJSONObject: items), encoding: .utf8)!
            let reviewed = try await call(session, id + 1, "cleanup.review",
                                          #"{"scanID":"\#(scan["scanID"] as? String ?? "")","itemIDs":\#(ids)}"#)
            let plan = try XCTUnwrap(result(reviewed)?["planID"] as? String, "\(reviewed)")
            let applied = try await call(session, id + 2, "cleanup.apply", #"{"planID":"\#(plan)"}"#)
            XCTAssertTrue((result(applied)?["notice"] as? String ?? "").hasPrefix("\(items.count) items ("), "\(applied)")
            let again = try await call(session, id + 3, "cleanup.apply", #"{"planID":"\#(plan)"}"#)
            XCTAssertEqual(errorCode(again), -32004, "a used plan is stale")
            let listed = try await call(session, id + 4, "cleanup.trashList", #"{"sourceID":"codex"}"#)
            let batches = try XCTUnwrap(listed["result"] as? [[String: Any]])
            return try XCTUnwrap(batches.first?["id"] as? String)
        }

        let batch = try await trashOldVersions(1)
        XCTAssertFalse(files.fileExists(atPath: releases.appending(path: "0.1/bin").path))
        let restored = try await call(session, 10, "cleanup.restore", #"{"sourceID":"codex","batchID":"\#(batch)"}"#)
        XCTAssertEqual(result(restored)?["notice"] as? String, "Items restored.")
        XCTAssertTrue(files.fileExists(atPath: releases.appending(path: "0.1/bin").path))

        let second = try await trashOldVersions(20)
        let asked = try await call(session, 30, "cleanup.purge", #"{"sourceID":"codex","batchID":"\#(second)"}"#)
        XCTAssertEqual((result(asked)?["confirmation"] as? [String: Any])?["kind"] as? String, "purge")
        let purged = try await call(session, 31, "cleanup.purge",
                                    #"{"sourceID":"codex","batchID":"\#(second)","confirm":"\#(try token(asked))"}"#)
        XCTAssertEqual(result(purged)?["notice"] as? String, "Items deleted for good.")

        var codes: [Int?] = []
        for (id, method, params) in [(40, "cleanup.scan", #"{"sourceID":"nope"}"#),
                                     (41, "cleanup.review", #"{"scanID":"\#(UUID().uuidString)","itemIDs":["x"]}"#),
                                     (42, "cleanup.restore", #"{"sourceID":"codex","batchID":"\#(second)"}"#),
                                     (43, "cleanup.purge", #"{"sourceID":"codex","batchID":"bad"}"#)] {
            codes.append(errorCode(try await call(session, id, method, params)))
        }
        XCTAssertEqual(codes, [-32003, -32004, -32003, -32602])
        try await session.close()
        XCTAssertFalse(session.raw.contains("sk-canary"))
    }
}
