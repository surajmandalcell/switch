import Foundation

// Usage history for the Overview dashboard: one year of daily points from the activity ledger,
// Claude Code logs, Grok Build sessions and provider charts, grouped by account, model or project.
//
// Attribution: a point carries an account only when its source belongs to one account (Codex
// authoritative account/day totals, a Claude profile with its own history folder, a Grok Build
// home with one account, a provider chart). Shared-home transcripts never carry one, so "by
// account" never includes them; "by model" and "by project" use every transcript.

public struct UsageHistoryPoint: Codable, Equatable, Sendable {
    /// UTC day, `yyyy-MM-dd`.
    public var day: String
    /// Provider id, such as `codex`, `claude-code`, `grok-build`.
    public var service: String
    public var accountID: String?
    public var model: String?
    /// Project folder path, or "Unknown project", for transcript points. Nil for account totals.
    public var project: String?
    public var tokens: Int64
    /// Estimated USD when a price is known (an input-rate equivalent, never billed cost).
    public var costUSD: Double?

    public init(day: String, service: String, accountID: String? = nil, model: String? = nil,
                project: String? = nil, tokens: Int64, costUSD: Double? = nil) {
        self.day = day
        self.service = service
        self.accountID = accountID
        self.model = model
        self.project = project
        self.tokens = tokens
        self.costUSD = costUSD
    }

    /// An account/day total has neither model nor project. It overlaps the transcripts of the
    /// same service, so day totals take the larger of the two views, never their sum.
    var isAccountTotal: Bool { model == nil && project == nil }
}

/// One thread, log, or session with usage on one UTC day.
public struct UsageDaySession: Identifiable, Sendable, Equatable {
    public let id: String
    /// Provider id, such as `codex`, `claude-code`, `grok-build`.
    public let service: String
    public let accountID: String?
    /// The Codex thread id Conversations knows the transcript by; nil for other tools.
    public let threadID: String?
    public let project: String
    /// The model with the most tokens that day.
    public let model: String?
    public let start: Date?
    public let tokens: Int64
    public let costUSD: Double?

    public init(id: String, service: String, accountID: String? = nil, threadID: String? = nil,
                project: String, model: String? = nil, start: Date? = nil, tokens: Int64, costUSD: Double? = nil) {
        self.id = id
        self.service = service
        self.accountID = accountID
        self.threadID = threadID
        self.project = project
        self.model = model
        self.start = start
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

public enum UsagePeriod: String, Codable, CaseIterable, Sendable {
    case week, month, year

    public var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .year: 365
        }
    }
}

public enum UsageGrouping: String, Codable, CaseIterable, Sendable {
    case account, model, project
}

public struct UsageGroup: Codable, Equatable, Sendable {
    /// Account id, model name, or project path. "unknown" holds transcript tokens with no model.
    public let key: String
    /// Display text for models and projects; the account id for accounts (the caller maps names).
    public let label: String
    /// Providers that contributed, most tokens first (for brand colors).
    public let services: [String]
    public let tokens: Int64
    /// Sum of the priced share; nil when nothing in the group has a price.
    public let costUSD: Double?
    /// Tokens per day, aligned with `UsageSummary.days`.
    public let daily: [Int64]
}

public struct UsageTotals: Codable, Equatable, Sendable {
    public let tokens: Int64
    public let costUSD: Double?
    public let activeAccounts: Int
    public let busiestDay: String?
    public let busiestDayTokens: Int64
}

public struct UsageSummary: Codable, Equatable, Sendable {
    public let period: UsagePeriod
    public let grouping: UsageGrouping
    /// Oldest first, ending today (UTC).
    public let days: [String]
    /// Tokens per day across everything, aligned with `days` (the heatmap for `.year`).
    public let dailyTotals: [Int64]
    /// Most tokens first.
    public let groups: [UsageGroup]
    public let totals: UsageTotals
}

public struct UsageHistorySnapshot: Sendable {
    public let points: [UsageHistoryPoint]
    /// Today in UTC.
    public let today: String
    /// Sources that failed to read, such as "ledger". Their data is missing, not zero.
    public let unavailableSources: [String]

    public init(points: [UsageHistoryPoint], today: String, unavailableSources: [String] = []) {
        self.points = points
        self.today = today
        self.unavailableSources = unavailableSources
    }

