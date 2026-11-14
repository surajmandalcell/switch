import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchRPC

/// The Backup checklist, a run with `$/progress`, and a restore into a folder, in a temporary root.
extension RPCRuntimeTests {
    func testBackupChecklistRunAndRestoreWithProgress() async throws {
        let home = paths.sharedRoot
        try CoreSupport.privateDirectory(home.appending(path: "sessions"), fileManager: .default)
        for number in 0..<3 {
            try CoreSupport.atomicWrite(Data("synthetic line \(number)".utf8),
                                        to: home.appending(path: "sessions/s\(number).jsonl"), fileManager: .default)
        }
        let folder = root.appending(path: "backups")
        try CoreSupport.privateDirectory(folder, fileManager: .default)
        let set = BackupSet(name: "Codex CLI", source: BackupSource(id: "codex", service: .codex, home: home),
                            items: BackupPresets.items(for: .codex), destination: folder)
        try await BackupEngine(applicationSupport: paths.applicationSupport).saveSets([set])
        let id = set.id.uuidString.lowercased()
        let manager = try manager()
        _ = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let session = try session(manager: manager)

        let listed = try await call(session, 1, "backup.checklist", "{}")
        let checklist = try XCTUnwrap(result(listed))
        let row = try XCTUnwrap((checklist["rows"] as? [[String: Any]])?.first { $0["sourceID"] as? String == "codex" })
        XCTAssertEqual(row["checked"] as? Bool, true)
        XCTAssertEqual(row["setID"] as? String, id)
        XCTAssertGreaterThan(row["bytes"] as? Int ?? 0, 0)
        XCTAssertEqual(checklist["folder"] as? String, folder.path)

        let run = try await call(session, 2, "backup.run", #"{"progressToken":"p-1"}"#)
        XCTAssertTrue((result(run)?["notice"] as? String ?? "").hasPrefix("Backed up "), "\(run)")
        let progress = session.frames.filter { $0["method"] as? String == "$/progress" }
        XCTAssertFalse(progress.isEmpty)
        XCTAssertEqual((progress.first?["params"] as? [String: Any])?["token"] as? String, "p-1")
        XCTAssertEqual(((progress.first?["params"] as? [String: Any])?["value"] as? [String: Any])?["setID"] as? String, id)

        let history = try await call(session, 3, "backup.history", #"{"setID":"\#(id)"}"#)
        let snapshot = try XCTUnwrap(((result(history)?["snapshots"] as? [[String: Any]])?.first)?["id"] as? String)
        let target = root.appending(path: "restored")
        try CoreSupport.privateDirectory(target, fileManager: .default)
        let restored = try await call(session, 4, "backup.restore",
                                      #"{"setID":"\#(id)","snapshotID":"\#(snapshot)","destination":"\#(target.path)"}"#)
        XCTAssertTrue((result(restored)?["notice"] as? String ?? "").hasSuffix(" to restored."), "\(restored)")
        XCTAssertEqual(try String(contentsOf: target.appending(path: "sessions/s1.jsonl"), encoding: .utf8), "synthetic line 1")

        var codes: [Int?] = []
        for (number, method, params) in [(5, "backup.run", #"{"setIDs":["\#(UUID().uuidString)"]}"#),
                                         (6, "backup.restore", #"{"setID":"\#(id)","snapshotID":"nope"}"#),
                                         (7, "backup.restore", #"{"setID":"bad","snapshotID":"x"}"#)] {
            codes.append(errorCode(try await call(session, number, method, params)))
        }
        XCTAssertEqual(codes, [-32003, -32003, -32602])
        try await session.close()
        XCTAssertFalse(session.raw.contains("sk-canary"))
    }
}
