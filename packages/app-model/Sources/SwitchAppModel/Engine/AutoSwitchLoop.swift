import Foundation
import AIManagerCore

/// One provider's auto-switch decision (Settings item 7a).
public struct AutoSwitchStep: Codable, Equatable, Sendable {
    public enum Decision: String, Codable, Sendable { case stay, switchTo, noneLeft }
    public var providerID: String
    public var decision: Decision
    public var fromAccountID: String
    public var toAccountID: String?
    /// Percent left on the default account; nil while it has no usage figure.
    public var leftPercent: Double?
}

public struct AutoSwitchPreview: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var threshold: Int
    public var steps: [AutoSwitchStep]
}

// shortcut: the Mac AutoSwitchController.evaluate keeps its own copy of this loop; delete that copy when the Mac app
// adopts SwitchAppModel.
/// The decision loop of the Mac `AutoSwitchController.evaluate`, shared by every GUI.
public enum AutoSwitchPlanner {
    /// One step per provider with a default, in Accounts order. `usage` holds each account's windows; an account
    /// that needs a new sign-in is left out of it, so it can neither trigger nor receive a switch.
    public static func steps(_ status: ManagerStatus, usage: [UUID: [UsageWindow]], threshold: Int,
                             now: Date) -> [AutoSwitchStep] {
        var providers: [ProviderID] = []
        for account in status.accounts where !providers.contains(account.identity.providerID) {
            providers.append(account.identity.providerID)
        }
        return providers.compactMap { provider in
            guard let defaultID = status.defaultAccountID(for: provider) else { return nil }
            let order = status.accounts.filter { $0.identity.providerID == provider }.map { account in
                AutoSwitch.Candidate(id: account.id, leftPercent: usage[account.id].flatMap {
                    AutoSwitch.leftPercent(of: $0, now: now)
                })
            }
            let left = order.first { $0.id == defaultID }?.leftPercent
            var step = AutoSwitchStep(providerID: provider.rawValue, decision: .stay,
                                      fromAccountID: defaultID.uuidString.lowercased(), leftPercent: left)
            switch AutoSwitch.decide(order: order, defaultID: defaultID, threshold: Double(threshold)) {
            case .stay: break
            case .noneLeft: step.decision = .noneLeft
            case .switchTo(let id):
                step.decision = .switchTo
                step.toAccountID = id.uuidString.lowercased()
            }
            return step
        }
    }
}

extension AppEngine {
    /// What auto switch would do now, from the cached usage. Reads nothing live.
    public func autoSwitchPreview() async -> AutoSwitchPreview {
        if status == nil { await reloadAccounts() }
        let threshold = autoSwitchThreshold
        return AutoSwitchPreview(enabled: settings.value("autoSwitchEnabled") == .bool(true), threshold: threshold,
                                 steps: status.map { AutoSwitchPlanner.steps($0, usage: autoSwitchUsage(), threshold: threshold,
                                                                             now: clock.now) } ?? [])
    }

    /// The Mac `evaluate` and `switchAway`, run after each usage refresh: at most one switch per pass, one notice
    /// per "nothing left" episode, and a failed switch is not retried until the decision changes. Running CLIs
    /// are left running (the Mac "Restart when idle" needs a terminal launcher on this platform).
    func evaluateAutoSwitch() async {
        guard settings.value("autoSwitchEnabled") == .bool(true), refreshes, !app.isBusy, !autoSwitching,
              let manager, let status else { return }
        let threshold = autoSwitchThreshold
        let privacy = PrivacySettings(settings)
        for step in AutoSwitchPlanner.steps(status, usage: autoSwitchUsage(), threshold: threshold, now: clock.now) {
            let name = AccountPresentation.providerName(ProviderID(rawValue: step.providerID))
            switch step.decision {
            case .stay:
                autoSwitchNoneLeft.remove(step.providerID)
            case .noneLeft:
                if autoSwitchNoneLeft.insert(step.providerID).inserted {
                    setNotice("Every \(name) account has \(threshold)% or less left. Switch left the default as it is.")
                }
            case .switchTo:
                autoSwitchNoneLeft.remove(step.providerID)
                let key = "\(step.fromAccountID)>\(step.toAccountID ?? "")"
                guard autoSwitchFailed[step.providerID] != key,
                      let from = status.accounts.first(where: { $0.id.uuidString.lowercased() == step.fromAccountID }),
                      let to = status.accounts.first(where: { $0.id.uuidString.lowercased() == step.toAccountID }) else { continue }
                autoSwitching = true
                defer { autoSwitching = false }
                _ = try? await perform { _ = try await manager.switchDefault(to: to.id) }
                await reloadAccounts()
                guard self.status?.defaultAccountID(for: to.identity.providerID) == to.id else {
                    autoSwitchFailed[step.providerID] = key
                    return
                }
                autoSwitchFailed[step.providerID] = nil
                let left = step.leftPercent.map { " has \(Int($0.rounded()))% left" } ?? " is nearly out"
                setNotice("\(name) account \(AccountPresentation.label(from.identity, privacy))\(left). "
                          + "Switched to \(AccountPresentation.label(to.identity, privacy)).")
                return  // One switch for each pass; the next refresh looks at the other providers.
            }
        }
    }

    /// Percent left; a stored value outside the menu falls back to 1%.
    private var autoSwitchThreshold: Int {
        guard case .int(let value) = settings.value("autoSwitchThreshold"), AutoSwitch.thresholds.contains(value) else {
            return AutoSwitch.thresholds[0]
        }
        return value
    }

    /// Each account's windows, without the hidden-row filter; nothing for an account that needs a new sign-in.
    private func autoSwitchUsage() -> [UUID: [UsageWindow]] {
        var usage: [UUID: [UsageWindow]] = [:]
        for account in status?.accounts ?? [] where providerUsage[account.id]?.needsSignIn != true {
            usage[account.id] = AccountPresentation.windows(account, codex: codexUsage[account.id]?.snapshot,
                                                            provider: providerUsage[account.id])
        }
        return usage
    }
}
