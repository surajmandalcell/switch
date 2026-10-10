import Foundation
import XCTest
@testable import AIManagerCore

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    private var bodies: [String] = []
    private var bearers: [String] = []
    func add(_ url: String, body: Data?, bearer: String?) {
        lock.lock(); defer { lock.unlock() }
        urls.append(url)
        bodies.append(body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        bearers.append(bearer ?? "")
    }
    var tokenCalls: [String] { lock.lock(); defer { lock.unlock() }; return zip(urls, bodies).filter { $0.0.contains("oauth2/token") }.map(\.1) }
    var billingBearers: [String] { lock.lock(); defer { lock.unlock() }; return zip(urls, bearers).filter { $0.0.contains("/billing") }.map(\.1) }
}

private final class Spy: @unchecked Sendable {
    private let lock = NSLock()
    private var _updated: Data?
    private var _live: [Bool] = []
    private var _beforeReturn: (@Sendable () throws -> Void)?
    var updated: Data? { get { lock.lock(); defer { lock.unlock() }; return _updated } set { lock.lock(); _updated = newValue; lock.unlock() } }
    var beforeReturn: (@Sendable () throws -> Void)? { get { lock.lock(); defer { lock.unlock() }; return _beforeReturn } set { lock.lock(); _beforeReturn = newValue; lock.unlock() } }
    func record(_ live: Bool) { lock.lock(); _live.append(live); lock.unlock() }
    var live: [Bool] { lock.lock(); defer { lock.unlock() }; return _live }
}

