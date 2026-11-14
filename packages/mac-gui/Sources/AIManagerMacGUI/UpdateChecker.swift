import AIManagerCore
import AppKit

/// The Mac side of the update check: it keeps the throttle state in UserDefaults and publishes the
/// newer build when the server has one. Errors stay silent. The rules live in `UpdateCheck`.
@MainActor
final class UpdateChecker: ObservableObject {
  static let shared = UpdateChecker()
  static let stateKey = "updateCheckState"

  @Published private(set) var available: UpdateInfo?
  private var task: Task<Void, Never>?

  static var installedVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  /// The first check runs 30 seconds after launch; the hourly tick only fires a check that is due.
  func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(30))
      while !Task.isCancelled {
        await self?.checkIfDue()
        try? await Task.sleep(for: .seconds(3600))
      }
    }
  }

  func checkIfDue(now: Date = Date(), calendar: Calendar = .current) async {
    let version = Self.installedVersion
    var state = Self.stored()
    guard UpdateCheck.isDue(state: state, now: now, calendar: calendar),
      let url = UpdateCheck.requestURL(version: version, state: state, now: now, calendar: calendar)
    else { return }
    state.lastAttempt = now
    Self.store(state)
    let result = await UpdateCheck.fetch(url)
    let newer = result.info.map { UpdateCheck.isNewer($0, installedVersion: version) } ?? false
    EventLog.standard.record(.info, area: "update", event: "update_check", message: "counted=\(result.counted) newer=\(newer)")
    guard result.counted else { return }
    UpdateCheck.recordSuccess(&state, now: now, calendar: calendar)
    Self.store(state)
    if let info = result.info { available = UpdateCheck.isNewer(info, installedVersion: version) ? info : nil }
  }

  #if AI_MANAGER_PREVIEW
  /// Acceptance and lint builds only: a made-up newer build, shown without any network call.
  static let previewInfo = try! JSONDecoder().decode(UpdateInfo.self, from: Data(
    #"{"app":"switch","platform":"macos","version":"9.9.9","build":9009009,"url":"https://example.com/switch","notes":null,"required":false}"#.utf8))

  func showForPreview(_ info: UpdateInfo?) { available = info }
  #endif

  /// Opens the server's download link in the browser. The core refuses anything but https.
  func openDownload() {
    guard let info = available, let url = UpdateCheck.downloadURL(info) else { return }
    NSWorkspace.shared.open(url)
  }

  private static func stored(defaults: UserDefaults = .standard) -> UpdateCheckState {
    defaults.data(forKey: stateKey).flatMap { try? JSONDecoder().decode(UpdateCheckState.self, from: $0) }
      ?? UpdateCheckState()
  }

  private static func store(_ state: UpdateCheckState, defaults: UserDefaults = .standard) {
    defaults.set(try? JSONEncoder().encode(state), forKey: stateKey)
  }
}
