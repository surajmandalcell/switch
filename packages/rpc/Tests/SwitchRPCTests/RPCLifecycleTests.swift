import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel
@testable import SwitchRPC

/// Adding, renaming, deleting, signing in, and importing accounts over the protocol, in a temporary root.
extension RPCRuntimeTests {
    func call(_ session: Session, _ id: Int, _ method: String, _ params: String) async throws -> [String: Any] {
        session.send(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#)
        try await session.wait(30) { $0.contains { $0["id"] as? Int == id } }
        return try reply(session.frames, id)
    }

    func token(_ reply: [String: Any]) throws -> String {
        let value = try XCTUnwrap(result(reply))
        XCTAssertEqual(value["status"] as? String, "needsConfirmation")
        return try XCTUnwrap((value["confirmation"] as? [String: Any])?["token"] as? String)
    }

    func testAddAndDeleteProviderAccountsWithConfirmation() async throws {
        let manager = try manager()
        let session = try session(manager: manager)
        let added = try await call(session, 1, "providers.add", #"{"providerID":"test-rpc","fields":{"apiKey":"\#(canary)"}}"#)
        let first = try XCTUnwrap(result(added)?["accountID"] as? String)
        XCTAssertEqual(result(added)?["notice"] as? String, "Test Rpc account was saved.")
        let added2 = try await call(session, 2, "providers.add", #"{"providerID":"test-rpc","fields":{"apiKey":"\#(canary)-2"}}"#)
        let second = try XCTUnwrap(result(added2)?["accountID"] as? String)
        let unknown = try await call(session, 3, "providers.add", #"{"providerID":"no-such","fields":{}}"#)
        XCTAssertEqual(errorCode(unknown), -32007)

        // Deleting the default asks first and names the replacement.
        let asked = try await call(session, 4, "accounts.delete", #"{"accountID":"\#(first)"}"#)
        let message = (result(asked)?["confirmation"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.hasPrefix("Remove this account's saved sign-in from Switch."), message)
        XCTAssertTrue(message.contains("will become the default"), message)
        let confirm = try token(asked)
        let deleted = try await call(session, 5, "accounts.delete", #"{"accountID":"\#(first)","confirm":"\#(confirm)"}"#)
        XCTAssertEqual(result(deleted)?["status"] as? String, "done")
        var status = try await manager.status()
        XCTAssertEqual(status.accounts.map { $0.id.uuidString.lowercased() }, [second])
        XCTAssertEqual(status.defaultAccountIDs["test-rpc"]?.uuidString.lowercased(), second)

        // The last account of a provider is the default and has no replacement.
        let last = try await call(session, 6, "accounts.delete", #"{"accountID":"\#(second)"}"#)
        XCTAssertEqual(errorCode(last), -32007)
        XCTAssertTrue(((last["error"] as? [String: Any])?["message"] as? String ?? "").contains("No saved account is available"))
        status = try await manager.status()
        XCTAssertEqual(status.accounts.count, 1)
        try await session.close()
        XCTAssertFalse(session.raw.contains("sk-canary"))
        XCTAssertEqual(String(describing: try JSONDecoder().decode(SecretString.self, from: Data(#""sk-x""#.utf8))), "<redacted>")
    }

    func testDroidRenameSignInAndDuplicateImport() async throws {
        let trap = KeychainTrap()
        let (manager, droid) = try await droidManager(trap, hint: "s***@example.com")
        let id = droid.uuidString.lowercased()
        let session = try session(manager: manager)

        let renamed = try await call(session, 1, "accounts.rename", #"{"accountID":"\#(id)","name":"Work"}"#)
        XCTAssertEqual(result(renamed)?["status"] as? String, "done")
        let saved = try await manager.status().accounts.first?.identity.accountID
        XCTAssertEqual(saved, "Work")

        func sessions(_ frames: [[String: Any]]) -> [[String: Any]]? {
            (changes(frames, "login").last?["value"] as? [String: Any])?["sessions"] as? [[String: Any]]
        }
        session.send(#"{"jsonrpc":"2.0","id":20,"method":"state.subscribe","params":{"topics":["login"]}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 20 } }

        // Signing in to a saved Droid account asks first; in a test home no terminal opens.
        let asked = try await call(session, 2, "login.start", #"{"accountID":"\#(id)"}"#)
        XCTAssertEqual((result(asked)?["confirmation"] as? [String: Any])?["kind"] as? String, "droidSignIn")
        let started = try await call(session, 3, "login.start", #"{"accountID":"\#(id)","confirm":"\#(try token(asked))"}"#)
        let login = try XCTUnwrap(result(started)?["login"] as? [String: Any])
        XCTAssertEqual(login["state"] as? String, "waitingForLogin")
        XCTAssertEqual(login["message"] as? String, "Sign-in file prepared for isolated validation. Terminal was not opened.")
        let sessionID = try XCTUnwrap(login["sessionID"] as? String)
        // The `login` topic lists the open session, and the sign-in script quotes every value.
        try await session.wait { sessions($0)?.map { $0["sessionID"] as? String } == [sessionID] }
#if os(Windows)
        let name = "Launch/sign-in.cmd"
#else
        let name = "Launch/sign-in.sh"
#endif
        // Windows lists the paths with "\".
        let scripts = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
            .map { $0.replacingOccurrences(of: "\\", with: "/") }.filter { $0.hasSuffix(name) }
        XCTAssertEqual(scripts.count, 1)
        let script = try String(contentsOf: root.appending(path: try XCTUnwrap(scripts.first)), encoding: .utf8)
#if os(Windows)
        XCTAssertTrue(script.hasPrefix("@echo off\r\nchcp 65001 >nul\r\nsetlocal DisableDelayedExpansion\r\nset \"FACTORY_API_KEY=\"\r\n"), script)
        XCTAssertTrue(script.contains("set \"FACTORY_HOME_OVERRIDE="), script)
#else
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\nset -e\nunset FACTORY_API_KEY "), script)
        XCTAssertTrue(script.contains("export FACTORY_HOME_OVERRIDE='\(root.path)"), script)
#endif
        XCTAssertFalse(script.contains("PATH="), "only the sign-in variables are exported")
        let cancelled = try await call(session, 4, "login.cancel", #"{"sessionID":"\#(sessionID)"}"#)
        XCTAssertEqual(result(cancelled)?["status"] as? String, "done")
        try await session.wait { sessions($0)?.isEmpty == true }
        let unknown = try await call(session, 5, "login.check", #"{"sessionID":"\#(UUID().uuidString)"}"#)
        XCTAssertEqual(errorCode(unknown), -32007)
        let bad = try await call(session, 6, "login.cancel", #"{"sessionID":"nope"}"#)
        XCTAssertEqual(errorCode(bad), -32602)

        // The same Droid login under a second name asks before it saves a duplicate.
        let duplicate = try await call(session, 7, "droid.import", #"{"name":"Again"}"#)
        XCTAssertEqual((result(duplicate)?["confirmation"] as? [String: Any])?["kind"] as? String, "droidDuplicate")
        let imported = try await call(session, 8, "droid.import", #"{"name":"Again","confirm":"\#(try token(duplicate))"}"#)
        XCTAssertEqual(result(imported)?["notice"] as? String, "Droid account saved.")
        XCTAssertNotNil(result(imported)?["accountID"] as? String)
        try await session.close()
        XCTAssertEqual(trap.calls, 0, "no Keychain read for these actions")
    }

    func testImportPlanIdsGoStale() async throws {
        let session = try session()
        let plan = UUID().uuidString
        var codes: [Int?] = []
        for (id, method, params) in [(1, "import.commit", #"{"planID":"\#(plan)"}"#), (2, "import.discard", #"{"planID":"\#(plan)"}"#),
                                     (3, "import.plan", #"{"source":"\#(root.path)/missing"}"#), (4, "import.commit", "{}")] {
            codes.append(errorCode(try await call(session, id, method, params)))
        }
        XCTAssertEqual(codes, [-32004, -32004, -32007, -32602])
        try await session.close()
    }
}
