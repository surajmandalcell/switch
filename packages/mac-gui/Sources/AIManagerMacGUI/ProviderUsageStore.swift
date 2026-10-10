import AIManagerCore
import Foundation

// Foundation-only pieces of the generic provider usage pipeline. The production and demo model
// checks compile this file next to AccountViewModel.swift, so it must not import UI frameworks.

extension ProviderID {
  /// Display name that knows the generic provider catalog ("OpenRouter", not "Openrouter").
  var guiName: String {
    [ProviderID.codex, .grokBuild, .claudeCode].contains(self)
      ? displayName : (ProviderCatalog.spec(self)?.name ?? displayName)
  }
}

/// The "Hide email addresses" privacy setting. Every place that shows an account email passes the
/// text through `display`, so the main window, menu popover, status-item tooltip, and
/// notifications agree.
enum EmailPrivacy {
  static let key = "hideEmailAddresses"

  static func isEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }

  /// `a••••@example.com`: the first character, four bullets, and the domain. The bullet count is
  /// fixed so the length of the address is not revealed.
  static func mask(_ email: String) -> String {
    guard let at = email.lastIndex(of: "@"), at != email.startIndex,
          email.index(after: at) != email.endIndex else { return email }
    return "\(email[email.startIndex])••••\(email[at...])"
  }

  private static let pattern = try? NSRegularExpression(
    pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+"#)

  /// Masks every email address in `text` when the setting is on; otherwise returns `text`. A SwiftUI
  /// view passes its own `@AppStorage` value as `hide`, so it redraws when the setting changes.
  static func display(_ text: String, hide: Bool = EmailPrivacy.isEnabled()) -> String {
    guard hide, text.contains("@"), let pattern else { return text }
    let whole = NSRange(text.startIndex..., in: text)
    var result = text
    for match in pattern.matches(in: text, range: whole).reversed() {
      guard let range = Range(match.range, in: result) else { continue }
      result.replaceSubrange(range, with: mask(String(result[range])))
    }
    return result
  }
}

extension AccountIdentity {
  /// Primary account label. Secret accounts have no email, so a short key tail tells them apart.
  /// Emails are masked when "Hide email addresses" is on.
  var accountLabel: String {
    if let email, !email.isEmpty { return EmailPrivacy.display(email) }
    if let accountID, !accountID.isEmpty { return accountID }
    if let userID, !userID.isEmpty, providerID != .codex {
      return "\(providerID.guiName) ···\(userID.suffix(4))"
    }
    return "Unresolved account"
  }
}

// MARK: - Provider status

/// Last good incident of one provider and when it was read.
struct ProviderStatusEntry: Equatable, Sendable {
  var incident: ProviderIncident
  var checkedAt: Date
}

extension ProviderIncident {
  enum Severity: Equatable, Sendable { case warning, critical }

  /// Yellow for minor and maintenance, red for major and critical, nothing for none and unknown.
  var severity: Severity? {
    switch indicator {
    case .minor, .maintenance: .warning
    case .major, .critical: .critical
    case .none, .unknown: nil
    }
  }

  /// Tooltip and accessibility value: the description and "updated <relative time>".
  func summary(checkedAt: Date, now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    let age = formatter.localizedString(for: updatedAt ?? checkedAt, relativeTo: now)
    let text = description?.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(text.flatMap { $0.isEmpty ? nil : $0 } ?? "Service issue") · updated \(age)"
  }
}

