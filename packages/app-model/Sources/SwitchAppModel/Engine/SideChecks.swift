import Foundation
import AIManagerCore

// shortcut: written from ProviderStatusPoller (ProviderUsageStore.swift), ClaudeActivity.swift, and the
// AccountViewModel side checks (refreshSideChecks, refreshDroidConversations, detectSignedInProviders) beside the
// Mac copies; delete those when the Mac app adopts SwitchAppModel (needs the window gates).

/// `providerStatus`: the incident dot of each provider with a saved account. Empty while "Check provider status"
/// is off.
public struct ProviderStatusValue: Codable, Equatable, Sendable {
    public var entries: [Entry] = []

    public struct Entry: Codable, Equatable, Sendable {
        public var providerID: String
        /// `none`, `maintenance`, `minor`, `major`, `critical`, or `unknown`.
        public var indicator: String
        /// `warning` (yellow) for minor and maintenance, `critical` (red) for major and critical, else nil.
        public var severity: String?
        /// The tooltip text: the feed's description, else "Service issue". The client adds "updated <age>".
        public var text: String
        public var updatedAt: Date?
        public var checkedAt: Date
    }
}

/// `activity`: local Claude Code and Droid usage (Today, Yesterday, Last 30 days), rescanned at most every 15
/// minutes unless forced.
public struct ActivityValue: Codable, Equatable, Sendable {
    public var claude: ActivitySummary?
    public var droid: ActivitySummary?
    public var claudeLoading = false
    public var droidLoading = false
}

public struct ActivitySummary: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var label: String
        public var tokens: Int
        /// API-equivalent estimate; nil when nothing in the period has a price.
        public var costUSD: Double?
        /// Exact token buckets for the tooltip.
        public var detail: String
    }
    public var rows: [Row]
    /// Models with usage but no published price; their cost is not in the totals.
    public var unpricedModels: [String]
    public var computedAt: Date
    /// 30 local days: estimated dollars when any day has a price, else tokens.
    public var chart: UsageChart?

    static let interval: TimeInterval = 15 * 60
    static let days = 30

    static func isDue(computedAt: Date?, force: Bool, now: Date) -> Bool {
        force || computedAt.map { now.timeIntervalSince($0) >= interval } ?? true
    }

    /// The Mac `ClaudeActivity.summarize`.
    static func summarize(_ daily: [ClaudeDailyCost], now: Date, calendar: Calendar = .current,
                          chartID: String = "claude-daily") -> ActivitySummary {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map(formatter.string(from:))
        func tokens(_ day: ClaudeDailyCost) -> Int {
            day.inputTokens + day.outputTokens + day.cacheReadTokens + day.cacheWriteTokens
        }
        func row(_ label: String, _ days: [ClaudeDailyCost]) -> Row {
            let priced = days.compactMap(\.costUSD)
            let (input, output) = (days.map(\.inputTokens).reduce(0, +), days.map(\.outputTokens).reduce(0, +))
            let (read, write) = (days.map(\.cacheReadTokens).reduce(0, +), days.map(\.cacheWriteTokens).reduce(0, +))
            return Row(label: label, tokens: input + output + read + write,
                       costUSD: priced.isEmpty ? nil : priced.reduce(0, +),
                       detail: "Input \(Fmt.number(Double(input))), output \(Fmt.number(Double(output))), "
                           + "cache read \(Fmt.number(Double(read))), cache write \(Fmt.number(Double(write))) tokens.")
        }
        let priced = daily.contains { $0.costUSD != nil }
        var byDay: [String: Double] = [:]
        for offset in 0..<days {
            if let day = calendar.date(byAdding: .day, value: -offset, to: now) { byDay[formatter.string(from: day)] = 0 }
        }
        for entry in daily where byDay[entry.date] != nil {
            byDay[entry.date] = priced ? (entry.costUSD ?? 0) : Double(tokens(entry))
        }
        let chart = UsageChart.daily(id: chartID, title: priced ? "Daily cost (API-equivalent estimate)" : "Daily tokens",
                                     unit: priced ? "USD" : "tokens", values: byDay)
        return ActivitySummary(
            rows: [row("Today", daily.filter { $0.date == today }),
                   row("Yesterday", daily.filter { $0.date == yesterday }),
                   row("Last 30 days", daily)],
            unpricedModels: Set(daily.flatMap(\.unpricedModels)).sorted(), computedAt: now,
            chart: chart.flatMap { $0.total > 0 ? $0 : nil })
    }
}