    /// One pass over the points; cheap enough to call on every period or grouping change.
    public func summary(period: UsagePeriod, grouping: UsageGrouping) -> UsageSummary {
        let days = Self.days(period.days, endingAt: today)
        var index: [String: Int] = [:]
        for (offset, day) in days.enumerated() { index[day] = offset }
        let zeros = [Int64](repeating: 0, count: days.count)

        struct Accumulator {
            var label: String
            var tokens: Int64 = 0
            var cost: Double?
            var daily: [Int64]
            var services: [String: Int64] = [:]
        }
        var groups: [String: Accumulator] = [:]
        var accountViews: [String: [Int64]] = [:]
        var transcriptViews: [String: [Int64]] = [:]
        var cost: Double?
        var accounts = Set<String>()

        for point in points {
            guard let slot = index[point.day] else { continue }
            if point.isAccountTotal {
                accountViews[point.service, default: zeros][slot] += point.tokens
            } else {
                transcriptViews[point.service, default: zeros][slot] += point.tokens
            }
            if let value = point.costUSD { cost = (cost ?? 0) + value }
            if let account = point.accountID, point.tokens > 0 || (point.costUSD ?? 0) > 0 {
                accounts.insert(account)
            }

            let key: String?
            let label: String
            switch grouping {
            case .account:
                key = point.accountID
                label = point.accountID ?? ""
            case .model:
                key = point.isAccountTotal ? nil : (point.model ?? "unknown")
                label = point.model ?? "Unknown model"
            case .project:
                key = point.project
                label = point.project.map(Self.projectLabel) ?? ""
            }
            guard let key else { continue }
            var group = groups[key] ?? Accumulator(label: label, daily: zeros)
            group.tokens += point.tokens
            group.daily[slot] += point.tokens
            group.services[point.service, default: 0] += point.tokens
            if let value = point.costUSD { group.cost = (group.cost ?? 0) + value }
            groups[key] = group
        }

        var dailyTotals = zeros
        for service in Set(accountViews.keys).union(transcriptViews.keys) {
            let account = accountViews[service] ?? zeros
            let transcript = transcriptViews[service] ?? zeros
            for slot in zeros.indices { dailyTotals[slot] += max(account[slot], transcript[slot]) }
        }
        let busiest = dailyTotals.enumerated().max { ($0.element, $1.offset) < ($1.element, $0.offset) }
        let ordered = groups.map { key, group in
            UsageGroup(key: key, label: group.label,
                       services: group.services.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key),
                       tokens: group.tokens, costUSD: group.cost, daily: group.daily)
        }.sorted { ($1.tokens, $0.key) < ($0.tokens, $1.key) }
        return UsageSummary(
            period: period, grouping: grouping, days: days, dailyTotals: dailyTotals, groups: ordered,
            totals: UsageTotals(
                tokens: dailyTotals.reduce(0, +), costUSD: cost, activeAccounts: accounts.count,
                busiestDay: busiest.flatMap { $0.element > 0 ? days[$0.offset] : nil },
                busiestDayTokens: busiest?.element ?? 0))
    }

    static func projectLabel(_ project: String) -> String {
        let name = URL(fileURLWithPath: project).lastPathComponent
        return project.hasPrefix("/") && !name.isEmpty ? name : project
    }

    /// `count` UTC days ending at `end`, oldest first.
    static func days(_ count: Int, endingAt end: String) -> [String] {
        guard let last = UsageHistory.epochDay(end) else { return [] }
        return (0..<count).map { ClaudeCostScanner.utcDayName(last - count + 1 + $0) }
    }
}

/// A provider's own daily chart for one account, such as 30 days of tokens or spend. Only
/// providers without a transcript scanner belong here (Codex, Claude Code and Grok Build are read
/// from their logs and ledger); their charts are ignored.
public struct ProviderChartSource: Sendable {
    public var service: String
    public var accountID: String
    public var chart: UsageChart

    public init(service: String, accountID: String, chart: UsageChart) {
        self.service = service
        self.accountID = accountID
        self.chart = chart
    }
}

