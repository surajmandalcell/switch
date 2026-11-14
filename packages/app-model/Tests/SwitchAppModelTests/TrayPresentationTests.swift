import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel

/// Parity with the Mac popover: the inputs and expected outputs of MenuBarContract.swift and NativeUIContract.swift
/// (window names, lines, reset text, tokens, builders, the status item), run against the shared rules.
final class TrayPresentationTests: XCTestCase {
    private typealias P = TrayPresentation

    private func account(_ name: String, _ usage: TrayUsage? = nil, verified: Bool = true, active: Bool = false,
                         shows: Bool = true, provider: ProviderID = .codex) -> TrayAccount {
        TrayAccount(identity: name, isVerified: verified, isActive: active, usage: usage, showsUsage: shows,
                    providerID: provider)
    }

    func testWindowNamesAndPools() {
        func name(_ title: String, _ minutes: Int? = nil) -> P.WindowName { P.windowName(minutes: minutes, title: title) }
        XCTAssertEqual(name("Session", 300), .init(pool: nil, label: "Session"))
        XCTAssertEqual(name("5-hour", 300), .init(pool: nil, label: "Session"))
        XCTAssertEqual(name("5 hours", 300), .init(pool: nil, label: "Session"))
        XCTAssertEqual(name("Daily", 1_440), .init(pool: nil, label: "Daily"))
        XCTAssertEqual(name("Monthly credits"), .init(pool: nil, label: "Monthly"))
        XCTAssertEqual(name("Credits"), .init(pool: nil, label: "Credits"))
        XCTAssertEqual(name("Pro", 1_440), .init(pool: nil, label: "Pro"))
        XCTAssertEqual(name("30-day window"), .init(pool: nil, label: "30-day window"))
        XCTAssertEqual(name("Core 5-hour", 300), .init(pool: "Core", label: "Session"))
        XCTAssertEqual(name("Core weekly", 10_080), .init(pool: "Core", label: "Weekly"))
        XCTAssertEqual(name("Core monthly"), .init(pool: "Core", label: "Monthly"))
        XCTAssertEqual(name("Weekly Opus", 10_080), .init(pool: "Opus", label: "Weekly"))
        XCTAssertEqual(name("Spark Session", 300), .init(pool: "Spark", label: "Session"))
        XCTAssertEqual(name("Spark 30-day window"), .init(pool: "Spark", label: "30-day window"))
        XCTAssertEqual(name("Premium weekly"), .init(pool: "Premium", label: "Weekly"))
        XCTAssertEqual(name("Spark credits"), .init(pool: "Spark", label: "Credits"))
        for model in ["Fable", "Sonnet", "Opus", "Future Model"] {
            XCTAssertEqual(name(UsageWindow.modelScopedTitle(model: model), 10_080), .init(pool: model, label: "Weekly"))
        }
    }

