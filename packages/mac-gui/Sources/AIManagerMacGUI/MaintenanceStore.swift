import AIManagerCore
import AppKit
import Combine
import Foundation

/// The UserDefaults keys that make Maintenance reopen where it was.
enum MaintenancePlace {
  static let sourceKey = "maintenanceSource"
  static let destinationKey = "backupDestination"
  static let rangeKey = "cleanupRange"
  static let fromKey = "cleanupFrom"
  static let throughKey = "cleanupThrough"
  static let expandedKey = "cleanupExpanded"
}

/// One row of the recent-backups list.
struct RecentBackup: Identifiable, Equatable {
  let id: String
  let date: Date
  let source: String
  let bytes: Int64
  let state: String
  let isSafety: Bool
}

/// Maintenance's state: the sources, the chosen source, backup sets, snapshots, the schedule, and
/// the running backup. File work runs in `BackupEngine` off the main actor.
@MainActor
final class MaintenanceStore: ObservableObject {
  @Published private(set) var sources: [CleanupSource] = []
  @Published var sourceID: String? {
    didSet { UserDefaults.standard.set(sourceID, forKey: MaintenancePlace.sourceKey) }
  }
  @Published private(set) var sets: [BackupSet] = []
  @Published private(set) var statuses: [UUID: BackupStatus] = [:]
  @Published private(set) var runningSetID: UUID?
  @Published private(set) var progress: BackupProgress?
  @Published private(set) var isRestoring = false
  @Published private(set) var isLoaded = false
  @Published var message: String?
  /// "Open Backup" on the Overview asks the Maintenance page for the Backup tab.
  @Published var wantsBackupTab = false
  @Published var destination: URL? {
    didSet { UserDefaults.standard.set(destination?.path, forKey: MaintenancePlace.destinationKey) }
  }

  private unowned let model: AccountViewModel
  private var engine: BackupEngine
  private var paths: ManagerPaths
  private var runTask: Task<Void, Never>?
  private var scheduler: Task<Void, Never>?
  private var observer: AnyCancellable?
  private var started = false
  #if AI_MANAGER_PREVIEW
  private var demo: MaintenanceDemo?
  #endif

