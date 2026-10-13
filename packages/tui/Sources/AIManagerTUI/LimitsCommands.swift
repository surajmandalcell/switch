import Foundation
import AIManagerCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Non-interactive commands for generic provider accounts: usage, guard, add, import.
// Usage values come only from the provider; a missing value stays missing.

// MARK: - Formatting shared with the interactive screen

enum LimitFormat {
    static func remaining(_ window: UsageWindow) -> Double? {
        window.usedPercent.map { max(0, 100 - $0) }
    }

    /// One line of ▁▂▃▄▅▆▇█ for a chart; a flat or empty series draws the lowest bar.
    static func sparkline(_ chart: UsageChart) -> String {
        let bars = Array("\u{2581}\u{2582}\u{2583}\u{2584}\u{2585}\u{2586}\u{2587}\u{2588}")
        let peak = chart.points.map(\.value).max() ?? 0
        return String(chart.points.map { point in
            peak > 0 ? bars[min(7, max(0, Int((point.value / peak * 7).rounded())))] : bars[0]
        })
    }

    /// "Daily spend  ▁▃▅█  total $12.40  peak $2.10 Oct 3".
    static func chartLine(_ chart: UsageChart) -> String {
        var text = "\(chart.title)  \(sparkline(chart))  total \(chart.format(chart.total))"
        if let peak = chart.peak, peak.value > 0 { text += "  peak \(chart.format(peak.value)) \(peak.label)" }
        return text
    }

    static func resetLabel(until reset: Date, now: Date = Date()) -> String {
        let minutes = Int(max(0, reset.timeIntervalSince(now)) / 60)
        if minutes == 0 { return reset > now ? "in <1m" : "now" }
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        let remainingMinutes = minutes % 60
        if days > 0 { return "in \(days)d \(hours)h \(remainingMinutes)m" }
        if hours > 0 { return "in \(hours)h \(remainingMinutes)m" }
        return "in \(remainingMinutes)m"
    }

    /// Money rows such as ("spend", "$12.00 / $50.00 (Monthly)"); only values the provider sent.
    static func costRows(_ cost: UsageCost) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if cost.used != nil || cost.limit != nil {
            var text = cost.used.map { Fmt.money($0, currency: cost.currency) } ?? "?"
            if let limit = cost.limit { text += " / " + Fmt.money(limit, currency: cost.currency) }
            if let period = cost.period { text += " (\(period))" }
            rows.append(("spend", text))
        }
        if let balance = cost.balance { rows.append(("balance", Fmt.money(balance, currency: cost.currency))) }
        if let reset = cost.resetsAt { rows.append(("resets", resetLabel(until: reset))) }
        return rows
    }

    static func message(_ error: Error) -> String {
        let text = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        return String(text.prefix(300))
    }
}

// MARK: - JSON model (switch.limits.v1)

private struct LimitsDocument: Encodable {
    struct Window: Encodable {
        let id: String
        let title: String
        let usedPercent: Double?
        let remainingPercent: Double?
        let resetsAt: Date?
        let windowSeconds: Int?
        let detail: String?
    }

    struct Cost: Encodable {
        let used: Double?
        let limit: Double?
        let balance: Double?
        let currency: String
        let period: String?
        let resetsAt: Date?
    }

    struct Point: Encodable { let label: String; let date: Date?; let value: Double }
    struct Chart: Encodable { let id: String; let title: String; let unit: String; let points: [Point] }
    struct Row: Encodable { let label: String; let value: String }
    struct Section: Encodable { let title: String?; let rows: [Row] }

    struct Account: Encodable {
        let id: UUID
        let provider: String
        let providerName: String
        let email: String?
        let plan: String?
        let isDefault: Bool
        let fetchedAt: Date
        let windows: [Window]
        let cost: Cost?
        let sections: [Section]
        let charts: [Chart]

        enum CodingKeys: String, CodingKey {
            case id, provider, providerName, email, plan, fetchedAt, windows, cost, sections, charts
            case isDefault = "default"
        }

