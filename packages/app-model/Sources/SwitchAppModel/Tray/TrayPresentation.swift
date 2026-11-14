import Foundation
import AIManagerCore

// shortcut: the popover rules are written from popover.md and the Mac MenuBarRows.swift, MenuBarPopover.swift,
// ResetDisplay.swift, MenuBarUsagePreferences.swift, and AccountsPage `UsagePresentation.credits`; the Mac keeps its
// own copy until the Mac app adopts SwitchAppModel (needs the window gates). TrayPresentationTests holds the Mac
// checks' inputs and outputs, so the two copies cannot drift unnoticed.

/// The usage behind one popover row (Mac `MenuBarUsageSnapshot`).
public struct TrayUsage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var title: String
        public var used: Int?
        public var resetsAt: Date?
        public var minutes: Int?
        public var balance: String?

        public init(title: String, used: Int?, resetsAt: Date?, minutes: Int?, balance: String? = nil) {
            (self.title, self.used, self.resetsAt, self.minutes, self.balance) = (title, used, resetsAt, minutes, balance)
        }
    }

    public var usedPercentage: Int?
    public var secondaryUsedPercentage: Int?
    public var resetsAt: Date?
    public var secondaryResetsAt: Date?
    public var fetchedAt: Date?
    public var tokenPeriodLabel: String?
    public var tokens: Int64?
    public var apiPrice: CodexAPIPrice?
    public var primaryLabel: String
    public var secondaryLabel: String
    public var primaryMinutes: Int?
    public var secondaryMinutes: Int?
    public var primaryDetail: String?
    public var secondaryDetail: String?
    public var balanceText: String?
    public var providerWindows: [Window]?

    public init(usedPercentage: Int?, secondaryUsedPercentage: Int? = nil, resetsAt: Date? = nil,
                secondaryResetsAt: Date? = nil, fetchedAt: Date? = nil, tokenPeriodLabel: String? = nil,
                tokens: Int64? = nil, apiPrice: CodexAPIPrice? = nil, primaryLabel: String = "Session",
                secondaryLabel: String = "Weekly", primaryMinutes: Int? = nil, secondaryMinutes: Int? = nil,
                primaryDetail: String? = nil, secondaryDetail: String? = nil, balanceText: String? = nil,
                providerWindows: [Window]? = nil) {
        self.usedPercentage = usedPercentage.map { max($0, 0) }
        self.secondaryUsedPercentage = secondaryUsedPercentage.map { max($0, 0) }
        self.resetsAt = resetsAt
        self.secondaryResetsAt = secondaryResetsAt
        self.fetchedAt = fetchedAt
        self.tokenPeriodLabel = tokenPeriodLabel
        self.tokens = tokens
        self.apiPrice = apiPrice
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
        self.primaryMinutes = primaryMinutes
        self.secondaryMinutes = secondaryMinutes
        self.primaryDetail = primaryDetail
        self.secondaryDetail = secondaryDetail
        self.balanceText = balanceText
        self.providerWindows = providerWindows
    }

    /// Non-Codex providers: session-like windows first, a cost limit as `<period> credits`, a balance line. Nil
    /// when there is neither a window nor a balance.
    public init?(providerUsage usage: ProviderUsage) {
        func isSessionLike(_ window: UsageWindow) -> Bool {
            window.title.localizedCaseInsensitiveContains("session") || (window.windowMinutes ?? .max) <= 300
        }
        let ordered = usage.windows.filter(isSessionLike) + usage.windows.filter { !isSessionLike($0) }
        var reported = ordered.map {
            Window(title: $0.title, used: $0.usedPercent.map { Int($0.rounded()) }, resetsAt: $0.resetsAt,
                   minutes: $0.windowMinutes, balance: $0.usedPercent == nil ? $0.detail : nil)
        }
        if let cost = usage.cost, let used = cost.used, let limit = cost.limit, limit > 0 {
            reported.append(Window(title: "\(cost.period ?? "Monthly") credits", used: Int((used / limit * 100).rounded()),
                                   resetsAt: cost.resetsAt, minutes: nil))
        }
        let balance = usage.cost?.balance.map { Fmt.money($0, currency: usage.cost?.currency ?? "USD") }
        guard !reported.isEmpty || balance != nil else { return nil }
        if let balance, !ordered.isEmpty {
            reported.append(Window(title: "Balance", used: nil, resetsAt: nil, minutes: nil, balance: balance))
        }
        let first = ordered.first, second = ordered.dropFirst().first
        self.init(usedPercentage: first?.usedPercent.map { Int($0.rounded()) },
                  secondaryUsedPercentage: second?.usedPercent.map { Int($0.rounded()) },
                  resetsAt: first?.resetsAt, secondaryResetsAt: second?.resetsAt, fetchedAt: usage.fetchedAt,
                  primaryLabel: first?.title ?? "Session", secondaryLabel: second?.title ?? "Weekly",
                  primaryMinutes: first?.windowMinutes, secondaryMinutes: second?.windowMinutes,
                  primaryDetail: first?.detail, secondaryDetail: second?.detail,
                  balanceText: ordered.isEmpty ? balance : nil, providerWindows: reported)
    }

    /// Codex: the shorter limit first (a lone weekly window takes the primary slot), credits, the other buckets as
    /// `<bucket> <period>`, and the monthly credits pool.
    public init?(bucket: CodexRateLimitBucketSnapshot, additionalBuckets: [String: CodexRateLimitBucketSnapshot] = [:],
                 extras: CodexWhamExtras? = nil, fetchedAt: Date, tokenPeriodLabel: String? = nil,
                 tokens: Int64? = nil, apiPrice: CodexAPIPrice? = nil) {
        let windows = [bucket.primary, bucket.secondary].compactMap { $0 }
            .sorted { ($0.windowDurationMinutes ?? .max) < ($1.windowDurationMinutes ?? .max) }
        let first = windows.first, second = windows.dropFirst().first
        var reported = windows.enumerated().map { index, window in
            Window(title: CodexBucketNaming.windowTitle(minutes: window.windowDurationMinutes,
                                                        fallback: index == 0 ? "Session" : "Weekly"),
                   used: window.usedPercent, resetsAt: window.resetsAt, minutes: window.windowDurationMinutes.map(Int.init))
        }
        if let credits = Self.credits(bucket.credits) {
            reported.append(Window(title: "Credits", used: nil, resetsAt: nil, minutes: nil, balance: credits))
        }
        var all = additionalBuckets
        var names = Set(additionalBuckets.map {
            CodexBucketNaming.title(id: $0.value.id ?? $0.key, name: $0.value.name, model: $0.value.model, fallback: $0.key)
        })
        for extra in extras?.additionalBuckets ?? [] {
            let id = extra.id ?? extra.model ?? extra.name ?? "Usage"
            let name = CodexBucketNaming.title(id: extra.id, name: extra.name, model: extra.model, fallback: id)
            if all[id] == nil, names.insert(name).inserted { all[id] = extra }
        }
        for (id, scoped) in all.sorted(by: { $0.key < $1.key })
            where scoped != bucket && (bucket.id == nil || (scoped.id ?? id) != bucket.id) {
            let name = CodexBucketNaming.title(id: scoped.id ?? id, name: scoped.name, model: scoped.model, fallback: id)
            for window in [scoped.primary, scoped.secondary].compactMap({ $0 }) {
                let period = CodexBucketNaming.windowTitle(minutes: window.windowDurationMinutes, fallback: "Usage")
                reported.append(Window(title: "\(name) \(period)", used: window.usedPercent, resetsAt: window.resetsAt,
                                       minutes: window.windowDurationMinutes.map(Int.init)))
            }
            if let credits = Self.credits(scoped.credits) {
                reported.append(Window(title: "\(name) credits", used: nil, resetsAt: nil, minutes: nil, balance: credits))
            }
        }
        if let monthly = extras?.monthlyCredits {
            let window = monthly.window
            reported.append(Window(title: window.title, used: window.usedPercent.map { Int($0.rounded()) },
                                   resetsAt: window.resetsAt, minutes: nil))
        }
        guard !reported.isEmpty else { return nil }
        self.init(usedPercentage: first?.usedPercent, secondaryUsedPercentage: second?.usedPercent,
                  resetsAt: first?.resetsAt, secondaryResetsAt: second?.resetsAt, fetchedAt: fetchedAt,
                  tokenPeriodLabel: tokenPeriodLabel, tokens: tokens, apiPrice: apiPrice,
                  primaryLabel: second == nil && first?.windowDurationMinutes == 10_080 ? "Weekly" : "Session",
                  primaryMinutes: first?.windowDurationMinutes.map(Int.init),
                  secondaryMinutes: second?.windowDurationMinutes.map(Int.init), providerWindows: reported)
    }

    /// The Mac `UsagePresentation.credits`: "Unlimited", "$31.84 · 796 credits", "Available", or "None".
    public static func credits(_ credits: CodexCreditsSnapshot?) -> String? {
        guard let credits else { return nil }
        if credits.unlimited == true { return "Unlimited" }
        if let balance = credits.balance?.trimmingCharacters(in: .whitespacesAndNewlines), !balance.isEmpty {
            return CodexCreditsText.text(balance: balance) ?? balance
        }
        return credits.hasCredits.map { $0 ? "Available" : "None" }
    }
}

