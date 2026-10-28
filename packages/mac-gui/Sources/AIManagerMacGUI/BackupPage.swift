import AIManagerCore
import AppKit
import SwiftUI

struct BackupRestoreRequest: Identifiable {
  let id = UUID()
  let snapshot: BackupSnapshot
  let set: BackupSet
}

/// Plain names for the preset paths of every tool. A path outside this list (one the owner added) has no name.
enum BackupLabels {
  static func name(_ path: String) -> String? {
    switch path {
    case "sessions", "projects", "session-state", "storage": "Conversations"
    case "archived_sessions": "Archived conversations"
    case "tmp": "Conversations and project data"
    case "config.toml", "settings.json": "Settings"
    case "AGENTS.md", "CLAUDE.md", "GEMINI.md": "Global instructions"
    case "prompts": "Custom prompts"
    case "rules": "Rules"
    case "commands": "Custom commands"
    case "agents": "Agents"
    case "droids": "Custom droids"
    case "skills": "Skills"
    case "extensions": "Extensions"
    case "plugins/installed_plugins.json": "Installed plugins"
    case "plugins/known_marketplaces.json": "Plugin marketplaces"
    case "backups": "Settings backups"
    case "history.jsonl": "Prompt history"
    case BackupSet.profilePrefix: "Claude Code profile folders"
    default: nil
    }
  }
}

/// What a checklist row says about a tool, so the page and its contract check read the same words.
enum BackupChecklistText {
  /// "Back up 3 tools now" (the count is the number of checked tools).
  static func button(_ count: Int) -> String { "Back up \(count) \(count == 1 ? "tool" : "tools") now" }

  /// What the tool's backup includes. Claude Code is one row: shared history plus every profile folder.
  static func included(_ source: CleanupSource) -> String {
    guard source.backupService != nil else { return "Not supported yet" }
    if source.tool == .claude {
      let profiles = source.extraHomes.count
      return profiles == 0 ? "Shared history" : "Shared history + \(profiles) \(profiles == 1 ? "profile" : "profiles")"
    }
    var names: [String] = []
    for item in source.backupItems where !item.isLogin {
      if let name = BackupLabels.name(item.path), !names.contains(name) { names.append(name) }
    }
    return names.prefix(3).joined(separator: ", ")
  }
}

/// The Backup tab: one checklist of every tool, the folder, schedule, and count they share, and History with Restore.
struct BackupPage: View {
  @ObservedObject var model: AccountViewModel
  @ObservedObject var store: MaintenanceStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var restoring: BackupRestoreRequest?
  @State private var free: Int64?

  private var hasAutomaticRecovery: Bool {
    model.status?.pendingRecovery.contains { $0.phase != .conflicted } == true
  }

  var body: some View {
    VStack(spacing: AIMTheme.cardGap) {
      if (!store.isLoaded || !model.hasLoaded) && store.checklistSources.isEmpty {
        AIMSection("What to back up") { AIMLoadingRows() }
      } else if store.checklistSources.isEmpty {
        AIMSection { Text("No supported tool was found on this Mac.").aimText(.secondary) }
      } else {
        checklistCard
        settingsCard
        historyCard
      }
      if model.status?.pendingRecovery.isEmpty == false { recoveryCard }
    }
    .task { store.start() }
    .task(id: store.checklistSources.map(\.id)) { await store.loadSizes() }
    .task(id: store.folder) {
      let folder = store.folder
      let available = await Task.detached(priority: .utility) {
        folder.flatMap { MaintenanceStore.freeSpace(at: $0) }
      }.value
      guard !Task.isCancelled else { return }
      free = available
    }
    .sheet(item: $restoring) { request in
      BackupRestoreSheet(request: request, store: store) { restoring = nil }
        .environment(\.aimCopyPath, model.copyPath)
        .tint(AIMTheme.passiveIcon)
    }
  }

  // MARK: What to back up

  private static let lastWidth: CGFloat = 150

  private var checklistCard: some View {
    let supported = store.checklistSources.filter { $0.backupService != nil }
    let checked = supported.filter { store.isChecked($0) }.count
    return AIMSection("What to back up", accessory: {
      Text("\(checked.formatted()) of \(supported.count.formatted()) checked").aimText(.secondary).monospacedDigit()
        .aimRolling(checked)
    }) {
      ForEach(store.checklistSources) { source in row(source) }
    }
  }