        init(_ account: AccountRecord, usage: ProviderUsage, isDefault: Bool) {
            id = account.id
            provider = account.identity.providerID.rawValue
            providerName = AIManagerCLI.providerName(account.identity.providerID)
            email = usage.email ?? account.identity.email
            plan = usage.plan
            self.isDefault = isDefault
            fetchedAt = usage.fetchedAt
            windows = usage.windows.map {
                Window(id: $0.id, title: $0.title, usedPercent: $0.usedPercent,
                       remainingPercent: LimitFormat.remaining($0), resetsAt: $0.resetsAt,
                       windowSeconds: $0.windowMinutes.map { $0 * 60 }, detail: $0.detail)
            }
            cost = usage.cost.map {
                Cost(used: $0.used, limit: $0.limit, balance: $0.balance, currency: $0.currency,
                     period: $0.period, resetsAt: $0.resetsAt)
            }
            sections = usage.sections.map { section in
                Section(title: section.title, rows: section.rows.map { Row(label: $0.label, value: $0.value) })
            }
            charts = usage.charts.map { chart in
                Chart(id: chart.id, title: chart.title, unit: chart.unit,
                      points: chart.points.map { Point(label: $0.label, date: $0.date, value: $0.value) })
            }
        }
    }

    struct Failure: Encodable {
        let accountId: UUID
        let provider: String
        let message: String
    }

    let schema = "switch.limits.v1"
    let generatedAt: Date
    let accounts: [Account]
    let errors: [Failure]
}

private struct GuardDecision: Encodable {
    let provider: String
    let account: UUID?
    let window: String?
    let remaining: Double?
    let threshold: Double
    let decision: String
    let reason: String
    let exitCode: Int32
}

// MARK: - Commands

enum LimitsCommands {
    static let guardUnknown: Int32 = 69

    // MARK: usage

