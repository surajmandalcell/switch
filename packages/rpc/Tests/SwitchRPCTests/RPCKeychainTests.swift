import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel
@testable import SwitchRPC

/// The helper reads the login Keychain only for a user-started action: never on startup, subscribe, a read method,
/// or a usage timer.
extension RPCRuntimeTests {
    final class KeychainTrap: DroidLoginReader.KeyProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func key(interactive: Bool) throws -> Data {
            lock.lock()
            count += 1
            lock.unlock()
            throw DroidLoginError.needsKeychainAccess
        }
    }

    /// A Droid account whose login is in the Keychain form, so reading its usage needs the Keychain key.
    /// `running` lists a Factory app process on that login.
    /// `hint` makes the fake `droid doctor` report that masked email, so a second import of the login is a duplicate.
    func droidManager(_ trap: KeychainTrap, running: Bool = false, hint: String? = nil) async throws -> (AccountManager, UUID) {
        let fake = root.appending(path: "fake-droid")
        try CoreSupport.privateDirectory(root, fileManager: .default)
        let doctor = hint.map { #"test "$1" = doctor && printf '%s' '{"results":[{"id":"auth.verify","status":"pass","detail":"authenticated as \#($0) via stored login session"}]}' && exit 0"# + "\n" } ?? ""
        XCTAssertTrue(FileManager.default.createFile(atPath: fake.path, contents: Data("#!/bin/sh\n\(doctor)exit 1\n".utf8),
                                                     attributes: [.posixPermissions: 0o700]))
        paths.droidExecutable = fake
        try CoreSupport.privateDirectory(paths.droidHome, fileManager: .default)
        let login = [Data(count: 16), Data(count: 16), Data("synthetic".utf8)].map { $0.base64EncodedString() }
        try CoreSupport.atomicWrite(Data(login.joined(separator: ":").utf8),
                                    to: paths.droidHome.appending(path: "auth.v2.loginkeychain"), fileManager: .default)
        let processes = running ? [DroidProcess(pid: 42, bundleID: "com.electron.factory", home: paths.droidHome)] : []
        let manager = running
            ? try AccountManager(paths: paths, writerCheck: { _ in .inactive }, droidProcessLister: { processes },
                                 droidLoginReader: DroidLoginReader(keyProvider: UserActionKeyProvider(base: trap)))
            : try AppEngine.makeManager(paths: paths, keychain: trap, writerCheck: { _ in .inactive })
        let account = try await manager.importDroidAccount(name: "Personal")
        return (manager, account.id)
    }

    func testNoKeychainReadWithoutAUserAction() async throws {
        let trap = KeychainTrap()
        let (manager, id) = try await droidManager(trap)
        let account = id.uuidString.lowercased()
        let server = RPCServer(manager: manager, paths: paths, version: "test-version", log: { _ in })
        await server.engine.setRefreshesInIsolation(true)
        let session = Session(server)
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        session.send(#"{"jsonrpc":"2.0","id":2,"method":"state.subscribe","params":{"topics":["app","notices","accounts"]}}"#)
        session.send(#"{"jsonrpc":"2.0","method":"initialized"}"#)
        let params = #"{"accountID":"\#(account)","day":"2026-11-14","id":"x","sourceID":"x","setID":"x"}"#
        let methods = RPCServer.readMethods + ["accounts.status", "usage.detail"]
        for (number, method) in methods.enumerated() {
            session.send(#"{"jsonrpc":"2.0","id":\#(number + 10),"method":"\#(method)","params":\#(params)}"#)
        }
        try await session.wait(30) { frames in frames.filter { ($0["id"] as? Int ?? 0) >= 10 }.count == methods.count }
        // The start-up refresh reads the Droid account's usage without the Keychain.
        try await session.wait(30) { frames in
            let rows = (self.changes(frames, "accounts").last?["value"] as? [String: Any])?["rows"] as? [[String: Any]]
            return rows?.first { $0["id"] as? String == account }?["checkedAt"] != nil
        }
        try await session.close()
        XCTAssertEqual(trap.calls, 0, "no Keychain read without a user action")
        let rows = (changes(session.frames, "accounts").last?["value"] as? [String: Any])?["rows"] as? [[String: Any]]
        XCTAssertEqual(rows?.first { $0["id"] as? String == account }?["needsDroidAccess"] as? Bool, true)

        // A user-started read reaches the Keychain reader, so the path above was really exercised.
        _ = try? await manager.readProviderUsage(accountID: id, interactive: true)
        XCTAssertEqual(trap.calls, 1)
    }
}