/// One account as the popover and the status item see it (Mac `MenuBarAccountSnapshot`). `identity` is already
/// privacy formatted.
public struct TrayAccount: Equatable, Sendable {
    public var id: UUID
    public var providerID: ProviderID
    public var identity: String
    public var isVerified: Bool
    public var isActive: Bool
    public var usage: TrayUsage?
    public var showsUsage: Bool
    public var needsDroidAccess: Bool

    public init(id: UUID = UUID(), identity: String, isVerified: Bool = true, isActive: Bool = false,
                usage: TrayUsage? = nil, showsUsage: Bool = true, providerID: ProviderID = .codex,
                needsDroidAccess: Bool = false) {
        self.id = id
        self.providerID = providerID
        self.identity = identity
        self.isVerified = isVerified
        self.isActive = isActive
        self.usage = showsUsage ? usage : nil
        self.showsUsage = showsUsage
        self.needsDroidAccess = needsDroidAccess
    }

    /// One prompt line and button instead of usage: Sign in or Allow access.
    public var showsPrompt: Bool { !isVerified || needsDroidAccess }
    /// Only the agent CLIs launch from Switch.
    public var supportsLaunch: Bool { [ProviderID.codex, .grokBuild, .droid, .claudeCode].contains(providerID) }
    public var quotaUsedPercentage: Int? {
        usage?.usedPercentage ?? usage?.secondaryUsedPercentage ?? usage?.providerWindows?.compactMap(\.used).first
    }
    public var remainingPercentage: Int? { quotaUsedPercentage.map { max(0, 100 - $0) } }
}