  private func row(_ source: CleanupSource) -> some View {
    let supported = source.backupService != nil
    let size = store.sizes[source.id].map(MaintenanceStore.size) ?? "Calculating…"
    let running = store.set(for: source).map { store.runningSetID == $0.id } ?? false
    return Toggle(isOn: Binding(
      get: { store.isChecked(source) },
      set: { on in Task { await store.setChecked(source, on: on) } })) {
      HStack(spacing: AIMTheme.rowSpacing) {
        ProviderMark(providerID: source.providerID, size: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(source.title).aimText(.body).lineLimit(1)
            .help(source.title)
          Text(supported ? "\(BackupChecklistText.included(source)) · \(size)" : BackupChecklistText.included(source))
            .aimText(.secondary).monospacedDigit().lineLimit(1).truncationMode(.tail)
            .help(supported ? "\(BackupChecklistText.included(source)) · \(size)" : BackupChecklistText.included(source))
        }
        Spacer(minLength: AIMTheme.rowSpacing)
        Group {
          if running { Badge(text: "Backing up", tint: AIMTheme.blue) }
          else if supported {
            Text(store.lastBackup(of: source).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never backed up")
              .aimText(.secondary).monospacedDigit().lineLimit(1)
              .help(store.lastBackup(of: source).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never backed up")
          }
        }
        .frame(width: Self.lastWidth, alignment: .trailing)
      }
    }
    .toggleStyle(AIMCheckboxToggleStyle())
    .disabled(!supported || store.isBackingUp)
    .accessibilityLabel(source.title)
  }

  // MARK: Folder, schedule, and run

  private var waiting: String? {
    for set in store.checkedSets {
      if case .waiting(let volume)? = store.status(for: set)?.state { return volume }
    }
    return nil
  }

  private var settingsCard: some View {
    let count = store.checkedSets.count + store.pendingChecked.count
    let folder = store.folder
    let running = store.isBackingUp
    return AIMSection("Folder and schedule", accessory: {
      if running { Badge(text: "Backing up", tint: AIMTheme.blue) }
      else if let waiting { Badge(text: "Waiting for \(waiting)", tint: AIMTheme.amber) }
      else if folder != nil { Badge(text: "Ready", tint: AIMTheme.green) }
    }) {
      LabeledContent {
        AIMButton(title: folder == nil ? "Choose a folder" : "Change", icon: .folder,
          tone: folder == nil ? .primary : .normal, disabled: store.isBackingUp) {
          Task { await store.chooseDestination() }
        }
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text("Backup folder").aimText(.body)
          if let folder {
            AIMCopyablePath(path: store.displayPath(folder))
            Text(waiting != nil
              ? "The drive is not connected. Backups wait for it."
              : (free.map { "\(MaintenanceStore.size($0)) free" } ?? "Free space unknown"))
              .aimText(.secondary).monospacedDigit()
          } else {
            Text("A drive or folder outside your tools. Nothing is copied yet.").aimText(.secondary)
          }
        }
      }
      LabeledContent {
        HStack(spacing: AIMTheme.rowSpacing) {
          AIMPopUp(
            options: [BackupSchedule.off, .daily, .weekly],
            selection: Binding(get: { store.shared.schedule }, set: { value in change { $0.schedule = value } }),
            accessibilityLabel: "Backup schedule", label: Self.scheduleName)
          AIMPopUp(
            options: [3, 5, 10, 20, 50],
            selection: Binding(get: { store.shared.keep }, set: { value in change { $0.keep = value } }),
            accessibilityLabel: "Backups to keep", label: { "Keep \($0)" })
        }
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text("Schedule").aimText(.body)
          Text(scheduleLine).aimText(.secondary).monospacedDigit()
        }
      }
      Toggle(isOn: Binding(get: { store.shared.promptsOnly == true }, set: { value in change { $0.promptsOnly = value } })) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Prompt-only backup").aimText(.body)
          Text("Save only your prompts as Markdown, grouped by project, with one file per conversation and an index. Responses, tools, login files, and settings stay out.")
            .aimText(.secondary)
        }
      }
      .disabled(running || store.isRestoring)
      Toggle(isOn: Binding(get: { store.shared.includeLogins && store.shared.promptsOnly != true }, set: { value in change { $0.includeLogins = value } })) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Include login files").aimText(.body)
          Text(store.shared.promptsOnly == true ? "Prompt-only backups always exclude login files."
            : "Off keeps sign-in files out. On, anyone who can read the backup folder can use your accounts, so keep the drive private.")
            .aimText(.secondary, tint: store.shared.includeLogins && store.shared.promptsOnly != true ? AIMTheme.amber : nil)
        }
      }
      .disabled(store.shared.promptsOnly == true)
      if running {
        HStack(spacing: AIMTheme.rowSpacing) {
          ProgressView().controlSize(.small)
          Text(progressLine).aimText(.secondary).monospacedDigit().lineLimit(1)
            .help(progressLine)
          Spacer()
          AIMButton(title: "Cancel") { store.cancelBackup() }
        }
        .transition(.opacity)
      } else {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            if let error = lastError {
              Text("Last error: \(error)").aimText(.secondary, tint: AIMTheme.amber).lineLimit(2)
                .help("Last error: \(error)")
            }
            Text(store.shared.promptsOnly == true
              ? "Prompt backups use this folder, schedule, and retention count. Restore exports them into a folder."
              : "The first backup copies everything. Later backups copy only what changed.").aimText(.secondary)
          }
          Spacer()
          AIMButton(title: BackupChecklistText.button(count), icon: .backup, tone: .primary,
            disabled: folder == nil || store.checkedSets.isEmpty || waiting != nil || store.isRestoring) {
              store.backUpNow(store.checkedSets)
            }
        }
      }
    }
  }

  private var lastError: String? { store.checkedSets.compactMap { store.status(for: $0)?.lastError }.first }

  private var progressLine: String {
    let running = store.sets.first { $0.id == store.runningSetID }
    let name = running.map { set in store.checklistSources.first { $0.id == set.toolKey }?.title ?? set.name } ?? ""
    let step = store.runPosition.count > 1 ? " (\(store.runPosition.index + 1) of \(store.runPosition.count))" : ""
    return "Backing up \(name)\(step) · \((store.progress?.files ?? 0).formatted()) files · \(MaintenanceStore.size(store.progress?.bytes ?? 0))"
  }

  private var scheduleLine: String {
    guard store.shared.schedule != .off else { return "Off. Back up when you choose." }
    guard let due = store.checkedSets.compactMap({ store.status(for: $0)?.nextDue }).min() else { return "Runs when Switch is open." }
    return due <= Date() ? "Due now. Runs while Switch is open." : "Next backup \(due.formatted(date: .abbreviated, time: .shortened))"
  }

  private static func scheduleName(_ schedule: BackupSchedule) -> String {
    switch schedule {
    case .off: "Schedule off"
    case .daily: "Every day"
    case .weekly: "Every week"
    }
  }

  private func change(_ edit: @escaping (inout SharedBackupSettings) -> Void) {
    Task { await store.changeShared(edit) }
  }

  // MARK: History

  private static let filesWidth: CGFloat = 72
  private static let sizeWidth: CGFloat = 88
  private static let stateWidth: CGFloat = 150
  private static let dateWidth: CGFloat = 200
  private static let actionWidth: CGFloat = 84
  private static let historyLimit = 20

  private var historyCard: some View {
    let all = store.history
    let rows = Array(all.prefix(Self.historyLimit))
    return AIMCard(title: "History", divider: true, scrolls: true, bottomInset: AIMTheme.tableEndInset, accessory: {
      Text("\(all.count.formatted()) kept").aimText(.secondary).monospacedDigit().aimRolling(all.count)
    }) {
      if !store.isLoaded && rows.isEmpty {
        AIMLoadingRows().padding(.bottom, AIMTheme.tableEndInset)
      } else if rows.isEmpty {
        Text(waiting != nil ? "Backups appear again when the drive is connected." : "No backups yet. Check a tool, then choose \(BackupChecklistText.button(store.checkedSets.count)).")
          .aimText(.secondary).padding(.horizontal, AIMTheme.cardInset).padding(.vertical, AIMTheme.contentInset)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(spacing: 0) {
          AIMTableRow {
            Text("Tool").frame(maxWidth: .infinity, alignment: .leading).help("Tool")
            Text("Date").frame(width: Self.dateWidth, alignment: .leading).help("Date")
            Text("Files").frame(width: Self.filesWidth, alignment: .trailing).help("Files")
            Text("Size").frame(width: Self.sizeWidth, alignment: .trailing).help("Size")
            Text("State").frame(width: Self.stateWidth, alignment: .leading).help("State")
            Color.clear.frame(width: Self.actionWidth, height: 1)
          }
          .aimText(.secondary)
          ForEach(rows) { row in
            AIMRowSeparator()
            historyRow(row)
              .transition(.opacity)
          }
        }
        .animation(reduceMotion ? nil : AIMMotion.fade(AIMMotion.appear), value: rows.map(\.id))
      }
    }
  }

  private func historyRow(_ row: BackupHistoryRow) -> some View {
    let snapshot = row.snapshot
    return AIMTableRow {
      HStack(spacing: AIMTheme.rowSpacing) {
        if let source = row.source { ProviderMark(providerID: source.providerID, size: 20) }
        Text(row.source?.title ?? row.set.name).aimText(.body).lineLimit(1)
          .help(row.source?.title ?? row.set.name)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(snapshot.date.formatted(date: .abbreviated, time: .shortened)).aimText(.body).monospacedDigit()
        .frame(width: Self.dateWidth, alignment: .leading)
        .help(snapshot.date.formatted(date: .abbreviated, time: .shortened))
      Text(snapshot.files.formatted()).aimText(.body).monospacedDigit()
        .frame(width: Self.filesWidth, alignment: .trailing)
        .help(snapshot.files.formatted())
      Text(MaintenanceStore.size(snapshot.totalBytes)).aimText(.body).monospacedDigit()
        .frame(width: Self.sizeWidth, alignment: .trailing)
        .help(MaintenanceStore.size(snapshot.totalBytes))
      HStack {
        if snapshot.manifest.safety { Badge(text: "Safety copy", tint: AIMTheme.amber) }
        else { Badge(text: snapshot.state == "Complete" ? (snapshot.manifest.promptsOnly == true ? "Prompts only" : "Complete") : "Some skipped",
          tint: snapshot.state == "Complete" ? AIMTheme.green : AIMTheme.amber) }
        Spacer(minLength: 0)
      }
      .frame(width: Self.stateWidth, alignment: .leading)
      AIMButton(title: "Restore", disabled: store.isBackingUp || store.isRestoring || waiting != nil) {
        restoring = BackupRestoreRequest(snapshot: snapshot, set: row.set)
      }
      .fixedSize()
      .frame(width: Self.actionWidth, alignment: .trailing)
    }
  }

  // MARK: Interrupted work

  private var recoveryCard: some View {
    AIMSection("Interrupted work") {
      if let operations = model.status?.pendingRecovery, !operations.isEmpty {
        ForEach(operations, id: \.id) { item in
          VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
            HStack(spacing: AIMTheme.sectionSpacing) {
              AIMIcon(name: .warning).aimText(.body).foregroundStyle(AIMTheme.amber)
              VStack(alignment: .leading, spacing: 2) {
                Text(item.kind.capitalized).aimText(.body)
                AIMCopyablePath(path: item.destination.path)
              }
              Spacer()
              WarningCopyButton(label: "Copy backup warning") {
                model.copyWarnings([
                  "Pending \(item.kind) operation (\(item.phase.rawValue))\nDestination: \(item.destination.path)"
                ])
              }
              Badge(text: item.phase.rawValue, tint: AIMTheme.amber)
            }
            if item.phase == .conflicted {
              HStack(spacing: 6) {
                Text("Both versions are protected. Choose which version to keep.").aimText(.secondary)
                Spacer()
                AIMButton(title: "Keep current", disabled: model.isBusy) {
                  Task { await model.resolveRecoveryConflict(item, choice: .preserveCurrent) }
                }
                AIMButton(title: "Restore backup", tone: .danger, disabled: model.isBusy) {
                  Task { await model.resolveRecoveryConflict(item, choice: .restoreBackup) }
                }
              }
            }
          }
        }
      }
      HStack {
        Text("Account imports that stopped part way can finish here.").aimText(.secondary)
        Spacer()
        AIMButton(title: "Finish pending work", icon: .backup, disabled: !hasAutomaticRecovery || model.isBusy) {
          Task { await model.recover() }
        }
      }
    }
  }
}

