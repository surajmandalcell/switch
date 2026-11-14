import Foundation
import AIManagerCore

public enum UsageHistorySourceList {
    // shortcut: written from the Mac AccountViewModel.loadUsageHistory source list, which keeps its own copy until
    // the Mac app adopts SwitchAppModel. The CLI `history` command calls this.
    /// The Overview sources: the Codex activity ledger and provider charts always; Claude, Grok, and Droid logs only
    /// outside a test home. Providers with a transcript scanner are never counted again from their charts.
    public static func make(paths: ManagerPaths, accounts: [AccountRecord], historyAccounts: [HistoricalUsageAccount],
                            ledger: CodexUsageStatisticsCache?, providerUsage: [UUID: ProviderUsage],
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> UsageHistorySources {
        let support = paths.applicationSupport
        var sources = UsageHistorySources(ledger: ledger)
        sources.accounts = Dictionary(grouping: historyAccounts, by: { $0.providerID.rawValue })
            .mapValues { $0.map { $0.id.uuidString.lowercased() } }
        // A test home never reads the real Claude, Grok, or Droid folders, nor fetches prices.
        if paths.isolationRoot == nil {
            let pricing = ClaudePricingSource(cacheURL: support.appending(path: "cache/model-pricing.json")).loader()
            sources.pricing = pricing
            sources.claude = ClaudeCostScanner(
                roots: ClaudeCostScanner.defaultRoots(environment: environment, home: paths.userHome),
                cacheURL: support.appending(path: "cache/claude-history.json"), pricing: pricing)
            sources.claudeHomes = UsageHistory.claudeProfileHomes(accounts: accounts)
            sources.grokSessions = paths.grokHome.appending(path: "sessions", directoryHint: .isDirectory)
            sources.droidSessions = DroidUsage.sessionsFolder(droidHome: paths.droidHome)
        }
        let scanned: Set<ProviderID> = [.codex, .claudeCode, .grokBuild, .droid]
        sources.charts = accounts.filter { !scanned.contains($0.identity.providerID) }.flatMap { account in
            (providerUsage[account.id]?.charts ?? []).map {
                ProviderChartSource(service: account.identity.providerID.rawValue,
                                    accountID: account.id.uuidString.lowercased(), chart: $0)
            }
        }
        return sources
    }
}

extension AppEngine {
    public static let usageHistoryMaxAge: TimeInterval = 60

    /// The Overview snapshot. One younger than `maxAge` is reused, so a page switch answers at once.
    public func usageHistory(maxAge: TimeInterval = AppEngine.usageHistoryMaxAge) async throws -> UsageHistorySnapshot {
        if let history, let loadedAt = historyLoadedAt, clock.now.timeIntervalSince(loadedAt) < maxAge {
            return history
        }
        guard let manager else { throw AppEngineError.unavailable }
        let accounts = try await manager.status().accounts
        let historyAccounts = try await manager.usageHistoryAccounts()
        let sources = UsageHistorySourceList.make(
            paths: paths, accounts: accounts, historyAccounts: historyAccounts, ledger: codexCache,
            providerUsage: providerUsage.compactMapValues(\.usage))
        let engine = UsageHistory(sources: sources)
        let snapshot = await engine.snapshot(now: clock.now)
        history = snapshot
        historyEngine = engine
        historyLoadedAt = clock.now
        return snapshot
    }

    /// The day sheet for one UTC day: that day's history points and its sessions.
    public func usageDay(_ day: String) async throws -> (points: [UsageHistoryPoint], sessions: [UsageDaySession]) {
        let snapshot = try await usageHistory()
        let points = snapshot.points.filter { $0.day == day }
        let sessions = await historyEngine?.daySessions(day: day) ?? []
        return (points, sessions)
    }
}
