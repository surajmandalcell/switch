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

/// One snapshot in History: the set it restores through and the tool it belongs to.
struct BackupHistoryRow: Identifiable {
  let snapshot: BackupSnapshot
  let set: BackupSet
  let source: CleanupSource?
  var id: String { self.set.id.uuidString + snapshot.id }
}

/// The schedule, snapshot count, and login choice that every checked tool shares.
struct SharedBackupSettings: Codable, Equatable {
  var schedule: BackupSchedule = .off
  var keep = 10
  var includeLogins = false
  var promptsOnly: Bool? = nil
  static let key = "backupShared"
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
  /// Which tool of a multi-tool run is going now (0-based) and how many the run has.
  @Published private(set) var runPosition: (index: Int, count: Int) = (0, 0)
  @Published private(set) var progress: BackupProgress?
  /// Bytes in each checklist row, by source id. Filled off the main actor; nil while it is being read.
  @Published private(set) var sizes: [String: Int64] = [:]
  /// Tools checked before a backup folder exists. The folder pick creates their sets.
  @Published private(set) var pendingChecked: Set<String> = []
  @Published private(set) var shared: SharedBackupSettings = {
    UserDefaults.standard.data(forKey: SharedBackupSettings.key)
      .flatMap { try? JSONDecoder().decode(SharedBackupSettings.self, from: $0) } ?? SharedBackupSettings()
  }()
  @Published private(set) var isRestoring = false
  @Published private(set) var isLoaded = false
  /// "Open Backup" on the Overview asks the Maintenance page for the Backup tab.
  @Published var wantsBackupTab = false
  @Published var destination: URL? {
    didSet { UserDefaults.standard.set(destination?.path, forKey: MaintenancePlace.destinationKey) }
  }