// MARK: - Restore sheet

/// Restore a whole backup or chosen items, back to the original place or into a new folder.
struct BackupRestoreSheet: View {
  let request: BackupRestoreRequest
  @ObservedObject var store: MaintenanceStore
  let close: () -> Void
  @State private var whole = true
  @State private var chosen: Set<String> = []
  @State private var inPlace = true
  @State private var folder: URL?

  private struct Group: Identifiable { let id: String; let files: Int; let bytes: Int64 }

  private var groups: [Group] {
    Dictionary(grouping: request.snapshot.manifest.entries, by: { String($0.path.split(separator: "/").first ?? "") })
      .map { Group(id: $0.key, files: $0.value.filter { $0.kind == .file }.count, bytes: $0.value.reduce(0) { $0 + $1.size }) }
      .filter { !$0.id.isEmpty }.sorted { $0.id < $1.id }
  }
  private static let visibleGroups = 6
  private static let groupRowHeight: CGFloat = 26
  private var promptBackup: Bool { request.snapshot.manifest.promptsOnly == true }
  private var ready: Bool { (whole || !chosen.isEmpty) && ((inPlace && !promptBackup) || folder != nil) && !store.isRestoring }

  var body: some View {
    VStack(spacing: 0) {
      // Not AIMSheetForm: its scroll view fills any height, and this sheet is as tall as its text.
      VStack(alignment: .leading, spacing: AIMTheme.sectionSpacing) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Restore a backup").aimText(.section)
          Text("\(request.set.name) · \(request.snapshot.date.formatted(date: .abbreviated, time: .shortened)) · \(request.snapshot.files.formatted()) files")
            .aimText(.secondary).monospacedDigit()
        }
        AIMSegmentedPicker(
          options: [true, false], selection: $whole, accessibilityLabel: "What to restore",
          label: { $0 ? "Whole backup" : "Chosen items" }, segmentWidth: 140)
        if !whole {
          let list = VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
            ForEach(groups) { group in
              Toggle(isOn: Binding(
                get: { chosen.contains(group.id) },
                set: { if $0 { chosen.insert(group.id) } else { chosen.remove(group.id) } })) {
                HStack {
                  Text(BackupLabels.name(group.id) ?? group.id).aimText(.body).lineLimit(1).truncationMode(.middle)
                    .help(BackupLabels.name(group.id) ?? group.id)
                  Spacer()
                  Text("\(group.files.formatted()) files · \(MaintenanceStore.size(group.bytes))")
                    .aimText(.secondary).monospacedDigit()
                }
              }
              .toggleStyle(AIMCheckboxToggleStyle())
            }
          }
          SwiftUI.Group {
            if groups.count > Self.visibleGroups {
              AIMScrollView { list }.frame(height: CGFloat(Self.visibleGroups) * Self.groupRowHeight)
            } else {
              list
            }
          }
          .transition(.opacity)
        }
        Divider()
        Text("Restore to").aimText(.section)
        if !promptBackup {
          AIMSegmentedPicker(
            options: [true, false], selection: $inPlace, accessibilityLabel: "Where to restore",
            label: { $0 ? "Original place" : "A folder" }, segmentWidth: 140)
        }
        if inPlace && !promptBackup {
          Text("Switch first saves a safety backup of the files it replaces. Newer files that are not in this backup stay where they are.")
            .aimText(.secondary)
        } else {
          HStack(spacing: AIMTheme.rowSpacing) {
            AIMButton(title: folder == nil ? "Choose a folder" : "Change", icon: .folder) {
              folder = MaintenanceStore.pickFolder(title: "Restore into a folder", prompt: "Restore", start: nil) ?? folder
            }
            if let folder { AIMCopyablePath(path: folder.path) }
          }
          Text("The original files are not touched.").aimText(.secondary)
        }
      }
      .padding(AIMTheme.pageMargin)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textFieldStyle(.plain).buttonStyle(AIMPushButtonStyle())
      .focusEffectDisabled(!AIMFocus.showsSystemRings)
      AIMHairline()
      HStack(spacing: AIMTheme.rowSpacing) {
        if store.isRestoring { ProgressView().controlSize(.small) }
        Spacer()
        AIMButton(title: "Cancel", disabled: store.isRestoring, action: close)
        AIMButton(title: "Restore", tone: .primary, disabled: !ready) {
          Task {
            await store.restore(
              request.snapshot, set: request.set, items: whole ? nil : chosen.sorted(), to: inPlace && !promptBackup ? nil : folder)
            close()
          }
        }
      }
      .padding(AIMTheme.cardInset)
    }
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
    .background(AIMTheme.page)
    .environment(\.aimCancelSheet, close)
    .animation(AIMMotion.fade(AIMMotion.state), value: whole)
    .animation(AIMMotion.fade(AIMMotion.state), value: inPlace)
  }
}