/// The pure popover rules (Mac `MenuBarPresentation`, `MenuBarSnapshot`, `ResetDisplay`, `UsagePercentagePreferences`).
/// Text width measuring stays with the client.
public enum TrayPresentation {
    public static let maximumStatusAccounts = 6
    public static let tokenLabel = "Tokens"
    public static let balanceLabel = "Balance"
    public static let signInSubtitle = "Sign in again to see usage"
    public static let allowAccessSubtitle = "Allow access to see usage"

    public struct Line: Equatable, Sendable {
        /// Window name in the label column (the pool name on a heading).
        public var label: String?
        /// Nil shows the amount text without a bar.
        public var used: Int?
        public var resetsAt: Date?
        public var minutes: Int?
        public var balance: String?
        public var helpTitle: String?
        public var pool: String?
        public var isHeading = false
    }

    public struct WindowName: Equatable, Sendable {
        public var pool: String?
        public var label: String
    }

    public enum Content: Equatable, Sendable { case signIn, lines([Line]) }

    // MARK: Usage percentage (Left or Used)

    /// Used keeps overage above 100; Left stops at 0. Negative input reads as 0.
    public static func displayedPercentage(forUsed used: Int, showsUsed: Bool) -> Int {
        let used = max(used, 0)
        return showsUsed ? used : max(100 - used, 0)
    }