/// Polls provider incident feeds: each provider at most once every five minutes, four at a time; a failed fetch
/// keeps the last good value. `enabled: false` stops every request and clears the entries.
actor ProviderStatusPoller {
    static let interval: TimeInterval = 5 * 60
    static let maxConcurrent = 4

    typealias Fetch = @Sendable (ProviderID, URL?) async -> ProviderIncident?
    private let fetch: Fetch
    private var attempts: [ProviderID: Date] = [:]
    private var entries: [ProviderID: (incident: ProviderIncident, checkedAt: Date)] = [:]

    init(fetch: @escaping Fetch = { id, page in await ProviderStatusFetcher.fetch(id, statusPage: page) }) {
        self.fetch = fetch
    }

    func poll(_ ids: [ProviderID], enabled: Bool, now: Date) async -> ProviderStatusValue {
        guard enabled else {
            attempts = [:]
            entries = [:]
            return ProviderStatusValue()
        }
        let wanted = Set(ids)
        entries = entries.filter { wanted.contains($0.key) }
        let due = wanted.sorted { $0.rawValue < $1.rawValue }.filter { id in
            attempts[id].map { now.timeIntervalSince($0) >= Self.interval } ?? true
        }
        for id in due { attempts[id] = now }
        let fetch = fetch
        await withTaskGroup(of: (ProviderID, ProviderIncident?).self) { group in
            var pending = due[...]
            func launch(_ id: ProviderID) {
                group.addTask { (id, await fetch(id, ProviderCatalog.spec(id)?.statusPage)) }
            }
            for _ in 0..<min(Self.maxConcurrent, due.count) {
                if let id = pending.popFirst() { launch(id) }
            }
            while let (id, incident) = await group.next() {
                if let incident { entries[id] = (incident, now) }
                if let next = pending.popFirst() { launch(next) }
            }
        }
        return ProviderStatusValue(entries: entries.sorted { $0.key.rawValue < $1.key.rawValue }.map { id, entry in
            let severity: String? = switch entry.incident.indicator {
            case .minor, .maintenance: "warning"
            case .major, .critical: "critical"
            case .none, .unknown: nil
            }
            let text = entry.incident.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .init(providerID: id.rawValue, indicator: entry.incident.indicator.rawValue, severity: severity,
                         text: text.isEmpty ? "Service issue" : text, updatedAt: entry.incident.updatedAt,
                         checkedAt: entry.checkedAt)
        })
    }
}

extension AppEngine {
    /// Test seam: a provider status poller with a fake transport.
    func setStatusPoller(_ poller: ProviderStatusPoller) { statusPoller = poller }

    /// The Mac `refreshSideChecks`: incident dots, Claude and Droid activity, and the Droid conversation binding.
    /// Each throttles itself, so it rides along with every usage pass. A test home reads nothing.
    func refreshSideChecks(force: Bool = false) async {
        guard refreshes else { return }
        async let status: Void = refreshProviderStatus()
        async let activity: Void = refreshActivity(force: force)
        async let binding = refreshDroidConversations()
        _ = await (status, activity, binding)
    }

    func refreshProviderStatus() async {
        guard refreshes, manager != nil else { return }
        let ids = Array(Set(status?.accounts.map(\.identity.providerID) ?? []))
        let enabled = settings.effective("checkProviderStatus") != .bool(false)
        let value = await statusPoller.poll(ids, enabled: enabled, now: clock.now)
        providerStatus = value
        publish(.providerStatus, value)
    }

    /// `providerStatus.refresh`: incident feeds now (each provider still at most once every five minutes).
    public func refreshProviderStatusNow() async -> ProviderStatusValue {
        await refreshProviderStatus()
        return providerStatus
    }

