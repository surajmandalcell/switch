import AIManagerCore
import AppKit
import SwiftUI

/// Maintenance: Cleanup and Backup, both acting on one chosen source.
enum MaintenanceSection: String, CaseIterable {
  case cleanup = "Cleanup"
  case backup = "Backup"
}

struct MaintenancePage: View {
  @ObservedObject var model: AccountViewModel
  @ObservedObject private var store: MaintenanceStore
  @Binding var section: MaintenanceSection

  init(model: AccountViewModel, section: Binding<MaintenanceSection>) {
    self.model = model
    _store = ObservedObject(wrappedValue: model.maintenance)
    _section = section
  }

  var body: some View {
    // One scrolling page at full content width: the bar sits on the card edges, then the cards.
    AIMScrollPage {
      HStack(spacing: AIMTheme.sectionSpacing) {
        AIMSegmentedPicker(
          options: MaintenanceSection.allCases, selection: $section,
          accessibilityLabel: "Maintenance section", label: \.rawValue, segmentWidth: 120,
          icon: { $0 == .cleanup ? .cleanup : .backup })
          .uiLint(.align("cards-start", .start))
        Spacer(minLength: 0)
        MaintenanceSourcePicker(store: store, cleanup: section == .cleanup)
          .uiLint(.align("cards-end", .end))
      }
      switch section {
      case .backup: BackupPage(model: model, store: store)
      case .cleanup: CleanupPage(model: model, store: store)
      }
    }
    // Each tab remembers its own scroll position.
    .environment(\.aimPageName, "maintenance-\(section.rawValue)")
    .task { store.start() }
    .onAppear { consumeRequest() }
    .onChange(of: store.wantsBackupTab) { _, _ in consumeRequest() }
  }

  private func consumeRequest() {
    guard store.wantsBackupTab else { return }
    store.wantsBackupTab = false
    section = .backup
  }
}

// MARK: - Source picker

/// The button at the right end of the tab bar: the chosen source, and a searchable list of the others.
struct MaintenanceSourcePicker: View {
  @ObservedObject var store: MaintenanceStore
  /// Cleanup lists Claude Code once; Backup also lists each account's own profile.
  var cleanup = false
  @State private var open = false

  var body: some View {
    Button { open.toggle() } label: {
      HStack(spacing: 8) {
        if let source = cleanup ? store.cleanupSource : store.source {
          ProviderMark(providerID: source.providerID, size: 18)
          Text(source.title).lineLimit(1)
          if source.accountID != nil { Text("profile").aimText(.secondary) }
        } else {
          Text("No source found")
        }
        Image(systemName: "chevron.up.chevron.down").aimFont(.secondary).foregroundStyle(.secondary)
      }
    }
    .buttonStyle(AIMPushButtonStyle())
    .disabled(store.sources.isEmpty)
    .accessibilityLabel("Source")
    .accessibilityValue((cleanup ? store.cleanupSource : store.source)?.title ?? "None")
    .popover(isPresented: $open, arrowEdge: .bottom) {
      MaintenanceSourcePanel(store: store, cleanup: cleanup) { source in
        store.sourceID = source.id
        open = false
      }
    }
  }
}

/// The list in the picker: a search field on top, then one row for each source.
struct MaintenanceSourcePanel: View {
  @ObservedObject var store: MaintenanceStore
  var cleanup = false
  let pick: (CleanupSource) -> Void
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  @State private var query = ""
  @FocusState private var focused: Bool

  static let width: CGFloat = 380
  static let rowHeight: CGFloat = 48

  private var choices: [CleanupSource] { cleanup ? store.cleanupSources : store.sources }
  private var chosen: CleanupSource? { cleanup ? store.cleanupSource : store.source }

  private var shown: [CleanupSource] {
    let text = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !text.isEmpty else { return choices }
    return choices.filter { source in
      [source.title, source.detail, source.accountEmail ?? ""].contains { $0.lowercased().contains(text) }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").aimFont(.body).foregroundStyle(.secondary).accessibilityHidden(true)
        TextField("Search sources", text: $query).textFieldStyle(.plain).focused($focused)
          .accessibilityLabel("Search sources")
        if !query.isEmpty {
          Button { query = "" } label: { Image(systemName: "xmark.circle.fill").aimFont(.body) }
            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
        }
      }
      .aimFieldChrome(focused: focused)
      .padding(8)
      AIMHairline()
      if shown.isEmpty {
        Text("No source matches.").aimText(.secondary).frame(maxWidth: .infinity, minHeight: Self.rowHeight)
      } else {
        AIMScrollView {
          VStack(spacing: 0) { ForEach(shown) { row($0) } }.padding(.vertical, 4)
        }
        .frame(height: min(CGFloat(shown.count), 7) * Self.rowHeight + 8)
      }
    }
    .frame(width: Self.width)
    .background(AIMTheme.page)
    .onAppear { focused = true }
  }

  private func row(_ source: CleanupSource) -> some View {
    PickerRow(selected: source.id == chosen?.id) { pick(source) } content: {
      ProviderMark(providerID: source.providerID, size: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(source.title).aimText(.body).lineLimit(1)
        Text(detail(source)).aimText(.secondary).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)
      if source.id == chosen?.id { AIMIcon(name: .check).aimFont(.body).foregroundStyle(AIMTheme.passiveIcon) }
    }
  }

  private func detail(_ source: CleanupSource) -> String {
    guard let email = source.accountEmail else { return source.detail }
    return "\(source.detail) · \(EmailPrivacy.display(email, hide: hideEmails))"
  }
}

