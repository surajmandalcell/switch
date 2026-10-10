import AIManagerCore
import Foundation

// Model checks for the Foundation-only feature logic: quota notifications, provider status
// polling, Claude activity, and email masking. Synthetic data and temporary folders only.

private struct FeatureCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw FeatureCheckFailure(message: message) }
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

enum FeatureLogicChecks {
    static func run() async throws {
        try emailPrivacy()
        try settingDefaults()
        try notificationEngine()
        try codexWindows()
        try notificationStore()
        try incidentDisplay()
        try await statusPoller()
        try await claudeActivity()
    }

    // MARK: Email privacy

    private static func emailPrivacy() throws {
        try expect(EmailPrivacy.mask("alice@example.com") == "a••••@example.com", "Email mask has the wrong shape")
        try expect(EmailPrivacy.mask("no-at-sign") == "no-at-sign" && EmailPrivacy.mask("@x.com") == "@x.com",
                   "A non-email was masked")
        try expect(EmailPrivacy.display("alice@example.com", hide: false) == "alice@example.com",
                   "Emails were masked while the setting is off")
        let sentence = "Signed in as bob.smith@corp.example.org and a@b.co now"
        let masked = EmailPrivacy.display(sentence, hide: true)
        try expect(masked == "Signed in as b••••@corp.example.org and a••••@b.co now", "Embedded emails: \(masked)")
        try expect(EmailPrivacy.display(masked, hide: true) == masked, "Masking is not idempotent")

        let suite = "switch-feature-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(!EmailPrivacy.isEnabled(defaults: defaults), "Hide email addresses is not off by default")
        let identity = AccountIdentity(email: "carol@example.com", userID: "u", accountID: "a", authMode: .chatGPT)
        UserDefaults.standard.set(true, forKey: EmailPrivacy.key)
        let hidden = identity.accountLabel
        UserDefaults.standard.removeObject(forKey: EmailPrivacy.key)
        try expect(hidden == "c••••@example.com" && identity.accountLabel == "carol@example.com",
                   "accountLabel does not follow the privacy setting")
    }