  init(model: AccountViewModel) {
    self.model = model
    paths = model.paths
    #if AI_MANAGER_PREVIEW
    if model.isDemo {
      let demo = MaintenanceDemo.make()
      self.demo = demo
      paths = demo.paths
      let root = demo.root
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { _ in try? FileManager.default.removeItem(at: root) }
    }
    #endif
    engine = BackupEngine(applicationSupport: paths.applicationSupport)
    sourceID = UserDefaults.standard.string(forKey: MaintenancePlace.sourceKey)
    destination = UserDefaults.standard.string(forKey: MaintenancePlace.destinationKey).map { URL(fileURLWithPath: $0) }
    refreshSources()
    #if AI_MANAGER_PREVIEW
    // The empty preview scenario has no backups yet, so the Overview card shows its empty state.
    if let demo {
      if model.status?.accounts.isEmpty == false {
        let seeded = MaintenanceDemo.seedSync(engine: engine, demo: demo, sources: sources)
        sets = seeded.0
        statuses = seeded.1
      }
      isLoaded = true
      if sourceID == nil || !sources.contains(where: { $0.id == sourceID }) { sourceID = sources.first?.id }
    }
    #endif
    observer = model.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshSources() }
  }

  #if AI_MANAGER_PREVIEW
  /// The synthetic Mac of the preview, so a check can delete it when it is done.
  var demoRoot: URL? { demo?.root }
  #endif

  /// A folder as the owner reads it: `~` for the home folder. The preview shows its demo drive as a real-looking volume.
  func displayPath(_ url: URL) -> String {
    #if AI_MANAGER_PREVIEW
    if let root = demo?.root, url.path.hasSuffix("/" + root.lastPathComponent + "/Backup Drive") {
      return "/Volumes/Backup Drive/Switch Backups"
    }
    #endif
    return (url.path as NSString).abbreviatingWithTildeInPath
  }

  // MARK: Sources

  var source: CleanupSource? { sources.first { $0.id == sourceID } ?? sources.first }

  func refreshSources() {
    #if AI_MANAGER_PREVIEW
    if let demo { sources = demo.sources(accounts: model.status?.accounts ?? []); return }
    #endif
    sources = CleanupSources.make(paths: paths, accounts: model.status?.accounts ?? [])
  }

  // MARK: Backup sets

  func set(for source: CleanupSource) -> BackupSet? { sets.first { $0.source.id == source.id } }

  func status(for set: BackupSet) -> BackupStatus? { statuses[set.id] }

  /// Loads the saved sets and their snapshots, then starts the schedule. Safe to call again.
  func start() {
    guard !started else { return }
    started = true
    scheduler = Task { [weak self] in
      guard let self else { return }
      await self.loadSets()
      while !Task.isCancelled {
        await self.runDueBackups()
        try? await Task.sleep(for: .seconds(300))
      }
    }
  }

  func loadSets() async {
    do { sets = try await engine.sets() } catch { message = "Backup settings could not be read. \(error.localizedDescription)" }
    isLoaded = true
    await refreshAll()
  }

  func refreshAll() async {
    for set in sets { await refresh(set) }
  }

  func refresh(_ set: BackupSet) async {
    do { statuses[set.id] = try await engine.status(for: set) }
    catch { message = "The backups of \(set.name) could not be read. \(error.localizedDescription)" }
  }

  /// A set for a source the owner has not backed up yet: needs a destination first.
  @discardableResult
  func createSet(for source: CleanupSource, destination: URL) async -> BackupSet? {
    guard let service = source.backupService else { return nil }
    let name = Self.setName(source)
    let set = BackupSet(
      name: name, source: BackupSource(id: source.id, service: service, home: source.home),
      items: source.backupItems, destination: destination)
    await save(sets + [set])
    return self.set(for: source)
  }

  static func setName(_ source: CleanupSource) -> String {
    source.accountID == nil ? source.title : "\(source.title) \(source.accountID!.uuidString.prefix(8))"
  }

  func update(_ set: BackupSet) async {
    guard let index = sets.firstIndex(where: { $0.id == set.id }) else { return }
    var next = sets
    next[index] = set
    await save(next)
  }

  private func save(_ next: [BackupSet]) async {
    do {
      try await engine.saveSets(next)
      sets = next
      for set in next where statuses[set.id] == nil { await refresh(set) }
      for set in next { await refresh(set) }
    } catch { message = error.localizedDescription }
  }

  // MARK: Destination and items (folder panels)

  func chooseDestination(for source: CleanupSource) async {
    guard let url = Self.pickFolder(title: "Choose a backup folder", prompt: "Choose",
      start: destination ?? FileManager.default.homeDirectoryForCurrentUser) else { return }
    destination = url
    if var existing = set(for: source) {
      existing.destination = url
      await update(existing)
    } else {
      await createSet(for: source, destination: url)
    }
  }

  func addItem(to set: BackupSet) async {
    guard let url = Self.pickItem(start: set.source.home) else { return }
    let home = CoreSupportBridge.canonical(set.source.home).path
    let path = CoreSupportBridge.canonical(url).path
    guard path.hasPrefix(home + "/") else {
      message = "Choose a file or folder inside \(set.source.home.lastPathComponent)."
      return
    }
    let relative = String(path.dropFirst(home.count + 1))
    guard !set.items.contains(where: { $0.path == relative }) else { return }
    var next = set
    next.items.append(BackupItem(relative, isLogin: BackupPresets.isLogin(relative)))
    await update(next)
  }

  static func pickFolder(title: String, prompt: String, start: URL?) -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.prompt = prompt
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = start
    return panel.runModal() == .OK ? panel.url : nil
  }

  static func pickItem(start: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Add a file or folder"
    panel.prompt = "Add"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = start
    return panel.runModal() == .OK ? panel.url : nil
  }

  // MARK: Running

  var isBackingUp: Bool { runningSetID != nil }

  func backUpNow(_ set: BackupSet) {
    guard runningSetID == nil, !isRestoring else { return }
    runningSetID = set.id
    progress = nil
    message = nil
    let box = ProgressBox()
    runTask = Task { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try await self.engine.snapshot(set) { [weak self] value in
          if box.shouldPublish() { Task { @MainActor in self?.progress = value } }
        }
        self.message = "Backed up \(snapshot.files.formatted()) files. \(Self.size(snapshot.newBytes)) of new data."
      } catch is CancellationError {
        self.message = "Backup cancelled. Nothing was added."
      } catch {
        self.message = error.localizedDescription
      }
      self.runningSetID = nil
      self.progress = nil
      await self.refresh(set)
    }
  }

  func backUp(_ set: BackupSet) async {
    backUpNow(set)
    await runTask?.value
  }

  func cancelBackup() { runTask?.cancel() }

  /// `items` nil restores the whole snapshot; `folder` nil restores in place after a safety snapshot.
  func restore(_ snapshot: BackupSnapshot, set: BackupSet, items: [String]?, to folder: URL?) async {
    guard runningSetID == nil, !isRestoring else { return }
    isRestoring = true
    defer { isRestoring = false }
    do {
      let result = try await engine.restore(snapshot, set: set, items: items, to: folder)
      var text = "Restored \(result.restored.formatted()) files"
      if let folder { text += " to \(folder.lastPathComponent)" }
      if result.safetySnapshot != nil { text += ". A safety snapshot of the current files was kept" }
      if !result.extraFiles.isEmpty { text += ". \(result.extraFiles.count.formatted()) newer files were left in place" }
      message = text + "."
    } catch { message = error.localizedDescription }
    await refresh(set)
  }

  /// Runs every set whose schedule is due, one at a time.
  func runDueBackups() async {
    for set in sets where set.schedule != .off {
      await refresh(set)
      guard let status = statuses[set.id], case .ready = status.state,
        let due = status.nextDue, due <= Date(), runningSetID == nil, !isRestoring else { continue }
      await backUp(set)
    }
  }

  // MARK: Recent snapshots

  var recent: [RecentBackup] {
    let all = sets.flatMap { set in
      (statuses[set.id]?.snapshots ?? []).map { snapshot in
        RecentBackup(
          id: set.id.uuidString + snapshot.id, date: snapshot.date, source: set.name,
          bytes: snapshot.totalBytes, state: snapshot.manifest.safety ? "Safety copy" : snapshot.state,
          isSafety: snapshot.manifest.safety)
      }
    }
    return Array(all.sorted { $0.date > $1.date }.prefix(3))
  }

  nonisolated static func size(_ bytes: Int64) -> String {
    bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  /// Free space on the destination's disk, or nil while it is missing.
  nonisolated static func freeSpace(at url: URL) -> Int64? {
    var existing = url
    while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
    return (try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage
  }
}

/// Lets the panel code reuse the core's link-resolving path rule without exposing it.
enum CoreSupportBridge {
  static func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
}

/// Passes about ten progress updates a second from the engine's worker to the main actor.
private final class ProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private var last = Date.distantPast
  func shouldPublish() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard Date().timeIntervalSince(last) > 0.1 else { return false }
    last = Date()
    return true
  }
}