    /// Bar fill, 0...1: never past the track, even when the text shows overage.
    public static func fill(forUsed used: Int, showsUsed: Bool) -> Double {
        min(max(Double(displayedPercentage(forUsed: used, showsUsed: showsUsed)) / 100, 0), 1)
    }

    public static func percentLabel(forUsed used: Int, showsUsed: Bool) -> String {
        "\(displayedPercentage(forUsed: used, showsUsed: showsUsed))% \(showsUsed ? "used" : "left")"
    }

    // MARK: Window names and lines

    private static let amountWords: Set<String> = [
        "credits", "credit", "quota", "limit", "usage", "budget", "allowance", "tokens", "requests", "window"]

    private static func period(in words: [String], at index: Int) -> (name: String, length: Int)? {
        let word = words[index].lowercased()
        switch word {
        case "session", "5-hour", "5-hours", "5h", "5hour": return ("Session", 1)
        case "weekly", "7-day": return ("Weekly", 1)
        case "monthly": return ("Monthly", 1)
        case "daily": return ("Daily", 1)
        default: break
        }
        guard index + 1 < words.count else { return nil }
        let next = words[index + 1].lowercased()
        if word == "5", next.hasPrefix("hour") { return ("Session", 2) }
        if word.range(of: #"^\d+-(day|hour|minute)s?$"#, options: .regularExpression) != nil, next == "window" {
            return ("\(words[index]) window", 2)
        }
        return nil
    }

    /// The period word is the label; the other words (amount words aside) are the pool. "Core 5-hour" is pool Core,
    /// label Session; "Spark credits" is pool Spark, label Credits. A title with no period word keeps its text.
    public static func windowName(minutes: Int?, title: String) -> WindowName {
        let words = title.split(separator: " ").map(String.init)
        for index in words.indices {
            guard let period = period(in: words, at: index) else { continue }
            var rest = words
            rest.removeSubrange(index..<(index + period.length))
            let pool = rest.filter { !amountWords.contains($0.lowercased()) }.joined(separator: " ")
            return WindowName(pool: pool.isEmpty ? nil : pool, label: period.name)
        }
        if words.count > 1, words.last?.lowercased() == "credits" {
            return WindowName(pool: words.dropLast().joined(separator: " "), label: "Credits")
        }
        if title.isEmpty, let minutes { return WindowName(pool: nil, label: minutes == 300 ? "Session" : "Weekly") }
        return WindowName(pool: nil, label: title)
    }

    /// The main pool's rows first, then each extra pool under its heading. One pool needs no heading.
    public static func grouped(_ rows: [Line]) -> [Line] {
        var pools: [String?] = []
        for row in rows where !pools.contains(where: { $0 == row.pool }) { pools.append(row.pool) }
        guard pools.count > 1 else { return rows }
        pools = pools.filter { $0 == nil } + pools.filter { $0 != nil }
        return pools.flatMap { pool -> [Line] in
            let own = rows.filter { $0.pool == pool }
            guard let pool else { return own }
            return [Line(label: pool, isHeading: true)] + own
        }
    }

    /// The collapsed row: the first two usage rows, with a pool heading above its rows.
    public static func collapsed(_ lines: [Line]) -> [Line] {
        var result: [Line] = [], rows = 0
        for line in lines {
            if rows >= 2 { break }
            if !line.isHeading { rows += 1 }
            result.append(line)
        }
        return result
    }

