import Foundation
import AIManagerCore
import SwitchAppModel

/// The read-only methods of architecture.md section 2.9. `usage.history` and `usage.day` go through the engine.
extension RPCServer {
    static let readMethods = [
        "providers.list", "accounts.savedAuthPath", "accounts.inspectLinks", "import.discover",
        "claude.shellIntegration.get", "droid.missions", "history.list", "history.detail", "history.export",
        "cleanup.sources", "cleanup.trashList", "cleanup.samples", "backup.list", "backup.history",
        "usage.projectActivity", "runningCLIs.list", "usage.history", "usage.day", "autoSwitch.preview",
        "app.searchIndex", "tray.rows",
    ]

    /// Nil when `method` is not a read method.
    func readMethod(_ method: String, frame: Data) async throws -> (any Encodable)? {
        switch method {
        case "providers.list":
            return AccountManager.providerCatalog
        case "tray.rows":
            // The `tray` topic value with reset texts computed now (the popover's 60 s countdown tick).
            return await engine.trayValue()
        case "app.searchIndex":
            // Every Settings row in page order, or the rows that match `query`, best first (the Mac toolbar search).
            return SettingsSearch.search((try? params(QueryParams.self, method: method, frame: frame))?.query ?? "")
        case "accounts.savedAuthPath":
            let params = try params(AccountParams.self, method: method, frame: frame)
            return ["path": try await account(try accountID(params.accountID)).credentialFile.path]
        case "accounts.inspectLinks":
            let params = try? params(OptionalAccountParams.self, method: method, frame: frame)
            let filter = try params?.accountID.map(accountID)
            return try await requireManager().status().linkedSettingsDivergences
                .filter { filter == nil || $0.accountID == filter }.map(WireDivergence.init)
        case "import.discover":
            let folder = (try? params(FolderParams.self, method: method, frame: frame))?.folder
            return try await requireManager().discover(explicit: folder.map { URL(fileURLWithPath: $0) })
                .map(WireDiscoveredSource.init)
        case "claude.shellIntegration.get":
            return ["enabled": try await requireManager().claudeShellIntegrationInstalled()]
        case "droid.missions":
            return try await requireManager().droidMissions().map(WireMission.init)
        case "history.list":
            let params = (try? params(HistoryListParams.self, method: method, frame: frame)) ?? .init()
            let limit = params.limit ?? 100
            guard (1...1_000).contains(limit) else { throw RPCError(-32602, "invalidParams", "limit must be 1 to 1000.") }
            return WireThreadList(try await chatIndex().refresh(query: params.query ?? "", limit: limit))
        case "history.detail":
            let params = try params(HistoryDetailParams.self, method: method, frame: frame)
            let limit = params.limit ?? 100
            guard (1...200).contains(limit) else { throw RPCError(-32602, "invalidParams", "limit must be 1 to 200.") }
            return WireThreadDetail(try await threadDetail(params.id, offset: params.offset ?? 0, limit: limit,
                                                          query: params.query ?? "", role: params.role))
        case "history.export":
            let params = try params(HistoryDetailParams.self, method: method, frame: frame)
            var text: [String] = []
            var offset: Int? = 0
            while let next = offset {
                let detail = try await threadDetail(params.id, offset: next, limit: 200, query: params.query ?? "",
                                                    role: params.role)
                text.append(ChatTranscriptExport.text(for: detail.messages))
                offset = detail.nextOffset
            }
            return ["text": text.joined(separator: "\n")]
        case "cleanup.sources":
            return try await cleanupSources().map(WireCleanupSource.init)
        case "cleanup.trashList":
            let params = try params(SourceParams.self, method: method, frame: frame)
            guard let source = try await cleanupSources().first(where: { $0.id == params.sourceID }) else {
                throw RPCError(-32003, "notFound", "No cleanup source has that ID.")
            }
            return try await requireManager().cleanupTrash(source).map(WireCleanupBatch.init)
        case "cleanup.samples":
            return try await requireCodexCache().cleanupSamples().map(WireUsageSample.init)
        case "backup.list":
            return try await BackupEngine(applicationSupport: paths.applicationSupport).sets().map(WireBackupSet.init)
        case "backup.history":
            let params = try params(SetParams.self, method: method, frame: frame)
            let engine = BackupEngine(applicationSupport: paths.applicationSupport)
            guard let set = try await engine.sets().first(where: { $0.id.uuidString.lowercased() == params.setID.lowercased() }) else {
                throw RPCError(-32003, "notFound", "No backup set has that ID.")
            }
            return WireBackupStatus(try await engine.status(for: set))
        case "usage.projectActivity":
            let params = try params(DayParams.self, method: method, frame: frame)
            return try await requireCodexCache().projectActivity(on: params.day).map(WireProjectActivity.init)
        case "runningCLIs.list":
            let claudeConfig = paths.userHome.appending(path: ".claude", directoryHint: .isDirectory)
            return RunningCLIs.find(claudeDefaultConfig: claudeConfig).map(WireRunningCLI.init)
        case "usage.history":
            let params = (try? params(UsageHistoryParams.self, method: method, frame: frame)) ?? .init()
            guard let period = UsagePeriod(rawValue: params.period ?? "week"),
                  let grouping = UsageGrouping(rawValue: params.grouping ?? "account") else {
                throw RPCError(-32602, "invalidParams", "period must be week, month, or year; grouping account, model, or project.")
            }
            let snapshot = try await engine.usageHistory()
            return WireUsageHistory(snapshot, summary: snapshot.summary(period: period, grouping: grouping))
        case "usage.day":
            let day = try params(DayParams.self, method: method, frame: frame).day
            let parts = day.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.map(\.count) == [4, 2, 2], parts.allSatisfy({ $0.allSatisfy(\.isASCII) && Int($0) != nil }) else {
                throw RPCError(-32602, "invalidParams", "day must be a UTC day such as 2026-11-14.")
            }
            let (points, sessions) = try await engine.usageDay(day)
            return WireUsageDay(day: day, points: points, sessions: sessions.map(WireDaySession.init),
                                threads: try await linkedThreads(sessions.compactMap(\.threadID)))
        case "autoSwitch.preview":
            return await engine.autoSwitchPreview()
        default:
            return nil
        }
    }

