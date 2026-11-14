import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel
@testable import SwitchRPC

/// Auto switch: the preview over the protocol, then the shared loop moving the default off a nearly empty account.
extension RPCRuntimeTests {
    func testAutoSwitchPreviewAndLoopSwitchOffANearlyEmptyAccount() async throws {
        // A key ending in "-low" has 1% left; any other key has 60% left.
        let spec = ProviderSpec(id: provider.rawValue, name: "RPC Test", style: .secret, fields: [.apiKey("TEST_RPC_KEY")],
                                fetch: { credential in
                                    let low = credential.fields["apiKey"]?.hasSuffix("-low") == true
                                    return FetchResult(ProviderUsage(windows: [UsageWindow(id: "session", title: "Session",
                                                                                           usedPercent: low ? 99 : 40)]))
                                })
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: [spec])
        let low = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": "\(canary)-low"])
        let full = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let session = try session(manager: manager)
        let engine = session.server.engine
        await engine.setRefreshesInIsolation(true)
        for (id, account) in [(1, low), (2, full)] {
            _ = try await call(session, id, "usage.refresh", #"{"accountID":"\#(account.id.uuidString.lowercased())"}"#)
        }

        let preview = try await call(session, 3, "autoSwitch.preview", "{}")
        let value = try XCTUnwrap(result(preview))
        XCTAssertEqual(value["enabled"] as? Bool, false)
        XCTAssertEqual(value["threshold"] as? Int, 1)
        let step = try XCTUnwrap((value["steps"] as? [[String: Any]])?.first)
        XCTAssertEqual(step["decision"] as? String, "switchTo")
        XCTAssertEqual(step["fromAccountID"] as? String, low.id.uuidString.lowercased())
        XCTAssertEqual(step["toAccountID"] as? String, full.id.uuidString.lowercased())

        // Off: the loop does nothing. On: one switch and the Mac notice.
        await engine.evaluateAutoSwitch()
        var status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID(for: provider), low.id)
        _ = try await call(session, 4, "settings.set", #"{"key":"autoSwitchEnabled","value":true}"#)
        await engine.evaluateAutoSwitch()
        status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID(for: provider), full.id)
        let notice = await engine.notices.notice
        XCTAssertEqual(notice?.hasSuffix("has 1% left. Switched to \(AccountPresentation.label(full.identity))."), true, notice ?? "")
        try await session.close()
        XCTAssertFalse(session.raw.contains("sk-canary"))
    }
}
