import Foundation

// Codex usage values that the app-server does not return: plan names, credit text, bucket and
// window naming, and the ChatGPT backend extras (reset credits, extra model buckets, monthly
// credit pool). Pure parsing and formatting, plus one read-only HTTP client.

public enum CodexPlanNames {
    private static let table = [
        "prolite": "Pro 100",
        "pro": "Pro 200",
        "promax": "Pro 500",
        "self_serve_business_prolite": "Business Premium",
    ]

    /// Display name for a Codex plan id; unknown ids keep their capitalized text.
    public static func display(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return table[raw.lowercased()] ?? raw.capitalized
    }
}

public enum CodexCreditsText {
    /// One Codex flex credit is worth 4 cents.
    public static let usdPerCredit = 0.04

    /// "$31.84 · 796 credits". Credits are floored first, then priced, so both values agree.
    public static func text(balance: Double) -> String {
        let credits = max(0, balance.rounded(.down))
        let unit = credits == 1 ? "credit" : "credits"
        return "\(Fmt.money(credits * usdPerCredit)) · \(Fmt.number(credits)) \(unit)"
    }

    /// Codex sends a fixed-point string such as "796.4009760000".
    public static func text(balance: String) -> String? {
        Double(balance.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? text(balance: $0) : nil }
    }
}