private struct PickerRow<Content: View>: View {
  let selected: Bool
  let action: () -> Void
  @ViewBuilder var content: Content
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) { content }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: MaintenanceSourcePanel.rowHeight, alignment: .leading)
        .background {
          RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous)
            .fill(selected ? AIMTheme.rowHighlight : (hovering ? AIMTheme.rowHover : Color.clear))
            .padding(.horizontal, 4).padding(.vertical, AIMTheme.highlightInset)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(AIMMotion.fade(AIMMotion.hover), value: hovering)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

// MARK: - Time range

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

  /// What the card says when the range hides everything, with what the tool uses in total.
  /// Example: "Nothing older than 30 days. Codex CLI uses 11.7 GB; choose a shorter range to see it."
  func nothingText(tool: String, total: Int64) -> String {
    let size = MaintenanceStore.size(total)
    if total == 0 { return "Nothing to clear. \(tool) has no files that Cleanup lists." }
    switch self {
    case .all: return "Nothing to clear. \(tool) uses \(size), but every item is in use or owned by another app."
    case .olderWeek, .olderMonth, .olderYear:
      return "Nothing \(rawValue.lowercased()). \(tool) uses \(size); choose a shorter range to see it."
    case .custom: return "Nothing in these dates. \(tool) uses \(size); choose other dates to see it."
    case .hour, .day, .week, .month:
      return "Nothing in the \(rawValue.lowercased()). \(tool) uses \(size); choose a longer range to see it."
    }
  }
}

// MARK: - Overview card

/// The Overview's Maintenance card: the last three backups across all sets, or a way to start one.
struct RecentBackupsCard: View {
  @ObservedObject var model: AccountViewModel
  @ObservedObject private var store: MaintenanceStore
  let openBackup: (() -> Void)?

  init(model: AccountViewModel, openBackup: (() -> Void)? = nil) {
    self.model = model
    _store = ObservedObject(wrappedValue: model.maintenance)
    self.openBackup = openBackup
  }

  private var pending: Int { model.status?.pendingRecovery.count ?? 0 }
  private static let sizeWidth: CGFloat = 88
  private static let stateWidth: CGFloat = 96

  var body: some View {
    let recent = store.recent
    AIMCard(title: "Recent backups", divider: true, bottomInset: recent.isEmpty ? 0 : AIMTheme.textRowsEndInset, accessory: {
      if pending > 0 {
        Badge(text: "\(pending) interrupted", tint: AIMTheme.amber)
      }
      AIMButton(title: "Open Backup", icon: .database, action: open)
    }) {
      if recent.isEmpty {
        HStack(spacing: AIMTheme.sectionSpacing) {
          VStack(alignment: .leading, spacing: 2) {
            Text(store.isLoaded ? "No backups yet" : "Reading backups…").aimText(.body)
            Text("Copy your chats and settings to a drive or folder you choose.").aimText(.secondary)
          }
          Spacer(minLength: AIMTheme.rowSpacing)
          AIMButton(title: "Set up a backup", tone: .primary, action: open)
        }
        .padding(.horizontal, AIMTheme.cardInset).padding(.vertical, AIMTheme.contentInset)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(recent.enumerated()), id: \.element.id) { index, backup in
            if index > 0 { AIMRowSeparator() }
            AIMTableRow {
              Text(backup.date.formatted(date: .abbreviated, time: .shortened)).aimText(.body).monospacedDigit()
                .frame(width: 170, alignment: .leading)
              Text(backup.source).aimText(.body).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
              Text(MaintenanceStore.size(backup.bytes)).aimText(.body).monospacedDigit()
                .frame(width: Self.sizeWidth, alignment: .trailing)
              Badge(text: backup.state, tint: backup.isSafety || backup.state != "Complete" ? AIMTheme.amber : AIMTheme.green)
                .frame(width: Self.stateWidth, alignment: .trailing)
            }
            .transition(.opacity)
          }
        }
      }
    }
    .task { store.start() }
  }

  private func open() {
    if let openBackup { openBackup(); return }
    store.wantsBackupTab = true
    NotificationCenter.default.post(name: AIManagerNavigation.request, object: AIManagerPage.maintenance)
  }
}

/// The Overview's older name for the card.
struct MaintenanceStatusCard: View {
  @ObservedObject var model: AccountViewModel
  let openBackup: () -> Void

  var body: some View { RecentBackupsCard(model: model, openBackup: openBackup) }
}
