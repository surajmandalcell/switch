import Foundation
import AIManagerCore

public enum UsageHistorySourceList {
    // shortcut: written from the Mac AccountViewModel.loadUsageHistory source list, which keeps its own copy until
    // the Mac app adopts SwitchAppModel. The CLI `history` command calls this.
    /// The Overview sources: the Codex activity ledger and provider charts always; Claude logs only outside a test
    /// home; Grok and Droid logs when their folder is inside the test home. Providers with a transcript scanner are
    /// never counted again from their charts.
    public static func make(paths: ManagerPaths, accounts: [AccountRecord], historyAccounts: [HistoricalUsageAccount],
                            ledger: CodexUsageStatisticsCache?, providerUsage: [UUID: ProviderUsage],
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> UsageHistorySources {
        let support = paths.applicationSupport
        var sources = UsageHistorySources(ledger: ledger)
        sources.accounts = Dictionary(grouping: historyAccounts, by: { $0.providerID.rawValue })
            .mapValues { $0.map { $0.id.uuidString.lowercased() } }
        // A test home never reads the real Claude, Grok, or Droid folders, nor fetches prices. Its own Grok and
        // Droid folders are synthetic, so they are read.
        let grok = paths.grokHome.appending(path: "sessions", directoryHint: .isDirectory)
        if paths.allowsRead(grok) { sources.grokSessions = grok }
        let droid = DroidUsage.sessionsFolder(droidHome: paths.droidHome)
        if paths.allowsRead(droid) { sources.droidSessions = droid }
        if paths.isolationRoot == nil {
            let pricing = ClaudePricingSource(cacheURL: support.appending(path: "cache/model-pricing.json")).loader()
            sources.pricing = pricing
            sources.claude = ClaudeCostScanner(
                roots: ClaudeCostScanner.defaultRoots(environment: environment, home: paths.userHome),
                cacheURL: support.appending(path: "cache/claude-history.json"), pricing: pricing)
            sources.claudeHomes = UsageHistory.claudeProfileHomes(accounts: accounts)
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

    public func overviewHistory(period: UsagePeriod, grouping: UsageGrouping, calendar: Calendar = .current)
        async throws -> (snapshot: UsageHistorySnapshot, summary: UsageSummary, unavailableSources: [String]) {
        let snapshot = try await usageHistory()
        let summary = snapshot.summary(period: period, grouping: grouping, now: clock.now, calendar: calendar)
        // shortcut: copy of OverviewPage.swift.OverviewHour.missingNote; delete when the Mac app adopts SwitchAppModel
        let dailyOnly = period == .today ? ["codex-account-totals", "droid", "provider-charts"] : []
        return (snapshot, summary, snapshot.unavailableSources + dailyOnly)
    }

    static func makeClaudeChatHistory(paths: ManagerPaths) -> ClaudeChatIndex {
        // shortcut: copy of AccountViewModel.swift.IndexedChatHistoryProvider setup; delete when the Mac app adopts SwitchAppModel
        let roots = if let root = paths.isolationRoot {
            [root, paths.userHome].flatMap { home in
                [home.appending(path: ".claude"), home.appending(path: ".config/claude")]
            }
        } else {
            ClaudeCostScanner.defaultRoots(home: paths.userHome)
        }
        return ClaudeChatIndex(roots: roots,
                               cacheFile: paths.applicationSupport.appending(path: "cache/claude-chat-history-v1.json"),
                               allowsRead: { paths.allowsRead($0) })
    }

    // shortcut: copy of AccountViewModel.swift.IndexedChatHistoryProvider.refresh; delete when the Mac app adopts SwitchAppModel
    public func conversationHistory(query: String, limit: Int, sources: Set<ChatThreadSource> = [])
        async throws -> (snapshot: ChatHistorySnapshot, appCounts: [String: Int]) {
        let accounts: [AccountRecord]
        if let status { accounts = status.accounts }
        else { accounts = (try? await manager?.status())?.accounts ?? [] }
        let homes = UsageHistory.claudeProfileHomes(accounts: accounts).values.filter { paths.allowsRead($0) }
        await claudeChatHistory.addRoots(homes)
        async let codex = chatHistory.refresh(query: query, limit: limit, sources: sources)
        async let claude = claudeChatHistory.refresh(query: query, limit: limit, sources: sources)
        let snapshot = try await ChatHistorySnapshot.merging(codex, claude, limit: limit)
        let counts = snapshot.librarySourceCounts.map { ($0.key.rawValue, $0.value) }
        return (snapshot, Dictionary(uniqueKeysWithValues: counts))
    }

    // shortcut: copy of AccountViewModel.swift.IndexedChatHistoryProvider.page; delete when the Mac app adopts SwitchAppModel
    public func conversationDetail(id: String, offset: Int, limit: Int, query: String, filter: ChatMessageFilter)
        async throws -> ChatThreadDetail {
        _ = try await conversationHistory(query: "", limit: 1)
        if let detail = try await claudeChatHistory.detail(for: id, offset: offset, limit: limit, query: query, filter: filter) {
            return detail
        }
        guard let detail = try await chatHistory.detail(for: id, offset: offset, limit: limit, query: query, filter: filter) else {
            throw AppEngineError.notFound("No conversation has that ID.")
        }
        return detail
    }
}