    /// `activity.refresh`: the Claude and Droid log scans. `force` ignores the 15-minute limit.
    public func refreshActivity(force: Bool) async {
        guard refreshes, manager != nil else { return }
        let accounts = status?.accounts ?? []
        let now = clock.now
        let pricing = ClaudePricingSource(cacheURL: paths.applicationSupport.appending(path: "cache/model-pricing.json"))
        if accounts.contains(where: { $0.identity.providerID == .claudeCode }), !activity.claudeLoading,
           ActivitySummary.isDue(computedAt: activity.claude?.computedAt, force: force, now: now) {
            activity.claudeLoading = true
            publish(.activity, activity)
            let roots = ClaudeCostScanner.defaultRoots(environment: ProcessInfo.processInfo.environment, home: paths.userHome)
            let cacheURL = paths.applicationSupport.appending(path: "claude-cost-cache.json")
            let summary = try? await Task.detached(priority: .utility) {
                let scanner = ClaudeCostScanner(roots: roots, cacheURL: cacheURL, pricing: pricing.loader())
                return ActivitySummary.summarize(try await scanner.daily(days: ActivitySummary.days, now: now), now: now)
            }.value
            if let summary { activity.claude = summary }  // a failed scan keeps the last good numbers
            activity.claudeLoading = false
            publish(.activity, activity)
        }
        if accounts.contains(where: { $0.identity.providerID == .droid }), !activity.droidLoading,
           ActivitySummary.isDue(computedAt: activity.droid?.computedAt, force: force, now: now) {
            activity.droidLoading = true
            publish(.activity, activity)
            let sessions = DroidUsage.sessionsFolder(droidHome: paths.droidHome)
            activity.droid = await Task.detached(priority: .utility) {
                let calendar = Calendar.current
                let start = calendar.date(byAdding: .day, value: -(ActivitySummary.days - 1),
                                          to: calendar.startOfDay(for: now)) ?? now
                let found = DroidUsage.sessions(in: sessions, from: start)
                let rates = found.contains { $0.model != nil } ? await pricing.loader()() : [:]
                return ActivitySummary.summarize(DroidUsage.daily(found, rates: rates, calendar: calendar), now: now,
                                                 calendar: calendar, chartID: "droid-daily")
            }.value
            activity.droidLoading = false
            publish(.activity, activity)
        }
    }

    public func activityValue() -> ActivityValue { activity }

    /// The Mac `refreshDroidConversations`: rebinds Droid conversations to the default account. A new report
    /// becomes the notice; a failure goes to the red bar.
    @discardableResult
    public func refreshDroidConversations() async -> DroidSessionBindingReport? {
        guard let manager, !app.isBusy else { return nil }
        do {
            guard let report = try await manager.refreshDroidConversationBinding() else { return nil }
            await reloadAccounts()
            guard report != droidBinding else { return report }
            droidBinding = report
            let count = report.updatedCount + report.unchangedCount
            let warnings = report.warnings.joined(separator: " ")
            if report.pending {
                setNotice("Droid conversation updates are pending and will retry automatically. \(warnings)")
            } else if count > 0 {
                setNotice("\(count) Droid \(count == 1 ? "conversation" : "conversations") ready to resume. \(warnings)")
            }
            return report
        } catch {
            setError("Couldn’t update Droid conversations. \(describe(error))")
            return nil
        }
    }

    /// `providers.detectSignedIn`: file-based providers whose own login exists in the user's home (the root's
    /// home in a test run). Reads only; a spec whose files are all optional cannot be detected and is skipped.
    public func detectSignedIn() async -> ProvidersValue {
        guard let manager else { return signedIn }
        let specs = ProviderCatalog.addable.filter { $0.style == .files && $0.files.contains { !$0.optional } }
        var found: [String] = []
        for spec in specs where await manager.liveProviderIdentity(providerID: spec.id) != nil {
            found.append(spec.id.rawValue)
        }
        signedIn = ProvidersValue(signedIn: found.sorted())
        publish(.providers, signedIn)
        return signedIn
    }

    /// `providers.liveIdentity`: the add sheet's "Signed in as" line (the Mac `LiveProviderImport.label`), with the
    /// privacy settings applied, and the plan. Nil when the user's home holds no complete login.
    public func liveIdentity(_ providerID: ProviderID) async -> [String: String?]? {
        guard let identity = await manager?.liveProviderIdentity(providerID: providerID) else { return nil }
        let privacy = PrivacySettings(settings)
        let label = identity.email.map { PrivacyText.display($0, privacy) }
            ?? (privacy.privacyMode ? PrivacyText.fakeName(seed: identity.key) : identity.key)
        return ["label": label, "plan": identity.plan]
    }

    func bumpHistoryVersion() {
        historyVersion.version += 1
        publish(.historyVersion, historyVersion)
    }

    /// The Overview data changed: the next `usage.history` reads again.
    func bumpUsageHistoryVersion() {
        historyLoadedAt = nil
        usageHistoryVersion.version += 1
        publish(.usageHistoryVersion, usageHistoryVersion)
    }
}