    private static func settingDefaults() throws {
        let suite = "switch-feature-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(QuotaNotificationSettings.load(defaults) == QuotaNotificationSettings()
                   && !QuotaNotificationSettings.load(defaults).anyEnabled,
                   "A notification toggle is on by default")
        try expect(ProviderStatusPoller.isEnabled(defaults: defaults), "Check provider status is not on by default")
        defaults.set(false, forKey: ProviderStatusPoller.enabledKey)
        try expect(!ProviderStatusPoller.isEnabled(defaults: defaults), "Check provider status cannot be turned off")
        defaults.set(true, forKey: QuotaNotificationSettings.paceKey)
        try expect(QuotaNotificationSettings.load(defaults).pace
                   && !QuotaNotificationSettings.load(defaults).almostOut, "Toggles do not load independently")
    }

    // MARK: Notification engine

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let account = UUID(uuidString: "0E0A1001-7F3A-4C27-9D84-5B1E2A6C0001")!
    private static let all = QuotaNotificationSettings(
        almostOut: true, pace: true, availableAgain: true, signInAgain: true)

    /// A 5-hour window halfway through: 20% used is blue, 47% yellow, 70% red.
    private static func paced(_ used: Double, resetsAt: Date? = nil, now at: Date = now) -> UsageWindow {
        UsageWindow(id: "session", title: "Session", usedPercent: used,
                    resetsAt: resetsAt ?? at.addingTimeInterval(150 * 60), windowMinutes: 300)
    }

    private static func plain(_ used: Double) -> UsageWindow {
        UsageWindow(id: "balance", title: "Credits", usedPercent: used)
    }

    private static func input(
        _ windows: [UsageWindow], signIn: QuotaSignInStatus = .ok, label: String = "a@x.test"
    ) -> [QuotaAccountInput] {
        [QuotaAccountInput(id: account, providerKey: "codex", providerName: "Codex CLI",
                           accountLabel: label, windows: windows, signIn: signIn)]
    }

    /// Runs one pass and commits every alert as delivered.
    @discardableResult
    private static func pass(
        _ store: inout QuotaNotificationStore, _ inputs: [QuotaAccountInput],
        _ settings: QuotaNotificationSettings = all, at time: Date = now, deliver: Bool = true
    ) -> [QuotaAlertKind] {
        let result = QuotaNotificationEngine.evaluate(inputs, store: store, settings: settings, now: time)
        store = deliver ? result.committed(delivered: Set(result.alerts.map(\.id))) : result.store
        return result.alerts.map(\.kind)
    }

    private static func notificationEngine() throws {
        // The state seen at launch raises no alert, however bad it is.
        var store = QuotaNotificationStore()
        try expect(pass(&store, input([paced(70)])).isEmpty, "A window primed in the red raised an alert")
        try expect(pass(&store, input([paced(70)])).isEmpty, "An unchanged window raised an alert")

        // Almost Out fires on the edge below 10% left, once, and re-arms after leaving.
        store = QuotaNotificationStore()
        try expect(pass(&store, input([plain(50)])).isEmpty, "Priming raised Almost Out")
        try expect(pass(&store, input([plain(89)])).isEmpty, "Almost Out fired at 11% left")
        let first = QuotaNotificationEngine.evaluate(input([plain(91)]), store: store, settings: all, now: now)
        try expect(first.alerts.map(\.kind) == [.almostOut], "Almost Out did not fire at 9% left")
        let alert = first.alerts[0]
        try expect(alert.title == "Almost Out" && alert.body == "Under 10% usage remaining for this window."
                   && alert.subtitle == "Codex CLI · a@x.test · Credits", "Almost Out text is wrong: \(alert)")
        // A failed delivery keeps the edge for the next pass.
        store = first.committed(delivered: [])
        try expect(pass(&store, input([plain(92)])) == [.almostOut], "A failed delivery consumed the edge")
        try expect(pass(&store, input([plain(93)])).isEmpty, "Almost Out repeated after delivery")
        try expect(pass(&store, input([plain(50)])).isEmpty, "Almost Out fired when leaving")
        try expect(pass(&store, input([plain(95)])) == [.almostOut], "Almost Out did not re-arm")
        // A crossing that a disabled toggle missed is not consumed.
        store = QuotaNotificationStore()
        var off = all
        off.almostOut = false
        pass(&store, input([plain(50)]), off)
        try expect(pass(&store, input([plain(95)]), off).isEmpty, "A disabled toggle alerted")
        try expect(pass(&store, input([plain(95)])) == [.almostOut], "A missed crossing was consumed")

        // Pace: blue to yellow fires Cutting It Close, yellow to red fires Will Run Out.
        store = QuotaNotificationStore()
        pass(&store, input([paced(20)]))
        try expect(pass(&store, input([paced(47)])) == [.cuttingItClose], "Blue to yellow")
        let close = QuotaNotificationEngine.evaluate(input([paced(47)]), store: store, settings: all, now: now)
        try expect(close.alerts.isEmpty, "Cutting It Close repeated")
        let run = QuotaNotificationEngine.evaluate(input([paced(70)]), store: store, settings: all, now: now)
        try expect(run.alerts.map(\.kind) == [.willRunOut], "Yellow to red")
        try expect(run.alerts[0].title == "Will Run Out"
                   && run.alerts[0].body == "Projected to finish before the limit resets.", "Will Run Out text")
        // Blue to red fires Will Run Out only.
        store = QuotaNotificationStore()
        pass(&store, input([paced(20)]))
        try expect(pass(&store, input([paced(70)])) == [.willRunOut], "A blue to red jump fired both alerts")
        // Improving clears the fired mark.
        pass(&store, input([paced(20)]))
        try expect(pass(&store, input([paced(70)])) == [.willRunOut], "Will Run Out did not re-arm after improving")
        // A worsening that Pace alerts missed (toggle off) is not consumed.
        store = QuotaNotificationStore()
        var noPace = all
        noPace.pace = false
        pass(&store, input([paced(20)]), noPace)
        pass(&store, input([paced(47)]), noPace)
        try expect(store.windows[QuotaNotificationEngine.windowKey(account, "session")]?.bucket == .healthy,
                   "A worsening was consumed by a disabled toggle")
        try expect(pass(&store, input([paced(47)])) == [.cuttingItClose], "Enabling Pace alerts did not catch up")

        // A later reset clears the fired marks.
        store = QuotaNotificationStore()
        pass(&store, input([paced(20)]))
        pass(&store, input([paced(47)]))
        let later = now.addingTimeInterval(5 * 3_600)
        try expect(pass(&store, input([paced(20, now: later)]), all, at: later).isEmpty, "Reset raised an alert")
        try expect(pass(&store, input([paced(47, now: later)]), all, at: later) == [.cuttingItClose],
                   "A reset did not clear Cutting It Close")

        // Available again: a spent window resets or drops below 100%.
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
        // A reset while the window is still full also counts.
        store = QuotaNotificationStore()
        pass(&store, input([paced(100)]))
        let reset = now.addingTimeInterval(6 * 3_600)
        let after = QuotaNotificationEngine.evaluate(
            input([paced(100, now: reset)]), store: store, settings: all, now: reset)
        try expect(after.alerts.map(\.kind).contains(.availableAgain), "A reset did not fire Available again")

        // Sign in again: once per failure episode, cleared by the next success.
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

        // Deleted accounts leave no state.
        var kept = QuotaNotificationStore()
        pass(&kept, input([plain(10)]))
        pass(&kept, [])
        try expect(kept.windows.isEmpty, "State of a removed account was kept")
    }

    private static func codexWindows() throws {
        func window(_ used: Int, _ minutes: Int64) -> CodexRateLimitWindowSnapshot {
            CodexRateLimitWindowSnapshot(usedPercent: used, windowDurationMinutes: minutes, resetsAt: now)
        }
        func bucket(_ primary: CodexRateLimitWindowSnapshot?, _ secondary: CodexRateLimitWindowSnapshot?)
            -> CodexRateLimitBucketSnapshot {
            CodexRateLimitBucketSnapshot(
                id: nil, name: nil, plan: nil, model: nil, primary: primary, secondary: secondary,
                credits: nil, spendControlReached: nil)
        }
        let both = QuotaWindows.codex(bucket(window(40, 300), window(60, 10_080)))
        try expect(both.map(\.id) == ["session", "weekly"] && both.map(\.usedPercent) == [40, 60]
                   && both[0].windowMinutes == 300, "Codex session and weekly windows")
        let swapped = QuotaWindows.codex(bucket(window(60, 10_080), window(40, 300)))
        try expect(swapped.map(\.usedPercent) == [40, 60], "A weekly primary window was not swapped")
        let weeklyOnly = QuotaWindows.codex(bucket(window(60, 10_080), nil))
        try expect(weeklyOnly.map(\.id) == ["weekly"], "A weekly-only bucket invented a session")
    }

    private static func notificationStore() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "switch-feature-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = QuotaNotificationStore.url(in: root.appending(path: "support"))
        var store = QuotaNotificationStore()
        pass(&store, input([plain(100)]))
        try store.save(to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        try expect(mode == 0o600, "The notification state file is not owner-private")
        var loaded = QuotaNotificationStore.load(from: url)
        let key = QuotaNotificationEngine.windowKey(account, "balance")
        try expect(loaded.windows[key]?.wasSpent == true && loaded.windows[key]?.primed == false,
                   "The saved state lost its fields or kept the primed flag")
        // A reset while the app was closed still raises Available again after the next launch.
        try expect(pass(&loaded, input([plain(30)])) == [.availableAgain], "Available again was lost across a launch")
        try expect(QuotaNotificationStore.load(from: root.appending(path: "missing.json")) == QuotaNotificationStore(),
                   "A missing state file did not load empty")
    }

    // MARK: Provider status

    private static func incidentDisplay() throws {
        func incident(_ indicator: ProviderIncident.Indicator) -> ProviderIncident {
            ProviderIncident(indicator: indicator, description: "Elevated errors", updatedAt: now.addingTimeInterval(-600))
        }
        try expect(incident(.minor).severity == .warning && incident(.maintenance).severity == .warning,
                   "Minor and maintenance are not yellow")
        try expect(incident(.major).severity == .critical && incident(.critical).severity == .critical,
                   "Major and critical are not red")
        try expect(incident(.none).severity == nil && incident(.unknown).severity == nil,
                   "No incident or an unknown status shows a dot")
        let text = incident(.minor).summary(checkedAt: now, now: now)
        try expect(text.hasPrefix("Elevated errors · updated "), "Status summary is wrong: \(text)")
        let noDescription = ProviderIncident(indicator: .major).summary(checkedAt: now, now: now)
        try expect(noDescription.hasPrefix("Service issue · updated "), "Missing description: \(noDescription)")
    }

    private static func statusPoller() async throws {
        let codex = ProviderID.codex, claude = ProviderID.claudeCode
        let groq = ProviderID(rawValue: "groq")
        let log = CallLog()
        let minor = ProviderIncident(indicator: .minor, description: "Errors")
        let poller = ProviderStatusPoller(fetch: { id, page in
            await log.record(id, page)
            return id == .codex ? minor : nil
        })
        let ids = [codex, claude, groq]
        var entries = await poller.poll(ids, enabled: true, now: now)
        var count = await log.calls.count
        try expect(count == 3, "Each provider with an account was not checked once")
        try expect(entries.keys.map(\.rawValue) == ["codex"] && entries[codex]?.incident == minor,
                   "Only a provider with a result should have an entry")
        let claudePage = await log.urls[claude] ?? nil
        try expect(claudePage?.host == "status.claude.com", "The catalog status page was not passed to the fetcher")
        entries = await poller.poll(ids, enabled: true, now: now.addingTimeInterval(299))
        count = await log.calls.count
        try expect(count == 3, "A provider was checked twice within five minutes")
        try expect(entries[codex] != nil, "Throttled polls lost the last value")
        entries = await poller.poll(ids, enabled: true, now: now.addingTimeInterval(300))
        count = await log.calls.count
        try expect(count == 6, "Providers were not checked again after five minutes")

        // A failed fetch keeps the last good value.
        let healthy = Flag()
        let flaky = ProviderStatusPoller(fetch: { _, _ in await healthy.value ? minor : nil })
        _ = await flaky.poll([codex], enabled: true, now: now)
        await healthy.set(false)
        entries = await flaky.poll([codex], enabled: true, now: now.addingTimeInterval(301))
        try expect(entries[codex]?.incident == minor, "A failed fetch replaced the last good value")
        // Removing the last account drops its entry.
        entries = await flaky.poll([], enabled: true, now: now.addingTimeInterval(700))
        try expect(entries.isEmpty, "A removed provider kept its entry")

        // Off: no request, no entries; back on: checked at once.
        let before = await log.calls.count
        entries = await poller.poll(ids, enabled: false, now: now.addingTimeInterval(1_000))
        count = await log.calls.count
        try expect(entries.isEmpty && count == before, "Check provider status off still made requests")
        entries = await poller.poll(ids, enabled: true, now: now.addingTimeInterval(1_001))
        count = await log.calls.count
        try expect(count == before + 3 && entries[codex] != nil, "Turning status on did not check at once")

        // At most four fetches at a time.
        let busy = ProviderStatusPoller(fetch: { _, _ in
            await log.enter()
            try? await Task.sleep(for: .milliseconds(30))
            await log.leave()
            return minor
        })
        let many = (1...9).map { ProviderID(rawValue: "provider-\($0)") }
        let all = await busy.poll(many, enabled: true, now: now)
        let peak = await log.peak
        try expect(all.count == 9, "Not every provider was checked")
        try expect(peak == ProviderStatusPoller.maxConcurrent, "Status checks ran \(peak) at a time")
        try expect(ProviderStatusPoller.interval == 5 * 60, "Status interval is not five minutes")
    }

    // MARK: Claude activity

    private static func claudeActivity() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let noon = Date(timeIntervalSince1970: 1_791_633_600)  // 2026-10-10T12:00:00Z
        let summary = ClaudeActivity.summarize(
            [
                ClaudeDailyCost(date: "2026-10-10", inputTokens: 100, outputTokens: 50, cacheReadTokens: 1_000,
                                cacheWriteTokens: 10, costUSD: 1.5),
                ClaudeDailyCost(date: "2026-10-09", inputTokens: 5, outputTokens: 5, costUSD: nil,
                                unpricedModels: ["claude-x"]),
                ClaudeDailyCost(date: "2026-09-20", inputTokens: 200, outputTokens: 0, costUSD: 2),
            ], now: noon, calendar: calendar)
        try expect(summary.rows.map(\.label) == ["Today", "Yesterday", "Last 30 days"], "Activity rows")
        try expect(summary.rows[0].tokens == 1_160 && summary.rows[0].costUSD == 1.5, "Today row")
        try expect(summary.rows[1].tokens == 10 && summary.rows[1].costUSD == nil, "Yesterday row")
        try expect(summary.rows[2].tokens == 1_370 && summary.rows[2].costUSD == 3.5, "Last 30 days row")
        try expect(summary.unpricedModels == ["claude-x"], "Unpriced models")
        // The 30-day chart is zero-filled, oldest first, priced days only count.
        guard let chart = summary.chart else { throw FeatureCheckFailure(message: "Activity chart is missing") }
        try expect(chart.unit == "USD" && chart.points.count == 30 && chart.points.last?.label == "Oct 10"
                   && chart.points.first?.label == "Sep 11", "Activity chart days")
        try expect(chart.points.last?.value == 1.5 && chart.points.first { $0.label == "Oct 9" }?.value == 0
                   && chart.points.first { $0.label == "Sep 20" }?.value == 2 && chart.total == 3.5, "Activity chart values")
        try expect(ClaudeActivity.summarize([], now: noon, calendar: calendar).rows.allSatisfy {
            $0.tokens == 0 && $0.costUSD == nil }, "An empty scan invented values")

        let fresh = noon.addingTimeInterval(-14 * 60 - 59)
        try expect(!ClaudeActivity.isDue(computedAt: fresh, force: false, now: noon), "Scanned again within 15 minutes")
        try expect(ClaudeActivity.isDue(computedAt: noon.addingTimeInterval(-15 * 60), force: false, now: noon)
                   && ClaudeActivity.isDue(computedAt: nil, force: false, now: noon)
                   && ClaudeActivity.isDue(computedAt: fresh, force: true, now: noon), "Scan due rules")

        // End to end over a synthetic log and a stubbed price catalog.
        let root = FileManager.default.temporaryDirectory.appending(
            path: "switch-feature-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appending(path: "projects/-proj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        func line(_ id: String, _ model: String) -> String {
            #"{"timestamp":"\#(stamp)","requestId":"r-\#(id)","message":{"id":"m-\#(id)","model":"\#(model)","usage":{"input_tokens":1000,"output_tokens":500}}}"#
        }
        try Data([line("1", "claude-sonnet-4-5"), line("2", "claude-mystery-9")].joined(separator: "\n").utf8)
            .write(to: projects.appending(path: "session.jsonl"))
        let catalog = Data(#"{"claude-sonnet-4-5":{"input_cost_per_token":0.000003,"output_cost_per_token":0.000015}}"#.utf8)
        let pricing = ClaudePricingSource(cacheURL: root.appending(path: "prices.json"), fetch: { _ in catalog })
        let scanned = try await ClaudeActivity.compute(
            roots: [root.appending(path: "projects")], cacheURL: root.appending(path: "claude-cost-cache.json"),
            pricing: pricing)
        try expect(scanned.rows[0].tokens == 3_000, "Scanned tokens: \(scanned.rows[0].tokens)")
        try expect(abs((scanned.rows[0].costUSD ?? 0) - 0.0105) < 1e-9, "Scanned cost: \(String(describing: scanned.rows[0].costUSD))")
        try expect(scanned.unpricedModels == ["claude-mystery-9"], "The unpriced model was not named")
    }
}
