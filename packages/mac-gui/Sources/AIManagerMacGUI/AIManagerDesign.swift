import AppKit
import SwiftUI

// Native design tokens. Switch follows the macOS Human Interface Guidelines: the system font in
// five text roles, system semantic colors, and native controls. These helpers only name the few
// shared values (the roles, container geometry, bar colors) so every page agrees.

private struct AIMCopyPathKey: EnvironmentKey {
  static let defaultValue: @MainActor (String) -> Bool = { _ in false }
}

enum UsageResetLabel {
  /// `exact` and `hourFormat` default to the Settings choices; pass them to pin a format.
  static func text(
    until reset: Date, now: Date = Date(), exact: Bool? = nil, hourFormat: HourFormat? = nil,
    usedPercent: Double? = nil
  ) -> String {
    if reset <= now { return ResetDisplay.pastText(usedPercent: usedPercent) }
    if exact ?? ResetDisplay.isExact() {
      return ResetDisplay.exactText(reset, now: now, hourFormat: hourFormat ?? ResetDisplay.hourFormat())
    }
    let minutes = Int(max(0, reset.timeIntervalSince(now)) / 60)
    if minutes == 0 { return "Resets in <1m" }
    let days = minutes / 1_440
    let hours = (minutes % 1_440) / 60
    let remainingMinutes = minutes % 60
    if days > 0 {
      return "Resets in \(days) \(days == 1 ? "day" : "days") \(hours)h \(remainingMinutes)m"
    }
    if hours > 0 { return "Resets in \(hours)h \(remainingMinutes)m" }
    return "Resets in \(remainingMinutes)m"
  }
}

private struct AIMCancelSheetKey: EnvironmentKey {
  static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
  var aimCopyPath: @MainActor (String) -> Bool {
    get { self[AIMCopyPathKey.self] }
    set { self[AIMCopyPathKey.self] = newValue }
  }
  /// Closes the Add Account or Advanced Import sheet; the standard Cancel button calls it.
  var aimCancelSheet: () -> Void {
    get { self[AIMCancelSheetKey.self] }
    set { self[AIMCancelSheetKey.self] = newValue }
  }
}

/// The five text roles. Every font in the app comes from one of them; there are no other sizes
/// or weights. Title: the focused account name, at most once per page. Section: card and form
/// section titles. Body: row labels, values, and buttons. Secondary: providers, descriptions,
/// reset text, and meta (secondary color). Caption: badges only. Numbers keep their role and add
/// `monospacedDigit()`; only file paths and IDs use the monospaced design, at the Secondary size.
enum AIMTextRole: CaseIterable {
  case title, section, body, secondary, caption

  var font: Font {
    switch self {
    case .title: .title2.weight(.semibold)
    case .section: .headline
    case .body: .body
    case .secondary: .subheadline
    case .caption: .caption
    }
  }
}

private struct AIMTextModifier: ViewModifier {
  let role: AIMTextRole
  let monospaced: Bool
  let tint: Color?

  func body(content: Content) -> some View {
    if role == .secondary {
      content.font(monospaced ? role.font.monospaced() : role.font)
        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
    } else {
      content.font(role.font)
    }
  }
}

extension View {
  /// Applies a text role. `monospaced` is for paths and IDs and applies to Secondary only.
  /// `tint` replaces the secondary color of a Secondary text, for a warning or an error.
  func aimText(_ role: AIMTextRole, monospaced: Bool = false, tint: Color? = nil,
               file: StaticString = #fileID, line: UInt = #line) -> some View {
    modifier(AIMTextModifier(role: role, monospaced: monospaced, tint: tint))
      .uiLintText(role, monospaced: monospaced, tint: tint, file: file, line: line)
  }

  /// Only the font of a role, for icons and controls that set their own color.
  func aimFont(_ role: AIMTextRole, file: StaticString = #fileID, line: UInt = #line) -> some View {
    font(role.font).uiLintText(role, file: file, line: line)
  }
}

enum AIMTheme {
  /// Rounded container corners.
  static let radius: CGFloat = 10
  /// Page margins, the gap between sections, and the space inside a row.
  static let pageMargin: CGFloat = 20
  static let sectionSpacing: CGFloat = 16
  static let rowSpacing: CGFloat = 8
  static let accountListWidth: CGFloat = 260
  /// Width of the toolbar's "Search accounts…" field.
  static let toolbarSearchWidth: CGFloat = 300

