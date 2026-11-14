import Foundation
import AIManagerCore

/// One line of a popover row. Raw values for layout and drawing, plus the formatted text.
public struct TrayLineValue: Codable, Equatable, Sendable {
    /// Label column text ("Session", "Balance"), or the pool name on a heading line.
    public var label: String?
    public var pool: String?
    public var isHeading: Bool
    /// Raw used percent (may pass 100); nil on a value-only or heading line.
    public var used: Int?
    /// "NN%" in the chosen Left or Used view, or "—" when the window has no value.
    public var percentText: String?
    /// Bar fill 0...1 in the chosen view.
    public var fill: Double?
    /// Used is 90% or more: the bar draws red.
    public var isHigh: Bool
    public var resetsAt: Date?
    /// Countdown or exact time when the value was built; empty without a reset time. Countdowns go stale: call
    /// `tray.rows` every 60 s while the popover shows.
    public var resetText: String
    /// Amount text of a value-only line (credits, balance).
    public var balance: String?
    /// Tooltip of the label: the full window title when it differs.
    public var help: String?
}

/// One account row of the popover (`tray` topic).
public struct TrayRowValue: Codable, Equatable, Sendable {
    public var id: String
    public var providerID: String
    /// Privacy-formatted, as every other shown label.
    public var label: String
    public var isDefault: Bool
    public var isVerified: Bool
    /// "Sign in again to see usage" or "Allow access to see usage"; nil for a usage row.
    public var prompt: String?
    /// "Sign in" or "Allow access" with `prompt`.
    public var promptButton: String?
    /// The account eye: not in `menuBarHiddenAccounts`.
    public var showsInTray: Bool
    public var showsSwitch: Bool
    /// "Open Codex" or "Open <service>" for the four agent CLIs.
    public var openToolTitle: String?
    public var canExpand: Bool
    /// The collapsed row's lines, and every line once expanded.
    public var lines: [TrayLineValue]
    public var expandedLines: [TrayLineValue]
    /// "24.1M since reset · ≈$96 API" under the label "Tokens"; nil when the row has no token line.
    public var tokens: String?
    public var accessibilityLabel: String
}

public struct TrayGroupValue: Codable, Equatable, Sendable {
    public var providerID: String
    public var name: String
    /// The service eye: not in `menuBarHiddenServices`.
    public var showsInTray: Bool
    public var rows: [TrayRowValue]
}

/// One account of the status item, in order. Consecutive items of one service form one icon group.
public struct TrayStatusItem: Codable, Equatable, Sendable {
    public var accountID: String
    public var providerID: String
    /// "NN%" in the chosen view, or "–" (en dash) when unknown.
    public var percentText: String
}

/// `tray` topic: the popover groups and the status item, ready to lay out. Text widths stay a client job.
public struct TrayValue: Codable, Equatable, Sendable {
    public var groups: [TrayGroupValue] = []
    public var status: [TrayStatusItem] = []
    /// One line per tray account, then the omitted ones; empty means "show the app name".
    public var tooltip = ""
    public var lastRefreshedAt: Date?
}

