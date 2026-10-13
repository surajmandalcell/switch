import AIManagerCore
import AppKit
import SwiftUI

private struct CleanupPage: View {
  @ObservedObject var model: AccountViewModel
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  @State private var sizes = RebuildableCacheSizes(usageBytes: 0, conversationBytes: 0)
  @State private var conversations: [CleanupConversation] = []
  @State private var samples: [CleanupUsageSample] = []
  @State private var trash: [ConversationCleanupBatch] = []
  @State private var selectedConversations: Set<String> = []
  @State private var selectedSamples: Set<Int64> = []
  @State private var clearIndex = false
  @State private var range: CleanupDateRange = .olderMonth
  @State private var from = Date().addingTimeInterval(-30 * 86_400)
  @State private var through = Date()
  @State private var anchor = Date()
  @State private var loading = false
  @State private var error: String?
  @State private var review: CleanupReview?
  @State private var confirming = false
  @State private var removingBatch: ConversationCleanupBatch?
  private var unavailable: Bool { loading || model.isBusy }
  private var visibleConversations: [CleanupConversation] {
    conversations.filter { range.contains($0.updatedAt, now: anchor, from: from, through: through) }
  }
  private var visibleSamples: [CleanupUsageSample] {
    samples.filter { range.contains($0.fetchedAt, now: anchor, from: from, through: through) }
  }

