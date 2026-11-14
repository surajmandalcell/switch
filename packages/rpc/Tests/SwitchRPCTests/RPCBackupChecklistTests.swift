import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchRPC

/// Backup checklist changes over the protocol, through the shared `BackupChecklist` rules.
extension RPCRuntimeTests {
    func testBackupChecklistConfigureShareUncheckAndRetire() async throws {
        try CoreSupport.privateDirectory(paths.sharedRoot.appending(path: "sessions"), fileManager: .default)
        let folder = root.appending(path: "backups")
        try CoreSupport.privateDirectory(folder, fileManager: .default)
        let session = try session(manager: try manager())
        func row(_ reply: [String: Any]) -> [String: Any]? {
            (result(reply)?["rows"] as? [[String: Any]])?.first { $0["sourceID"] as? String == "codex" }
        }

        let early = try await call(session, 1, "backup.setChecked", #"{"sourceID":"codex","checked":true}"#)
        XCTAssertEqual((early["error"] as? [String: Any])?["message"] as? String, "Invalid source: Choose a backup folder first.")

        let configured = try await call(session, 2, "backup.configure",
                                        #"{"sourceID":"codex","destination":"\#(folder.path)","schedule":"daily","keep":3}"#)
        XCTAssertEqual(row(configured)?["checked"] as? Bool, true, "\(configured)")
        let setID = try XCTUnwrap(row(configured)?["setID"] as? String)
        XCTAssertEqual(result(configured)?["folder"] as? String, folder.path)
        XCTAssertEqual((result(configured)?["shared"] as? [String: Any])?["schedule"] as? String, "daily")

        let shared = try await call(session, 3, "backup.setShared", #"{"keep":5,"includeLogins":true}"#)
        let values = result(shared)?["shared"] as? [String: Any]
        XCTAssertEqual(values?["keep"] as? Int, 5)
        XCTAssertEqual(values?["includeLogins"] as? Bool, true)
        XCTAssertEqual(values?["schedule"] as? String, "daily")

        let unchecked = try await call(session, 4, "backup.setChecked", #"{"sourceID":"codex","checked":false}"#)
        XCTAssertEqual(row(unchecked)?["checked"] as? Bool, false)
        // Checking again needs a folder: no tool is checked now, so it asks for one.
        let again = try await call(session, 5, "backup.configure", #"{"sourceID":"codex","destination":"\#(folder.path)"}"#)
        XCTAssertEqual(row(again)?["setID"] as? String, setID, "the unchecked set in the same folder comes back")

        let unknown = try await call(session, 6, "backup.retire", #"{"tool":"nope"}"#)
        XCTAssertEqual(errorCode(unknown), -32003)
        let retired = try await call(session, 7, "backup.retire", #"{"tool":"codex"}"#)
        XCTAssertEqual(row(retired)?["checked"] as? Bool, false)
        let sets = try await BackupEngine(applicationSupport: paths.applicationSupport).sets()
        XCTAssertEqual(sets.map(\.retired), [true])
        try await session.close()
    }
}