extension AppEngine {
    /// The popover and status item now (Mac `menuBarSnapshot`). Nothing until the accounts load.
    public func trayValue(now: Date? = nil) -> TrayValue {
        guard let status else { return TrayValue() }
        let now = now ?? clock.now
        let privacy = PrivacySettings(settings)
        func bool(_ key: String) -> Bool { settings.effective(key) == .bool(true) }
        func strings(_ key: String) -> [String] {
            guard case .array(let items) = settings.effective(key) else { return [] }
            return items.compactMap { if case .string(let text) = $0 { text } else { nil } }
        }
        let showsUsed = bool("showUsageAsUsed"), exact = bool("resetTimesExact")
        let hourFormat: String = if case .string(let text) = settings.effective("timeFormat") { text } else { "auto" }
        let period: String = if case .string(let text) = settings.effective("menuBarTokenPeriod") { text } else { "sinceReset" }
        let order = strings("menuBarServiceOrder").map(ProviderID.init(rawValue:))
        let hiddenServices = Set(strings("menuBarHiddenServices").map(ProviderID.init(rawValue:)))
        let hiddenAccounts = Set(strings("menuBarHiddenAccounts").compactMap(UUID.init(uuidString:)))
        let onePerService = bool("menuBarOneAccountPerService")

        let accounts = status.accounts.map { account -> TrayAccount in
            let providerID = account.identity.providerID
            let isCodex = providerID == .codex
            let state = providerUsage[account.id]
            // Claude profiles join once their usage arrives; other providers always have a spec.
            let supportsUsage = isCodex || providerID == .droid || ProviderCatalog.spec(providerID) != nil || state?.usage != nil
            let showsUsage = supportsUsage && showsUsageInTray(account.id)
            let signedOut = account.verification.state == .needsSignIn
            var usage: TrayUsage?
            if showsUsage, isCodex, !signedOut, let snapshot = codexUsage[account.id]?.snapshot,
               let limits = snapshot.rateLimits,
               let bucket = limits.defaultBucket ?? limits.buckets.sorted(by: { $0.key < $1.key }).first?.value {
                let rows = codexDaily[account.id] ?? snapshot.dailyUsage
                usage = TrayUsage(bucket: bucket, additionalBuckets: limits.buckets, extras: snapshot.extras,
                                  fetchedAt: snapshot.fetchedAt,
                                  tokenPeriodLabel: rows.isEmpty ? nil : TrayPresentation.tokenPeriodLabel(period),
                                  tokens: rows.isEmpty ? nil : TrayPresentation.tokens(period, rows: rows, usage: snapshot, now: now),
                                  apiPrice: apiPrice)
            } else if showsUsage, !isCodex, var provider = state?.usage, state?.needsSignIn != true, !signedOut {
                let hidden = AccountPresentation.hiddenRows(account.id, settings)
                provider.windows = provider.windows.filter { !hidden.contains($0.id) }
                usage = TrayUsage(providerUsage: provider)
            }
            return TrayAccount(id: account.id, identity: Self.trayLabel(account.identity, privacy),
                               isVerified: account.verification.state != .needsSignIn && account.verification.state != .unsupported,
                               isActive: status.defaultAccountIDs[providerID.rawValue] == account.id, usage: usage,
                               showsUsage: showsUsage, providerID: providerID,
                               needsDroidAccess: providerID == .droid && state?.needsKeychainAccess == true)
        }
        let ordered = TrayPresentation.orderedAccounts(accounts, order: order)
        let shown = TrayPresentation.statusGroups(ordered, hiddenServices: hiddenServices, hiddenAccounts: hiddenAccounts,
                                                  onePerService: onePerService).flatMap { $0 }

        func line(_ line: TrayPresentation.Line) -> TrayLineValue {
            let bar = line.isHeading || line.balance != nil ? nil : line.used
            return TrayLineValue(
                label: line.isHeading ? line.label : TrayPresentation.displayLabel(line), pool: line.pool,
                isHeading: line.isHeading, used: line.used,
                percentText: line.isHeading || line.balance != nil ? nil
                    : bar.map { "\(TrayPresentation.displayedPercentage(forUsed: $0, showsUsed: showsUsed))%" } ?? "—",
                fill: bar.map { TrayPresentation.fill(forUsed: $0, showsUsed: showsUsed) }, isHigh: (bar ?? 0) >= 90,
                resetsAt: line.resetsAt,
                resetText: line.resetsAt.map {
                    TrayPresentation.resetText($0, now: now, exact: exact, hourFormat: hourFormat, used: line.used)
                } ?? "",
                balance: line.balance, help: line.helpTitle == line.label ? nil : line.helpTitle)
        }
        func row(_ account: TrayAccount) -> TrayRowValue {
            let allow = account.isVerified && account.showsPrompt
            return TrayRowValue(
                id: account.id.uuidString.lowercased(), providerID: account.providerID.rawValue, label: account.identity,
                isDefault: account.isActive, isVerified: account.isVerified,
                prompt: account.showsPrompt ? (allow ? TrayPresentation.allowAccessSubtitle : TrayPresentation.signInSubtitle) : nil,
                promptButton: account.showsPrompt ? (allow ? "Allow access" : "Sign in") : nil,
                showsInTray: !hiddenAccounts.contains(account.id), showsSwitch: TrayPresentation.showsSwitch(account),
                openToolTitle: account.supportsLaunch ? TrayPresentation.openToolTitle(account) : nil,
                canExpand: TrayPresentation.canExpand(account),
                lines: TrayPresentation.lines(for: account).map(line),
                expandedLines: TrayPresentation.lines(for: account, expanded: true).map(line),
                tokens: TrayPresentation.hasTokenCaption(account) ? account.usage.flatMap(TrayPresentation.tokenCaption) : nil,
                accessibilityLabel: TrayPresentation.accessibilityLabel(account, showsUsed: showsUsed, now: now, exact: exact,
                                                                        hourFormat: hourFormat))
        }
        let fetched = codexUsage.values.compactMap(\.fetchedAt) + providerUsage.values.compactMap { $0.usage?.fetchedAt }
        return TrayValue(
            groups: TrayPresentation.groups(ordered).map { group in
                let provider = group[0].providerID
                return TrayGroupValue(providerID: provider.rawValue, name: AccountPresentation.providerName(provider),
                                      showsInTray: !hiddenServices.contains(provider), rows: group.map(row))
            },
            status: shown.map {
                TrayStatusItem(accountID: $0.id.uuidString.lowercased(), providerID: $0.providerID.rawValue,
                               percentText: $0.quotaUsedPercentage.map {
                                   "\(TrayPresentation.displayedPercentage(forUsed: $0, showsUsed: showsUsed))%"
                               } ?? "–")
            },
            tooltip: TrayPresentation.statusTooltip(ordered, shown: shown, hiddenServices: hiddenServices,
                                                    hiddenAccounts: hiddenAccounts, onePerService: onePerService,
                                                    showsUsed: showsUsed),
            lastRefreshedAt: fetched.max())
    }