  // System semantic colors; the user's accent color applies in light and dark.
  /// The grouped container fill: the same faint system fill a grouped Form draws.
  static let container = Color(nsColor: .quaternarySystemFill)
  static let panel = Color(nsColor: .controlBackgroundColor)
  static let chatUserSurface = Color.accentColor.opacity(0.14)
  static let chatAssistantSurface = Color.primary.opacity(0.045)
  static let chatCodeSurface = Color.primary.opacity(0.06)
  static let chatOtherSurface = Color.primary.opacity(0.08)
  static let line = Color(nsColor: .separatorColor)
  static let blue = Color.accentColor
  static let green = Color(nsColor: .systemGreen)
  static let amber = Color(nsColor: .systemOrange)
  static let yellow = Color(nsColor: .systemYellow)
  static let red = Color(nsColor: .systemRed)
  /// Empty track of a usage bar.
  static let track = Color(nsColor: .quaternaryLabelColor)
}

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255,
      opacity: 1
    )
  }
}

enum AIMMotion {
  static let state = 0.10
}

// MARK: - Usage bars

enum UsageBarColor {
  /// Green above 50% left, yellow from 20% to 50%, red below 20%. Nil is an unknown value.
  static func color(leftPercent: Double?) -> Color? {
    guard let left = leftPercent else { return nil }
    return left > 50 ? AIMTheme.green : (left >= 20 ? AIMTheme.yellow : AIMTheme.red)
  }
}

/// The one usage bar: a 6-point capsule in the Overview, Accounts, the account detail, and the
/// popover. `usedPercent` drives the color (by the share left) unless `tint` overrides it; "Show
/// percentage used" flips the fill to the used share. An unknown value shows an empty grey track.
/// The fill is clamped to the track, so overage never overflows. The pace tick draws over the bar
/// and never changes the layout height.
struct UsageBar: View {
  static let height: CGFloat = 6
  let usedPercent: Double?
  var showsUsed = false
  /// Overrides the color by percent, for example the popover's pace-aware level.
  var tint: Color? = nil
  /// Even-pace marker as a 0...1 position.
  var tick: Double? = nil

  var body: some View {
    let used = usedPercent.map { min(max($0, 0), 100) }
    let color = tint ?? UsageBarColor.color(leftPercent: used.map { 100 - $0 })
    let fill = used.map { (showsUsed ? $0 : 100 - $0) / 100 } ?? 0
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(AIMTheme.track)
        if let color, fill > 0 {
          Capsule().fill(color).frame(width: max(Self.height, geometry.size.width * fill))
        }
        if let tick {
          Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1.5, height: Self.height + 4)
            .offset(x: min(max(geometry.size.width * tick - 0.75, 0), geometry.size.width - 1.5))
        }
      }
      .frame(height: geometry.size.height, alignment: .leading)
    }
    .frame(height: Self.height)
    .accessibilityHidden(true)
  }
}

// MARK: - Badge

/// The one badge: Caption text on a capsule with a tinted fill. Used for Default, Signed in on
/// this Mac, and every attention state.
struct Badge: View {
  let text: String
  var tint: Color = AIMTheme.green

  var body: some View {
    Text(text)
      .aimText(.caption)
      .foregroundStyle(AIMTheme.legible(tint))
      .lineLimit(1)
      .padding(.horizontal, 8).padding(.vertical, 2)
      .background(tint.opacity(0.16), in: Capsule())
  }
}

// MARK: - Paths

struct AIMCopyablePath: View {
  let path: String
  @Environment(\.aimCopyPath) private var copyPath
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  @State private var copied = false
  @State private var feedbackTask: Task<Void, Never>?

  var body: some View {
    Text(path)
      .aimText(.secondary, monospaced: true)
      .lineLimit(1).truncationMode(.middle)
      .contentShape(Rectangle())
      .highPriorityGesture(TapGesture().onEnded { copy() })
      .focusable()
      .onKeyPress(.return) { copy(); return .handled }
      .onKeyPress(.space) { copy(); return .handled }
      .help("Click to copy \(path)")
      .accessibilityLabel("Copy path: \(path)")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { copy() }
      .background { AIMCopyCursor(enabled: isEnabled).allowsHitTesting(false) }
      .overlay(alignment: .topTrailing) {
        Badge(text: "Copied")
          .background(AIMTheme.panel, in: Capsule())
          .offset(y: -18)
          .opacity(copied ? 1 : 0)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: copied)
      .onDisappear { feedbackTask?.cancel() }
  }

  private func copy() {
    guard copyPath(path) else { return }
    feedbackTask?.cancel()
    copied = true
    feedbackTask = Task { @MainActor in
      do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
      copied = false
    }
  }
}

