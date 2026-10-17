import AIManagerCore
import AppKit
import Combine
import UserNotifications

// Delivers the alerts that QuotaNotificationEngine decides on. The decisions are Foundation-only
// and unit-tested; this file owns the macOS permission, the notification center, and the stored
// state.

extension AccountIdentity {
  /// Account name in an alert: the email (masked when "Hide email addresses" is on), else a key tail.
  var notificationLabel: String {
    if EmailPrivacy.isPrivacyMode() { return accountLabel }
    return providerID == .codex
      ? (email.map { EmailPrivacy.display($0) } ?? "\(providerID.displayName) account") : accountLabel
  }
}

/// Notification permission shown in Settings. The first toggle that turns on asks macOS.
@MainActor
final class QuotaNotificationPermission: ObservableObject {
  static let isAvailable = Bundle.main.bundleURL.pathExtension == "app"

  @Published private(set) var status: UNAuthorizationStatus = .notDetermined

  var isDenied: Bool { status == .denied }

  func refresh() async {
    guard Self.isAvailable else { return }
    status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }

  func requestIfNeeded() {
    guard Self.isAvailable else { return }
    Task {
      await refresh()
      if status == .notDetermined {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refresh()
      }
    }
  }

  func openSystemSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }
}

/// The result of an action as a macOS notification: the text in the body (macOS titles it "Switch"),
/// no sound. The first post asks macOS for permission; when notifications are off the message is dropped.
/// The app installs `post` as `AccountViewModel.messagePoster`; the model skips Preview and isolated runs.
@MainActor
enum ActionMessage {
  static func post(_ text: String) {
    guard QuotaNotificationPermission.isAvailable else { return }
    Task {
      let center = UNUserNotificationCenter.current()
      var status = await center.notificationSettings().authorizationStatus
      if status == .notDetermined {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        status = await center.notificationSettings().authorizationStatus
      }
      guard status == .authorized || status == .provisional else { return }
      let content = UNMutableNotificationContent()
      content.body = text
      content.threadIdentifier = "switch.message"
      try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
  }
}

@MainActor
final class QuotaNotifier: NSObject, UNUserNotificationCenterDelegate {
  private static let thread = "switch.quota"

  private let model: AccountViewModel
  private let stateURL: URL
  private let openApp: () -> Void
  private var store: QuotaNotificationStore
  private var isDelivering = false
  private var rerun = false
  private var observers = Set<AnyCancellable>()

  init(model: AccountViewModel, openApp: @escaping () -> Void) {
    self.model = model
    self.openApp = openApp
    stateURL = QuotaNotificationStore.url(in: model.paths.applicationSupport)
    store = model.paths.isolationRoot == nil ? .load(from: stateURL) : QuotaNotificationStore()
    super.init()
    if QuotaNotificationPermission.isAvailable { UNUserNotificationCenter.current().delegate = self }
    // @Published fires before the value changes; wait for the burst to settle, then read.
    Publishers.MergeMany([
      model.$status.map { _ in () }.eraseToAnyPublisher(),
      model.$usageSnapshots.map { _ in () }.eraseToAnyPublisher(),
      model.$providerUsage.map { _ in () }.eraseToAnyPublisher(),
      model.$accountUsage.map { _ in () }.eraseToAnyPublisher(),
    ])
    .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
    .sink { [weak self] in self?.evaluate() }
    .store(in: &observers)
  }

  /// One pass over every account window. Runs after each model change; the state machine makes
  /// repeated passes over unchanged data a no-op.
  func evaluate(now: Date = Date()) {
    guard model.paths.isolationRoot == nil else { return }
    if isDelivering {
      rerun = true
      return
    }
    let pass = QuotaNotificationEngine.evaluate(
      inputs(), store: store, settings: .load(), now: now)
    guard !pass.alerts.isEmpty else {
      update(pass.store)
      return
    }
    isDelivering = true
    Task {
      var delivered = Set<String>()
      for alert in pass.alerts {
        if await deliver(alert) { delivered.insert(alert.id) }
      }
      update(pass.committed(delivered: delivered))
      isDelivering = false
      if rerun {
        rerun = false
        evaluate()
      }
    }
  }

  private func update(_ next: QuotaNotificationStore) {
    guard next != store else { return }
    store = next
    let url = stateURL
    Task.detached(priority: .utility) { try? next.save(to: url) }
  }

  private func deliver(_ alert: QuotaAlert) async -> Bool {
    guard QuotaNotificationPermission.isAvailable else { return false }
    let center = UNUserNotificationCenter.current()
    let status = await center.notificationSettings().authorizationStatus
    guard status == .authorized || status == .provisional else { return false }
    let content = UNMutableNotificationContent()
    content.title = alert.title
    content.subtitle = alert.subtitle
    content.body = alert.body
    content.sound = .default
    content.threadIdentifier = Self.thread
    do {
      try await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
      return true
    } catch {
      return false
    }
  }

  /// Every account's usage windows and sign-in state; Auto switch reads the same numbers.
  func inputs() -> [QuotaAccountInput] {
    (model.status?.accounts ?? []).map { account in
      let providerID = account.identity.providerID
      let needsSignIn = account.verification.state == .needsSignIn
      var windows: [UsageWindow] = []
      var signIn = QuotaSignInStatus.unknown
      if providerID == .codex {
        let failure = model.cachedUsage(for: account.id)?.failure
        let snapshot = model.usageSnapshots[account.id]
        if needsSignIn || failure == .authenticationRequired {
          signIn = .needsSignIn
        } else {
          windows = snapshot?.rateLimits?.defaultBucket.map(QuotaWindows.codex) ?? []
          if snapshot != nil, failure == nil { signIn = .ok }
        }
      } else {
        let state = model.providerUsage[account.id]
        if needsSignIn || state?.needsSignIn == true {
          signIn = .needsSignIn
        } else {
          windows = state?.usage?.windows ?? []
          if state?.usage != nil, state?.error == nil { signIn = .ok }
        }
      }
      return QuotaAccountInput(
        id: account.id, providerKey: providerID.rawValue, providerName: providerID.guiName,
        accountLabel: account.identity.notificationLabel, windows: windows, signIn: signIn)
    }
  }

  // MARK: UNUserNotificationCenterDelegate

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    // Shown also while Switch is in front. Only quota alerts carry a sound; action messages do not.
    notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    await MainActor.run { openApp() }
  }
}