    func publishTray() { publish(.tray, trayValue()) }

    /// `showAccountUsageInMenuBar.account.<UUID>` (the Mac writes the uppercase UUID), else the default switch.
    private func showsUsageInTray(_ id: UUID) -> Bool {
        for key in ["showAccountUsageInMenuBar.account.\(id.uuidString)",
                    "showAccountUsageInMenuBar.account.\(id.uuidString.lowercased())"] {
            if case .bool(let value) = settings.value(key) { return value }
        }
        return settings.effective("showAccountUsageInMenuBar") != .bool(false)
    }

    /// The Mac `notificationLabel`: a Codex account shows its email (or "Codex account"), others their label.
    static func trayLabel(_ identity: AccountIdentity, _ privacy: PrivacySettings) -> String {
        guard !privacy.privacyMode, identity.providerID == .codex else { return PrivacyText.label(identity, privacy) }
        return identity.email.map { PrivacyText.display($0, privacy) } ?? "\(identity.providerID.displayName) account"
    }

    /// The configured Codex model's API price, from the 24 h pricing cache (fetched when stale). Live runs only.
    func loadAPIPrice() async {
        guard refreshes else { return }
        let config = paths.defaultHome.appending(path: "config.toml")
        guard let data = try? Data(contentsOf: config), let model = CodexAPIPricingResolver.configuredModel(in: data)
        else { return }
        let resolver = CodexAPIPricingResolver(cacheURL: paths.applicationSupport.appending(path: "cache/model-pricing.json"))
        guard let price = try? await resolver.price(for: model), price != apiPrice else { return }
        apiPrice = price
        publishTray()
    }
}
