import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchRPC

/// The page actions: reorder, open, refresh all, popover opened, Claude shell line, Droid usage key.
extension RPCRuntimeTests {
    func testPageActions() async throws {
        let manager = try manager()
        let first = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let second = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary + "-2"])
        let ids = [second.id, first.id].map { $0.uuidString.lowercased() }
        let session = try session(manager: manager)

        let reordered = try await call(session, 1, "accounts.reorder", #"{"accountIDs":["\#(ids[0])","\#(ids[1])"]}"#)
        XCTAssertEqual(result(reordered)?["status"] as? String, "done")
        let order = try await manager.status().accounts.map { $0.id.uuidString.lowercased() }
        XCTAssertEqual(order, ids)
        let bad = try await call(session, 2, "accounts.reorder", #"{"accountIDs":["nope"]}"#)
        XCTAssertEqual(errorCode(bad), -32602)

        // Nothing is read over the network in a test home; both still answer done.
        for (id, method) in [(3, "app.refresh"), (4, "tray.opened")] {
            let reply = try await call(session, id, method, "{}")
            XCTAssertEqual(result(reply)?["status"] as? String, "done", method)
        }

        // The shell line goes into the test home's rc file only.
        let shell = try await call(session, 5, "claude.shellIntegration.set", #"{"enabled":true}"#)
        XCTAssertEqual(result(shell)?["status"] as? String, "done")
        let enabled = try await manager.claudeShellIntegrationInstalled()
        XCTAssertTrue(enabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.userHome.appending(path: ".zshrc").path))
        _ = try await call(session, 6, "claude.shellIntegration.set", #"{"enabled":false}"#)
        let disabled = try await manager.claudeShellIntegrationInstalled()
        XCTAssertFalse(disabled)

        // The usage key is Droid-only: this provider's account is not found.
        let key = try await call(session, 7, "droid.setUsageKey", #"{"accountID":"\#(ids[0])","key":"\#(canary)"}"#)
        XCTAssertEqual(errorCode(key), -32003)
        try await session.close()
        XCTAssertFalse(session.raw.contains(canary))
    }
}