    func testLinesPoolsAndCollapsedRows() throws {
        let droidSix = try XCTUnwrap(TrayUsage(providerUsage: ProviderUsage(windows: [
            .init(id: "session", title: "5-hour", usedPercent: 10, windowMinutes: 300),
            .init(id: "weekly", title: "Weekly", usedPercent: 20, windowMinutes: 10_080),
            .init(id: "monthly", title: "Monthly", usedPercent: 30),
            .init(id: "factory-core-5h", title: "Core 5-hour", usedPercent: 40, windowMinutes: 300),
            .init(id: "factory-core-7d", title: "Core weekly", usedPercent: 50, windowMinutes: 10_080),
            .init(id: "factory-core-monthly", title: "Core monthly", usedPercent: 60)])))
        let droidRows = P.lines(for: account("droid", droidSix), expanded: true)
        XCTAssertEqual(droidRows.map(\.label), ["Session", "Weekly", "Monthly", "Core", "Session", "Weekly", "Monthly"])
        XCTAssertEqual(droidRows.map(\.isHeading), [false, false, false, true, false, false, false])
        XCTAssertEqual(P.lines(for: account("droid", droidSix)).map(\.label), ["Session", "Weekly"])

        let now = Date()
        let two = account("a", TrayUsage(usedPercentage: 24, secondaryUsedPercentage: 59, resetsAt: now + 3_600,
                                         secondaryResetsAt: now + 86_400, primaryMinutes: 300, secondaryMinutes: 10_080))
        XCTAssertEqual(P.lines(for: two).map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(P.lines(for: two).map(\.used), [24, 59])
        let one = account("b", TrayUsage(usedPercentage: 88, primaryLabel: "Weekly", primaryMinutes: 10_080))
        XCTAssertEqual(P.lines(for: one).map(\.label), ["Weekly"])
        let provider = account("p", TrayUsage(usedPercentage: nil, providerWindows: [
            .init(title: "Session", used: 20, resetsAt: nil, minutes: 300),
            .init(title: "Weekly", used: nil, resetsAt: nil, minutes: 10_080),
            .init(title: "Monthly", used: 65, resetsAt: nil, minutes: 43_200)]), provider: .claudeCode)
        XCTAssertEqual(P.lines(for: provider).map(\.label), ["Session", "Monthly"], "An empty window still draws a bar")
        XCTAssertEqual(P.lines(for: provider).map(\.used), [20, 65])
        let weeklyOnly = account("h", TrayUsage(usedPercentage: nil, secondaryUsedPercentage: 96))
        XCTAssertEqual(P.lines(for: weeklyOnly).map(\.label), ["Weekly"])
        XCTAssertEqual(P.lines(for: weeklyOnly).map(\.used), [96])
        XCTAssertEqual(P.content(for: account("i")), .lines([]))
        XCTAssertEqual(P.content(for: account("j", verified: false)), .signIn)
        let balance = account("k", TrayUsage(usedPercentage: nil, balanceText: "$12.40"))
        XCTAssertEqual(P.lines(for: balance).first?.balance, "$12.40")
        XCTAssertEqual(P.lines(for: balance).first.flatMap(P.displayLabel), "Balance")

        // NativeUIContract: the Fable pool under its heading, a cost limit as Monthly credits.
        let fable = account("popover@example.test", TrayUsage(providerUsage: ProviderUsage(windows: [
            .init(id: "s", title: "Session", usedPercent: 20, windowMinutes: 300),
            .init(id: "w", title: "Weekly", usedPercent: nil, windowMinutes: 10_080),
            .init(id: "f", title: "Weekly Fable", usedPercent: 36, windowMinutes: 10_080),
            .init(id: "m", title: "Monthly", usedPercent: 80, windowMinutes: 43_200),
        ], cost: UsageCost(used: 2, limit: 10, currency: "USD", period: "Monthly"))), provider: .claudeCode)
        XCTAssertEqual(P.lines(for: fable).map(\.label), ["Session", "Monthly"])
        XCTAssertEqual(P.lines(for: fable, expanded: true).map(\.label), ["Session", "Monthly", "Monthly", "Fable", "Weekly"])
        XCTAssertTrue(P.lines(for: fable, expanded: true).allSatisfy { $0.isHeading || $0.used != nil || $0.balance != nil })
        let amountOnly = account("credits@example.test", TrayUsage(providerUsage: ProviderUsage(windows: [
            .init(id: "credits", title: "Credits", usedPercent: nil, detail: "12 credits")])))
        XCTAssertEqual(P.lines(for: amountOnly).first?.balance, "12 credits")
        XCTAssertTrue(P.canExpand(fable))
        XCTAssertEqual(P.openToolTitle(account("l")), "Open Codex")
        XCTAssertEqual(P.openToolTitle(account("m", provider: .claudeCode)), "Open \(ProviderID.claudeCode.displayName)")
    }

    func testResetTextCountdownAndExactTimes() throws {
        let now = Date()
        func countdown(_ interval: TimeInterval) -> String { P.resetText(now + interval, now: now, exact: false) }
        XCTAssertEqual(countdown(6 * 86_400 + 8 * 3_600 + 30), "6d 8h")
        XCTAssertEqual(countdown(3_600 + 45 * 60 + 30), "1h 45m")
        XCTAssertEqual(countdown(12 * 60 + 30), "12m")
        XCTAssertEqual(countdown(20), "<1m")
        XCTAssertEqual(countdown(-5), "Not started")
        XCTAssertEqual(P.resetText(now - 5, now: now, exact: false, used: 40), "Resetting…")
        XCTAssertEqual(P.resetText(now - 5, now: now, exact: true, used: 0), "Not started")

        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        func date(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)))
        }
        let base = try date(10, 15, 25)
        func exact(_ reset: Date, _ format: String) -> String {
            P.exactText(reset, now: base, hourFormat: format, timeZone: utc)
        }
        XCTAssertEqual(exact(try date(10, 17, 30), "12h"), "Resets 5:30 PM")
        XCTAssertEqual(exact(try date(10, 17, 30), "24h"), "Resets 17:30")
        XCTAssertEqual(exact(try date(11, 9, 5), "12h"), "Resets tomorrow 9:05 AM")
        XCTAssertEqual(exact(try date(13, 0, 0), "24h"), "Resets Tue 00:00")
        XCTAssertEqual(exact(try date(20, 23, 45), "12h"), "Resets Oct 20, 11:45 PM")
        XCTAssertEqual(exact(base - 5, "12h"), "Not started")
        XCTAssertEqual(P.exactText(base - 5, now: base, usedPercent: 40), "Resetting…")
        // The reset column drops "Resets": "5:30 PM", "tomorrow 9:05 AM".
        XCTAssertEqual(P.resetText(try date(10, 17, 30), now: base, exact: true, hourFormat: "12h", timeZone: utc), "5:30 PM")
        XCTAssertEqual(P.resetText(try date(11, 9, 5), now: base, exact: true, hourFormat: "24h", timeZone: utc),
                       "tomorrow 09:05")
    }

    func testTokensAndPrices() {
        XCTAssertEqual(P.compactTokens(24_100_000), "24.1M")
        XCTAssertEqual(P.compactTokens(24_000_000), "24M")
        XCTAssertEqual(P.compactTokens(950), "950")
        XCTAssertEqual(P.compactTokens(3_200), "3.2K")
        XCTAssertEqual(P.compactTokens(999_950), "1M")
        XCTAssertEqual(P.compactTokens(1_250_000_000), "1.3B")
        let price = CodexAPIPrice(model: "gpt-5.6-sol", inputPerMillion: 4, cachedInputPerMillion: 0.4, outputPerMillion: 20)
        let short = TrayUsage(usedPercentage: 10, tokenPeriodLabel: "since reset", tokens: 24_100_000)
        XCTAssertEqual(P.tokenCaption(short), "24.1M since reset")
        XCTAssertEqual(P.tokenLabel, "Tokens")
        // 24.1M input tokens at $4 per million: $96.40, zero decimals.
        let long = TrayUsage(usedPercentage: 10, tokenPeriodLabel: "since reset", tokens: 24_100_000, apiPrice: price)
        XCTAssertEqual(P.tokenCaption(long), "24.1M since reset · ≈$96 API")
        let big = TrayUsage(usedPercentage: 10, tokenPeriodLabel: "since reset", tokens: 412_000_000, apiPrice: price)
        XCTAssertEqual(P.tokenCaption(big), "412M since reset · ≈$1,648 API")
        XCTAssertNil(P.tokenCaption(TrayUsage(usedPercentage: 20, tokenPeriodLabel: "since reset", tokens: 0)))
        XCTAssertTrue(P.hasTokenCaption(account("t", short)))
        XCTAssertEqual(P.tokenPeriodLabel("monthly"), "in 30 days")
        XCTAssertEqual(P.tokenPeriodLabel("sinceReset"), "since reset")
    }

    func testPercentLabelsKeepOverageAndClampTheBar() {
        XCTAssertEqual(P.percentLabel(forUsed: 130, showsUsed: true), "130% used")
        XCTAssertEqual(P.percentLabel(forUsed: 130, showsUsed: false), "0% left")
        XCTAssertEqual(P.fill(forUsed: 130, showsUsed: true), 1)
        XCTAssertEqual(P.fill(forUsed: -5, showsUsed: true), 0)
        XCTAssertEqual(P.fill(forUsed: 25, showsUsed: false), 0.75)
    }

    func testUsageBuilders() throws {
        let end = Date()
        let weeklyPrimary = TrayUsage(bucket: .init(
            id: nil, name: nil, plan: nil, model: nil,
            primary: .init(usedPercent: 1, windowDurationMinutes: 10_080, resetsAt: nil),
            secondary: nil, credits: nil, spendControlReached: nil), fetchedAt: end)
        XCTAssertEqual(weeklyPrimary?.usedPercentage, 1)
        XCTAssertNil(weeklyPrimary?.secondaryUsedPercentage)
        XCTAssertEqual(weeklyPrimary?.primaryLabel, "Weekly")
        let weeklySecondary = TrayUsage(bucket: .init(
            id: nil, name: nil, plan: nil, model: nil, primary: nil,
            secondary: .init(usedPercent: 3, windowDurationMinutes: 10_080, resetsAt: nil),
            credits: nil, spendControlReached: nil), fetchedAt: end)
        XCTAssertEqual(weeklySecondary?.usedPercentage, 3)
        XCTAssertEqual(weeklySecondary?.primaryLabel, "Weekly")
        let card = TrayUsage(providerUsage: ProviderUsage(windows: [
            UsageWindow(id: "w", title: "Weekly", usedPercent: 40.4, windowMinutes: 10_080),
            UsageWindow(id: "s", title: "Session", usedPercent: 20, windowMinutes: 300)]))
        XCTAssertEqual(card?.primaryLabel, "Session")
        XCTAssertEqual(card?.secondaryLabel, "Weekly")
        XCTAssertEqual(card?.usedPercentage, 20)
        XCTAssertEqual(card?.secondaryUsedPercentage, 40)
        XCTAssertNil(TrayUsage(providerUsage: ProviderUsage()))
        let balanceOnly = TrayUsage(providerUsage: ProviderUsage(cost: UsageCost(balance: 12.4, currency: "USD")))
        XCTAssertEqual(balanceOnly?.balanceText, "$12.40")
        XCTAssertNil(balanceOnly?.usedPercentage)
        let three = TrayUsage(providerUsage: ProviderUsage(windows: [
            UsageWindow(id: "a", title: "A", usedPercent: 10), UsageWindow(id: "b", title: "B", usedPercent: 20),
            UsageWindow(id: "c", title: "C", usedPercent: 30)]))
        XCTAssertEqual(three?.secondaryLabel, "B")
        XCTAssertEqual(three?.secondaryUsedPercentage, 20)
        // Codex credits, an extra bucket, and the Credits line text.
        let codex = try XCTUnwrap(TrayUsage(bucket: .init(
            id: "codex", name: nil, plan: nil, model: nil,
            primary: .init(usedPercent: 12, windowDurationMinutes: 300, resetsAt: nil),
            secondary: .init(usedPercent: 79, windowDurationMinutes: 10_080, resetsAt: nil),
            credits: .init(hasCredits: true, unlimited: false, balance: "796.4009760000"), spendControlReached: nil),
            additionalBuckets: ["spark": .init(id: "spark", name: "GPT-5.3-Codex-Spark", plan: nil, model: nil,
                primary: .init(usedPercent: 5, windowDurationMinutes: 300, resetsAt: nil), secondary: nil,
                credits: nil, spendControlReached: nil)], fetchedAt: end))
        XCTAssertEqual(codex.providerWindows?.map(\.title).first, "Session")
        XCTAssertEqual(codex.providerWindows?.first { $0.title == "Credits" }?.balance, "$31.84 · 796 credits")
        let rows = P.lines(for: account("codex", codex), expanded: true)
        XCTAssertEqual(rows.filter(\.isHeading).count, 1, "\(rows.map(\.label))")
        XCTAssertEqual(TrayUsage.credits(.init(hasCredits: nil, unlimited: true, balance: nil)), "Unlimited")
        XCTAssertEqual(TrayUsage.credits(.init(hasCredits: false, unlimited: nil, balance: nil)), "None")
    }

    /// MenuBarContract `statusItemFailures`: eight accounts, account 1 hidden from usage, 2 and 5 Claude Code.
    func testStatusItemSelectionOrderAndTooltip() {
        let enabled = (0..<8).map { index in
            TrayAccount(identity: "account-\(index)@example.test", isActive: index == 5,
                        usage: TrayUsage(usedPercentage: index * 10), showsUsage: index != 1,
                        providerID: index == 2 || index == 5 ? .claudeCode : .codex)
        }
        func status(_ order: [ProviderID] = [], services: Set<ProviderID> = [], accounts: Set<UUID> = [],
                    one: Bool = false) -> [UUID] {
            P.statusGroups(P.orderedAccounts(enabled, order: order), hiddenServices: services, hiddenAccounts: accounts,
                           onePerService: one).flatMap { $0 }.map(\.id)
        }
        func title(_ order: [ProviderID] = [], one: Bool = false, used: Bool = false) -> String {
            P.statusGroups(P.orderedAccounts(enabled, order: order), hiddenServices: [], hiddenAccounts: [],
                           onePerService: one).flatMap { $0 }
                .map { $0.quotaUsedPercentage.map { "\(P.displayedPercentage(forUsed: $0, showsUsed: used))%" } ?? "–" }
                .joined(separator: " ")
        }
        func ids(_ indexes: [Int]) -> [UUID] { indexes.map { enabled[$0].id } }
        func rows(_ order: [ProviderID] = []) -> [UUID] { P.groups(P.orderedAccounts(enabled, order: order)).flatMap { $0 }.map(\.id) }

        XCTAssertEqual(status(), ids([0, 3, 4, 6, 7, 2]))
        XCTAssertEqual(title(), "100% 70% 60% 40% 30% 80%")
        XCTAssertEqual(title(used: true), "0% 30% 40% 60% 70% 20%")
        let shown = P.statusGroups(P.orderedAccounts(enabled, order: []), hiddenServices: [], hiddenAccounts: [],
                                   onePerService: false).flatMap { $0 }
        let tooltip = P.statusTooltip(enabled, shown: shown, hiddenServices: [], hiddenAccounts: [], onePerService: false,
                                      showsUsed: false)
        XCTAssertTrue(tooltip.contains("Claude Code, \(enabled[2].identity), 80% left"), tooltip)
        XCTAssertFalse(tooltip.contains(enabled[1].identity))

        XCTAssertEqual(status([.claudeCode]), ids([2, 5, 0, 3, 4, 6]))
        XCTAssertEqual(title([.claudeCode]), "80% 50% 100% 70% 60% 40%")
        XCTAssertEqual(P.groups(P.orderedAccounts(enabled, order: [.claudeCode])).map { $0[0].providerID }, [.claudeCode, .codex])
        XCTAssertEqual(status([.claudeCode], services: [.claudeCode]), ids([0, 3, 4, 6, 7]))
        XCTAssertEqual(rows([.claudeCode]), ids([2, 5, 0, 3, 4, 6, 7]), "Hiding a service removes its popover rows")
        XCTAssertEqual(status(accounts: [enabled[0].id, enabled[2].id]), ids([3, 4, 6, 7, 5]))
        XCTAssertEqual(rows(), ids([0, 3, 4, 6, 7, 2, 5]))
        XCTAssertEqual(status(one: true), ids([0, 5]))
        XCTAssertEqual(status(accounts: [enabled[5].id], one: true), ids([0, 2]))
        XCTAssertEqual(title(one: true), "100% 50%")

        // A hidden service's signed-out account stays out of the tooltip.
        let signedOut = TrayAccount(identity: "hidden-service", isVerified: false, providerID: .claudeCode)
        let all = enabled + [signedOut]
        let hiddenTooltip = P.statusTooltip(all, shown: P.statusGroups(all, hiddenServices: [.claudeCode], hiddenAccounts: [],
                                                                        onePerService: false).flatMap { $0 },
                                            hiddenServices: [.claudeCode], hiddenAccounts: [], onePerService: false,
                                            showsUsed: false)
        XCTAssertFalse(hiddenTooltip.contains("hidden-service") || hiddenTooltip.contains("Claude Code"))
        // A shown signed-out account says so.
        let outTooltip = P.statusTooltip([signedOut], shown: [], hiddenServices: [], hiddenAccounts: [], onePerService: false,
                                         showsUsed: false)
        XCTAssertEqual(outTooltip, "Claude Code, hidden-service, needs sign-in")
    }

    func testStatusItemSkipsAccountsWithoutAQuotaAndKeepsSavedPairs() {
        let noCache = TrayAccount(identity: "empty@example.test")
        let signedOut = TrayAccount(identity: "out@example.test", isVerified: false, usage: TrayUsage(usedPercentage: 10))
        let eligible = (0..<7).map { TrayAccount(identity: "tray\($0)@example.test", usage: TrayUsage(usedPercentage: $0 * 10)) }
        XCTAssertEqual(P.statusGroups([signedOut, noCache] + eligible, hiddenServices: [], hiddenAccounts: [],
                                      onePerService: false).flatMap { $0 }.map(\.id), eligible.prefix(6).map(\.id))
        for provider in [ProviderID(rawValue: "devin"), .droid] {
            let pair = (0..<2).map {
                TrayAccount(identity: "saved-\($0)", isActive: $0 == 0, usage: TrayUsage(usedPercentage: 20 + $0), providerID: provider)
            }
            let groups = P.statusGroups(pair, hiddenServices: [], hiddenAccounts: [], onePerService: false)
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(groups[0].map(\.id), pair.map(\.id))
        }
        let mixed = (0..<7).map {
            TrayAccount(identity: "mixed-\($0)", isActive: $0 == 0, usage: TrayUsage(usedPercentage: $0 * 10),
                        providerID: $0 == 0 || $0 == 6 ? .droid : .codex)
        }
        let ordered = P.orderedAccounts(mixed, order: [])
        let groups = P.statusGroups(ordered, hiddenServices: [], hiddenAccounts: [], onePerService: false)
        XCTAssertEqual(groups.flatMap { $0 }.map(\.id), [0, 6, 1, 2, 3, 4].map { mixed[$0].id })
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertEqual(P.groups(ordered).flatMap { $0 }.map(\.id), [0, 6, 1, 2, 3, 4, 5].map { mixed[$0].id })
        XCTAssertEqual(P.orderedProviders([.codex, .claudeCode, .droid],
                                          order: [.claudeCode, .claudeCode, ProviderID(rawValue: "unknown-service")]),
                       [.claudeCode, .codex, .droid])
    }

    func testAccessibilityLabel() {
        let now = Date()
        let row = TrayAccount(identity: "ada@example", isActive: true,
                              usage: TrayUsage(usedPercentage: 30, resetsAt: now + 3_600 + 30, primaryMinutes: 300))
        XCTAssertEqual(P.accessibilityLabel(row, showsUsed: false, now: now, exact: false),
                       "ada@example, Codex CLI, Default, Session 70% left, Resets 1h 0m")
        XCTAssertEqual(P.accessibilityLabel(TrayAccount(identity: "x", isVerified: false), showsUsed: false, now: now,
                                            exact: false), "x, Codex CLI, Needs sign in")
    }
}