public struct UsageHistorySources: Sendable {
    /// The activity ledger: Codex account/day totals and shared-home transcript days.
    public var ledger: CodexUsageStatisticsCache?
    /// Claude Code logs. Use a cache file apart from the 30 day cost scan.
    public var claude: ClaudeCostScanner?
    /// Claude profile id -> its config folder. A log is attributed to a profile only when its real
    /// path lies inside that folder, which is not the case for profiles that link to shared history.
    public var claudeHomes: [String: URL]
    /// Grok Build `sessions` folder, and the account that owns the home (nil with several accounts).
    public var grokSessions: URL?
    public var grokAccountID: String?
    public var charts: [ProviderChartSource]
    /// LiteLLM rates, used for Codex cost.
    public var pricing: (@Sendable () async -> [String: ModelRate])?

    public init(ledger: CodexUsageStatisticsCache? = nil, claude: ClaudeCostScanner? = nil,
                claudeHomes: [String: URL] = [:], grokSessions: URL? = nil, grokAccountID: String? = nil,
                charts: [ProviderChartSource] = [],
                pricing: (@Sendable () async -> [String: ModelRate])? = nil) {
        self.ledger = ledger
        self.claude = claude
        self.claudeHomes = claudeHomes
        self.grokSessions = grokSessions
        self.grokAccountID = grokAccountID
        self.charts = charts
        self.pricing = pricing
    }
}