struct AIMCopyCursor: NSViewRepresentable {
  let enabled: Bool

  func makeNSView(context: Context) -> CursorView {
    let view = CursorView()
    view.enabled = enabled
    return view
  }

  func updateNSView(_ view: CursorView, context: Context) {
    guard view.enabled != enabled else { return }
    view.enabled = enabled
    view.window?.invalidateCursorRects(for: view)
  }

  final class CursorView: NSView {
    var enabled = true
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() {
      super.resetCursorRects()
      if enabled { addCursorRect(visibleRect, cursor: .pointingHand) }
    }
  }
}

// MARK: - Icons

struct AIMIcon: View {
  enum Name: CaseIterable {
    case overview, account, settings, history, maintenance, backup, cleanup, search, plus, more, refresh, close, minimize
    case chevron, check, circle, square, checkSquare, folder, play, copy, trash, warning, info, success, terminal, openApp, menuBar
    case link
    case ellipsis, chart, clock, calendar, database, arrowRight

    var symbol: String {
      switch self {
      case .ellipsis: "ellipsis"
      case .chart: "chart.bar"
      case .clock: "clock"
      case .calendar: "calendar"
      case .database: "cylinder.split.1x2"
      case .arrowRight: "arrow.right"
      case .overview: "house"
      case .link: "arrow.up.right.square"
      case .account: "person.crop.circle"
      case .settings: "gearshape"
      case .history: "bubble.left.and.bubble.right"
      case .maintenance: "externaldrive"
      case .backup: "archivebox"
      case .cleanup: "eraser"
      case .search: "magnifyingglass"
      case .plus: "plus"
      case .more: "ellipsis.circle"
      case .refresh: "arrow.clockwise"
      case .close: "xmark"
      case .minimize: "minus"
      case .chevron: "chevron.right"
      case .terminal: "terminal"
      case .openApp: "macwindow"
      case .menuBar: "menubar.rectangle"
      case .check: "checkmark"
      case .circle: "circle"
      case .square: "square"
      case .checkSquare: "checkmark.square.fill"
      case .folder: "folder"
      case .play: "play"
      case .copy: "doc.on.doc"
      case .trash: "trash"
      case .warning: "exclamationmark.triangle"
      case .info: "info.circle"
      case .success: "checkmark.circle"
      }
    }
  }

  let name: Name

  /// A template symbol that scales with the surrounding text role.
  var body: some View {
    Image(systemName: name.symbol)
      .symbolRenderingMode(.monochrome)
      .accessibilityHidden(true)
  }
}

// MARK: - Containers

extension View {
  /// The shared container surface: the system grouped fill with rounded corners.
  func aimContainer() -> some View {
    background(AIMTheme.container, in: RoundedRectangle(cornerRadius: AIMTheme.radius))
  }

