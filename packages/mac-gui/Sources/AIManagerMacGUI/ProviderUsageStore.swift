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

extension AccountIdentity {
  /// Primary account label. Secret accounts have no email, so a short key tail tells them apart.
  var accountLabel: String {
    if let email, !email.isEmpty { return email }
    if let accountID, !accountID.isEmpty { return accountID }
    if let userID, !userID.isEmpty, providerID != .codex {
      return "\(providerID.guiName) ···\(userID.suffix(4))"
    }
    return "Unresolved account"
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