/// Polls provider incident feeds: each provider at most once every five minutes, four at a time,
/// and a failed fetch keeps the last good value. Pass `enabled: false` to stop all requests.
actor ProviderStatusPoller {
  static let interval: TimeInterval = 5 * 60
  static let maxConcurrent = 4
  static let enabledKey = "checkProviderStatus"

  /// "Check provider status" is on unless the user turned it off.
  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
  }

  typealias Fetch = @Sendable (ProviderID, URL?) async -> ProviderIncident?

  private let fetch: Fetch
  private var attempts: [ProviderID: Date] = [:]
  private var entries: [ProviderID: ProviderStatusEntry] = [:]

  init(fetch: @escaping Fetch = { id, page in await ProviderStatusFetcher.fetch(id, statusPage: page) }) {
    self.fetch = fetch
  }

  /// Returns the last good entry of each provider in `ids`.
  func poll(_ ids: [ProviderID], enabled: Bool, now: Date = Date()) async -> [ProviderID: ProviderStatusEntry] {
    guard enabled else {
      attempts = [:]
      entries = [:]
      return [:]
    }
    let wanted = Set(ids)
    entries = entries.filter { wanted.contains($0.key) }
    let due = Array(Set(ids)).sorted { $0.rawValue < $1.rawValue }.filter { id in
      guard let last = attempts[id] else { return true }
      return now.timeIntervalSince(last) >= Self.interval
    }
    for id in due { attempts[id] = now }
    let fetch = fetch
    await withTaskGroup(of: (ProviderID, ProviderIncident?).self) { group in
      var pending = due[...]
      func launch(_ id: ProviderID) {
        group.addTask { (id, await fetch(id, ProviderCatalog.spec(id)?.statusPage)) }
      }
      for _ in 0..<min(Self.maxConcurrent, due.count) {
        if let id = pending.popFirst() { launch(id) }
      }
      while let (id, incident) = await group.next() {
        if let incident { entries[id] = ProviderStatusEntry(incident: incident, checkedAt: now) }
        if let next = pending.popFirst() { launch(next) }
      }
    }
    return entries
  }
}

/// Last known usage of one non-Codex account, plus the state of its latest check.
struct ProviderUsageState: Equatable, Sendable {
  var usage: ProviderUsage?
  var error: String?
  var needsSignIn = false
  /// End of the latest attempt, successful or not.
  var checkedAt: Date?
  var isRefreshing = false

  /// Last good values kept after a failed check.
  var isOutdated: Bool { usage != nil && error != nil }
}

enum ProviderUsagePolicy {
  static let interval: TimeInterval = 5 * 60
  static let failureCooldown: TimeInterval = 5 * 60
  static let fetchTimeout: TimeInterval = 60
  static let maxConcurrent = 4

  /// `onCadence` is the fixed timer tick: it ignores the age of the cache but not a failure.
  static func isDue(_ state: ProviderUsageState?, onCadence: Bool, now: Date = Date()) -> Bool {
    guard let state else { return true }
    if state.isRefreshing { return false }
    if state.error != nil, let checkedAt = state.checkedAt,
       now.timeIntervalSince(checkedAt) < failureCooldown { return false }
    if onCadence { return true }
    guard let fetchedAt = state.usage?.fetchedAt else { return true }
    return now.timeIntervalSince(fetchedAt) >= interval
  }

  static func failure(_ error: Error) -> (message: String, needsSignIn: Bool) {
    let providerError = error as? ProviderError
    return (error.localizedDescription, providerError?.needsSignIn ?? false)
  }
}

/// `<applicationSupport>/provider-usage-cache.json`: the last good usage of each account, so the
/// window and menu show values before the first network check finishes.
enum ProviderUsageCache {
  private struct File: Codable {
    var version = 1
    var usage: [String: ProviderUsage]
  }

  static func url(in applicationSupport: URL) -> URL {
    applicationSupport.appending(path: "provider-usage-cache.json")
  }

  static func load(from url: URL) -> [UUID: ProviderUsage] {
    guard let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
    return Dictionary(uniqueKeysWithValues: file.usage.compactMap { key, value in
      UUID(uuidString: key).map { ($0, value) }
    })
  }

  /// Owner-private (0600) and atomic: the bytes go to a private temporary file, then replace.
  static func save(_ usage: [UUID: ProviderUsage], to url: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(File(usage: Dictionary(
      uniqueKeysWithValues: usage.map { ($0.key.uuidString, $0.value) })))
    let temporary = url.deletingLastPathComponent()
      .appending(path: ".provider-usage-cache-\(UUID().uuidString).tmp")
    guard fileManager.createFile(
      atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    do {
      if fileManager.fileExists(atPath: url.path) {
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
      } else {
        try fileManager.moveItem(at: temporary, to: url)
      }
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      try? fileManager.removeItem(at: temporary)
      throw error
    }
  }

  /// Runs `operation` and fails with a timeout error when it takes longer than `seconds`.
  static func withTimeout<T: Sendable>(
    _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw ProviderError.network("The usage check timed out. Switch will retry later.")
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else { throw CancellationError() }
      return first
    }
  }
}