    static func usage(_ input: CommandLineInput, manager: AccountManager) async throws -> Int32 {
        try rejectUnknownFlags(input, allowed: ["--json", "--force"], code: 2)
        guard input.positional.count <= 1 else {
            throw CLIError.exit(2, "Use at most one provider ID or account UUID.")
        }
        let status = try await manager.status()
        var accounts = status.accounts
        if let target = input.positional.first {
            if let id = UUID(uuidString: target) {
                accounts = accounts.filter { $0.id == id }
                guard !accounts.isEmpty else { throw CLIError.exit(2, "No saved account has the ID \(target).") }
            } else {
                guard AccountManager.providerCatalog.contains(where: { $0.id.rawValue == target }) else {
                    throw CLIError.exit(2, "Unknown provider '\(target)'. Run switch providers.")
                }
                accounts = accounts.filter { $0.identity.providerID.rawValue == target }
            }
        }

        let cache = codexCache(input.paths)
        let force = input.values.contains("--force")
        let results = await fetchAll(accounts) { account in
            try await fetchUsage(account, manager: manager, cache: cache, force: force)
        }

        var fetched: [LimitsDocument.Account] = []
        var plain: [String] = []
        var failures: [LimitsDocument.Failure] = []
        for (account, result) in zip(accounts, results) {
            switch result {
            case .success(let usage):
                fetched.append(.init(account, usage: usage, isDefault: status.isDefault(account)))
                plain.append(plainBlock(account, usage: usage, isDefault: status.isDefault(account)))
            case .failure(let error):
                let message = LimitFormat.message(error)
                failures.append(.init(accountId: account.id, provider: account.identity.providerID.rawValue,
                                      message: message))
                plain.append("error  \(AIManagerCLI.providerName(account.identity.providerID)) "
                    + "\(account.id.uuidString): \(message)")
            }
        }
        if input.json {
            let document = LimitsDocument(generatedAt: Date(), accounts: fetched, errors: failures)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(document), as: UTF8.self))
        } else if plain.isEmpty {
            print("No saved accounts to check.")
        } else {
            print(plain.joined(separator: "\n\n"))
        }
        return !accounts.isEmpty && fetched.isEmpty ? 4 : 0
    }

    // MARK: history

    /// `ai-manager history [--json] [--period week|month|year] [--group account|model|project]`:
    /// the Overview dashboard's data. Account groups come only from attributable sources.
    static func history(_ input: CommandLineInput, manager: AccountManager) async throws {
        try rejectUnknownFlags(input, allowed: ["--json", "--period", "--group"], code: 2)
        func option(_ name: String) -> String? {
            input.values.firstIndex(of: name).flatMap { input.values.dropFirst($0 + 1).first }
        }
        guard let period = UsagePeriod(rawValue: option("--period") ?? "week") else {
            throw CLIError.exit(2, "Period must be week, month, or year.")
        }
        guard let grouping = UsageGrouping(rawValue: option("--group") ?? "account") else {
            throw CLIError.exit(2, "Group must be account, model, or project.")
        }
        let accounts = try await manager.status().accounts
        let support = input.paths.applicationSupport
        let pricing = ClaudePricingSource(cacheURL: support.appending(path: "cache/model-pricing.json"))
        let grok = accounts.filter { $0.identity.providerID == .grokBuild }
        let sources = UsageHistorySources(
            ledger: codexCache(input.paths),
            claude: ClaudeCostScanner(cacheURL: support.appending(path: "cache/claude-history.json"),
                                      pricing: pricing.loader()),
            claudeHomes: UsageHistory.claudeProfileHomes(
                applicationSupport: support,
                accountIDs: accounts.filter { $0.identity.providerID == .claudeCode }.map(\.id)),
            grokSessions: UsageHistory.grokSessionsFolder(),
            grokAccountID: grok.count == 1 ? grok.first?.id.uuidString.lowercased() : nil,
            pricing: pricing.loader())
        let summary = await UsageHistory(sources: sources).snapshot().summary(period: period, grouping: grouping)
        if input.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(summary), as: UTF8.self))
            return
        }
        let totals = summary.totals
        print("\(period.rawValue): \(totals.tokens) tokens"
            + (totals.costUSD.map { String(format: ", about $%.2f", $0) } ?? "")
            + ", \(totals.activeAccounts) active accounts"
            + (totals.busiestDay.map { ", busiest \($0)" } ?? ""))
        for group in summary.groups {
            print("  \(group.label)  \(group.tokens)" + (group.costUSD.map { String(format: "  $%.2f", $0) } ?? ""))
        }
    }

    /// One block per account, plain text.
    private static func plainBlock(_ account: AccountRecord, usage: ProviderUsage, isDefault: Bool) -> String {
        var lines: [String] = []
        var header = AIManagerCLI.providerName(account.identity.providerID)
        if let email = usage.email ?? account.identity.email { header += "  \(email)" }
        if let plan = usage.plan { header += "  \(plan)" }
        if isDefault { header += "  DEFAULT" }
        lines.append(header)
        lines.append("  id      \(account.id.uuidString)")
        for window in usage.windows {
            var row = "  \(window.title.padding(toLength: 18, withPad: " ", startingAt: 0))"
            if let left = LimitFormat.remaining(window) {
                row += "\(Int(left.rounded()))% left"
            } else {
                row += "unavailable"
            }
            if let reset = window.resetsAt { row += "  resets \(LimitFormat.resetLabel(until: reset))" }
            lines.append(row)
            if let detail = window.detail { lines.append("    \(detail)") }
        }
        if let cost = usage.cost {
            for row in LimitFormat.costRows(cost) {
                lines.append("  \(row.label.padding(toLength: 8, withPad: " ", startingAt: 0))\(row.value)")
            }
        }
        for chart in usage.charts { lines.append("  " + LimitFormat.chartLine(chart)) }
        for section in usage.sections {
            if let title = section.title { lines.append("  \(title)") }
            for row in section.rows { lines.append("    \(row.label): \(row.value)") }
        }
        if lines.count == 2 { lines.append("  The provider returned no limits.") }
        return lines.joined(separator: "\n")
    }

    // MARK: guard

    static func guardLimit(_ input: CommandLineInput, manager: AccountManager) async throws -> Int32 {
        try rejectUnknownFlags(
            input, allowed: ["--json", "--fail-open", "--provider", "--account", "--min-remaining", "--window"],
            code: 64)
        guard input.positional.isEmpty else { throw CLIError.exit(64, "guard takes options only. Run switch help.") }
        guard let providerValue = input.option("--provider"), !providerValue.hasPrefix("--") else {
            throw CLIError.exit(64, "--provider <id> is required.")
        }
        guard AccountManager.providerCatalog.contains(where: { $0.id.rawValue == providerValue }) else {
            throw CLIError.exit(64, "Unknown provider '\(providerValue)'. Run switch providers.")
        }
        guard let thresholdText = input.option("--min-remaining"),
              let threshold = Double(thresholdText), threshold.isFinite, (0...100).contains(threshold) else {
            throw CLIError.exit(64, "--min-remaining must be a number from 0 to 100.")
        }
        var requested: UUID?
        if input.values.contains("--account") {
            guard let value = input.option("--account"), let id = UUID(uuidString: value) else {
                throw CLIError.exit(64, "--account must be an account UUID.")
            }
            requested = id
        }
        let windowID = input.option("--window")
        if input.values.contains("--window"), windowID == nil || windowID!.hasPrefix("--") {
            throw CLIError.exit(64, "--window needs a window ID.")
        }
        let provider = ProviderID(rawValue: providerValue)
        let status = try await manager.status()
        let accountID = requested ?? status.defaultAccountID(for: provider)
        if let requested, !status.accounts.contains(where: { $0.id == requested && $0.identity.providerID == provider }) {
            throw CLIError.exit(64, "No saved \(providerValue) account has the ID \(requested.uuidString).")
        }

        func finish(_ decision: String, _ reason: String, window: String? = nil, remaining: Double? = nil) -> Int32 {
            let blocked = decision == "block"
            let unknown = decision == "unknown"
            let code: Int32 = blocked ? 1 : unknown ? (input.values.contains("--fail-open") ? 0 : guardUnknown) : 0
            if input.json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let value = GuardDecision(provider: providerValue, account: accountID, window: window,
                                          remaining: remaining, threshold: threshold, decision: decision,
                                          reason: reason, exitCode: code)
                if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
            } else {
                print("\(decision): \(reason)")
            }
            return code
        }

        guard let accountID, let account = status.accounts.first(where: { $0.id == accountID }) else {
            return finish("unknown", "No default \(providerValue) account is saved.")
        }
        let usage: ProviderUsage
        do {
            let cache = codexCache(input.paths)
            usage = try await withTimeout(60) {
                try await fetchUsage(account, manager: manager, cache: cache, force: true)
            }
        } catch {
            return finish("unknown", "Usage could not be read: \(LimitFormat.message(error))")
        }
        let window: UsageWindow?
        if let windowID {
            window = usage.windows.first { $0.id == windowID }
        } else {
            window = usage.windows.first
        }
        guard let window else {
            return finish("unknown", windowID.map { "The provider returned no window '\($0)'." }
                ?? "The provider returned no limit windows.")
        }
        guard let remaining = LimitFormat.remaining(window) else {
            return finish("unknown", "The provider gave no usage share for \(window.id).", window: window.id)
        }
        let shown = Fmt.number(remaining, digits: 1)
        if remaining > threshold {
            return finish("allow", "\(shown)% remains in \(window.id), above \(Fmt.number(threshold, digits: 1))%.",
                          window: window.id, remaining: remaining)
        }
        return finish("block", "\(shown)% remains in \(window.id), at or below \(Fmt.number(threshold, digits: 1))%.",
                      window: window.id, remaining: remaining)
    }

    // MARK: add and import for generic providers

    static func genericSpec(_ value: String?) -> ProviderSpec? {
        guard let value, let spec = ProviderCatalog.spec(ProviderID(rawValue: value)),
              ProviderCatalog.addable.contains(where: { $0.id == spec.id }) else { return nil }
        return spec
    }

    /// `add <provider>`: typed credentials for secret providers; foreground sign-in for file providers.
    static func add(_ spec: ProviderSpec, input: CommandLineInput, manager: AccountManager) async throws {
        if spec.style == .files {
            guard !input.json else {
                throw CLIError.exit(2, "\(spec.name) sign-in needs a terminal. Run switch add \(spec.id.rawValue), or switch import \(spec.id.rawValue) after signing in.")
            }
            guard spec.login != nil else {
                throw CLIError.exit(2, "\(spec.name) has no sign-in command. Sign in with its own tool, then run switch import \(spec.id.rawValue).")
            }
            try AIManagerCLI.confirm(input, "Run the \(spec.name) sign-in in this terminal and save the account?")
            let result = try await signIn(spec, manager: manager)
            if result.check.state == .completed {
                print(result.check.message)
            } else {
                let exited = result.status == 0 ? "" : "\(spec.name) sign-in exited with status \(result.status). "
                throw CLIError.exit(1, "\(exited)\(result.check.message) "
                    + "Run switch check-login \(result.session.id.uuidString) --yes after it finishes.")
            }
            return
        }
        try rejectUnknownFlags(input, allowed: ["--field", "--stdin", "--json", "--yes"], code: 2)
        var values: [String: String] = [:]
        for pair in input.optionValues("--field") {
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                throw CLIError.exit(2, "Use --field key=value.")
            }
            let key = String(pair[..<separator])
            guard spec.fields.contains(where: { $0.key == key }) else {
                throw CLIError.exit(2, "Unknown field '\(key)' for \(spec.name). Fields: \(spec.fields.map(\.key).joined(separator: ", ")).")
            }
            guard values[key] == nil else { throw CLIError.exit(2, "Field '\(key)' was given twice.") }
            values[key] = String(pair[pair.index(after: separator)...])
        }
        if input.values.contains("--stdin") {
            let open = spec.fields.filter { $0.secure && values[$0.key] == nil }
            guard open.count == 1, let field = open.first else {
                throw CLIError.exit(2, "--stdin fills exactly one secure field that has no --field value.")
            }
            let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CLIError.exit(2, "Standard input was empty.") }
            values[field.key] = text
        }
        let missing = spec.fields.filter {
            !$0.optional && (values[$0.key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        guard missing.isEmpty else {
            let names = missing.map(\.key).joined(separator: ", ")
            throw CLIError.exit(2, "\(spec.name) needs: \(names). Pass --field key=value, or --stdin for one secure field.")
        }
        let account = try await manager.addProviderAccount(providerID: spec.id, fields: values)
        try await report(saved: account, spec: spec, manager: manager, json: input.json)
    }

    /// `import <provider>`: saves the current sign-in of a file provider.
    static func importLive(_ spec: ProviderSpec, input: CommandLineInput, manager: AccountManager) async throws {
        guard spec.style == .files else {
            throw CLIError.exit(2, "\(spec.name) uses typed credentials. Run switch add \(spec.id.rawValue) --field key=value.")
        }
        try rejectUnknownFlags(input, allowed: ["--json", "--yes"], code: 2)
        guard let identity = await manager.liveProviderIdentity(providerID: spec.id) else {
            throw CLIError.exit(1, "\(spec.name) is not signed in on this Mac.")
        }
        try AIManagerCLI.confirm(input, "Save the current \(spec.name) sign-in (\(describe(identity))) as a Switch account?")
        let account = try await manager.importLiveProviderAccount(providerID: spec.id)
        try await report(saved: account, spec: spec, manager: manager, json: input.json)
    }

    /// Runs the official sign-in command in the foreground, then saves the account when it finished.
    static func signIn(
        _ spec: ProviderSpec, manager: AccountManager
    ) async throws -> (session: AccountLoginSession, check: AccountLoginCheck, status: Int32) {
        let start = try await manager.startAccountLogin(providerID: spec.id)
        let status = try await manager.run(start.launchSpec)
        let check = try await manager.checkAccountLogin(id: start.session.id)
        return (start.session, check, status)
    }

    static func describe(_ identity: CredentialIdentity) -> String {
        [identity.email, identity.plan].compactMap { $0 }.joined(separator: ", ").nilIfEmpty ?? "account found"
    }

    private static func report(saved account: AccountRecord, spec: ProviderSpec, manager: AccountManager,
                               json: Bool) async throws {
        let status = try await manager.status()
        if json {
            struct Saved: Encodable {
                let id: UUID
                let provider: String
                let providerName: String
                let email: String?
                let isDefault: Bool
                enum CodingKeys: String, CodingKey { case id, provider, providerName, email, isDefault = "default" }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let saved = Saved(id: account.id, provider: spec.id.rawValue, providerName: spec.name,
                              email: account.identity.email, isDefault: status.isDefault(account))
            print(String(decoding: try encoder.encode(saved), as: UTF8.self))
        } else {
            print("Saved \(spec.name) account \(account.id.uuidString)\(status.isDefault(account) ? " (default)" : "").")
        }
    }

    // MARK: helpers

    private static func rejectUnknownFlags(_ input: CommandLineInput, allowed: Set<String>, code: Int32) throws {
        for value in input.values where value.hasPrefix("--") && !allowed.contains(value) {
            throw CLIError.exit(code, "Unknown option '\(value)'. Run switch help.")
        }
    }

    private static func codexCache(_ paths: ManagerPaths) -> CodexUsageStatisticsCache? {
        try? CodexUsageStatisticsCache(
            databaseURL: paths.applicationSupport.appending(path: "cache/account-usage.sqlite"),
            activityDatabaseURL: paths.applicationSupport.appending(path: "activity/daily.sqlite"))
    }

    /// Codex uses the existing app-server check (cached unless forced); every other provider
    /// goes through its `ProviderSpec`.
    static func fetchUsage(
        _ account: AccountRecord, manager: AccountManager, cache: CodexUsageStatisticsCache?, force: Bool
    ) async throws -> ProviderUsage {
        guard account.identity.providerID == .codex else {
            return try await manager.readProviderUsage(accountID: account.id)
        }
        if !force, let entry = try? await cache?.latest(for: [account.id]).first,
           let snapshot = entry.snapshot, !entry.isStale, let usage = codexUsage(snapshot, account: account) {
            return usage
        }
        let result = await manager.checkAccount(accountID: account.id)
        guard let snapshot = result.usage else { throw CLIError.message(result.verification.detail) }
        try? await cache?.upsertSuccess(accountID: account.id, snapshot: snapshot)
        guard let usage = codexUsage(snapshot, account: account) else {
            throw CLIError.message("Codex returned no limits for this account.")
        }
        return usage
    }

    static func codexUsage(_ snapshot: CodexAccountUsageSnapshot, account: AccountRecord) -> ProviderUsage? {
        guard let bucket = snapshot.rateLimits?.defaultBucket else { return nil }
        let windows = [bucket.primary, bucket.secondary].enumerated().compactMap { index, window -> UsageWindow? in
            guard let window else { return nil }
            let weekly = window.windowDurationMinutes == 10_080 || (index == 1 && window.windowDurationMinutes != 300)
            return UsageWindow(
                id: weekly ? "weekly" : "session", title: weekly ? "Weekly" : "Session",
                usedPercent: window.usedPercent.map(Double.init), resetsAt: window.resetsAt,
                windowMinutes: window.windowDurationMinutes.map(Int.init))
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(windows: windows + snapshot.extraWindows,
                             sections: [UsageSection(nil, snapshot.factRows)],
                             plan: CodexPlanNames.display(snapshot.account?.plan),
                             email: snapshot.account?.email ?? account.identity.email,
                             fetchedAt: snapshot.fetchedAt).sanitized()
    }

    /// At most `concurrency` fetches at once, each cut off after `timeout` seconds. Results keep input order.
    static func fetchAll(
        _ accounts: [AccountRecord], concurrency: Int = 4, timeout: TimeInterval = 60,
        _ fetch: @escaping @Sendable (AccountRecord) async throws -> ProviderUsage
    ) async -> [Result<ProviderUsage, Error>] {
        var results = [Result<ProviderUsage, Error>](
            repeating: .failure(CLIError.message("Not checked.")), count: accounts.count)
        await withTaskGroup(of: (Int, Result<ProviderUsage, Error>).self) { group in
            var next = 0
            var running = 0
            while next < accounts.count || running > 0 {
                while running < concurrency && next < accounts.count {
                    let index = next, account = accounts[next]
                    group.addTask {
                        do {
                            return (index, .success(try await withTimeout(timeout) { try await fetch(account) }))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                    next += 1
                    running += 1
                }
                if let (index, result) = await group.next() {
                    results[index] = result
                    running -= 1
                }
            }
        }
        return results
    }

    /// Returns when the work ends or the deadline passes, even if the work ignores cancellation.
    static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let timer = Task {
                guard (try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))) != nil else { return }
                once.finish(.failure(CLIError.message("The provider did not answer within \(Int(seconds)) seconds.")))
            }
            Task {
                do { once.finish(.success(try await work())) } catch { once.finish(.failure(error)) }
                timer.cancel()
            }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<T, Error>

        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            continuation.resume(with: result)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