  /// Weak: the schedule task and a profile sync keep the store alive past a model that is gone
  /// (a check makes and drops many), and an unowned read then aborted the app.
  private weak var model: AccountViewModel?
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
        destination = demo.drive
        shared = SharedBackupSettings(schedule: .daily, keep: 10, includeLogins: false)
      }
      isLoaded = true
      if sourceID == nil || !sources.contains(where: { $0.id == sourceID }) { sourceID = sources.first?.id }
    }
    #endif
    observer = model.$status.receive(on: RunLoop.main).sink { [weak self] _ in
      self?.refreshSources()
      Task { await self?.syncProfiles() }
    }
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

  /// Cleanup lists Claude Code once: an account's own profile folds into the shared entry (so does Backup's checklist).
  var cleanupSources: [CleanupSource] {
    sources.filter { !$0.isClaudeProfile }.map { $0.tool == .claude ? $0.withDetail($0.detail.replacingOccurrences(of: "Shared history · ", with: "")) : $0 }
  }

  /// The source Cleanup acts on. A remembered Claude profile id maps to the merged entry.
  var cleanupSource: CleanupSource? {
    let choices = cleanupSources
    guard let chosen = source else { return choices.first }
    return choices.first { $0.id == chosen.id } ?? choices.first { $0.tool == chosen.tool } ?? choices.first
  }

  func refreshSources() {
    #if AI_MANAGER_PREVIEW
    if let demo { sources = demo.sources(accounts: model?.status?.accounts ?? []); return }
    #endif
    sources = CleanupSources.make(paths: paths, accounts: model?.status?.accounts ?? [])
  }

  // MARK: Backup sets

  /// The tools on the Backup checklist: each once. An account's own Claude Code profile is part of the Claude Code row.
  var checklistSources: [CleanupSource] { sources.filter { !$0.isClaudeProfile } }

  /// The tool's checked set. A retired set (unchecked, or left behind by a folder change) is history only.
  func set(for source: CleanupSource) -> BackupSet? { sets.first { $0.source.id == source.id && !$0.retired } }

  func isChecked(_ source: CleanupSource) -> Bool { set(for: source) != nil || pendingChecked.contains(source.id) }

  var checkedSets: [BackupSet] { checklistSources.compactMap { set(for: $0) } }

  /// The newest backup of a tool across all its sets (older folders and profile sets included).
  func lastBackup(of source: CleanupSource) -> Date? {
    sets.filter { $0.toolKey == source.id }
      .flatMap { statuses[$0.id]?.snapshots ?? [] }.filter { !$0.manifest.safety }.map(\.date).max()
  }

  func status(for set: BackupSet) -> BackupStatus? { statuses[set.id] }

  /// The backup folder the checked tools share: the remembered pick, else the folder of a checked set.
  var folder: URL? { destination ?? checkedSets.first?.destination }

  /// What History lists: snapshots of every set, newest first, each with the set it restores through.
  var history: [BackupHistoryRow] {
    sets.flatMap { set in
      (statuses[set.id]?.snapshots ?? []).map { snapshot in
        BackupHistoryRow(snapshot: snapshot, set: set, source: checklistSources.first { $0.id == set.toolKey })
      }
    }.sorted { $0.snapshot.date > $1.snapshot.date }
  }

  #if AI_MANAGER_PREVIEW
  /// For a render check that cannot wait: reads the sizes on the calling thread.
  func loadSizesNow() {
    for source in checklistSources where source.backupService != nil { sizes[source.id] = BackupChecklist.size(of: source) }
  }
  #endif

  func loadSizes() async {
    for source in checklistSources where source.backupService != nil && sizes[source.id] == nil {
      let bytes = await Task.detached(priority: .utility) { BackupChecklist.size(of: source) }.value
      sizes[source.id] = bytes
    }
  }

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
    defer { isLoaded = true }
    do { sets = try await engine.sets() } catch { model?.errorMessage = "Backup settings could not be read. \(error.localizedDescription)" }
    await refreshAll()
    await migrate()
    await syncProfiles()
  }

  /// Older installs saved one set for each source, maybe in different folders. This folds them into the checklist once.
  private func migrate() async {
    let lastUsed = sets.reduce(into: [UUID: Date]()) { result, set in
      result[set.id] = statuses[set.id]?.snapshots.filter { !$0.manifest.safety }.map(\.date).max()
    }
    let result = BackupChecklist.migrate(sets, lastUsed: lastUsed)
    if result.sets != sets { await save(result.sets) }
    if let folder = result.folder { destination = folder }
    // One shared toggle must never read Off while a set still copies login files: On only when every checked set has it.
    let checked = checkedSets
    guard let derived = Self.derivedShared(checked) else { return }
    if checked.contains(where: { $0.schedule != derived.schedule || $0.keep != derived.keep || $0.includeLogins != derived.includeLogins || $0.promptsOnly != (derived.promptsOnly == true) }) {
      guard await save(Self.applying(derived, to: sets)) else {
        // Not saved: show On while any set still copies login files, and keep the stored choice as it was.
        shared.includeLogins = checked.contains { $0.includeLogins }
        return
      }
    }
    commitShared(derived)
  }

  private func commitShared(_ next: SharedBackupSettings) {
    shared = next
    UserDefaults.standard.set(try? JSONEncoder().encode(next), forKey: SharedBackupSettings.key)
  }

  /// The shared values of the checked sets: schedule and count of the first, login files On only if every set has them.
  static func derivedShared(_ checked: [BackupSet]) -> SharedBackupSettings? {
    guard let first = checked.first else { return nil }
    return SharedBackupSettings(schedule: first.schedule, keep: first.keep, includeLogins: checked.allSatisfy(\.includeLogins),
      promptsOnly: checked.allSatisfy(\.promptsOnly))
  }

  static func applying(_ settings: SharedBackupSettings, to sets: [BackupSet]) -> [BackupSet] {
    sets.map { set in
      guard !set.retired else { return set }
      var copy = set
      copy.schedule = settings.schedule; copy.keep = settings.keep; copy.includeLogins = settings.includeLogins
      copy.promptsOnly = settings.promptsOnly == true
      return copy
    }
  }

  /// Claude Code's set follows its accounts: a new Claude Code profile joins it, a removed one leaves it.
  func syncProfiles() async {
    guard model?.status != nil, let source = sources.first(where: { $0.id == "claude" }),
      let set = set(for: source) else { return }
    let next = BackupChecklist.withProfiles(set, homes: source.extraHomes)
    if next != set { await update(next) }
  }

  func refreshAll() async {
    for set in sets { await refresh(set) }
  }

  func refresh(_ set: BackupSet) async {
    do { statuses[set.id] = try await engine.status(for: set) }
    catch { model?.errorMessage = "The backups of \(set.name) could not be read. \(error.localizedDescription)" }
  }

  /// A set for a tool the owner has not backed up yet, with the shared schedule, count, and login choice.
  /// A set that was unchecked in the same folder comes back instead, so its snapshots stay in one history.
  @discardableResult
  func createSet(for source: CleanupSource, destination: URL) async -> BackupSet? {
    guard let service = source.backupService else { return nil }
    let contents = BackupChecklist.contents(for: source)
    var next = sets
    if let back = next.firstIndex(where: {
      $0.retired && $0.source.id == source.id && BackupChecklist.sameFolder($0.destination, destination)
    }) {
      next[back].retired = false
      next[back].items = contents.items
      next[back].profiles = contents.profiles
      next[back].source.home = source.home
    } else {
      next.append(BackupSet(
        name: Self.setName(source), source: BackupSource(id: source.id, service: service, home: source.home),
        items: contents.items, destination: destination, includeLogins: shared.includeLogins,
        schedule: shared.schedule, keep: shared.keep, profiles: contents.profiles))
    }
    if let index = next.firstIndex(where: { $0.source.id == source.id && !$0.retired }) {
      next[index].schedule = shared.schedule
      next[index].keep = shared.keep
      next[index].includeLogins = shared.includeLogins
      next[index].promptsOnly = shared.promptsOnly == true
    }
    await save(next)
    return set(for: source)
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

  /// True when the sets were written. On failure the old sets stay and the error message shows.
  @discardableResult
  private func save(_ next: [BackupSet]) async -> Bool {
    do {
      try await engine.saveSets(next)
      sets = next
      for set in next where statuses[set.id] == nil { await refresh(set) }
      for set in next { await refresh(set) }
      return true
    } catch { model?.errorMessage = error.localizedDescription; return false }
  }

  // MARK: Destination and items (folder panels)

  /// One folder for every checked tool. Tools backed up elsewhere before keep their snapshots there (History)
  /// and continue in the new folder; tools checked before any folder existed get their sets now.
  func chooseDestination() async {
    guard let url = Self.pickFolder(title: "Choose a backup folder", prompt: "Choose",
      start: folder ?? FileManager.default.homeDirectoryForCurrentUser) else { return }
    await useFolder(url)
  }

  func useFolder(_ url: URL) async {
    destination = url
    await save(BackupChecklist.move(sets, to: url))
    for source in checklistSources where pendingChecked.contains(source.id) {
      pendingChecked.remove(source.id)
      await createSet(for: source, destination: url)
    }
  }

  /// Check or uncheck a tool. Unchecking stops its schedule; snapshots and source files are never touched.
  func setChecked(_ source: CleanupSource, on: Bool) async {
    guard source.backupService != nil else { return }
    if on {
      guard set(for: source) == nil else { return }
      if let url = folder { await createSet(for: source, destination: url) } else { pendingChecked.insert(source.id) }
    } else {
      pendingChecked.remove(source.id)
      await save(BackupChecklist.retire(sets, tool: source.id))
    }
  }

  /// A shared setting changes for every checked tool at once.
  func changeShared(_ change: (inout SharedBackupSettings) -> Void) async {
    var next = shared
    change(&next)
    // Fail closed: the shown setting changes only after the sets are saved with it.
    if await save(Self.applying(next, to: sets)) { commitShared(next) }
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

  // MARK: Running

  var isBackingUp: Bool { runningSetID != nil }

  /// A scheduled run is silent on success: a message is only for an action the owner started.
  func backUpNow(_ set: BackupSet, scheduled: Bool = false) { backUpNow([set], scheduled: scheduled) }

  /// Backs up the sets one after another. The first run of a set copies everything; later runs copy what changed.
  func backUpNow(_ list: [BackupSet], scheduled: Bool = false) {
    guard runningSetID == nil, !isRestoring, let first = list.first else { return }
    runningSetID = first.id
    runPosition = (0, list.count)
    progress = nil
    let box = ProgressBox()
    runTask = Task { [weak self] in
      guard let self else { return }
      await self.syncProfiles()
      var files = 0, tools = 0
      var fresh: Int64 = 0
      var cancelled = false
      for (index, queued) in list.enumerated() {
        let set = self.sets.first { $0.id == queued.id } ?? queued
        self.runningSetID = set.id
        self.runPosition = (index, list.count)
        do {
          let snapshot = try await self.engine.snapshot(set) { [weak self] value in
            if box.shouldPublish() { Task { @MainActor in self?.progress = value } }
          }
          files += snapshot.files; fresh += snapshot.newBytes; tools += 1
        } catch is CancellationError {
          cancelled = true
        } catch {
          self.model?.errorMessage = list.count > 1 ? "\(set.name): \(error.localizedDescription)" : error.localizedDescription
        }
        self.progress = nil
        await self.refresh(set)
        if cancelled { break }
      }
      if !scheduled {
        if cancelled { self.model?.notice = "Backup cancelled." }
        else if tools > 0 {
          let each = tools > 1 ? "\(tools) tools: " : ""
          self.model?.notice = "Backed up \(each)\(files.formatted()) files. \(Self.size(fresh)) of new data."
        }
      }
      self.runningSetID = nil
      self.runPosition = (0, 0)
    }
  }

  func backUp(_ set: BackupSet, scheduled: Bool = false) async {
    backUpNow(set, scheduled: scheduled)
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
      model?.notice = text + "."
    } catch { model?.errorMessage = error.localizedDescription }
    await refresh(set)
  }

  /// Runs every set whose schedule is due, one at a time.
  func runDueBackups() async {
    for set in sets where set.schedule != .off && !set.retired {
      await refresh(set)
      guard let status = statuses[set.id], case .ready = status.state,
        let due = status.nextDue, due <= Date(), runningSetID == nil, !isRestoring else { continue }
      await backUp(set, scheduled: true)
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

private extension CleanupSource {
  func withDetail(_ detail: String) -> CleanupSource {
    CleanupSource(
      id: id, tool: tool, title: title, detail: detail, providerID: providerID, accountID: accountID,
      accountEmail: accountEmail, home: home, userHome: userHome, extraHomes: extraHomes)
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
