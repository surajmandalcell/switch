import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel
@testable import SwitchRPC

/// `accounts.setDefault`, `accounts.check`, and `usage.refresh` through the action lane.
extension RPCRuntimeTests {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened { lock.unlock(); continuation.resume() } else { waiter = continuation; lock.unlock() }
            }
        }
        func open() {
            lock.lock()
            opened = true
            let waiter = waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }
    }

    func rows(_ frames: [[String: Any]]) -> [[String: Any]] {
        (changes(frames, "accounts").last?["value"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
    }

    func testSetDefaultAndCheckPublishTheirResults() async throws {
        let manager = try manager()
        _ = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let second = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary + "-2"])
        let id = second.id.uuidString.lowercased()
        let session = try session(manager: manager)
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"state.subscribe","params":{"topics":["accounts","notices"]}}"#)
        session.send(#"{"jsonrpc":"2.0","method":"initialized"}"#)
        try await session.wait { self.rows($0).count == 2 }
        XCTAssertEqual(rows(session.frames).first { $0["id"] as? String == id }?["isDefault"] as? Bool, false)

        session.send(#"{"jsonrpc":"2.0","id":2,"method":"accounts.setDefault","params":{"accountID":"\#(id)"}}"#)
        try await session.wait { self.rows($0).first { $0["id"] as? String == id }?["isDefault"] as? Bool == true }
        let switched = try XCTUnwrap(result(try reply(session.frames, 2)))
        XCTAssertEqual(switched["status"] as? String, "done")
        // The Mac text: the test provider is not in the built-in catalog.
        XCTAssertEqual(switched["notice"] as? String, "Test Rpc sign-in files updated. Reopen the tool to load this account.")
        try await session.wait {
            (self.changes($0, "notices").last?["value"] as? [String: Any])?["notice"] as? String == switched["notice"] as? String
        }

        session.send(#"{"jsonrpc":"2.0","id":3,"method":"accounts.check","params":{"accountID":"\#(id)"}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 3 } }
        XCTAssertEqual(result(try reply(session.frames, 3))?["notice"] as? String, "Account checked.")
        try await session.wait { self.rows($0).first { $0["id"] as? String == id }?["verification"] as? String == "verifiedLocally" }

        session.send(#"{"jsonrpc":"2.0","id":4,"method":"accounts.check","params":{"accountID":"\#(UUID().uuidString)"}}"#)
        session.send(#"{"jsonrpc":"2.0","id":5,"method":"usage.refresh","params":{"accountID":"nope"}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 4 } && $0.contains { $0["id"] as? Int == 5 } }
        XCTAssertEqual(errorCode(try reply(session.frames, 4)), -32003)
        XCTAssertEqual(errorCode(try reply(session.frames, 5)), -32602)
        try await session.close()
        XCTAssertFalse(session.raw.contains("sk-canary"))
    }

    func testActionsWhileTheLaneIsBusyAnswerBusy() async throws {
        let manager = try manager()
        let account = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let id = account.id.uuidString.lowercased()
        let session = try session(manager: manager)
        let engine = session.server.engine
        let gate = Gate()
        let held = Task { try await engine.perform { await gate.wait() } }
        while !(await engine.app.isBusy) { await Task.yield() }
        for (number, method) in RPCServer.writeMethods.enumerated() {
            session.send(#"{"jsonrpc":"2.0","id":\#(number + 1),"method":"\#(method)","params":{"accountID":"\#(id)"}}"#)
        }
        try await session.wait { $0.count == RPCServer.writeMethods.count }
        for reply in session.frames {
            XCTAssertEqual(errorCode(reply), -32001)
            XCTAssertEqual(((reply["error"] as? [String: Any])?["data"] as? [String: Any])?["retryable"] as? Bool, true)
        }
        gate.open()
        try await held.value
        session.send(#"{"jsonrpc":"2.0","id":9,"method":"accounts.setDefault","params":{"accountID":"\#(id)"}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 9 } }
        XCTAssertEqual(result(try reply(session.frames, 9))?["status"] as? String, "done")
        try await session.close()
    }

    func testSwitchWhileDroidRunsNeedsAConfirmationToken() async throws {
        let trap = KeychainTrap()
        let (manager, droid) = try await droidManager(trap, running: true)
        let id = droid.uuidString.lowercased()
        let clock = ManualClock()
        let session = try session(manager: manager, clock: clock)
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"accounts.setDefault","params":{"accountID":"\#(id)"}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 1 } }
        let asked = try XCTUnwrap(result(try reply(session.frames, 1)))
        XCTAssertEqual(asked["status"] as? String, "needsConfirmation")
        let confirmation = try XCTUnwrap(asked["confirmation"] as? [String: Any])
        XCTAssertEqual(confirmation["action"] as? String, "Switch")
        XCTAssertEqual(confirmation["message"] as? String, DroidAccountError.running([]).localizedDescription)
        let token = try XCTUnwrap(confirmation["token"] as? String)

        // The token is bound to this account, single use, and lasts 120 s.
        let other = UUID().uuidString.lowercased()
        session.send(#"{"jsonrpc":"2.0","id":2,"method":"accounts.setDefault","params":{"accountID":"\#(other)","confirm":"\#(token)"}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 2 } }
        XCTAssertEqual(errorCode(try reply(session.frames, 2)), -32004)

        session.send(#"{"jsonrpc":"2.0","id":3,"method":"accounts.setDefault","params":{"accountID":"\#(id)"}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 3 } }
        let fresh = try XCTUnwrap((result(try reply(session.frames, 3))?["confirmation"] as? [String: Any])?["token"] as? String)
        clock.advance(seconds: RPCServer.confirmationLifetime + 1)
        session.send(#"{"jsonrpc":"2.0","id":4,"method":"accounts.setDefault","params":{"accountID":"\#(id)","confirm":"\#(fresh)"}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 4 } }
        XCTAssertEqual(errorCode(try reply(session.frames, 4)), -32004, "an expired token")

        session.send(#"{"jsonrpc":"2.0","id":5,"method":"accounts.setDefault","params":{"accountID":"\#(id)"}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 5 } }
        let last = try XCTUnwrap((result(try reply(session.frames, 5))?["confirmation"] as? [String: Any])?["token"] as? String)
        session.send(#"{"jsonrpc":"2.0","id":6,"method":"accounts.setDefault","params":{"accountID":"\#(id)","confirm":"\#(last)"}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 6 } }
        XCTAssertEqual(result(try reply(session.frames, 6))?["status"] as? String, "done")
        session.send(#"{"jsonrpc":"2.0","id":7,"method":"accounts.setDefault","params":{"accountID":"\#(id)","confirm":"\#(last)"}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 7 } }
        XCTAssertEqual(errorCode(try reply(session.frames, 7)), -32004, "a used token")
        try await session.close()
        XCTAssertEqual(trap.calls, 0)
    }

    /// `usage.refresh` is the user action that may read the login Keychain; the timers never do.
    func testUsageRefreshIsAnInteractiveUserAction() async throws {
        let trap = KeychainTrap()
        let (manager, droid) = try await droidManager(trap)
        let id = droid.uuidString.lowercased()
        let server = RPCServer(manager: manager, paths: paths, version: "test-version", log: { _ in })
        await server.engine.setRefreshesInIsolation(true)
        let session = Session(server)
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"state.subscribe","params":{"topics":["accounts"]}}"#)
        session.send(#"{"jsonrpc":"2.0","method":"initialized"}"#)
        try await session.wait(30) { self.rows($0).first?["checkedAt"] != nil }
        XCTAssertEqual(trap.calls, 0)
        session.send(#"{"jsonrpc":"2.0","id":2,"method":"usage.refresh","params":{"accountID":"\#(id)"}}"#)
        try await session.wait(30) { $0.contains { $0["id"] as? Int == 2 } }
        XCTAssertEqual(result(try reply(session.frames, 2))?["status"] as? String, "done")
        XCTAssertEqual(trap.calls, 1, "the user action reached the Keychain reader")
        try await session.close()
        XCTAssertEqual(rows(session.frames).first?["needsDroidAccess"] as? Bool, true)
    }
}