    public static func content(for account: TrayAccount, expanded: Bool = true) -> Content {
        guard !account.showsPrompt else { return .signIn }
        guard let usage = account.usage else { return .lines([]) }
        if let providerWindows = usage.providerWindows, !providerWindows.isEmpty {
            let visible = providerWindows.filter { $0.used != nil || $0.balance?.isEmpty == false }
            let rows = grouped(visible.map {
                let name = windowName(minutes: $0.minutes, title: $0.title)
                return Line(label: name.label, used: $0.used, resetsAt: $0.resetsAt, minutes: $0.minutes,
                            balance: $0.balance, helpTitle: $0.title, pool: name.pool)
            })
            return .lines(expanded ? rows : collapsed(rows))
        }
        var windows: [(title: String, used: Int?, reset: Date?, minutes: Int?, detail: String?)] = []
        if usage.usedPercentage != nil || usage.primaryDetail?.isEmpty == false {
            windows.append((usage.primaryLabel, usage.usedPercentage, usage.resetsAt, usage.primaryMinutes, usage.primaryDetail))
        }
        if usage.secondaryUsedPercentage != nil || usage.secondaryDetail?.isEmpty == false {
            windows.append((usage.secondaryLabel, usage.secondaryUsedPercentage, usage.secondaryResetsAt,
                            usage.secondaryMinutes, usage.secondaryDetail))
        }
        if windows.isEmpty {
            guard let balance = usage.balanceText, !balance.isEmpty else { return .lines([]) }
            return .lines([Line(balance: balance)])
        }
        let rows = grouped(windows.map {
            let name = windowName(minutes: $0.minutes, title: $0.title)
            return Line(label: name.label, used: $0.used, resetsAt: $0.reset, minutes: $0.minutes,
                        balance: $0.used == nil ? $0.detail : nil, pool: name.pool)
        })
        return .lines(expanded ? rows : collapsed(rows))
    }

    public static func lines(for account: TrayAccount, expanded: Bool = false) -> [Line] {
        if case .lines(let lines) = content(for: account, expanded: expanded) { return lines }
        return []
    }

    /// The label column text: the window name, or "Balance" for a value-only line with none.
    public static func displayLabel(_ line: Line) -> String? { line.label ?? (line.balance == nil ? nil : balanceLabel) }

    public static func showsSwitch(_ account: TrayAccount) -> Bool { !account.isActive }

    /// The action band shows (Sign in, Switch, or Open <tool>), so the row can expand.
    public static func hasActions(_ account: TrayAccount) -> Bool {
        !account.isVerified || showsSwitch(account) || account.supportsLaunch
    }

    public static func canExpand(_ account: TrayAccount) -> Bool {
        account.showsUsage && (hasActions(account) || lines(for: account, expanded: true).count > lines(for: account).count)
    }

    public static func hasTokenCaption(_ account: TrayAccount) -> Bool {
        guard account.isVerified, let usage = account.usage else { return false }
        return (usage.tokens ?? 0) > 0 && usage.tokenPeriodLabel != nil
            && (usage.usedPercentage != nil || usage.secondaryUsedPercentage != nil)
    }

    public static func openToolTitle(_ account: TrayAccount) -> String {
        "Open \(account.providerID == .codex ? "Codex" : account.providerID.displayName)"
    }

    // MARK: Tokens

