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
    case "sessions", "projects": "Conversations"
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
    default: nil
    }
  }
}

/// The Backup tab: one backup set for the chosen source, its snapshots, restore, and recovery.
struct BackupPage: View {
  @ObservedObject var model: AccountViewModel
  @ObservedObject var store: MaintenanceStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var restoring: BackupRestoreRequest?
  @State private var free: Int64?

  private var source: CleanupSource? { store.source }
  private var set: BackupSet? { source.flatMap { store.set(for: $0) } }
  private var hasAutomaticRecovery: Bool {
    model.status?.pendingRecovery.contains { $0.phase != .conflicted } == true
  }

  var body: some View {
    VStack(spacing: AIMTheme.cardGap) {
      if let source {
        if source.backupService == nil {
          AIMSection {
            Text("Backup is not available for \(source.title) yet. Cleanup works for it.").aimText(.secondary)
          }
        } else if let set {
          setCards(set)
        } else {
          startCard(source)
        }
      } else {
        AIMSection { Text("No supported tool was found on this Mac.").aimText(.secondary) }
      }
      if model.status?.pendingRecovery.isEmpty == false { recoveryCard }
    }
    .task { store.start() }
    .task(id: set?.destination) {
      let destination = set?.destination
      let available = await Task.detached(priority: .utility) {
        destination.flatMap { MaintenanceStore.freeSpace(at: $0) }
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

  // MARK: No backup yet

  private func startCard(_ source: CleanupSource) -> some View {
    AIMSection("Back up \(source.title)") {
      Text("Switch copies the chats, settings, and rules of \(source.title) into a folder you choose. Files that did not change are linked to the earlier backup, so a repeat backup adds only what is new. Login files are left out unless you add them.")
        .aimText(.secondary)
      LabeledContent {
        AIMButton(title: "Choose a folder", icon: .folder, tone: .primary) {
          Task { await store.chooseDestination(for: source) }
        }
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text("Backup folder").aimText(.body)
          Text("A drive or folder outside \(source.title). Nothing is copied yet.").aimText(.secondary)
        }
      }
    }
  }

  // MARK: Backup set

  @ViewBuilder private func setCards(_ set: BackupSet) -> some View {
    let status = store.status(for: set)
    let running = store.runningSetID == set.id
    let waiting: String? = { if case .waiting(let volume)? = status?.state { return volume } else { return nil } }()
    AIMSection("\(set.name) backup", accessory: {
      if running { Badge(text: "Backing up", tint: AIMTheme.blue) }
      else if let waiting { Badge(text: "Waiting for \(waiting)", tint: AIMTheme.amber) }
      else { Badge(text: "Ready", tint: AIMTheme.green) }
    }) {
      LabeledContent {
        HStack(spacing: AIMTheme.rowSpacing) {
          AIMButton(title: "Change", icon: .folder, disabled: store.isBackingUp) {
            Task { await store.chooseDestination(for: source!) }
          }
        }
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text("Backup folder").aimText(.body)
          AIMCopyablePath(path: store.displayPath(set.destination))
          Text(waiting != nil
            ? "The drive is not connected. Backups wait for it."
            : (free.map { "\(MaintenanceStore.size($0)) free" } ?? "Free space unknown"))
            .aimText(.secondary).monospacedDigit()
        }
      }
      LabeledContent {
        HStack(spacing: AIMTheme.rowSpacing) {
          AIMPopUp(
            options: [BackupSchedule.off, .daily, .weekly],
            selection: Binding(get: { set.schedule }, set: { value in update(set) { $0.schedule = value } }),
            accessibilityLabel: "Backup schedule", label: Self.scheduleName)
          AIMPopUp(
            options: [3, 5, 10, 20, 50],
            selection: Binding(get: { set.keep }, set: { value in update(set) { $0.keep = value } }),
            accessibilityLabel: "Backups to keep", label: { "Keep \($0)" })
        }
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text("Schedule").aimText(.body)
          Text(scheduleLine(set, status)).aimText(.secondary).monospacedDigit()
        }
      }
      Toggle(isOn: Binding(get: { set.includeLogins }, set: { value in update(set) { $0.includeLogins = value } })) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Include login files").aimText(.body)
          Text("Off keeps sign-in files out. On, anyone who can read the backup folder can use your accounts, so keep the drive private.")
            .aimText(.secondary, tint: set.includeLogins ? AIMTheme.amber : nil)
        }
      }
      if running {
        HStack(spacing: AIMTheme.rowSpacing) {
          ProgressView().controlSize(.small)
          Text("\((store.progress?.files ?? 0).formatted()) files · \(MaintenanceStore.size(store.progress?.bytes ?? 0))")
            .aimText(.secondary).monospacedDigit().aimRolling(store.progress?.files ?? 0)
          Spacer()
          AIMButton(title: "Cancel") { store.cancelBackup() }
        }
        .transition(.opacity)
      } else {
        HStack {
          Text(status?.lastError.map { "Last error: \($0)" } ?? "Backups never change or delete the source files.")
            .aimText(.secondary, tint: status?.lastError == nil ? nil : AIMTheme.amber)
          Spacer()
          AIMButton(title: "Back Up Now", icon: .backup, tone: .primary,
            disabled: waiting != nil || store.isBackingUp || store.isRestoring || set.items.isEmpty) {
              store.backUpNow(set)
            }
        }
      }
    }
    itemsCard(set)
    snapshotsCard(set, status: status, waiting: waiting)
  }

  private func scheduleLine(_ set: BackupSet, _ status: BackupStatus?) -> String {
    guard set.schedule != .off else { return "Off. Back up when you choose." }
    guard let due = status?.nextDue else { return "Runs when Switch is open." }
    return due <= Date() ? "Due now. Runs while Switch is open." : "Next backup \(due.formatted(date: .abbreviated, time: .shortened))"
  }

  private static func scheduleName(_ schedule: BackupSchedule) -> String {
    switch schedule {
    case .off: "Schedule off"
    case .daily: "Every day"
    case .weekly: "Every week"
    }
  }

  private func update(_ set: BackupSet, _ change: (inout BackupSet) -> Void) {
    var next = set
    change(&next)
    Task { await store.update(next) }
  }

  // MARK: What to back up

  private func itemsCard(_ set: BackupSet) -> some View {
    let presets = (source?.backupItems ?? []).filter { !$0.isLogin }.map(\.path)
    let custom = set.items.filter { !$0.isLogin }.map(\.path).filter { !presets.contains($0) }
    return AIMSection("What to back up") {
      ForEach(presets + custom, id: \.self) { path in
        let on = set.items.contains { $0.path == path }
        Toggle(isOn: Binding(get: { on }, set: { enabled in
          update(set) { next in
            if enabled { next.items.append(BackupItem(path, isLogin: BackupPresets.isLogin(path))) }
            else { next.items.removeAll { $0.path == path } }
          }
        })) {
          HStack(spacing: AIMTheme.rowSpacing) {
            if let name = BackupLabels.name(path) {
              Text(name).aimText(.body).lineLimit(1)
              Text(path).aimText(.secondary, monospaced: true).lineLimit(1).truncationMode(.middle)
            } else {
              Text(path).aimText(.body).lineLimit(1).truncationMode(.middle)
            }
            if custom.contains(path) { Badge(text: "Added", tint: AIMTheme.blue) }
            Spacer(minLength: 0)
          }
        }
        .toggleStyle(AIMCheckboxToggleStyle())
        .disabled(store.isBackingUp)
      }
      HStack {
        Text("Paths are inside \(set.source.home.lastPathComponent). Add anything else from there.").aimText(.secondary)
        Spacer()
        AIMButton(title: "Add file or folder", icon: .plus, disabled: store.isBackingUp) {
          Task { await store.addItem(to: set) }
        }
      }
    }
  }

  // MARK: Snapshots

  private static let filesWidth: CGFloat = 72
  private static let sizeWidth: CGFloat = 88
  private static let stateWidth: CGFloat = 150
  private static let actionWidth: CGFloat = 84

  private func snapshotsCard(_ set: BackupSet, status: BackupStatus?, waiting: String?) -> some View {
    let snapshots = (status?.snapshots ?? []).sorted { $0.date > $1.date }
    return AIMCard(title: "Backups", divider: true, scrolls: true, bottomInset: AIMTheme.tableEndInset, accessory: {
      Text("\(snapshots.count.formatted()) kept").aimText(.secondary).monospacedDigit().aimRolling(snapshots.count)
    }) {
      if snapshots.isEmpty {
        Text(waiting != nil ? "Backups appear again when the drive is connected." : "No backups yet. Choose Back Up Now.")
          .aimText(.secondary).padding(.horizontal, AIMTheme.cardInset).padding(.vertical, AIMTheme.contentInset)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(spacing: 0) {
          AIMTableRow {
            Text("Date").frame(maxWidth: .infinity, alignment: .leading)
            Text("Files").frame(width: Self.filesWidth, alignment: .trailing)
            Text("Total").frame(width: Self.sizeWidth, alignment: .trailing)
            Text("New data").frame(width: Self.sizeWidth, alignment: .trailing)
            Text("State").frame(width: Self.stateWidth, alignment: .leading)
            Color.clear.frame(width: Self.actionWidth, height: 1)
          }
          .aimText(.secondary)
          ForEach(snapshots) { snapshot in
            AIMRowSeparator()
            AIMTableRow {
              Text(snapshot.date.formatted(date: .abbreviated, time: .shortened)).aimText(.body).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
              Text(snapshot.files.formatted()).aimText(.body).monospacedDigit()
                .frame(width: Self.filesWidth, alignment: .trailing)
              Text(MaintenanceStore.size(snapshot.totalBytes)).aimText(.body).monospacedDigit()
                .frame(width: Self.sizeWidth, alignment: .trailing)
              Text(MaintenanceStore.size(snapshot.newBytes)).aimText(.body).monospacedDigit()
                .frame(width: Self.sizeWidth, alignment: .trailing)
              HStack {
                if snapshot.manifest.safety { Badge(text: "Safety copy", tint: AIMTheme.amber) }
                else { Badge(text: snapshot.state == "Complete" ? "Complete" : "Some skipped",
                  tint: snapshot.state == "Complete" ? AIMTheme.green : AIMTheme.amber) }
                Spacer(minLength: 0)
              }
              .frame(width: Self.stateWidth, alignment: .leading)
              AIMButton(title: "Restore", disabled: store.isBackingUp || store.isRestoring || waiting != nil) {
                restoring = BackupRestoreRequest(snapshot: snapshot, set: set)
              }
              .fixedSize()
              .frame(width: Self.actionWidth, alignment: .trailing)
            }
            .transition(.opacity)
          }
        }
        .animation(reduceMotion ? nil : AIMMotion.fade(AIMMotion.appear), value: snapshots.map(\.id))
      }
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
  private var ready: Bool { (whole || !chosen.isEmpty) && (inPlace || folder != nil) && !store.isRestoring }

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
        AIMSegmentedPicker(
          options: [true, false], selection: $inPlace, accessibilityLabel: "Where to restore",
          label: { $0 ? "Original place" : "A folder" }, segmentWidth: 140)
        if inPlace {
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
              request.snapshot, set: request.set, items: whole ? nil : chosen.sorted(), to: inPlace ? nil : folder)
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