  /// A row inside a container: 8 points of vertical space.
  func aimRow() -> some View {
    padding(.horizontal, AIMTheme.sectionSpacing).padding(.vertical, AIMTheme.rowSpacing)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The one container of the Overview: the Section title above, then rows on the system secondary
/// background. Callers put a `Divider()` (a hairline) between rows.
struct AIMPanel<Content: View>: View {
  var title: String? = nil
  var accessory: AnyView? = nil
  @ViewBuilder var content: Content

  var body: some View {
    AIMCard(title: title, accessory: { accessory ?? AnyView(EmptyView()) }) {
      VStack(spacing: 0) { content }
    }
  }
}

// MARK: - Virtual list

/// A virtualized list of hosted rows. Native scrollers; `onReachEnd` pages long lists.
struct AIMVirtualList<Item: Identifiable & Equatable>: NSViewRepresentable
where Item.ID: Hashable {
  let items: [Item]
  let rowSpacing: CGFloat
  let fixedRowHeight: CGFloat?
  let contentRevision: Int
  let onReachEnd: (() -> Void)?
  let rowContent: (Item) -> AnyView
  @Environment(\.aimCopyPath) private var copyPath

  init(
    items: [Item], rowSpacing: CGFloat = 0, fixedRowHeight: CGFloat? = nil,
    contentRevision: Int = 0,
    onReachEnd: (() -> Void)? = nil,
    rowContent: @escaping (Item) -> AnyView
  ) {
    self.items = items
    self.rowSpacing = rowSpacing
    self.fixedRowHeight = fixedRowHeight
    self.contentRevision = contentRevision
    self.onReachEnd = onReachEnd
    self.rowContent = rowContent
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> AIMOwnedScrollView {
    let scrollView = AIMOwnedScrollView(frame: .zero)
    scrollView.onReachEnd = onReachEnd
    let tableView = AIMVirtualTableView(frame: .zero)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.style = .plain
    tableView.selectionHighlightStyle = .none
    tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    tableView.focusRingType = .none
    tableView.delegate = context.coordinator
    tableView.dataSource = context.coordinator
    scrollView.documentView = tableView
    context.coordinator.tableView = tableView
    updateCoordinator(context.coordinator)
    tableView.reloadData()
    return scrollView
  }

  func updateNSView(_ scrollView: AIMOwnedScrollView, context: Context) {
    scrollView.onReachEnd = onReachEnd
    updateCoordinator(context.coordinator)
    if let tableView = context.coordinator.tableView,
       let column = tableView.tableColumns.first {
      column.width = scrollView.contentSize.width
    }
  }

  private func updateCoordinator(_ coordinator: Coordinator) {
    coordinator.update(
      items: items,
      rowSpacing: rowSpacing,
      fixedRowHeight: fixedRowHeight,
      contentRevision: contentRevision,
      rowContent: rowContent,
      copyPath: copyPath)
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: NSTableView?
    private var items: [Item] = []
    private var fixedRowHeight: CGFloat?
    private var contentRevision = 0
    private var rowContent: ((Item) -> AnyView)?
    private var copyPath: @MainActor (String) -> Bool = { _ in false }

    func update(
      items nextItems: [Item], rowSpacing: CGFloat, fixedRowHeight: CGFloat?,
      contentRevision nextContentRevision: Int,
      rowContent: @escaping (Item) -> AnyView,
      copyPath: @escaping @MainActor (String) -> Bool
    ) {
      let oldItems = items
      items = nextItems
      self.fixedRowHeight = fixedRowHeight
      self.rowContent = rowContent
      let contentChanged = contentRevision != nextContentRevision
      contentRevision = nextContentRevision
      self.copyPath = copyPath
      guard let tableView else { return }
      tableView.intercellSpacing = NSSize(width: 0, height: rowSpacing)
      tableView.usesAutomaticRowHeights = fixedRowHeight == nil
      if let fixedRowHeight { tableView.rowHeight = fixedRowHeight }
      let sameIDs = oldItems.map(\.id) == nextItems.map(\.id)
      if sameIDs {
        var changed = IndexSet(nextItems.indices.filter { oldItems[$0] != nextItems[$0] })
        if contentChanged {
          let visible = tableView.rows(in: tableView.visibleRect)
          if visible.location != NSNotFound, visible.length > 0 {
            let lower = max(0, visible.location)
            let upper = min(nextItems.count, visible.location + visible.length)
            changed.formUnion(IndexSet(integersIn: lower..<upper))
          }
        }
        if !changed.isEmpty {
          tableView.reloadData(
            forRowIndexes: changed,
            columnIndexes: IndexSet(integer: 0))
          tableView.noteHeightOfRows(withIndexesChanged: changed)
        }
      } else {
        tableView.reloadData()
      }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      fixedRowHeight ?? -1
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      guard items.indices.contains(row), let rowContent else { return nil }
      let identifier = NSUserInterfaceItemIdentifier("AIMVirtualCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? AIMVirtualCell
        ?? AIMVirtualCell(identifier: identifier)
      cell.host.rootView = AnyView(
        rowContent(items[row])
          .environment(\.aimCopyPath, copyPath)
          .foregroundStyle(.primary))
      return cell
    }
  }
}

final class AIMVirtualTableView: NSTableView {}

private final class AIMVirtualCell: NSTableCellView {
  let host = NSHostingView(rootView: AnyView(EmptyView()))

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    focusRingType = .none
    host.translatesAutoresizingMaskIntoConstraints = false
    host.focusRingType = .none
    addSubview(host)
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: leadingAnchor),
      host.trailingAnchor.constraint(equalTo: trailingAnchor),
      host.topAnchor.constraint(equalTo: topAnchor),
      host.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable) required init?(coder: NSCoder) { nil }
}

/// The system scroll view. `onReachEnd` fires near the bottom so long conversations page in.
final class AIMOwnedScrollView: NSScrollView {
  var onReachEnd: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    drawsBackground = false
    borderType = .noBorder
    hasHorizontalScroller = false
    hasVerticalScroller = true
    autohidesScrollers = true
  }

  @available(*, unavailable) required init?(coder: NSCoder) { nil }

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    guard let documentView, documentView.isFlipped,
          documentView.frame.height > 0, clipView.bounds.height > 0,
          documentView.frame.height - clipView.bounds.maxY < 180 else { return }
    onReachEnd?()
  }
}
