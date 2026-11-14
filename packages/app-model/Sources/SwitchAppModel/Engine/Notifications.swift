import Foundation
import AIManagerCore

// shortcut: written from QuotaNotificationLogic.swift and the QuotaNotifier input builder (QuotaNotifier.swift
// 106-190) beside the Mac copies; delete those when the Mac app adopts SwitchAppModel (needs the window gates).

/// What the engine needs from the app around it (architecture.md 3.1). The helper sends `notify.post`; the Mac
/// app would post a user notification. Terminal launch and folder watching still call the platform code directly.
public protocol AppHost: AnyObject, Sendable {
    /// Shows one notification. True when it was shown, so the alert is not raised again.
    func postNotification(_ post: NotificationPost) async -> Bool
}

/// `notify.post`: the same `id` replaces an earlier notification; `group` threads them (`switch.quota`).
public struct NotificationPost: Codable, Equatable, Sendable {
    public var id: String
    public var group: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var sound: Bool
}

enum QuotaAlertKind: String, Codable, Sendable {
    case almostOut, cuttingItClose, willRunOut, availableAgain, signInAgain

    var title: String {
        switch self {
        case .almostOut: "Almost Out"
        case .cuttingItClose: "Cutting It Close"
        case .willRunOut: "Will Run Out"
        case .availableAgain: "Available again"
        case .signInAgain: "Sign in again"
        }
    }

    func body(provider: String) -> String {
        switch self {
        case .almostOut: "Under 10% usage remaining for this window."
        case .cuttingItClose: "Projected to finish close to your limit."
        case .willRunOut: "Projected to finish before the limit resets."
        case .availableAgain: "This window has reset. You can use this account again."
        case .signInAgain: "\(provider) needs you to sign in again."
        }
    }
}

/// The four Settings toggles, all off by default.
struct QuotaNotificationSettings: Equatable, Sendable {
    var almostOut = false
    var pace = false
    var availableAgain = false
    var signInAgain = false

    var anyEnabled: Bool { almostOut || pace || availableAgain || signInAgain }

    init(almostOut: Bool = false, pace: Bool = false, availableAgain: Bool = false, signInAgain: Bool = false) {
        (self.almostOut, self.pace, self.availableAgain, self.signInAgain) = (almostOut, pace, availableAgain, signInAgain)
    }

    init(_ store: any SettingsStore) {
        func on(_ key: String) -> Bool { store.effective(key) == .bool(true) }
        self.init(almostOut: on("notifyAlmostOut"), pace: on("notifyPaceAlerts"),
                  availableAgain: on("notifyAvailableAgain"), signInAgain: on("notifySignInAgain"))
    }
}

/// Pace verdict of a window, reduced to the four steps the alerts care about.
enum QuotaBucket: String, Codable, Sendable {
    case untracked, healthy, close, runningOut

    var severity: Int {
        switch self {
        case .untracked: -1
        case .healthy: 0
        case .close: 1
        case .runningOut: 2
        }
    }

    init(_ state: UsagePace.MeterState) {
        switch state {
        case .noData, .level: self = .untracked
        case .healthy: self = .healthy
        case .closeToLimit: self = .close
        case .runningOut, .spent: self = .runningOut
        }
    }
}

struct QuotaWindowState: Codable, Equatable, Sendable {
    var resetsAt: Date?
    var firedClose = false
    var firedRunOut = false
    var bucket: QuotaBucket = .untracked
    var wasUnderTen = false
    /// The window was at or above 100% used when last seen.
    var wasSpent = false
    /// False at every start: the state seen at start raises no pace or Almost Out alert.
    var primed = false

    private enum CodingKeys: String, CodingKey {
        case resetsAt, firedClose, firedRunOut, bucket, wasUnderTen, wasSpent
    }
}

/// The same file and format as the Mac (`quota-notification-state.json`), owner-only.
struct QuotaNotificationStore: Codable, Equatable, Sendable {
    /// Keyed `<account uuid>/<window id>`.
    var windows: [String: QuotaWindowState] = [:]
    /// Accounts with an open "Sign in again" failure episode.
    var signInAlerted: Set<String> = []

    static func url(in applicationSupport: URL) -> URL {
        applicationSupport.appending(path: "quota-notification-state.json")
    }

