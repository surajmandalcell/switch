import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchRPC

/// Two paths that need synthetic data: the Droid unfinished-missions notice after a switch, and a successful
/// import plan from a Codex home with a fake JWT.
extension RPCRuntimeTests {
    func testSwitchingAwayFromADroidAccountNamesItsUnfinishedMissions() async throws {
        let trap = KeychainTrap()
        let (manager, personal) = try await droidManager(trap)
        // A second, different synthetic login, so Work is its own account.
        let login = [Data(count: 16), Data(count: 16), Data("synthetic-work".utf8)].map { $0.base64EncodedString() }
        try CoreSupport.atomicWrite(Data(login.joined(separator: ":").utf8),
                                    to: paths.droidHome.appending(path: "auth.v2.loginkeychain"), fileManager: .default)
        let work = try await manager.importDroidAccount(name: "Work")
        XCTAssertNotEqual(work.id, personal)
        _ = try await manager.switchDefault(to: personal)
        _ = try await manager.droidMissions()  // first sight: earlier missions stay without an owner
        let folder = paths.droidHome.appending(path: "missions/one11111")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        try JSONSerialization.data(withJSONObject: ["missionId": "mis_one11111", "state": "paused",
                                                    "workingDirectory": "/tmp/synthetic-project",
                                                    "createdAt": stamp, "updatedAt": stamp])
            .write(to: folder.appending(path: "state.json"))
        try JSONSerialization.data(withJSONObject: ["features": [["id": "f-0", "description": "Do it", "status": "pending",
                                                                  "expectedBehavior": ["Works"], "milestone": "m1"]]])
            .write(to: folder.appending(path: "features.json"))

        let session = try session(manager: manager)
        let switched = try await call(session, 1, "accounts.setDefault", #"{"accountID":"\#(work.id.uuidString.lowercased())"}"#)
        XCTAssertEqual(result(switched)?["notice"] as? String,
                       "New Droid sessions will use this account. 1 unfinished Droid mission stays with Personal. Resume them from Accounts.")
        try await session.close()
        XCTAssertEqual(trap.calls, 0)
        let owner = try await manager.droidMissions().first?.owner
        XCTAssertEqual(owner, personal, "the mission stays with Personal")
    }

    func testImportPlanFromACodexHomeCommitsTheAccount() async throws {
        // A Codex home on "another Mac": a fake JWT whose payload names a synthetic account. Never a real token.
        func base64URL(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let claims: [String: Any] = ["email": "import@example.test", "chatgpt_user_id": "user-synthetic",
                                     "chatgpt_account_id": "acct-synthetic", "workspace_id": "personal"]
        let jwt = "header.\(try base64URL(claims)).signature"
        let source = root.appending(path: "other-mac/.codex")
        try CoreSupport.privateDirectory(source, fileManager: .default)
        let auth: [String: Any] = ["last_refresh": "2026-01-01T00:00:00Z",
                                   "tokens": ["access_token": jwt, "account_id": "acct-synthetic",
                                              "refresh_token": "synthetic-refresh"]]
        try CoreSupport.atomicWrite(try JSONSerialization.data(withJSONObject: auth), to: source.appending(path: "auth.json"),
                                    fileManager: .default)
        try CoreSupport.atomicWrite(Data("model = \"synthetic\"\n".utf8), to: source.appending(path: "config.toml"),
                                    fileManager: .default)
        let manager = try manager()
        let session = try session(manager: manager)

        let planned = try await call(session, 1, "import.plan", #"{"source":"\#(source.path)","mode":"authOnly"}"#)
        let plan = try XCTUnwrap(result(planned)?["plan"] as? [String: Any], "\(planned)")
        let planID = try XCTUnwrap(plan["planID"] as? String)
        XCTAssertEqual(plan["mode"] as? String, "authOnly")
        let committed = try await call(session, 2, "import.commit", #"{"planID":"\#(planID)"}"#)
        XCTAssertEqual(result(committed)?["status"] as? String, "done", "\(committed)")
        XCTAssertTrue((result(committed)?["notice"] as? String ?? "").hasSuffix(" imported."))
        let accounts = try await manager.status().accounts
        XCTAssertEqual(accounts.map(\.identity.providerID), [.codex])
        let again = try await call(session, 3, "import.commit", #"{"planID":"\#(planID)"}"#)
        XCTAssertEqual(errorCode(again), -32004, "a committed plan is stale")
        try await session.close()
        XCTAssertFalse(session.raw.contains("synthetic-refresh"))
        XCTAssertFalse(session.raw.contains(jwt))
    }
}
