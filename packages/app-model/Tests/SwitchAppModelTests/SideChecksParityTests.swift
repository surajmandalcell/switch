import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel

// Ported from the Mac FeatureLogicChecks (notificationEngine, codexWindows, notificationStore, statusPoller,
// claudeActivity, chatMarkdown), so the shared copies keep the Mac behavior.

private func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertTrue(condition(), message, file: file, line: line)
}

private actor Flag {
    private(set) var value = true
    func set(_ next: Bool) { value = next }
}

private actor CallLog {
    private(set) var calls: [ProviderID] = []
    private(set) var urls: [ProviderID: URL?] = [:]
    private var running = 0
    private(set) var peak = 0

    func record(_ id: ProviderID, _ url: URL?) { calls.append(id); urls[id] = url }
    func enter() { running += 1; peak = max(peak, running) }
    func leave() { running -= 1 }
}

final class SideChecksParityTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let account = UUID(uuidString: "0E0A1001-7F3A-4C27-9D84-5B1E2A6C0001")!
    private static let all = QuotaNotificationSettings(almostOut: true, pace: true, availableAgain: true, signInAgain: true)
    private var now: Date { Self.now }
    private var account: UUID { Self.account }
    private var all: QuotaNotificationSettings { Self.all }

    /// A 5-hour window halfway through: 20% used is blue, 47% yellow, 70% red.
    private func paced(_ used: Double, resetsAt: Date? = nil, now at: Date = now) -> UsageWindow {
        UsageWindow(id: "session", title: "Session", usedPercent: used,
                    resetsAt: resetsAt ?? at.addingTimeInterval(150 * 60), windowMinutes: 300)
    }

    private func plain(_ used: Double) -> UsageWindow { UsageWindow(id: "balance", title: "Credits", usedPercent: used) }

    private func input(_ windows: [UsageWindow], signIn: QuotaSignInStatus = .ok, label: String = "a@x.test")
        -> [QuotaAccountInput] {
        [QuotaAccountInput(id: account, providerKey: "codex", providerName: "Codex CLI", accountLabel: label,
                           windows: windows, signIn: signIn)]
    }

    /// Runs one pass and commits every alert as delivered.
    @discardableResult
    private func pass(_ store: inout QuotaNotificationStore, _ inputs: [QuotaAccountInput],
                      _ settings: QuotaNotificationSettings = all, at time: Date = now, deliver: Bool = true)
        -> [QuotaAlertKind] {
        let result = QuotaNotificationEngine.evaluate(inputs, store: store, settings: settings, now: time)
        store = deliver ? result.committed(delivered: Set(result.alerts.map(\.id))) : result.store
        return result.alerts.map(\.kind)
    }

    func testNotificationEngine() throws {
        var store = QuotaNotificationStore()
        try expect(pass(&store, input([paced(70)])).isEmpty, "A window primed in the red raised an alert")
        try expect(pass(&store, input([paced(70)])).isEmpty, "An unchanged window raised an alert")

        store = QuotaNotificationStore()
        try expect(pass(&store, input([plain(50)])).isEmpty, "Priming raised Almost Out")
        try expect(pass(&store, input([plain(89)])).isEmpty, "Almost Out fired at 11% left")
        let first = QuotaNotificationEngine.evaluate(input([plain(91)]), store: store, settings: all, now: now)
        try expect(first.alerts.map(\.kind) == [.almostOut], "Almost Out did not fire at 9% left")
        let alert = first.alerts[0]
        try expect(alert.title == "Almost Out" && alert.body == "Under 10% usage remaining for this window."
                   && alert.subtitle == "Codex CLI · a@x.test · Credits", "Almost Out text is wrong: \(alert)")
        store = first.committed(delivered: [])
        try expect(pass(&store, input([plain(92)])) == [.almostOut], "A failed delivery consumed the edge")
        try expect(pass(&store, input([plain(93)])).isEmpty, "Almost Out repeated after delivery")
        try expect(pass(&store, input([plain(50)])).isEmpty, "Almost Out fired when leaving")
        try expect(pass(&store, input([plain(95)])) == [.almostOut], "Almost Out did not re-arm")
        store = QuotaNotificationStore()
        var off = all
        off.almostOut = false
        pass(&store, input([plain(50)]), off)
        try expect(pass(&store, input([plain(95)]), off).isEmpty, "A disabled toggle alerted")
        try expect(pass(&store, input([plain(95)])) == [.almostOut], "A missed crossing was consumed")

        store = QuotaNotificationStore()
        pass(&store, input([paced(20)]))
        try expect(pass(&store, input([paced(47)])) == [.cuttingItClose], "Blue to yellow")
        let close = QuotaNotificationEngine.evaluate(input([paced(47)]), store: store, settings: all, now: now)
        try expect(close.alerts.isEmpty, "Cutting It Close repeated")
        let run = QuotaNotificationEngine.evaluate(input([paced(70)]), store: store, settings: all, now: now)
        try expect(run.alerts.map(\.kind) == [.willRunOut], "Yellow to red")
        try expect(run.alerts[0].title == "Will Run Out"
                   && run.alerts[0].body == "Projected to finish before the limit resets.", "Will Run Out text")
        store = QuotaNotificationStore()
        pass(&store, input([paced(20)]))
        try expect(pass(&store, input([paced(70)])) == [.willRunOut], "A blue to red jump fired both alerts")
        pass(&store, input([paced(20)]))
        try expect(pass(&store, input([paced(70)])) == [.willRunOut], "Will Run Out did not re-arm after improving")
        store = QuotaNotificationStore()
        var noPace = all
        noPace.pace = false
        pass(&store, input([paced(20)]), noPace)
        pass(&store, input([paced(47)]), noPace)
        try expect(store.windows[QuotaNotificationEngine.windowKey(account, "session")]?.bucket == .healthy,
                   "A worsening was consumed by a disabled toggle")
        try expect(pass(&store, input([paced(47)])) == [.cuttingItClose], "Enabling Pace alerts did not catch up")

        store = QuotaNotificationStore()
        pass(&store, input([paced(20)]))
        pass(&store, input([paced(47)]))
        let later = now.addingTimeInterval(5 * 3_600)
        try expect(pass(&store, input([paced(20, now: later)]), all, at: later).isEmpty, "Reset raised an alert")
        try expect(pass(&store, input([paced(47, now: later)]), all, at: later) == [.cuttingItClose],
                   "A reset did not clear Cutting It Close")

        store = QuotaNotificationStore()
        pass(&store, input([paced(20)]))
        try expect(pass(&store, input([paced(47)])) == [.cuttingItClose], "Rolling window: first alert")
        let rolled = now.addingTimeInterval(600)
        let rolling = paced(32, resetsAt: now.addingTimeInterval(150 * 60 + 3_600), now: rolled)
        try expect(pass(&store, input([rolling]), all, at: rolled).isEmpty, "An early reset move re-alerted")
        try expect(pass(&store, input([rolling]), all, at: rolled).isEmpty, "A refresh of the same window re-alerted")
        try expect(store.windows[QuotaNotificationEngine.windowKey(account, "session")]?.firedClose == true,
                   "An early reset move cleared the fired mark")
        var legacy = try JSONDecoder().decode(QuotaNotificationStore.self, from: Data(
            #"{"windows":{"\#(account.uuidString)/session":{"firedClose":true,"firedRunOut":false,"bucket":"close","wasUnderTen":false,"wasSpent":false}},"signInAlerted":[]}"#.utf8))
        try expect(pass(&legacy, input([paced(47)])).isEmpty, "A legacy state raised an alert at launch")
        store = QuotaNotificationStore()
        pass(&store, input([plain(50)]))
        try expect(pass(&store, input([plain(95)])) == [.almostOut], "Almost Out before the drop")
        try expect(pass(&store, input([plain(92)])).isEmpty, "A small drop re-alerted")

        store = QuotaNotificationStore()
        try expect(pass(&store, input([plain(100)])).isEmpty, "A window primed at 100% alerted")
        try expect(pass(&store, input([plain(100)])).isEmpty, "A spent window alerted")
        try expect(pass(&store, input([plain(40)])) == [.availableAgain], "Available again did not fire")
        try expect(pass(&store, input([plain(40)])).isEmpty, "Available again repeated")
        store = QuotaNotificationStore()
        var noAvailable = all
        noAvailable.availableAgain = false
        pass(&store, input([plain(100)]), noAvailable)
        pass(&store, input([plain(40)]), noAvailable)
        try expect(pass(&store, input([plain(40)])).isEmpty, "A stale Available again event was kept")
        store = QuotaNotificationStore()
        pass(&store, input([paced(100)]))
        let reset = now.addingTimeInterval(6 * 3_600)
        let after = QuotaNotificationEngine.evaluate(input([paced(100, now: reset)]), store: store, settings: all, now: reset)
        try expect(after.alerts.map(\.kind).contains(.availableAgain), "A reset did not fire Available again")

        store = QuotaNotificationStore()
        let signedOut = input([paced(70)], signIn: .needsSignIn)
        let episode = QuotaNotificationEngine.evaluate(signedOut, store: store, settings: all, now: now)
        try expect(episode.alerts.map(\.kind) == [.signInAgain], "Sign in again did not fire")
        try expect(episode.alerts[0].subtitle == "Codex CLI · a@x.test"
                   && episode.alerts[0].body == "Codex CLI needs you to sign in again.", "Sign in text")
        store = episode.committed(delivered: Set(episode.alerts.map(\.id)))
        try expect(pass(&store, signedOut).isEmpty, "Sign in again repeated within one episode")
        try expect(pass(&store, input([paced(70)], signIn: .unknown)).isEmpty, "A failure cleared the episode")
        try expect(pass(&store, signedOut).isEmpty, "A non-sign-in result reopened the episode")
        pass(&store, input([paced(20)], signIn: .ok))
        try expect(pass(&store, signedOut) == [.signInAgain], "A success did not clear the episode")
        store = QuotaNotificationStore()
        try expect(pass(&store, signedOut, QuotaNotificationSettings()).isEmpty, "Sign in alerted while off")

        var kept = QuotaNotificationStore()
        pass(&kept, input([plain(10)]))
        pass(&kept, [])
        try expect(kept.windows.isEmpty, "State of a removed account was kept")
    }

    func testCodexWindows() throws {
        func window(_ used: Int, _ minutes: Int64) -> CodexRateLimitWindowSnapshot {
            CodexRateLimitWindowSnapshot(usedPercent: used, windowDurationMinutes: minutes, resetsAt: now)
        }
        func bucket(_ primary: CodexRateLimitWindowSnapshot?, _ secondary: CodexRateLimitWindowSnapshot?)
            -> CodexRateLimitBucketSnapshot {
            CodexRateLimitBucketSnapshot(id: nil, name: nil, plan: nil, model: nil, primary: primary, secondary: secondary,
                                         credits: nil, spendControlReached: nil)
        }
        let both = QuotaNotificationEngine.codexWindows(bucket(window(40, 300), window(60, 10_080)))
        try expect(both.map(\.id) == ["session", "weekly"] && both.map(\.usedPercent) == [40, 60]
                   && both[0].windowMinutes == 300, "Codex session and weekly windows")
        let swapped = QuotaNotificationEngine.codexWindows(bucket(window(60, 10_080), window(40, 300)))
        try expect(swapped.map(\.usedPercent) == [40, 60], "A weekly primary window was not swapped")
        let weeklyOnly = QuotaNotificationEngine.codexWindows(bucket(window(60, 10_080), nil))
        try expect(weeklyOnly.map(\.id) == ["weekly"], "A weekly-only bucket invented a session")
    }

    func testNotificationStoreFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "switch-side-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = QuotaNotificationStore.url(in: root.appending(path: "support"))
        var store = QuotaNotificationStore()
        pass(&store, input([plain(100)]))
        try store.save(to: url)
        #if !os(Windows)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        try expect(mode == 0o600, "The notification state file is not owner-private")
        #endif
        var loaded = QuotaNotificationStore.load(from: url)
        let key = QuotaNotificationEngine.windowKey(account, "balance")
        try expect(loaded.windows[key]?.wasSpent == true && loaded.windows[key]?.primed == false,
                   "The saved state lost its fields or kept the primed flag")
        try expect(pass(&loaded, input([plain(30)])) == [.availableAgain], "Available again was lost across a launch")
        try expect(QuotaNotificationStore.load(from: root.appending(path: "missing.json")) == QuotaNotificationStore(),
                   "A missing state file did not load empty")
    }

    func testStatusPoller() async throws {
        let codex = ProviderID.codex, claude = ProviderID.claudeCode
        let groq = ProviderID(rawValue: "groq")
        let log = CallLog()
        let minor = ProviderIncident(indicator: .minor, description: "Errors")
        let poller = ProviderStatusPoller(fetch: { id, page in
            await log.record(id, page)
            return id == .codex ? minor : nil
        })
        let ids = [codex, claude, groq]
        var entries = await poller.poll(ids, enabled: true, now: now).entries
        var count = await log.calls.count
        try expect(count == 3, "Each provider with an account was not checked once")
        try expect(entries.map(\.providerID) == ["codex"] && entries[0].indicator == "minor"
                   && entries[0].severity == "warning" && entries[0].text == "Errors",
                   "Only a provider with a result should have an entry")
        let claudePage = await log.urls[claude] ?? nil
        try expect(claudePage?.host == "status.claude.com", "The catalog status page was not passed to the fetcher")
        entries = await poller.poll(ids, enabled: true, now: now.addingTimeInterval(299)).entries
        count = await log.calls.count
        try expect(count == 3, "A provider was checked twice within five minutes")
        try expect(!entries.isEmpty, "Throttled polls lost the last value")
        _ = await poller.poll(ids, enabled: true, now: now.addingTimeInterval(300))
        count = await log.calls.count
        try expect(count == 6, "Providers were not checked again after five minutes")

        let healthy = Flag()
        let flaky = ProviderStatusPoller(fetch: { _, _ in await healthy.value ? minor : nil })
        _ = await flaky.poll([codex], enabled: true, now: now)
        await healthy.set(false)
        entries = await flaky.poll([codex], enabled: true, now: now.addingTimeInterval(301)).entries
        try expect(entries.first?.indicator == "minor", "A failed fetch replaced the last good value")
        entries = await flaky.poll([], enabled: true, now: now.addingTimeInterval(700)).entries
        try expect(entries.isEmpty, "A removed provider kept its entry")

        let before = await log.calls.count
        entries = await poller.poll(ids, enabled: false, now: now.addingTimeInterval(1_000)).entries
        count = await log.calls.count
        try expect(entries.isEmpty && count == before, "Check provider status off still made requests")
        entries = await poller.poll(ids, enabled: true, now: now.addingTimeInterval(1_001)).entries
        count = await log.calls.count
        try expect(count == before + 3 && !entries.isEmpty, "Turning status on did not check at once")

        let busy = ProviderStatusPoller(fetch: { _, _ in
            await log.enter()
            try? await Task.sleep(nanoseconds: 30_000_000)
            await log.leave()
            return ProviderIncident(indicator: .major)
        })
        let many = (1...9).map { ProviderID(rawValue: "provider-\($0)") }
        let value = await busy.poll(many, enabled: true, now: now)
        let peak = await log.peak
        try expect(value.entries.count == 9 && value.entries[0].severity == "critical"
                   && value.entries[0].text == "Service issue", "Not every provider was checked")
        try expect(peak == ProviderStatusPoller.maxConcurrent, "Status checks ran \(peak) at a time")
        try expect(ProviderStatusPoller.interval == 5 * 60, "Status interval is not five minutes")
    }

    func testActivitySummary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let noon = Date(timeIntervalSince1970: 1_791_633_600)  // 2026-10-10T12:00:00Z
        let summary = ActivitySummary.summarize([
            ClaudeDailyCost(date: "2026-10-10", inputTokens: 100, outputTokens: 50, cacheReadTokens: 1_000,
                            cacheWriteTokens: 10, costUSD: 1.5),
            ClaudeDailyCost(date: "2026-10-09", inputTokens: 5, outputTokens: 5, costUSD: nil, unpricedModels: ["claude-x"]),
            ClaudeDailyCost(date: "2026-09-20", inputTokens: 200, outputTokens: 0, costUSD: 2),
        ], now: noon, calendar: calendar)
        try expect(summary.rows.map(\.label) == ["Today", "Yesterday", "Last 30 days"], "Activity rows")
        try expect(summary.rows[0].tokens == 1_160 && summary.rows[0].costUSD == 1.5, "Today row")
        try expect(summary.rows[1].tokens == 10 && summary.rows[1].costUSD == nil, "Yesterday row")
        try expect(summary.rows[2].tokens == 1_370 && summary.rows[2].costUSD == 3.5, "Last 30 days row")
        try expect(summary.unpricedModels == ["claude-x"], "Unpriced models")
        let chart = try XCTUnwrap(summary.chart)
        try expect(chart.unit == "USD" && chart.points.count == 30 && chart.points.last?.label == "Oct 10"
                   && chart.points.first?.label == "Sep 11", "Activity chart days")
        try expect(chart.points.last?.value == 1.5 && chart.points.first { $0.label == "Oct 9" }?.value == 0
                   && chart.points.first { $0.label == "Sep 20" }?.value == 2 && chart.total == 3.5, "Activity chart values")
        try expect(ActivitySummary.summarize([], now: noon, calendar: calendar).rows.allSatisfy {
            $0.tokens == 0 && $0.costUSD == nil }, "An empty scan invented values")
        let fresh = noon.addingTimeInterval(-14 * 60 - 59)
        try expect(!ActivitySummary.isDue(computedAt: fresh, force: false, now: noon), "Scanned again within 15 minutes")
        try expect(ActivitySummary.isDue(computedAt: noon.addingTimeInterval(-15 * 60), force: false, now: noon)
                   && ActivitySummary.isDue(computedAt: nil, force: false, now: noon)
                   && ActivitySummary.isDue(computedAt: fresh, force: true, now: noon), "Scan due rules")
    }

    func testChatBlocks() throws {
        let source = #"""
        # Goal

        Keep **all** the content.

        ## Inputs

        Name | Value
        :--- | ---:
        Repository | `/Projects/Reader`
        Pipe | left\|right
        Code | ``left|right``
        Missing |

        ## Steps

        1. Read the file
        2. Run the check

        ```swift
        let x = 1
        ```
        > quoted
        - one
        - two
        ---
        """#
        let blocks = ChatBlock.parse(ChatMessage(id: "table", role: .user, text: source, timestamp: nil))
        try expect(blocks.map(\.kind) == ["heading", "paragraph", "heading", "table", "heading", "orderedList", "code",
                                          "quote", "unorderedList", "divider"], "Block kinds: \(blocks.map(\.kind))")
        let table = blocks[3]
        try expect(table.headers == ["Name", "Value"], "Markdown table headers or alignment rules were not parsed")
        // Inline Markdown stays for the client; escaped pipes and pipes inside inline code stay in their cell.
        try expect(table.rows == [["Repository", "`/Projects/Reader`"], ["Pipe", "left|right"],
                                  ["Code", "``left|right``"], ["Missing", ""]],
                   "Markdown table parsing lost escaped pipes, inline code, or a missing cell: \(table.rows ?? [])")
        try expect(blocks[1].text == "Keep **all** the content." && blocks[0].level == 1 && blocks[2].level == 2,
                   "Headings or inline text changed")
        try expect(blocks[5].items == ["Read the file", "Run the check"] && blocks[6].language == "swift"
                   && blocks[6].preview == "let x = 1" && blocks[6].expanded == nil, "List or code block")
        let plain = ChatBlock.parse(ChatMessage(id: "plain", role: .assistant, text: "Name | Value\nnot | a separator",
                                                timestamp: nil))
        try expect(!plain.contains { $0.kind == "table" }, "Pipe-separated prose became a table without a separator")
        let single = ChatBlock.parse(ChatMessage(id: "single", role: .assistant, text: "| Field |\n| --- |\n| Value |",
                                                 timestamp: nil))
        try expect(single.contains { $0.kind == "table" && $0.headers?.count == 1 && $0.rows?.count == 1 },
                   "A single-column Markdown table was not preserved")
        let tool = ChatBlock.parse(ChatMessage(id: "tool", role: .tool, text: "  a  |  b\n# not a heading", timestamp: nil))
        try expect(tool.count == 1 && tool[0].kind == "code" && tool[0].preview == "  a  |  b\n# not a heading",
                   "Tool output lost its spacing or became Markdown")
    }
}
