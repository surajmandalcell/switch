import Foundation
import XCTest
@testable import AIManagerCore

/// A rejected API key becomes a saved "needs sign-in" state, and automatic refreshes stop
/// calling the provider until the credential changes.
final class RejectedCredentialTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fileManager = FileManager.default
    private let providerID = ProviderID(rawValue: "test-rejected")

    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var answer: ProviderError?
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func call() throws -> ProviderUsage {
            lock.lock(); _calls += 1; let answer = answer; lock.unlock()
            if let answer { throw answer }
            return ProviderUsage(plan: "Plan")
        }
    }

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(path: "RejectedCredentialTests-\(UUID().uuidString)")
        paths = .init(applicationSupport: root.appending(path: "support"),
                      credentialStore: root.appending(path: "user/.switch/codex"),
                      defaultHome: root.appending(path: "user/.codex"),
                      sharedRoot: root.appending(path: "user/.codex"),
                      orcaAccountsRoot: root.appending(path: "orca"), isolationRoot: root)
    }

    override func tearDownWithError() throws { if let root { try? fileManager.removeItem(at: root) } }

    private func manager(_ server: Server) throws -> AccountManager {
        let spec = ProviderSpec(id: providerID.rawValue, name: "Rejected", style: .secret,
                                fields: [.apiKey("TEST_REJECTED_KEY")], fetch: { _ in FetchResult(try server.call()) })
        return try .init(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: [spec])
    }

    private func state(_ manager: AccountManager, _ id: UUID) async throws -> VerificationState? {
        try await manager.status().accounts.first { $0.id == id }?.verification.state
    }

    private func signInEvents() throws -> Int {
        let text = (try? String(contentsOf: paths.applicationSupport.appending(path: "logs/events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { $0.contains(#""event":"sign_in_required""#) }.count
    }

    private func assertNeedsSignIn(_ manager: AccountManager, _ id: UUID, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await manager.readProviderUsage(accountID: id)
            XCTFail("expected a sign-in error", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? ProviderError)?.needsSignIn, true, "\(error)", file: file, line: line)
        }
    }

    func testRejectedKeyIsSavedAsNeedsSignInAndIsNotRetried() async throws {
        let server = Server()
        server.answer = .unauthorized("The provider rejected this credential. Sign in again or replace it.")
        let manager = try manager(server)
        let account = try await manager.addProviderAccount(providerID: providerID, fields: ["apiKey": "synthetic-key-1"])

        await assertNeedsSignIn(manager, account.id)
        XCTAssertEqual(server.calls, 1)
        let saved = try await state(manager, account.id)
        XCTAssertEqual(saved, .needsSignIn)

        // The 10-minute cadence calls again: no request reaches the provider.
        for _ in 0..<5 { await assertNeedsSignIn(manager, account.id) }
        XCTAssertEqual(server.calls, 1)
        XCTAssertEqual(try signInEvents(), 1)
    }

    func testSigningInAgainResumesRefreshes() async throws {
        let server = Server()
        server.answer = .unauthorized("rejected")
        let manager = try manager(server)
        let account = try await manager.addProviderAccount(providerID: providerID, fields: ["apiKey": "synthetic-key-2"])
        await assertNeedsSignIn(manager, account.id)

        server.answer = nil
        _ = try await manager.addProviderAccount(providerID: providerID, fields: ["apiKey": "synthetic-key-2"])
        _ = try await manager.readProviderUsage(accountID: account.id)
        XCTAssertEqual(server.calls, 2)
        let saved = try await state(manager, account.id)
        XCTAssertEqual(saved, .verifiedLocally)
    }

    func testAnExplicitCheckStillAsksTheProvider() async throws {
        let server = Server()
        server.answer = .unauthorized("rejected")
        let manager = try manager(server)
        let account = try await manager.addProviderAccount(providerID: providerID, fields: ["apiKey": "synthetic-key-3"])
        await assertNeedsSignIn(manager, account.id)

        server.answer = nil
        let checked = await manager.checkAccount(accountID: account.id)
        XCTAssertEqual(checked.verification.state, .verifiedLocally)
        XCTAssertEqual(server.calls, 2)
        _ = try await manager.readProviderUsage(accountID: account.id)
        XCTAssertEqual(server.calls, 3)
    }

    func testRateLimitIsNotARejectedKey() async throws {
        let server = Server()
        let response = HTTPResponse(status: 403, data: Data(), headers: ["retry-after": "120"])
        XCTAssertThrowsError(try HTTP.check(response)) { server.answer = $0 as? ProviderError }
        let manager = try manager(server)
        let account = try await manager.addProviderAccount(providerID: providerID, fields: ["apiKey": "synthetic-key-4"])

        for _ in 0..<2 {
            do { _ = try await manager.readProviderUsage(accountID: account.id); XCTFail("expected a rate limit") }
            catch { XCTAssertEqual((error as? ProviderError)?.needsSignIn, false, "\(error)") }
        }
        XCTAssertEqual(server.calls, 2)
        let saved = try await state(manager, account.id)
        XCTAssertNotEqual(saved, .needsSignIn)
        XCTAssertEqual(try signInEvents(), 0)
    }
}