    /// "24.1M", "3.2K", "950": one decimal at most.
    public static func compactTokens(_ tokens: Int64) -> String {
        guard tokens >= 1_000 else { return String(tokens) }
        for (size, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] {
            let value = (Double(tokens) / size * 10).rounded() / 10
            if value >= 1 { return (value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)) + suffix }
        }
        return String(tokens)
    }

    /// "24.1M since reset · ≈$96 API" (the price only when the model has one). Money is en_US, as the spec says.
    public static func tokenCaption(_ usage: TrayUsage) -> String? {
        guard let tokens = usage.tokens, tokens > 0, let period = usage.tokenPeriodLabel else { return nil }
        let price = usage.apiPrice.map { "≈$\(Fmt.number($0.inputEquivalent(for: tokens).rounded())) API" }
        return ["\(compactTokens(tokens)) \(period)", price].compactMap { $0 }.joined(separator: " · ")
    }

    /// The `menuBarTokenPeriod` choice as its summary words.
    public static func tokenPeriodLabel(_ period: String) -> String {
        ["today": "today", "yesterday": "yesterday", "weekly": "in 7 days", "monthly": "in 30 days",
         "yearly": "in 1 year"][period] ?? "since reset"
    }

    /// Token total of `period`. "sinceReset" starts at the weekly reset minus the weekly length, else 7 days.
    public static func tokens(_ period: String, rows: [CodexDailyUsageSnapshot], usage: CodexAccountUsageSnapshot?,
                              now: Date) -> Int64 {
        if let fixed = CodexTokenPeriod(rawValue: period) { return fixed.tokens(in: rows, endingAt: now) }
        let bucket = usage?.rateLimits?.defaultBucket
        let windows = [bucket?.primary, bucket?.secondary].compactMap { $0 }
        guard let weekly = windows.filter({ ($0.windowDurationMinutes ?? 0) >= 10_080 })
            .max(by: { ($0.windowDurationMinutes ?? 0) < ($1.windowDurationMinutes ?? 0) }),
            let reset = weekly.resetsAt, let minutes = weekly.windowDurationMinutes, minutes > 0
        else { return CodexTokenPeriod.weekly.tokens(in: rows, endingAt: now) }
        return CodexTokenPeriod.tokens(in: rows, from: reset.addingTimeInterval(-TimeInterval(minutes) * 60), through: now)
    }

    // MARK: Reset text

    /// A passed reset: "Not started" while the window is unused, else "Resetting…". Never "now".
    public static func pastText(usedPercent: Double?) -> String {
        (usedPercent ?? 0).rounded() <= 0 ? "Not started" : "Resetting…"
    }

    /// "Resets 5:30 PM", "Resets tomorrow 5:30 PM", "Resets Thu 5:30 PM", or "Resets Oct 14, 5:30 PM".
    /// `hourFormat` is the `timeFormat` setting: "auto", "12h", or "24h".
    public static func exactText(_ reset: Date, now: Date, hourFormat: String = "auto", timeZone: TimeZone = .current,
                                 usedPercent: Double? = nil) -> String {
        guard reset > now else { return pastText(usedPercent: usedPercent) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let posix = Locale(identifier: "en_US_POSIX")
        func format(_ pattern: String, locale: Locale = posix) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            return formatter.string(from: reset)
        }
        let clock: String
        switch hourFormat {
        case "12h": clock = format("h:mm a")
        case "24h": clock = format("HH:mm")
        default:
            let pattern = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: .current) ?? "h:mm a"
            clock = format(pattern, locale: .current)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: reset)).day ?? 0
        switch days {
        case ..<1: return "Resets \(clock)"
        case 1: return "Resets tomorrow \(clock)"
        case 2..<7: return "Resets \(format("EEE")) \(clock)"
        default: return "Resets \(format("MMM d")), \(clock)"
        }
    }

    /// The reset column: "6d 8h", "1h 45m", "12m", "<1m" as a countdown, or the exact clock time without "Resets".
    public static func resetText(_ reset: Date, now: Date, exact: Bool, hourFormat: String = "auto",
                                 timeZone: TimeZone = .current, used: Int? = nil) -> String {
        guard reset > now else { return pastText(usedPercent: used.map(Double.init)) }
        if exact {
            let text = exactText(reset, now: now, hourFormat: hourFormat, timeZone: timeZone)
            return text.hasPrefix("Resets ") ? String(text.dropFirst(7)) : text
        }
        let minutes = Int(reset.timeIntervalSince(now) / 60)
        if minutes < 1 { return "<1m" }
        let days = minutes / 1_440, hours = (minutes % 1_440) / 60, rest = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(rest)m" }
        return "\(rest)m"
    }

    // MARK: Accessibility

    public static func accessibilityLabel(_ account: TrayAccount, showsUsed: Bool, now: Date, exact: Bool,
                                          hourFormat: String = "auto", timeZone: TimeZone = .current) -> String {
        var parts = [account.identity, AccountPresentation.providerName(account.providerID)]
        if account.isActive { parts.append("Default") }
        switch content(for: account) {
        case .signIn:
            parts.append("Needs sign in")
        case .lines(let lines):
            for line in lines where !line.isHeading {
                let value = line.balance.map { "Balance \($0)" }
                    ?? line.used.map { percentLabel(forUsed: $0, showsUsed: showsUsed) } ?? "Usage unknown"
                parts.append([line.pool, line.label, value].compactMap { $0 }.joined(separator: " "))
            }
            for line in lines where !line.isHeading {
                if let reset = line.resetsAt {
                    let text = resetText(reset, now: now, exact: exact, hourFormat: hourFormat, timeZone: timeZone,
                                         used: line.used)
                    parts.append(reset > now ? "Resets " + text : text)
                }
            }
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Service order and the status item (Mac `MenuBarSnapshot`)

    /// Saved order first (each once, absent services skipped), then services in arrival order.
    public static func orderedProviders(_ providers: [ProviderID], order: [ProviderID]) -> [ProviderID] {
        var seen: Set<ProviderID> = []
        let present = Set(providers)
        return (order + providers).filter { present.contains($0) && seen.insert($0).inserted }
    }

    public static func orderedAccounts(_ accounts: [TrayAccount], order: [ProviderID]) -> [TrayAccount] {
        orderedProviders(accounts.map(\.providerID), order: order).flatMap { provider in
            accounts.filter { $0.providerID == provider }
        }
    }

    /// The popover groups: accounts with usage shown, one group per service in first-seen order.
    public static func groups(_ accounts: [TrayAccount]) -> [[TrayAccount]] {
        var groups: [[TrayAccount]] = []
        for account in accounts.filter(\.showsUsage) {
            if let index = groups.firstIndex(where: { $0.first?.providerID == account.providerID }) {
                groups[index].append(account)
            } else { groups.append([account]) }
        }
        return groups
    }

    /// The status item accounts: shown, verified, with a percentage, allowed by both eyes; with One account per
    /// service the default (else first) of each; the first six, grouped by service.
    public static func statusGroups(_ ordered: [TrayAccount], hiddenServices: Set<ProviderID>, hiddenAccounts: Set<UUID>,
                                    onePerService: Bool) -> [[TrayAccount]] {
        var eligible = ordered.filter {
            $0.showsUsage && $0.isVerified && $0.remainingPercentage != nil
                && !hiddenServices.contains($0.providerID) && !hiddenAccounts.contains($0.id)
        }
        if onePerService {
            let chosen = Set(Dictionary(grouping: eligible, by: \.providerID).values.compactMap {
                ($0.first(where: \.isActive) ?? $0.first)?.id
            })
            eligible = eligible.filter { chosen.contains($0.id) }
        }
        var groups: [[TrayAccount]] = []
        for account in eligible.prefix(maximumStatusAccounts) {
            if let index = groups.firstIndex(where: { $0.first?.providerID == account.providerID }) {
                groups[index].append(account)
            } else { groups.append([account]) }
        }
        return groups
    }

    /// The status item tooltip: one line per tray account, then the omitted ones (unverified or without a
    /// percentage). Empty when there are none; the client then shows the app name.
    public static func statusTooltip(_ ordered: [TrayAccount], shown: [TrayAccount], hiddenServices: Set<ProviderID>,
                                     hiddenAccounts: Set<UUID>, onePerService: Bool, showsUsed: Bool) -> String {
        let services = Set(shown.map(\.providerID))
        let omitted = ordered.filter {
            $0.showsUsage && !hiddenServices.contains($0.providerID) && !hiddenAccounts.contains($0.id)
                && (!$0.isVerified || $0.remainingPercentage == nil) && !(onePerService && services.contains($0.providerID))
        }
        return (shown + omitted).map { account in
            let service = AccountPresentation.providerName(account.providerID)
            guard account.isVerified else { return "\(service), \(account.identity), needs sign-in" }
            let quota = account.quotaUsedPercentage.map { percentLabel(forUsed: $0, showsUsed: showsUsed) } ?? "no usage yet"
            return "\(service), \(account.identity), \(quota)"
        }.joined(separator: "\n")
    }
}
