import AIManagerCore
import Combine
import Foundation

/// Settings > Auto switch (specs/product.md, item 7a). Off by default.
enum AutoSwitchPreferences {
  static let enabledKey = "autoSwitchEnabled"
  static let thresholdKey = "autoSwitchThreshold"
  static let runningCLIsKey = "autoSwitchRunningCLIs"
  static let resumeMessageKey = "autoSwitchResumeMessage"
  static var keys: [String] { [enabledKey, thresholdKey, runningCLIsKey, resumeMessageKey] }

  enum RunningCLIs: String, CaseIterable {
    case restart, leave
    var label: String { self == .restart ? "Restart when idle" : "Leave running" }
  }

  static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }

  /// Percent left; any stored value outside the menu falls back to 1%.
  static func threshold(_ defaults: UserDefaults = .standard) -> Int {
    let value = defaults.object(forKey: thresholdKey) as? Int ?? AutoSwitch.thresholds[0]
    return AutoSwitch.thresholds.contains(value) ? value : AutoSwitch.thresholds[0]
  }

  static func runningCLIs(_ defaults: UserDefaults = .standard) -> RunningCLIs {
    defaults.string(forKey: runningCLIsKey).flatMap(RunningCLIs.init(rawValue:)) ?? .restart
  }

  static func resumeMessage(_ defaults: UserDefaults = .standard) -> String {
    defaults.string(forKey: resumeMessageKey) ?? AutoSwitch.defaultResumeMessage
  }
}

/// Runs after each usage refresh. When a provider's default account is at the threshold it makes
/// the next account in Accounts order the default, sends one notification, and (Restart when idle)
/// reopens that provider's idle Codex or Claude Code sessions on the new account.
@MainActor
final class AutoSwitchController {
  private let model: AccountViewModel
  private let inputs: () -> [QuotaAccountInput]
  private var observers = Set<AnyCancellable>()
  private var isSwitching = false
  /// Providers whose "nothing left" notification went out in the current episode.
  private var noneLeftNotified = Set<String>()
  /// "from>to" of a switch that failed, so a broken switch is not retried on every refresh.
  private var failed: [String: String] = [:]
  private var restarting = Set<Int32>()

  init(model: AccountViewModel, inputs: @escaping () -> [QuotaAccountInput]) {
    self.model = model
    self.inputs = inputs
    // @Published fires before the value changes; wait for the burst to settle, then read.
    Publishers.MergeMany([
      model.$status.map { _ in () }.eraseToAnyPublisher(),
      model.$usageSnapshots.map { _ in () }.eraseToAnyPublisher(),
      model.$providerUsage.map { _ in () }.eraseToAnyPublisher(),
      model.$accountUsage.map { _ in () }.eraseToAnyPublisher(),
      model.$isBusy.map { _ in () }.eraseToAnyPublisher(),
    ])
    .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
    .sink { [weak self] in self?.evaluate() }
    .store(in: &observers)
  }