    static func load(from url: URL) -> QuotaNotificationStore {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum QuotaSignInStatus: Sendable {
    /// A usage check just succeeded.
    case ok
    /// The latest usage check returned needs-sign-in.
    case needsSignIn
    /// Not checked, or failed for a reason other than sign-in.
    case unknown
}

struct QuotaAccountInput: Sendable {
    var id: UUID
    var providerKey: String
    var providerName: String
    /// Already masked when "Hide email addresses" is on.
    var accountLabel: String
    var windows: [UsageWindow]
    var signIn: QuotaSignInStatus
}

struct QuotaAlert: Equatable, Sendable {
    var id: String
    var kind: QuotaAlertKind
    var title: String
    var subtitle: String
    var body: String
}

struct QuotaPass {
    var alerts: [QuotaAlert]
    /// The state to keep when no alert was delivered.
    var store: QuotaNotificationStore
    fileprivate var commits: [String: (inout QuotaNotificationStore) -> Void]

    /// The state to keep once the alerts with these ids were delivered.
    func committed(delivered: Set<String>) -> QuotaNotificationStore {
        var result = store
        for id in delivered { commits[id]?(&result) }
        return result
    }
}

/// A pass returns the alerts to deliver and the state to keep; a fired mark is committed only for alerts whose
/// delivery succeeded, so a denied permission keeps the edge for the next pass.
enum QuotaNotificationEngine {
    /// Jitter tolerance when comparing reset times.
    static let resetJitter: TimeInterval = 1

    static func windowKey(_ accountID: UUID, _ windowID: String) -> String {
        "\(accountID.uuidString)/\(windowID)"
    }

    static func evaluate(_ accounts: [QuotaAccountInput], store: QuotaNotificationStore,
                         settings: QuotaNotificationSettings, now: Date) -> QuotaPass {
        var next = store
        let known = Set(accounts.map { $0.id.uuidString })
        next.windows = next.windows.filter { known.contains(String($0.key.prefix(36))) }
        next.signInAlerted.formIntersection(known)
        var alerts: [QuotaAlert] = []
        var commits: [String: (inout QuotaNotificationStore) -> Void] = [:]

        for account in accounts {
            let accountKey = account.id.uuidString
            func identifier(_ window: String, _ kind: QuotaAlertKind) -> String {
                "\(account.providerKey).\(accountKey).\(window).\(kind.rawValue)"
            }
            switch account.signIn {
            case .ok:
                next.signInAlerted.remove(accountKey)
            case .needsSignIn:
                if settings.signInAgain, !next.signInAlerted.contains(accountKey) {
                    let alert = QuotaAlert(id: identifier("account", .signInAgain), kind: .signInAgain,
                                           title: QuotaAlertKind.signInAgain.title,
                                           subtitle: "\(account.providerName) · \(account.accountLabel)",
                                           body: QuotaAlertKind.signInAgain.body(provider: account.providerName))
                    alerts.append(alert)
                    commits[alert.id] = { $0.signInAlerted.insert(accountKey) }
                }
            case .unknown:
                break
            }
            // Numbers beside a sign-in request are stale.
            guard account.signIn != .needsSignIn else { continue }

            for window in account.windows {
                let key = windowKey(account.id, window.id)
                let step = step(next.windows[key] ?? QuotaWindowState(), window, settings: settings, now: now)
                next.windows[key] = step.state
                for (kind, commit) in step.pending {
                    let alert = QuotaAlert(id: identifier(window.id, kind), kind: kind, title: kind.title,
                                           subtitle: "\(account.providerName) · \(account.accountLabel) · \(window.title)",
                                           body: kind.body(provider: account.providerName))
                    alerts.append(alert)
                    commits[alert.id] = { store in
                        if var state = store.windows[key] {
                            commit(&state)
                            store.windows[key] = state
                        }
                    }
                }
            }
        }
        return QuotaPass(alerts: alerts, store: next, commits: commits)
    }

    typealias Commit = (inout QuotaWindowState) -> Void

    /// One window, one pass. `pending` alerts carry the mutation to apply after delivery.
    static func step(_ old: QuotaWindowState, _ window: UsageWindow, settings: QuotaNotificationSettings, now: Date)
        -> (state: QuotaWindowState, pending: [(QuotaAlertKind, Commit)]) {
        guard let used = window.usedPercent else { return (old, []) }  // no data: no change, no alert
        var s = old
        var pending: [(QuotaAlertKind, Commit)] = []
        let underTen = 1 - used / 100 < 0.10
        let spent = used >= 100
        let bucket = QuotaBucket(UsagePace.meterState(window, now: now))

        var resetAdvanced = false
        if let reset = window.resetsAt {
            // A new window starts only once the old reset has passed; a reset that moves forward earlier (a rolling
            // window) is the same window, so it keeps its fired marks.
            if let known = s.resetsAt, known <= now, reset.timeIntervalSince(known) > resetJitter {
                resetAdvanced = true
                s.firedClose = false
                s.firedRunOut = false
                s.wasUnderTen = false
                s.bucket = .untracked
            }
            s.resetsAt = reset
        }

        // Available again: a spent window reset or dropped below 100%. It also counts across starts.
        if s.wasSpent, resetAdvanced || !spent {
            if settings.availableAgain {
                pending.append((.availableAgain, { $0.wasSpent = spent }))
            } else {
                s.wasSpent = spent  // a stale event is not kept for a later opt-in
            }
        } else if spent {
            s.wasSpent = true
        }

        if !s.primed {
            s.primed = true
            s.bucket = bucket
            s.wasUnderTen = underTen
            if bucket.severity < 2 { s.firedRunOut = false }
            if bucket.severity < 1 { s.firedClose = false }
            return (s, pending)
        }

        let previous = s.bucket.severity, current = bucket.severity
        var pace: QuotaAlertKind?
        if settings.pace, bucket != .untracked {
            if bucket == .close, previous < 1, !s.firedClose {
                pace = .cuttingItClose
            } else if current >= 2, previous < 2, !s.firedRunOut {
                pace = .willRunOut  // a blue to red jump fires this one only
            }
        }
        if current < previous {
            if current < 2 { s.firedRunOut = false }
            if current < 1 { s.firedClose = false }
        }
        if let pace {
            pending.append((pace, { state in
                if pace == .cuttingItClose { state.firedClose = true } else { state.firedRunOut = true }
                state.bucket = bucket
            }))
        } else if current <= previous || settings.pace {
            // A worsening that no enabled toggle caught is not consumed.
            s.bucket = bucket
        }

        if !underTen {
            s.wasUnderTen = false  // leaving under 10% re-arms Almost Out
        } else if !s.wasUnderTen, settings.almostOut {
            pending.append((.almostOut, { $0.wasUnderTen = true }))
        }
        return (s, pending)
    }

    /// Codex's session and weekly windows from its default rate-limit bucket.
    static func codexWindows(_ bucket: CodexRateLimitBucketSnapshot) -> [UsageWindow] {
        let primaryIsWeekly = bucket.primary?.windowDurationMinutes == 10_080
        func make(_ id: String, _ title: String, _ window: CodexRateLimitWindowSnapshot?) -> UsageWindow? {
            guard let window, let used = window.usedPercent else { return nil }
            return UsageWindow(id: id, title: title, usedPercent: Double(used), resetsAt: window.resetsAt,
                               windowMinutes: window.windowDurationMinutes.map(Int.init))
        }
        return [make("session", "Session", primaryIsWeekly ? bucket.secondary : bucket.primary),
                make("weekly", "Weekly", primaryIsWeekly ? bucket.primary : bucket.secondary)].compactMap { $0 }
    }
}

extension AppEngine {
    public func setHost(_ host: (any AppHost)?) { self.host = host }

    /// Every account's windows and sign-in state, as the Mac `QuotaNotifier.inputs`.
    func quotaInputs() -> [QuotaAccountInput] {
        (status?.accounts ?? []).map { account in
            let providerID = account.identity.providerID
            let needsSignIn = account.verification.state == .needsSignIn
            var windows: [UsageWindow] = []
            var signIn = QuotaSignInStatus.unknown
            if providerID == .codex {
                let cached = codexUsage[account.id]
                if needsSignIn || cached?.failure == .authenticationRequired {
                    signIn = .needsSignIn
                } else {
                    windows = cached?.snapshot?.rateLimits?.defaultBucket.map(QuotaNotificationEngine.codexWindows) ?? []
                    if cached?.snapshot != nil, cached?.failure == nil { signIn = .ok }
                }
            } else {
                let state = providerUsage[account.id]
                if needsSignIn || state?.needsSignIn == true {
                    signIn = .needsSignIn
                } else {
                    windows = state?.usage?.windows ?? []
                    if state?.usage != nil, state?.error == nil { signIn = .ok }
                }
            }
            return QuotaAccountInput(id: account.id, providerKey: providerID.rawValue,
                                     providerName: AccountPresentation.providerName(providerID),
                                     accountLabel: label(account.identity), windows: windows, signIn: signIn)
        }
    }

    /// Runs one quota pass 300 ms after the account data settles (the Mac debounce). Only with a host and outside a
    /// test home unless the test turned refreshes on.
    func scheduleQuotaPass() {
        guard host != nil, refreshes, !quotaPassScheduled else { return }
        quotaPassScheduled = true
        let clock = clock
        timers.removeAll { $0.isCancelled }
        timers.append(Task { [weak self] in
            guard (try? await clock.sleep(seconds: 0.3)) != nil else { return }
            await self?.runQuotaPass()
        })
    }

    func runQuotaPass() async {
        quotaPassScheduled = false
        guard let host else { return }
        let url = QuotaNotificationStore.url(in: paths.applicationSupport)
        let store = quotaStore ?? (paths.isolationRoot == nil ? .load(from: url) : QuotaNotificationStore())
        let pass = QuotaNotificationEngine.evaluate(quotaInputs(), store: store, settings: QuotaNotificationSettings(settings),
                                                    now: clock.now)
        var delivered = Set<String>()
        for alert in pass.alerts {
            let post = NotificationPost(id: alert.id, group: "switch.quota", title: alert.title, subtitle: alert.subtitle,
                                        body: alert.body, sound: true)
            if await host.postNotification(post) { delivered.insert(alert.id) }
        }
        let next = pass.committed(delivered: delivered)
        guard next != quotaStore else { return }
        quotaStore = next
        if paths.isolationRoot == nil { try? next.save(to: url) }
    }
}