final class GrokUsageRefreshTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fileManager = FileManager.default
    private let fileID = ProviderCatalog.agentGrok.files[0].id
    private let billing = #"{"config":{"creditUsagePercent":10,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-01T00:00:00Z","end":"2026-07-08T00:00:00Z"}}}"#

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(path: "GrokUsageRefreshTests-\(UUID().uuidString)")
        paths = .init(
            applicationSupport: root.appending(path: "support"),
            credentialStore: root.appending(path: "user/.switch/codex"),
            defaultHome: root.appending(path: "user/.codex"),
            sharedRoot: root.appending(path: "user/.codex"),
            orcaAccountsRoot: root.appending(path: "orca"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            grokExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            isolationRoot: root
        )
        try fileManager.createDirectory(at: paths.defaultHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    // MARK: Spec

    private func authFile(token: String = "old-access", expires: String = "2020-01-01T00:00:00Z",
                          user: String = "u1") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "https://auth.x.ai::synthetic-client": [
                "key": token, "auth_mode": "oidc", "user_id": user, "email": "\(user)@example.test",
                "refresh_token": "old-refresh", "expires_at": expires,
                "oidc_issuer": "https://auth.x.ai", "oidc_client_id": "synthetic-client",
                "custom_field": "keep-me",
            ]
        ], options: [.sortedKeys])
    }

    /// Fake network: the token endpoint hands out `new-access`; billing accepts only `acceptedBearer`.
    private func send(_ calls: Calls, accepted: String = "new-access") -> GrokBuildUsage.Send {
        { url, _, headers, body in
            calls.add(url, body: body, bearer: headers["Authorization"])
            if url.contains("oauth2/token") {
                return .init(status: 200, data: Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8), headers: [:])
            }
            if url.contains("/settings") {
                return .init(status: 200, data: Data(#"{"subscription_tier_display":"SuperGrok"}"#.utf8), headers: [:])
            }
            let ok = headers["Authorization"] == "Bearer \(accepted)"
            return .init(status: ok ? 200 : 401, data: Data(self.billing.utf8), headers: [:])
        }
    }

    func testVaultCopyRefreshesExpiredTokenAndKeepsEveryOtherKey() async throws {
        let calls = Calls()
        let credential = ProviderCredential(files: [fileID: try authFile()])
        let result = try await GrokBuildUsage.fetch(credential, fileID: fileID, send: send(calls))

        XCTAssertEqual(result.usage.plan, "SuperGrok")
        XCTAssertEqual(calls.tokenCalls.count, 1)
        XCTAssertTrue(calls.tokenCalls[0].contains("grant_type=refresh_token"))
        XCTAssertTrue(calls.tokenCalls[0].contains("client_id=synthetic-client"))
        XCTAssertTrue(calls.tokenCalls[0].contains("refresh_token=old-refresh"))
        XCTAssertEqual(calls.billingBearers, ["Bearer new-access"])

        let updated = try XCTUnwrap(result.updated?.files[fileID])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: [String: Any]])
        let entry = try XCTUnwrap(object["https://auth.x.ai::synthetic-client"])
        XCTAssertEqual(entry["key"] as? String, "new-access")
        XCTAssertEqual(entry["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(entry["custom_field"] as? String, "keep-me")
        XCTAssertEqual(entry["user_id"] as? String, "u1")
        XCTAssertEqual(entry["oidc_issuer"] as? String, "https://auth.x.ai")
        let expiry = try XCTUnwrap(JSON(entry["expires_at"] as Any).date)
        XCTAssertGreaterThan(expiry, Date())
        XCTAssertEqual(result.updated?.isLive, false)
    }

    func testVaultCopyRefreshesAndRetriesOnceAfter401() async throws {
        let calls = Calls()
        let credential = ProviderCredential(files: [fileID: try authFile(token: "stale", expires: "2099-01-01T00:00:00Z")])
        let result = try await GrokBuildUsage.fetch(credential, fileID: fileID, send: send(calls))

        XCTAssertEqual(calls.billingBearers, ["Bearer stale", "Bearer new-access"])
        XCTAssertEqual(calls.tokenCalls.count, 1)
        XCTAssertNotNil(result.updated)
    }

    func testValidVaultTokenIsNotRefreshed() async throws {
        let calls = Calls()
        let credential = ProviderCredential(files: [fileID: try authFile(token: "new-access", expires: "2099-01-01T00:00:00Z")])
        let result = try await GrokBuildUsage.fetch(credential, fileID: fileID, send: send(calls))

        XCTAssertTrue(calls.tokenCalls.isEmpty)
        XCTAssertNil(result.updated)
    }

    func testLiveCredentialNeverRefreshes() async throws {
        let expired = ProviderCredential(files: [fileID: try authFile()], isLive: true)
        let rejected = ProviderCredential(files: [fileID: try authFile(token: "stale", expires: "2099-01-01T00:00:00Z")], isLive: true)
        for credential in [expired, rejected] {
            let calls = Calls()
            do {
                _ = try await GrokBuildUsage.fetch(credential, fileID: fileID, send: send(calls))
                XCTFail("expected unauthorized")
            } catch let error as ProviderError {
                XCTAssertEqual(error, .unauthorized(GrokBuildUsage.refreshMessage))
            }
            XCTAssertTrue(calls.tokenCalls.isEmpty)
        }
    }

    // MARK: Manager

    private func makeManager(_ spy: Spy) throws -> AccountManager {
        let fake = ProviderSpec(
            id: "grok-build", name: "Grok Build", style: .files, files: ProviderCatalog.agentGrok.files,
            fetch: { credential in
                spy.record(credential.isLive)
                try spy.beforeReturn?()
                return FetchResult(ProviderUsage(plan: "fake"),
                                   updated: spy.updated.map { ProviderCredential(files: [ProviderCatalog.agentGrok.files[0].id: $0]) })
            })
        let specs = ProviderCatalog.all.filter { $0.id != .grokBuild } + [fake]
        return try AccountManager(paths: paths, writerCheck: { _ in .inactive },
                                  loginRunner: .init(launch: { _, _ in }), providerSpecs: specs)
    }

    private func addGrok(_ manager: AccountManager, user: String) async throws -> AccountRecord {
        let start = try await manager.startAccountLogin(providerID: .grokBuild)
        let home = URL(fileURLWithPath: try XCTUnwrap(start.launchSpec.environment["GROK_HOME"]))
        let auth = home.appending(path: "auth.json")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try authFile(token: "access-\(user)", expires: "2099-01-01T00:00:00Z", user: user).write(to: auth)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        let checked = try await manager.checkAccountLogin(id: start.session.id)
        return try XCTUnwrap(checked.account)
    }

    /// Default account `first`; `second` is saved but not the default.
    private func twoAccounts(_ manager: AccountManager) async throws -> (first: AccountRecord, second: AccountRecord) {
        let first = try await addGrok(manager, user: "first")
        let second = try await addGrok(manager, user: "second")
        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID(for: .grokBuild), first.id)
        return (first, second)
    }

    /// Reads the recorded digest straight from the registry file (status() would re-validate the vault).
    private func registryDigest(_ manager: AccountManager, _ id: UUID) async throws -> String {
        let data = try Data(contentsOf: paths.applicationSupport.appending(path: "accounts.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        let match = accounts.first { $0["id"] as? String == id.uuidString }
        return try XCTUnwrap(match?["credentialDigest"] as? String)
    }

    private func refreshed(_ data: Data, token: String = "refreshed-access", user: String? = nil) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        let key = "https://auth.x.ai::synthetic-client"
        object[key]?["key"] = token
        if let user { object[key]?["user_id"] = user }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testManagerPersistsRefreshForNonDefaultAccount() async throws {
        let spy = Spy()
        let manager = try makeManager(spy)
        let (first, second) = try await twoAccounts(manager)
        let before = try Data(contentsOf: second.credentialFile)
        let new = try refreshed(before)
        spy.updated = new

        _ = try await manager.readProviderUsage(accountID: second.id)

        XCTAssertEqual(spy.live, [false])
        XCTAssertEqual(try Data(contentsOf: second.credentialFile), new)
        let after_second = try await registryDigest(manager, second.id)
        XCTAssertEqual(after_second, CoreSupport.digest(new))
        let mode = try fileManager.attributesOfItem(atPath: second.credentialFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let after_first = try await registryDigest(manager, first.id)
        XCTAssertNotEqual(after_first, CoreSupport.digest(new))
        let leftovers = try fileManager.contentsOfDirectory(atPath: second.credentialFile.deletingLastPathComponent().path)
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".tmp") })
    }

    func testManagerDoesNotPersistForDefaultAccount() async throws {
        let spy = Spy()
        let manager = try makeManager(spy)
        let (first, _) = try await twoAccounts(manager)
        let before = try Data(contentsOf: first.credentialFile)
        let digest = try await registryDigest(manager, first.id)
        spy.updated = try refreshed(before)

        _ = try await manager.readProviderUsage(accountID: first.id)

        XCTAssertEqual(try Data(contentsOf: first.credentialFile), before)
        let after_first = try await registryDigest(manager, first.id)
        XCTAssertEqual(after_first, digest)
    }

    func testManagerDoesNotPersistLiveCredential() async throws {
        let spy = Spy()
        let manager = try makeManager(spy)
        let (_, second) = try await twoAccounts(manager)
        _ = try await manager.switchDefault(to: second.id)
        let before = try Data(contentsOf: second.credentialFile)
        let digest = try await registryDigest(manager, second.id)
        spy.updated = try refreshed(before)

        _ = try await manager.readProviderUsage(accountID: second.id)

        XCTAssertEqual(spy.live, [true])
        XCTAssertEqual(try Data(contentsOf: second.credentialFile), before)
        let after_second = try await registryDigest(manager, second.id)
        XCTAssertEqual(after_second, digest)
    }

    func testManagerDropsRefreshWhenVaultDigestChanged() async throws {
        let spy = Spy()
        let manager = try makeManager(spy)
        let (_, second) = try await twoAccounts(manager)
        let before = try Data(contentsOf: second.credentialFile)
        let digest = try await registryDigest(manager, second.id)
        let other = try refreshed(before, token: "written-by-someone-else")
        let file = second.credentialFile
        spy.beforeReturn = {
            try other.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        spy.updated = try refreshed(before)

        _ = try await manager.readProviderUsage(accountID: second.id)

        XCTAssertEqual(try Data(contentsOf: file), other)
        let after_second = try await registryDigest(manager, second.id)
        XCTAssertEqual(after_second, digest)
    }

    func testManagerDropsRefreshWithDifferentIdentity() async throws {
        let spy = Spy()
        let manager = try makeManager(spy)
        let (_, second) = try await twoAccounts(manager)
        let before = try Data(contentsOf: second.credentialFile)
        let digest = try await registryDigest(manager, second.id)
        spy.updated = try refreshed(before, user: "someone-else")

        _ = try await manager.readProviderUsage(accountID: second.id)

        XCTAssertEqual(try Data(contentsOf: second.credentialFile), before)
        let after_second = try await registryDigest(manager, second.id)
        XCTAssertEqual(after_second, digest)
    }
}