    /// The Conversations threads behind a day's Codex sessions: the newest list first, then a search for older ids.
    private func linkedThreads(_ ids: [String]) async throws -> [WireThread] {
        guard !ids.isEmpty else { return [] }
        let index = chatIndex()
        var threads: [String: ChatThreadSummary] = [:]
        for thread in try await index.refresh(query: "").threads { threads[thread.threadID] = thread }
        for id in ids where threads[id] == nil {
            if let thread = await index.search(query: id).threads.first(where: { $0.threadID == id }) { threads[id] = thread }
        }
        return Set(ids).compactMap { threads[$0] }.sorted { $0.updatedAt > $1.updatedAt }.map(WireThread.init)
    }

    private func chatIndex() -> ChatHistoryIndex { engine.chatHistory }

    private func threadDetail(_ id: String, offset: Int, limit: Int, query: String, role: String?) async throws
        -> ChatThreadDetail {
        let roles: [String: ChatMessageFilter] = ["all": .all, "prompts": .prompts, "responses": .responses,
                                                  "tools": .tools, "other": .other]
        guard let filter = roles[role ?? "all"] else {
            throw RPCError(-32602, "invalidParams", "role must be all, prompts, responses, tools, or other.")
        }
        let index = chatIndex()
        _ = try await index.refresh(limit: 1)
        guard let detail = try await index.detail(for: id, offset: max(0, offset), limit: limit, query: query,
                                                  filter: filter) else {
            throw RPCError(-32003, "notFound", "No conversation has that ID.")
        }
        return detail
    }

    private func cleanupSources() async throws -> [CleanupSource] {
        CleanupSources.make(paths: paths, accounts: try await requireManager().status().accounts)
    }

    private func requireCodexCache() throws -> CodexUsageStatisticsCache {
        guard let codexCache else { throw RPCError(-32002, "unavailable", "Switch cannot open its usage cache.") }
        return codexCache
    }
}

private struct AccountParams: Decodable { let accountID: String }
private struct OptionalAccountParams: Decodable { let accountID: String? }
private struct FolderParams: Decodable { let folder: String? }
private struct QueryParams: Decodable { let query: String? }
private struct HistoryListParams: Decodable { var query: String? = nil; var limit: Int? = nil }
private struct HistoryDetailParams: Decodable {
    let id: String
    let offset: Int?
    let limit: Int?
    let query: String?
    let role: String?
}
private struct SourceParams: Decodable { let sourceID: String }
private struct SetParams: Decodable { let setID: String }
private struct DayParams: Decodable { let day: String }
private struct UsageHistoryParams: Decodable { var period: String? = nil; var grouping: String? = nil }