public actor UsageHistory {
    public static let windowDays = 365

    private struct GrokFile {
        var size: Int
        var modified: Date
        var turns: [MajorsSpend.Entry]
    }

    private let sources: UsageHistorySources
    private var grokFiles: [String: GrokFile] = [:]

    public init(sources: UsageHistorySources) {
        self.sources = sources
    }

    /// The last 365 UTC days. Unchanged logs are served from caches, so a repeat call reads only
    /// stat data and the ledger. Run it off the main actor; a first call may parse logs.
    public func snapshot(now: Date = Date()) async -> UsageHistorySnapshot {
        let today = ClaudeCostScanner.utcDayName(Int((now.timeIntervalSince1970 / 86_400).rounded(.down)))
        let start = ClaudeCostScanner.utcDayName(Int((now.timeIntervalSince1970 / 86_400).rounded(.down)) - Self.windowDays + 1)
        var points: [UsageHistoryPoint] = []
        var unavailable: [String] = []

        if let ledger = sources.ledger {
            do {
                points += try await ledgerPoints(ledger, from: start, through: today)
            } catch {
                unavailable.append("ledger")
            }
        }
        if let claude = sources.claude {
            let homes = sources.claudeHomes.map { ($0.key, $0.value.resolvingSymlinksInPath().path + "/") }
            let rows = await claude.history(days: Self.windowDays, now: now) { path in
                homes.first { path.hasPrefix($0.1) }?.0
            }
            points += rows.map {
                UsageHistoryPoint(day: $0.day, service: ProviderID.claudeCode.rawValue, accountID: $0.accountID,
                                  model: $0.model, project: $0.project, tokens: $0.tokens, costUSD: $0.costUSD)
            }
        }
        if let sessions = sources.grokSessions {
            points += grokPoints(sessions, start: start, today: today, now: now)
        }
        points += chartPoints(start: start, through: today)
        return UsageHistorySnapshot(points: points, today: today, unavailableSources: unavailable)
    }

    // MARK: Sources

    private func ledgerPoints(_ ledger: CodexUsageStatisticsCache, from start: String, through end: String)
        async throws -> [UsageHistoryPoint] {
        let service = ProviderID.codex.rawValue
        var points = try await ledger.accountDays(from: start, through: end).map {
            UsageHistoryPoint(day: $0.day, service: service, accountID: $0.accountID, tokens: $0.tokens)
        }
        let threads = try await ledger.threadDays(from: start, through: end)
        var rates: [String: ModelRate] = [:]
        if let pricing = sources.pricing, threads.contains(where: { $0.model != nil && $0.input + $0.output > 0 }) {
            rates = await pricing()
        }
        var table = ModelRateTable(rates)
        for row in threads {
            let cost = Self.codexCost(model: row.model, input: row.input, cached: row.cached, output: row.output, table: &table)
            points.append(UsageHistoryPoint(day: row.day, service: service, model: row.model,
                                            project: row.project, tokens: row.tokens, costUSD: cost))
        }
        return points
    }

    /// Cached input is part of input; reasoning is part of output.
    private static func codexCost(model: String?, input: Int64, cached: Int64, output: Int64,
                                  table: inout ModelRateTable) -> Double? {
        guard let model, input + output > 0, let rate = table.resolve(model) else { return nil }
        return (Double(max(input - cached, 0)) * rate.inputPerMillion
            + Double(cached) * rate.cacheReadPerMillion
            + Double(output) * rate.outputPerMillion) / 1_000_000
    }

    // MARK: Sessions of one day

    /// The sessions with usage on one UTC day, most tokens first, from the same files as `snapshot`:
    /// Codex threads from the ledger, Claude Code logs, Grok Build sessions. Sources that keep no
    /// per-session data (provider charts, account totals) add none. Run it off the main actor.
    public func daySessions(day: String) async -> [UsageDaySession] {
        var sessions: [UsageDaySession] = []
        if let ledger = sources.ledger, let rows = try? await ledger.threadSessions(day: day) {
            var rates: [String: ModelRate] = [:]
            if let pricing = sources.pricing, rows.contains(where: { $0.model != nil && $0.input + $0.output > 0 }) {
                rates = await pricing()
            }
            var table = ModelRateTable(rates)
            struct Sum { var project = ""; var first = ""; var tokens: Int64 = 0; var cost: Double?; var models: [String: Int64] = [:] }
            var threads: [String: Sum] = [:]
            for row in rows {
                var sum = threads[row.threadID] ?? Sum()
                (sum.project, sum.first) = (row.project, row.firstEvent)
                sum.tokens += row.tokens
                if let cost = Self.codexCost(model: row.model, input: row.input, cached: row.cached, output: row.output, table: &table) {
                    sum.cost = (sum.cost ?? 0) + cost
                }
                if let model = row.model { sum.models[model, default: 0] += row.tokens }
                threads[row.threadID] = sum
            }
            let service = ProviderID.codex.rawValue
            sessions += threads.map { id, sum in
                UsageDaySession(
                    id: id, service: service, threadID: id.hasPrefix("codex:") ? String(id.dropFirst(6)) : id,
                    project: sum.project, model: sum.models.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key,
                    start: Self.firstEventDate(sum.first), tokens: sum.tokens, costUSD: sum.cost)
            }
        }
        if let claude = sources.claude {
            let homes = sources.claudeHomes.map { ($0.key, $0.value.resolvingSymlinksInPath().path + "/") }
            sessions += await claude.daySessions(day: day) { path in homes.first { path.hasPrefix($0.1) }?.0 }.map {
                UsageDaySession(id: "claude-code:" + $0.sessionID, service: ProviderID.claudeCode.rawValue,
                                accountID: $0.accountID, project: $0.project, model: $0.model, start: $0.start,
                                tokens: $0.tokens, costUSD: $0.costUSD)
            }
        }
        if let root = sources.grokSessions?.resolvingSymlinksInPath().path {
            var seen = Set<String>()
            struct Sum { var tokens: Int64 = 0; var cost: Double?; var start = Date.distantFuture; var models: [String: Int64] = [:] }
            for path in grokFiles.keys.sorted() {
                var sum = Sum()
                for turn in grokFiles[path]?.turns ?? [] {
                    if let key = turn.key, !seen.insert(key).inserted { continue }
                    guard ClaudeCostScanner.utcDayName(Int((turn.date.timeIntervalSince1970 / 86_400).rounded(.down))) == day else { continue }
                    sum.tokens += Int64(turn.tokens)
                    if let cost = turn.cost { sum.cost = (sum.cost ?? 0) + cost }
                    sum.start = min(sum.start, turn.date)
                    if let model = turn.model { sum.models[model, default: 0] += Int64(turn.tokens) }
                }
                guard sum.tokens > 0 else { continue }
                sessions.append(UsageDaySession(
                    id: "grok-build:" + path, service: ProviderID.grokBuild.rawValue, accountID: sources.grokAccountID,
                    project: Self.grokProject(path: path, root: root),
                    model: sum.models.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key, start: sum.start,
                    tokens: sum.tokens, costUSD: sum.cost))
            }
        }
        return sessions.sorted { ($1.tokens, $0.id) < ($0.tokens, $1.id) }
    }

    /// `<ISO timestamp>:<total>`: the date before the last colon.
    static func firstEventDate(_ event: String) -> Date? {
        guard let colon = event.lastIndex(of: ":") else { return nil }
        let text = String(event[..<colon])
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// ponytail: the Grok turn cache lives in memory, so a restart re-reads the logs of the last
    /// year once; persist it like the Claude cache if that first call gets slow.
    private func grokPoints(_ sessions: URL, start: String, today: String, now: Date) -> [UsageHistoryPoint] {
        guard let first = Self.epochDay(start) else { return [] }
        let since = Date(timeIntervalSince1970: Double(first) * 86_400)
        let root = sessions.resolvingSymlinksInPath()
        var live: [String: GrokFile] = [:]
        if let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
            for case let url as URL in walker where url.lastPathComponent == "updates.jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let modified = values?.contentModificationDate, modified >= since,
                      let size = values?.fileSize, size < 200_000_000 else { continue }
                let path = url.resolvingSymlinksInPath().path
                if let known = grokFiles[path], known.size == size, known.modified == modified {
                    live[path] = known
                } else {
                    live[path] = GrokFile(size: size, modified: modified, turns: GrokBuildUsage.turns(in: url))
                }
            }
        }
        grokFiles = live
        var seen = Set<String>()
        var sums: [String: UsageHistoryPoint] = [:]
        for path in live.keys.sorted() {
            let project = Self.grokProject(path: path, root: root.path)
            for turn in live[path]?.turns ?? [] where turn.date >= since && turn.date < now.addingTimeInterval(86_400) {
                if let key = turn.key, !seen.insert(key).inserted { continue }
                let day = ClaudeCostScanner.utcDayName(Int((turn.date.timeIntervalSince1970 / 86_400).rounded(.down)))
                let id = "\(day)\0\(turn.model ?? "")\0\(project)"
                var point = sums[id] ?? UsageHistoryPoint(
                    day: day, service: ProviderID.grokBuild.rawValue, accountID: sources.grokAccountID,
                    model: turn.model, project: project, tokens: 0)
                point.tokens += Int64(turn.tokens)
                if let cost = turn.cost { point.costUSD = (point.costUSD ?? 0) + cost }
                sums[id] = point
            }
        }
        return sums.values.sorted { ($0.day, $0.project ?? "", $0.model ?? "") < ($1.day, $1.project ?? "", $1.model ?? "") }
    }

    /// Grok keeps `sessions/<percent-encoded working folder>/<session>/updates.jsonl`.
    private static func grokProject(path: String, root: String) -> String {
        let relative = path.dropFirst(root.count).drop { $0 == "/" }
        let folder = relative.split(separator: "/").first.map(String.init) ?? ""
        let decoded = folder.removingPercentEncoding ?? folder
        return decoded.isEmpty ? "Unknown project" : decoded
    }

    private func chartPoints(start: String, through end: String) -> [UsageHistoryPoint] {
        let handled: Set<String> = [ProviderID.codex.rawValue, ProviderID.claudeCode.rawValue, ProviderID.grokBuild.rawValue]
        var points: [UsageHistoryPoint] = []
        for source in sources.charts where !handled.contains(source.service) {
            let unit = source.chart.unit.lowercased()
            guard unit == "tokens" || unit == "usd" else { continue }
            for point in source.chart.points where point.value > 0 {
                guard let date = point.date else { continue }
                let day = ClaudeCostScanner.utcDayName(Int((date.timeIntervalSince1970 / 86_400).rounded(.down)))
                guard day >= start, day <= end else { continue }
                points.append(UsageHistoryPoint(
                    day: day, service: source.service, accountID: source.accountID,
                    tokens: unit == "tokens" ? Int64(min(point.value, 1e15)) : 0,
                    costUSD: unit == "usd" ? point.value : nil))
            }
        }
        return points
    }

    /// Config folder of a Claude Code profile that Switch created (lowercase id keys, as the ledger uses).
    public static func claudeProfileHomes(applicationSupport: URL, accountIDs: [UUID]) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: accountIDs.map {
            ($0.uuidString.lowercased(), applicationSupport
                .appending(path: "claude-code-profiles/\($0.uuidString)/config", directoryHint: .isDirectory))
        })
    }

    /// `$GROK_HOME/sessions`, else `~/.grok/sessions`.
    public static func grokSessionsFolder(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = environment["GROK_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appending(path: ".grok", directoryHint: .isDirectory)
        return base.appending(path: "sessions", directoryHint: .isDirectory)
    }

    /// Days since 1970-01-01 of a `yyyy-MM-dd` string (UTC).
    static func epochDay(_ day: String) -> Int? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return Int((date.timeIntervalSince1970 / 86_400).rounded())
    }
}