  var body: some View {
    VStack(spacing: AIMTheme.cardGap) {
      AIMSection {
        HStack(spacing: AIMTheme.sectionSpacing) {
          CleanupRangeSelect(selection: $range).disabled(unavailable)
          if range == .custom {
            AIMDateField(title: "From", selection: $from)
            AIMDateField(title: "Through", selection: $through, after: from)
          }
          Spacer(minLength: 0)
          if loading { ProgressView().controlSize(.small) }
          AIMButton(title: "Reload", icon: .refresh, disabled: unavailable) { Task { await reload() } }
        }
      }
      AIMSection("Conversations", accessory: {
        Text("\(visibleConversations.count.formatted()) conversations · Shared · Codex CLI")
          .aimText(.secondary)
      }) {
        if visibleConversations.isEmpty {
          HStack {
            Text("No conversations match this time range.").aimText(.secondary)
            Spacer()
            if range != .all {
              AIMButton(title: "Show all") { range = .all }
            }
          }
        } else {
          Text("Choose projects or conversations. Dates use their last update.")
            .aimText(.secondary)
          if visibleConversations.contains(where: { !$0.archived }) {
            conversationTree(archived: false)
          }
          if visibleConversations.contains(where: \.archived) {
            conversationTree(archived: true)
          }
        }
      }
      .disabled(unavailable)
      AIMSection("Cached data", accessory: {
        Text("\(visibleSamples.count.formatted()) samples").aimText(.secondary)
      }) {
        DisclosureGroup("Usage history by account") {
          let grouped = Dictionary(grouping: visibleSamples, by: \.accountID)
          VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
            ForEach(grouped.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { accountID in
              let entries = grouped[accountID] ?? []
              let name = EmailPrivacy.display(
                model.status?.accounts.first { $0.id == accountID }?.identity.email ?? accountID.uuidString,
                hide: hideEmails)
              Toggle("\(name) · \(entries.count.formatted()) samples · \(sizeText(entries.reduce(0) { $0 + $1.bytes }))", isOn: Binding(
                get: { entries.allSatisfy { selectedSamples.contains($0.id) } },
                set: { enabled in
                  let ids = Set(entries.map(\.id))
                  if enabled { selectedSamples.formUnion(ids) } else { selectedSamples.subtract(ids) }
                  review = nil
                })).toggleStyle(AIMCheckboxToggleStyle()).frame(maxWidth: .infinity, alignment: .leading)
            }
            if visibleSamples.isEmpty { Text("No cached samples in this date range.").aimText(.secondary) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        Toggle("Shared conversation index · \(sizeText(sizes.conversationBytes))", isOn: $clearIndex)
          .toggleStyle(AIMCheckboxToggleStyle()).disabled(range != .all || sizes.conversationBytes == 0)
          .help("Choose All time to clear search metadata. This index rebuilds when Chat History opens.")
        Text("Caches rebuild when needed. Daily activity stays saved.")
          .aimText(.secondary)
      }
      .disabled(unavailable)
      AIMSection {
        let protectedCount = conversations.filter { $0.exclusionReason != nil }.count
        if protectedCount > 0 {
          HStack(spacing: 6) {
            AIMIcon(name: .info)
            Text("\(protectedCount.formatted()) \(protectedCount == 1 ? "file is" : "files are") protected.")
          }.aimText(.secondary)
            .help("Linked or foreign-owned files cannot be removed. Other conversations remain selectable.")
        }
        HStack {
          Text("Selected").aimText(.body)
          Text(selectedConversations.isEmpty && selectedSamples.isEmpty && !clearIndex
            ? "Choose items to review."
            : "\(selectedConversations.count.formatted()) conversations · \(selectedSamples.count.formatted()) samples\(clearIndex ? " · index" : "")")
            .aimText(.secondary).monospacedDigit()
          Spacer()
          AIMButton(title: "Review selection", tone: .primary,
            disabled: unavailable || (selectedConversations.isEmpty && selectedSamples.isEmpty && !clearIndex)) {
              Task { await makeReview() }
            }
        }
      }
      if let review {
        AIMSection("Review before cleanup") {
          if let plan = review.plan {
            Text("\(plan.conversations.count) conversations · \(sizeText(plan.bytes)) to recoverable trash")
          }
          if !review.samples.isEmpty {
            Text("\(review.samples.count) cache samples · \(sizeText(review.samples.reduce(0) { $0 + $1.bytes })) of cached payloads")
          }
          if review.clearIndex { Text("Clear the shared conversation index (\(sizeText(sizes.conversationBytes)))") }
          Text("\(range.rawValue). Moving conversations does not free disk space. Cached payload bytes exclude database overhead.")
            .aimText(.secondary)
          if let plan = review.plan {
            DisclosureGroup("Selected conversations") {
              AIMVirtualList(items: plan.conversations, fixedRowHeight: 32) { item in
                AnyView(HStack {
                  AIMCopyablePath(path: item.relativePath).help(item.title)
                  Spacer()
                  Text(sizeText(item.bytes)).aimText(.secondary).monospacedDigit()
                }.padding(.horizontal, 4))
              }.frame(height: min(CGFloat(plan.conversations.count) * 32, 192))
            }
          }
          if !review.samples.isEmpty {
            DisclosureGroup("Selected cache samples") {
              AIMVirtualList(items: review.samples, fixedRowHeight: 30) { sample in
                AnyView(HStack {
                  Text(EmailPrivacy.display(
                    model.status?.accounts.first { $0.id == sample.accountID }?.identity.email
                      ?? sample.accountID.uuidString, hide: hideEmails))
                    .aimText(.body).lineLimit(1)
                  Spacer()
                  Text(sample.fetchedAt.formatted()).aimText(.secondary).monospacedDigit()
                }.padding(.horizontal, 4))
              }.frame(height: min(CGFloat(review.samples.count) * 30, 180))
            }
          }
          HStack {
            AIMButton(title: "Cancel") { self.review = nil }
            Spacer()
            AIMButton(title: "Confirm cleanup", tone: .primary, disabled: unavailable) { confirming = true }
          }
        }
      }
      if !trash.isEmpty {
        AIMSection("Recoverable conversation trash") {
          ForEach(trash) { batch in
            HStack(spacing: AIMTheme.sectionSpacing) {
              VStack(alignment: .leading, spacing: 2) {
                Text("\(batch.conversations.count.formatted()) conversations · \(sizeText(batch.bytes))")
                Text(batch.createdAt.formatted()).aimText(.secondary).monospacedDigit()
              }
              Spacer()
              AIMButton(title: "Restore", disabled: unavailable) { Task { await restore(batch) } }
              AIMButton(title: "Remove permanently", disabled: unavailable) { removingBatch = batch }
            }
          }
        }
      }
      AIMSection {
        Text("Account access, settings, backups, and saved activity stay unchanged.")
          .aimText(.secondary)
        if let error { Notice(text: error, tone: AIMTheme.amber) }
        if let notice = model.notice { Notice(text: notice, tone: AIMTheme.blue) }
      }
    }
    .task { await reload() }
    .onChange(of: range) { _, _ in resetSelection() }
    .onChange(of: from) { _, _ in resetSelection() }
    .onChange(of: through) { _, _ in resetSelection() }
    .onChange(of: clearIndex) { _, _ in review = nil }
    .alert("Apply reviewed cleanup?", isPresented: $confirming) {
      Button("Cancel", role: .cancel) {}
      Button("Apply cleanup") { Task { await apply() } }
    } message: { Text("Selected conversations move to recoverable trash. Selected cache records are cleared. Daily activity totals remain saved.") }
    .alert("Permanently remove conversation trash?", isPresented: Binding(
      get: { removingBatch != nil }, set: { if !$0 { removingBatch = nil } }), presenting: removingBatch) { batch in
      Button("Cancel", role: .cancel) { removingBatch = nil }
      Button("Remove permanently", role: .destructive) {
        Task { await remove(batch) }
      }
    } message: { batch in Text("\(batch.conversations.count) conversations will be removed from trash. This cannot be undone.") }
  }

  private func conversationTree(archived: Bool) -> some View {
    let entries = visibleConversations.filter { $0.archived == archived }
    let grouped = Dictionary(grouping: entries, by: \.project)
    return DisclosureGroup(archived ? "Archived conversations (\(entries.count.formatted()))" : "Active conversations (\(entries.count.formatted()))") {
      VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
        ForEach(grouped.keys.sorted(), id: \.self) { project in
          let projectEntries = grouped[project] ?? []
          let selectable = projectEntries.filter { $0.exclusionReason == nil }
          DisclosureGroup {
            AIMVirtualList(items: projectEntries, fixedRowHeight: 34) { item in
              AnyView(HStack(spacing: AIMTheme.rowSpacing) {
                Toggle(item.title, isOn: Binding(
                  get: { selectedConversations.contains(item.id) },
                  set: { enabled in
                    if enabled { selectedConversations.insert(item.id) } else { selectedConversations.remove(item.id) }
                    review = nil
                  })).toggleStyle(AIMCheckboxToggleStyle()).lineLimit(1)
                  .disabled(item.exclusionReason != nil).help(item.exclusionReason ?? item.relativePath)
                Spacer(minLength: 4)
                Text(item.updatedAt.formatted(date: .abbreviated, time: .omitted))
                  .aimText(.secondary).monospacedDigit()
                Text(sizeText(item.bytes)).aimText(.secondary).monospacedDigit()
                  .frame(width: 80, alignment: .trailing)
              }.padding(.horizontal, 4))
            }.frame(height: min(CGFloat(projectEntries.count) * 34, 204))
          } label: {
            Toggle("\(URL(fileURLWithPath: project).lastPathComponent) (\(projectEntries.count.formatted()))", isOn: Binding(
              get: { !selectable.isEmpty && selectable.allSatisfy { selectedConversations.contains($0.id) } },
              set: { enabled in
                let ids = Set(selectable.map(\.id))
                if enabled { selectedConversations.formUnion(ids) } else { selectedConversations.subtract(ids) }
                review = nil
              })).toggleStyle(AIMCheckboxToggleStyle()).disabled(selectable.isEmpty).help(project)
                .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        if entries.isEmpty { Text("No conversations in this date range.").aimText(.secondary) }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func resetSelection() {
    selectedConversations = []
    selectedSamples = []
    clearIndex = false
    review = nil
  }
  private func reload() async {
    loading = true
    defer { loading = false }
    error = nil
    do {
      let data = try await model.cleanupData()
      conversations = data.conversations
      samples = data.samples
      trash = data.trash
      sizes = await model.rebuildableCacheSizes()
      anchor = Date()
      resetSelection()
    } catch { self.error = error.localizedDescription }
  }
  private func makeReview() async {
    loading = true
    defer { loading = false }
    error = nil
    do {
      let selected = visibleConversations.filter { selectedConversations.contains($0.id) }
      let plan = selected.isEmpty ? nil : try await model.reviewConversationCleanup(selected)
      review = CleanupReview(plan: plan, samples: visibleSamples.filter { selectedSamples.contains($0.id) }, clearIndex: clearIndex)
    } catch { self.error = error.localizedDescription }
  }
  private func apply() async {
    guard let review else { return }
    do {
      try await model.applyCleanup(review.plan, samples: review.samples, clearIndex: review.clearIndex)
      self.review = nil
      await reload()
    } catch {
      self.review = nil
      await reload()
      self.error = "\(error.localizedDescription) Review again. Files already in trash can be restored."
    }
  }
  private func restore(_ batch: ConversationCleanupBatch) async {
    do { try await model.restoreCleanup(batch.id); await reload() }
    catch { self.error = error.localizedDescription }
  }
  private func remove(_ batch: ConversationCleanupBatch) async {
    removingBatch = nil
    do { try await model.emptyCleanup(batch.id); await reload() }
    catch { self.error = error.localizedDescription }
  }

  private func sizeText(_ bytes: Int64) -> String {
    bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

private struct CleanupReview {
  let plan: ConversationCleanupPlan?
  let samples: [CleanupUsageSample]
  let clearIndex: Bool
}

/// The Cleanup time range: a native pop-up button.
struct CleanupRangeSelect: View {
  @Binding var selection: CleanupDateRange

  var body: some View {
    AIMPopUp(
      options: CleanupDateRange.allCases, selection: $selection, accessibilityLabel: "Time range",
      separatorAfter: [.month, .olderYear], label: \.rawValue)
      .accessibilityIdentifier("cleanup-time-range")
  }
}

enum CleanupDateRange: String, CaseIterable, Identifiable {
  case hour = "Last hour", day = "Last 24 hours", week = "Last 7 days", month = "Last 4 weeks"
  case olderWeek = "Older than 7 days", olderMonth = "Older than 30 days", olderYear = "Older than 1 year"
  case all = "All time", custom = "Custom dates"
  var id: String { rawValue }
  func contains(_ date: Date, now: Date, from: Date, through: Date) -> Bool {
    if self == .all { return true }
    if self == .custom {
      let start = Calendar.current.startOfDay(for: from)
      let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: through)) ?? through
      return start <= date && date < end
    }
    let seconds: TimeInterval
    switch self {
    case .hour: seconds = 3_600
    case .day: seconds = 86_400
    case .week, .olderWeek: seconds = 7 * 86_400
    case .month: seconds = 28 * 86_400
    case .olderMonth: seconds = 30 * 86_400
    case .olderYear: seconds = 365 * 86_400
    case .all, .custom: return false
    }
    let cutoff = now.addingTimeInterval(-seconds)
    return [.olderWeek, .olderMonth, .olderYear].contains(self) ? date < cutoff : cutoff <= date && date <= now
  }
}

private struct BackupPage: View {
  @ObservedObject var model: AccountViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var hasAutomaticRecovery: Bool {
    model.status?.pendingRecovery.contains { $0.phase != .conflicted } == true
  }
  var body: some View {
    VStack(spacing: AIMTheme.cardGap) {
      AIMSection("Pending operations") {
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
                  Text("Both versions are protected. Choose which version to keep.")
                    .aimText(.secondary)
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
        } else {
          Text("No interrupted backup work needs attention.").aimText(.secondary)
        }
      }
      AIMSection("Backup policy") {
        DetailRow(
          label: "Before import", value: "Review destination, conflicts, and required space")
        DetailRow(
          label: "During import", value: "Back up, stage, verify, then publish")
        DetailRow(
          label: "On failure", value: "Keep prior credentials and preserve a backup journal")
      }
      AIMSection {
        LabeledContent {
          AIMButton(
            title: "Finish pending work", icon: .backup, tone: .primary,
            disabled: !hasAutomaticRecovery || model.isBusy
          ) { Task { await model.recover() } }
        } label: {
          Text("Backups never delete source data.").aimText(.secondary)
        }
      }
      #if AI_MANAGER_PREVIEW
      if model.isDemo { BackupExamples(model: model) }
      #endif
      if let notice = model.notice {
        AIMSection { Notice(text: notice, tone: AIMTheme.blue) }
          .transition(reduceMotion ? .identity : .opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.notice)
  }
}

/// Maintenance: Cleanup first, then backup and recovery.
enum MaintenanceSection: String, CaseIterable {
  case cleanup = "Cleanup"
  case backup = "Backup"
}

struct MaintenancePage: View {
  @ObservedObject var model: AccountViewModel
  @Binding var section: MaintenanceSection

  var body: some View {
    // One scrolling page at full content width: the picker sits on the card edge, then the cards.
    AIMScrollPage {
      HStack {
        AIMSegmentedPicker(
          options: MaintenanceSection.allCases, selection: $section,
          accessibilityLabel: "Maintenance section", label: \.rawValue, segmentWidth: 120,
          icon: { $0 == .cleanup ? .cleanup : .backup })
          .uiLint(.align("cards-start", .start))
        Spacer(minLength: 0)
      }
      switch section {
      case .backup: BackupPage(model: model)
      case .cleanup: CleanupPage(model: model)
      }
    }
    // Each tab remembers its own scroll position.
    .environment(\.aimPageName, "maintenance-\(section.rawValue)")
  }
}

#if AI_MANAGER_PREVIEW
private struct BackupExamples: View {
  @ObservedObject var model: AccountViewModel
  var body: some View {
    AIMSection("Backup examples") {
      BackupExampleRow(
        title: "Regular conversation", detail: "Complete snapshot before replacement",
        location: "~/Documents/Switch Backups", state: "Ready", color: AIMTheme.green)
      BackupExampleRow(
        title: "Incremental", detail: "Only changes since the last snapshot",
        location: "Local backup set · 18 MB", state: "Current", color: AIMTheme.blue)
      BackupExampleRow(
        title: "Custom location", detail: "A selected folder outside the default backup location",
        location: "/Volumes/Studio Archive/Codex", state: "Available", color: AIMTheme.green)
      BackupExampleRow(
        title: "External drive", detail: "The selected backup volume is disconnected",
        location: "/Volumes/Field SSD/Codex", state: "Offline", color: AIMTheme.amber)
      HStack(spacing: AIMTheme.rowSpacing) {
        Spacer()
        AIMButton(title: "Wait for drive") {
          model.notice = "Demo backup paused until Field SSD reconnects."
        }
        AIMButton(title: "Back up elsewhere", icon: .folder) {
          model.notice = "Demo destination changed. No folder picker was opened."
        }
      }
    }
  }
}

private struct BackupExampleRow: View {
  let title: String, detail: String, location: String, state: String, color: Color
  var body: some View {
    HStack(spacing: AIMTheme.sectionSpacing) {
      AIMIcon(name: .backup).aimText(.body).foregroundStyle(color)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).aimText(.body)
        Text(detail).aimText(.secondary)
      }
      Spacer(minLength: AIMTheme.sectionSpacing)
      Text(location).aimText(.secondary, monospaced: true).lineLimit(1)
        .truncationMode(.middle).textSelection(.enabled).help(location)
      Badge(text: state, tint: color)
    }
  }
}
#endif

// MARK: - Card 5: maintenance

struct MaintenanceStatusCard: View {
  @ObservedObject var model: AccountViewModel
  let openBackup: () -> Void

  private var pending: Int { model.status?.pendingRecovery.count ?? 0 }

  var body: some View {
    AIMCard(title: "Maintenance", divider: true, bottomInset: 0) {
      HStack(spacing: 12) {
        ZStack {
          Circle().fill(pending == 0 ? AIMTheme.green : AIMTheme.yellow).frame(width: 28, height: 28)
            .uiLint(.item)
          Image(systemName: pending == 0 ? "checkmark" : "exclamationmark")
            .aimFont(.section).foregroundStyle(.white)
        }
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(pending == 0 ? "All systems operational" : "Backup work is pending").aimText(.body)
          Text(pending == 0
            ? "No pending backup work."
            : "\(pending) interrupted \(pending == 1 ? "operation needs" : "operations need") attention.")
            .aimText(.secondary)
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: AIMTheme.rowSpacing)
        Button(action: openBackup) {
          Label("Open Backup", systemImage: AIMIcon.Name.database.symbol)
        }
        .buttonStyle(AIMPushButtonStyle())
      }
      .padding(.horizontal, AIMTheme.cardInset)
      // The title text sits 14 pt below the top edge; the content ends 14 pt above the bottom.
      .padding(.vertical, 14)
    }
  }
}