public enum CodexBucketNaming {
    /// Bucket title: "Spark" for the GPT-5.3-Codex-Spark limit, else the reported name, else the id.
    public static func title(id: String?, name: String?, model: String? = nil, fallback: String) -> String {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        let values = [clean(id), clean(name), clean(model)].compactMap { $0 }
        if values.contains(where: { $0.localizedCaseInsensitiveContains("spark") }) { return "Spark" }
        if let name = clean(name) { return name }
        let raw = clean(id) ?? fallback
        return raw.lowercased() == "codex" ? "Codex" : raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Window title by duration: 300 minutes is the Session, 10 080 is Weekly.
    public static func windowTitle(minutes: Int64?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        if minutes == 300 { return "Session" }
        if minutes == 10_080 { return "Weekly" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
    }
}

public struct CodexWindowRow: Identifiable, Equatable, Sendable {
    /// "primary" or "secondary", assigned after sorting by duration.
    public let slot: String
    public let window: CodexRateLimitWindowSnapshot
    public let usage: UsageWindow
    public var id: String { usage.id }
}

extension CodexRateLimitBucketSnapshot {
    /// Windows that report a percentage, named by duration. A lone window takes the primary slot,
    /// and two windows run shorter first, whichever slot Codex used.
    public func windowRows(idPrefix: String = "") -> [CodexWindowRow] {
        var windows = [primary, secondary].compactMap { $0 }.filter { $0.usedPercent != nil }
        if windows.count == 2, let first = windows[0].windowDurationMinutes,
           let second = windows[1].windowDurationMinutes, first > second {
            windows.swapAt(0, 1)
        }
        return windows.enumerated().map { index, window in
            let slot = index == 0 ? "primary" : "secondary"
            let title = CodexBucketNaming.windowTitle(
                minutes: window.windowDurationMinutes,
                fallback: index == 0 ? "Current window" : "Secondary window")
            return CodexWindowRow(
                slot: slot,
                window: window,
                usage: UsageWindow(
                    id: idPrefix + slot, title: title,
                    usedPercent: window.usedPercent.map(Double.init),
                    resetsAt: window.resetsAt,
                    windowMinutes: window.windowDurationMinutes.map(Int.init)))
        }
    }
}

public struct CodexResetCredits: Sendable, Equatable, Codable {
    public let count: Int
    /// Expiry of each still-available credit, soonest first.
    public let expiries: [Date]

    public init(count: Int, expiries: [Date]) {
        self.count = count
        self.expiries = expiries.sorted()
    }

    private static let day = Date.FormatStyle(date: .abbreviated, time: .omitted)

    /// "2 · next expires Oct 14, 2026"; the count alone when no expiry is known.
    public var summary: String {
        expiries.first.map { "\(count) · next expires \($0.formatted(Self.day))" } ?? "\(count)"
    }

    /// Every expiry, for a tooltip; nil when none is known.
    public var expiryList: String? {
        expiries.isEmpty ? nil : "Expires: " + expiries.map { $0.formatted(Self.day) }.joined(separator: ", ")
    }
}

extension CodexAccountUsageSnapshot {
    /// Windows outside the default bucket: model buckets such as Spark, then the monthly credit pool.
    public var extraWindows: [UsageWindow] {
        func title(_ bucket: CodexRateLimitBucketSnapshot) -> String {
            CodexBucketNaming.title(id: bucket.id, name: bucket.name, model: bucket.model, fallback: "Codex")
        }
        let main = rateLimits?.defaultBucket.map(title)
        var seen = Set(main.map { [$0] } ?? [])
        let listed = (rateLimits?.buckets.values.sorted { ($0.id ?? "") < ($1.id ?? "") } ?? [])
            + (extras?.additionalBuckets ?? [])
        let model = listed.filter { seen.insert(title($0)).inserted }.flatMap { bucket in
            bucket.windowRows().map { row in
                var window = row.usage
                window.id = "\(bucket.id ?? title(bucket))/\(row.slot)"
                window.title = "\(title(bucket)) \(row.usage.title)"
                return window
            }
        }
        return model + [extras?.monthlyCredits?.window].compactMap { $0 }
    }

    /// Reset credits and credits balance as short rows.
    public var factRows: [UsageRow] {
        var rows: [UsageRow] = []
        if let credits = extras?.resetCredits { rows.append(UsageRow("Reset credits", credits.summary)) }
        let buckets = [rateLimits?.defaultBucket].compactMap { $0 } + Array((rateLimits?.buckets ?? [:]).values)
        let balance = buckets.compactMap { $0.credits?.balance }.first ?? extras?.creditsBalance
        if let balance, let text = CodexCreditsText.text(balance: balance) {
            rows.append(UsageRow("Credits", text))
        }
        return rows
    }
}

public struct CodexMonthlyCredits: Sendable, Equatable, Codable {
    public let limit: Double
    public let used: Double
    public let remainingPercent: Double
    public let resetsAt: Date?

    public init(limit: Double, used: Double, remainingPercent: Double, resetsAt: Date?) {
        self.limit = limit
        self.used = used
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }

    /// The pool as a usage window: percent used, reset, and "7,761 / 100,000 credits".
    public var window: UsageWindow {
        UsageWindow(
            id: "monthly-credits", title: "Monthly credits",
            usedPercent: 100 - remainingPercent, resetsAt: resetsAt,
            detail: "\(Fmt.number(used)) / \(Fmt.number(limit)) credits")
    }
}

/// Values read from the ChatGPT backend with the account's own access token.
public struct CodexWhamExtras: Sendable, Equatable, Codable {
    public let resetCredits: CodexResetCredits?
    public let monthlyCredits: CodexMonthlyCredits?
    /// Model buckets such as GPT-5.3-Codex-Spark from `additional_rate_limits`.
    public let additionalBuckets: [CodexRateLimitBucketSnapshot]
    /// Credit balance, used only when the app-server bucket has none.
    public let creditsBalance: String?

    public init(
        resetCredits: CodexResetCredits?, monthlyCredits: CodexMonthlyCredits?,
        additionalBuckets: [CodexRateLimitBucketSnapshot], creditsBalance: String?
    ) {
        self.resetCredits = resetCredits
        self.monthlyCredits = monthlyCredits
        self.additionalBuckets = additionalBuckets
        self.creditsBalance = creditsBalance
    }

    /// Nil when neither response held a usable value.
    public static func parse(usage: HTTPResponse?, resetCredits: HTTPResponse?, now: Date) -> CodexWhamExtras? {
        func body(_ response: HTTPResponse?) -> JSON? {
            guard let response, (200..<300).contains(response.status) else { return nil }
            return try? response.json()
        }
        let usageBody = body(usage) ?? JSON(nil)
        let dedicated = body(resetCredits)
        let source = dedicated.flatMap { $0["available_count"].double != nil ? $0 : nil }
            ?? usageBody["rate_limit_reset_credits"]

        var credits: CodexResetCredits?
        if let count = source["available_count"].double, count >= 0, count.isFinite {
            let expiries = (source["credits"].raw as? [Any] ?? []).compactMap { entry -> Date? in
                let credit = JSON(entry)
                // status is optional upstream; only an explicit non-available state drops the credit.
                if let status = credit["status"].string, status != "available" { return nil }
                return Fmt.date(credit["expires_at"].raw)
            }
            credits = CodexResetCredits(count: Int(count), expiries: expiries)
        }

        let limit = [
            usageBody["individual_limit"], usageBody["individualLimit"],
            usageBody["rate_limit"]["individual_limit"], usageBody["rate_limit"]["individualLimit"],
            usageBody["spend_control"]["individual_limit"], usageBody["spendControl"]["individualLimit"],
            usageBody["spend_control"]["individualLimit"],
        ].first { $0.exists }
        let monthly = limit.flatMap(monthlyCredits)

        let buckets = (usageBody["additional_rate_limits"].raw as? [Any] ?? []).compactMap {
            additionalBucket(JSON($0), now: now)
        }

        var balance = usageBody["credits"]["balance"].double.map { String($0) }
        if balance == nil, usageBody["credits"]["has_credits"].bool == false { balance = "0" }
        if balance == nil, let header = usage?.headers["x-codex-credits-balance"], Double(header) != nil {
            balance = header
        }

        if credits == nil, monthly == nil, buckets.isEmpty, balance == nil { return nil }
        return CodexWhamExtras(
            resetCredits: credits, monthlyCredits: monthly, additionalBuckets: buckets,
            creditsBalance: balance)
    }

    private static func monthlyCredits(_ limit: JSON) -> CodexMonthlyCredits? {
        guard let total = limit["limit"].double, total > 0 else { return nil }
        let remaining = limit["remaining_percent"].double ?? limit["remainingPercent"].double
        let used = limit["used"].double ?? remaining.map { total * max(0, min(100, 100 - $0)) / 100 } ?? 0
        let left = remaining ?? max(0, min(100, 100 - used / total * 100))
        let reset = [limit["resets_at"], limit["resetsAt"], limit["reset_at"]].lazy
            .compactMap { Fmt.date($0.raw) }.first
        return CodexMonthlyCredits(limit: total, used: used, remainingPercent: left, resetsAt: reset)
    }

    private static func additionalBucket(_ entry: JSON, now: Date) -> CodexRateLimitBucketSnapshot? {
        func window(_ json: JSON) -> CodexRateLimitWindowSnapshot? {
            guard let used = json["used_percent"].double else { return nil }
            let seconds = json["limit_window_seconds"].double
            let reset = json["reset_at"].double.flatMap(Fmt.epoch)
                ?? json["reset_after_seconds"].double.map { now.addingTimeInterval($0) }
            return CodexRateLimitWindowSnapshot(
                usedPercent: Int(used.rounded()),
                windowDurationMinutes: seconds.flatMap { $0 > 0 ? Int64($0 / 60) : nil },
                resetsAt: reset)
        }
        let primary = window(entry["rate_limit"]["primary_window"])
        let secondary = window(entry["rate_limit"]["secondary_window"])
        guard primary != nil || secondary != nil else { return nil }
        return CodexRateLimitBucketSnapshot(
            id: entry["metered_feature"].string, name: entry["limit_name"].string, plan: nil, model: nil,
            primary: primary, secondary: secondary, credits: nil, spendControlReached: nil)
    }
}

/// Reads the ChatGPT backend extras with the access token of a private auth file. Read only: an
/// expired token skips the extras, because the app-server path owns token refresh.
public struct CodexWhamClient: Sendable {
    static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    static let resetCreditsURL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"

    private let send: @Sendable (String, [String: String]) async throws -> HTTPResponse

    public init(send: @escaping @Sendable (String, [String: String]) async throws -> HTTPResponse = {
        try await HTTP.send($0, headers: $1)
    }) {
        self.send = send
    }

    public func fetch(authFile: URL, now: Date) async -> CodexWhamExtras? {
        guard let size = (try? authFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= CoreSupport.maxAuthBytes,
              let data = try? Data(contentsOf: authFile),
              let auth = try? JSON(data: data),
              let token = auth["tokens"]["access_token"].string,
              let expiry = Fmt.jwtClaims(token)?["exp"].double.flatMap(Fmt.epoch),
              expiry > now.addingTimeInterval(30)
        else { return nil }
        var base = ["Authorization": "Bearer \(token)"]
        if let account = auth["tokens"]["account_id"].string { base["ChatGPT-Account-Id"] = account }
        let headers = base
        let creditHeaders = base.merging(["OpenAI-Beta": "codex-1", "originator": "Codex Desktop"]) { $1 }
        async let usage = bounded(CodexWhamClient.usageURL, headers)
        async let credits = bounded(CodexWhamClient.resetCreditsURL, creditHeaders)
        return CodexWhamExtras.parse(usage: await usage, resetCredits: await credits, now: now)
    }

    /// One request, abandoned after 10 seconds; any failure reads as no data.
    private func bounded(_ url: String, _ headers: [String: String]) async -> HTTPResponse? {
        await withTaskGroup(of: HTTPResponse?.self) { group in
            group.addTask { try? await send(url, headers) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