  func evaluate() {
    guard AutoSwitchPreferences.isEnabled(), model.paths.isolationRoot == nil,
          !model.isBusy, !isSwitching, let status = model.status else { return }
    #if AI_MANAGER_PREVIEW
    guard !model.isDemo else { return }
    #endif
    let threshold = AutoSwitchPreferences.threshold()
    let usage = Dictionary(inputs().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var groups: [(provider: ProviderID, accounts: [AccountRecord])] = []
    for account in status.accounts {
      let provider = account.identity.providerID
      if let index = groups.firstIndex(where: { $0.provider == provider }) {
        groups[index].accounts.append(account)
      } else {
        groups.append((provider, [account]))
      }
    }
    for (provider, accounts) in groups {
      guard let defaultID = status.defaultAccountID(for: provider) else { continue }
      let order = accounts.map { account -> AutoSwitch.Candidate in
        let input = usage[account.id]
        let left = input.flatMap { $0.signIn == .needsSignIn ? nil : AutoSwitch.leftPercent(of: $0.windows) }
        return .init(id: account.id, leftPercent: left)
      }
      let key = provider.rawValue
      switch AutoSwitch.decide(order: order, defaultID: defaultID, threshold: Double(threshold)) {
      case .stay:
        noneLeftNotified.remove(key)
      case .noneLeft:
        if noneLeftNotified.insert(key).inserted {
          ActionMessage.post(
            "Every \(provider.guiName) account has \(threshold)% or less left. Switch left the default as it is.")
        }
      case .switchTo(let id):
        noneLeftNotified.remove(key)
        guard failed[key] != "\(defaultID)>\(id)",
              let from = accounts.first(where: { $0.id == defaultID }),
              let to = accounts.first(where: { $0.id == id }) else { continue }
        isSwitching = true
        let percent = order.first { $0.id == defaultID }?.leftPercent
        Task {
          await switchAway(provider: provider, from: from, to: to, percentLeft: percent)
          isSwitching = false
        }
        return  // One switch for each pass; the next refresh looks at the other providers.
      }
    }
  }

  private func switchAway(provider: ProviderID, from: AccountRecord, to: AccountRecord, percentLeft: Double?) async {
    let key = provider.rawValue
    let restart = AutoSwitchPreferences.runningCLIs() == .restart
    // Look before the switch: a Claude Code session belongs to the account it started on.
    let sessions = restart ? await runningSessions(provider: provider, oldAccountID: from.id) : []
    await model.switchDefault(to: to.id, announce: false)
    guard model.status?.defaultAccountID(for: provider) == to.id else {
      failed[key] = "\(from.id)>\(to.id)"
      return
    }
    failed[key] = nil
    let left = percentLeft.map { " has \(Int($0.rounded()))% left" } ?? " is nearly out"
    var text = "\(provider.guiName) account \(from.identity.notificationLabel)\(left). Switched to \(to.identity.notificationLabel)."
    if !sessions.isEmpty {
      text += " \(sessions.count) running \(sessions.count == 1 ? "session reopens" : "sessions reopen") in Terminal when \(sessions.count == 1 ? "it is" : "they are") idle."
    }
    ActionMessage.post(text)
    let options = CLIRestartOptions(resumeMessage: AutoSwitchPreferences.resumeMessage())
    for cli in sessions where restarting.insert(cli.pid).inserted {
      Task {
        let outcome = await RunningCLIs.restart(cli, options: options) { await self.model.openResume($0) }
        restarting.remove(cli.pid)
        switch outcome {
        case .leftRunning:
          ActionMessage.post(
            "A \(provider.guiName) session in \(cli.cwd) did not finish its turn in 2 hours. Switch left it running on \(from.identity.notificationLabel).")
        case .launchFailed:
          let line = CLIResume(tool: cli.tool, sessionID: cli.sessionID, cwd: cli.cwd, prompt: nil).arguments
          ActionMessage.post(
            "Switch stopped a \(provider.guiName) session but Terminal could not reopen it. Run: \(cli.tool.rawValue) \(line.joined(separator: " ")) in \(cli.cwd).")
        case .relaunched, .exited:
          break
        }
      }
    }
  }

  /// Interactive sessions of the provider's CLI that run on the old account.
  private func runningSessions(provider: ProviderID, oldAccountID: UUID) async -> [RunningCLI] {
    let tool: CLITool
    switch provider {
    case .codex: tool = .codex
    case .claudeCode: tool = .claude
    default: return []
    }
    let defaultConfig = model.paths.userHome.appending(path: ".claude", directoryHint: .isDirectory)
    let old = oldAccountID.uuidString
    return await Task.detached(priority: .utility) {
      RunningCLIs.find(claudeDefaultConfig: defaultConfig) { dir in
        dir == defaultConfig.path || dir.contains(old)
      }.filter { $0.tool == tool }
    }.value
  }
}
