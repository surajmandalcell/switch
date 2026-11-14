import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel

final class AppEngineHistoryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AppEngineHistoryTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func paths(isolated: Bool) -> ManagerPaths {
        .init(applicationSupport: root.appending(path: "support"), defaultHome: root.appending(path: "user/.codex"),
              sharedRoot: root.appending(path: "user/.codex"), orcaAccountsRoot: root.appending(path: "orca"),
              grokHome: root.appending(path: "user/.grok"), droidHome: root.appending(path: "user/.factory"),
              isolationRoot: isolated ? root : nil)
    }

    func account(_ provider: ProviderID) -> AccountRecord {
        AccountRecord(id: UUID(), identity: .init(providerID: provider, authMode: .apiKey), home: root, source: root,
                      importedAt: Date(), verification: .init(state: .verifiedLocally, detail: ""), credentialDigest: "")
    }

    func testSourceListKeepsTestHomesOffRealLogsAndChartsOffScannedProviders() {
        let codex = account(.codex)
        let other = account(ProviderID(rawValue: "test-history"))
        let chart = UsageChart(id: "tokens", title: "Tokens", unit: "tokens",
                               points: [UsagePoint(label: "2026-11-14", value: 10)])
        let usage = [codex.id: ProviderUsage(charts: [chart]), other.id: ProviderUsage(charts: [chart])]
        let owners = [HistoricalUsageAccount(id: codex.id, providerID: .codex)]

        let isolated = UsageHistorySourceList.make(paths: paths(isolated: true), accounts: [codex, other],
                                                   historyAccounts: owners, ledger: nil, providerUsage: usage,
                                                   environment: [:])
        XCTAssertNil(isolated.claude)
        XCTAssertNil(isolated.grokSessions)
        XCTAssertNil(isolated.droidSessions)
        XCTAssertNil(isolated.pricing)
        XCTAssertEqual(isolated.accounts, ["codex": [codex.id.uuidString.lowercased()]])
        XCTAssertEqual(isolated.charts.map(\.accountID), [other.id.uuidString.lowercased()], "Codex is scanned, not charted")

        let live = UsageHistorySourceList.make(paths: paths(isolated: false), accounts: [codex, other],
                                               historyAccounts: owners, ledger: nil, providerUsage: usage,
                                               environment: [:])
        XCTAssertNotNil(live.claude)
        XCTAssertNotNil(live.pricing)
        XCTAssertEqual(live.grokSessions, root.appending(path: "user/.grok/sessions", directoryHint: .isDirectory))
    }

    func testSnapshotIsReusedForSixtySeconds() async throws {
        let paths = paths(isolated: true)
        let clock = ManualClock()
        let engine = AppEngine(manager: try AccountManager(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: []),
                               paths: paths, clock: clock)
        _ = try await engine.usageHistory()
        let first = await engine.historyLoadedAt
        clock.advance(seconds: 59)
        _ = try await engine.usageHistory()
        var loadedAt = await engine.historyLoadedAt
        XCTAssertEqual(loadedAt, first)
        clock.advance(seconds: 1)
        let (points, sessions) = try await engine.usageDay("2026-11-14")
        loadedAt = await engine.historyLoadedAt
        XCTAssertEqual(loadedAt, clock.now)
        XCTAssertTrue(points.isEmpty)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testUnavailableEngineHasNoHistory() async {
        let engine = AppEngine(manager: nil, paths: paths(isolated: true), clock: ManualClock())
        do {
            _ = try await engine.usageHistory()
            XCTFail("no history without the data folder")
        } catch {
            XCTAssertEqual(error as? AppEngineError, .unavailable)
        }
    }
}
