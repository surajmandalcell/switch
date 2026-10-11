import AppKit
import SwiftUI

// Native design tokens. Switch follows the macOS Human Interface Guidelines: the system font at
// standard text styles, system semantic colors, and native controls. These helpers only name the
// few shared values (card geometry, bar colors) so every page agrees.

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

enum AIMTheme {
  /// Card geometry: 10-point corners, 16-point padding, 12-point gaps.
  static let radius: CGFloat = 10
  static let controlRadius: CGFloat = 6
  static let panelContentInset: CGFloat = 16
  static let modalOuterInset: CGFloat = 16
  static let modalSectionSpacing: CGFloat = 12
  static let cardSpacing: CGFloat = 12
  static let sidebarWidth: CGFloat = 200
  static let accountListWidth: CGFloat = 260
  /// Width of the toolbar's "Search accounts…" field.
  static let toolbarSearchWidth: CGFloat = 300

  // System semantic colors; the user's accent color applies in light and dark.
  static let canvas = Color(nsColor: .windowBackgroundColor)
  /// Secondary system background used by cards.
  static let panel = Color(nsColor: .controlBackgroundColor)
  static let panel2 = Color.primary.opacity(0.045)
  static let panel3 = Color.primary.opacity(0.08)
  static let listStripe = Color.primary.opacity(0.03)
  static let listSelection = Color.accentColor.opacity(0.18)
  static let chatUserSurface = Color.accentColor.opacity(0.14)
  static let chatCodeSurface = Color.primary.opacity(0.06)
  static let line = Color(nsColor: .separatorColor)
  static let lineSoft = Color(nsColor: .separatorColor).opacity(0.6)
  static let ink = Color.primary
  static let muted = Color.secondary
  static let faint = Color(nsColor: .tertiaryLabelColor)
  static let blue = Color.accentColor
  static let green = Color(nsColor: .systemGreen)
  static let amber = Color(nsColor: .systemOrange)
  static let yellow = Color(nsColor: .systemYellow)
  static let red = Color(nsColor: .systemRed)
  static let control = Color.primary.opacity(0.1)
  /// Empty track of a usage bar.
  static let track = Color(nsColor: .quaternaryLabelColor)

  enum FontWeight: String {
    case regular = "Regular"
    case medium = "Medium"
    case semibold = "SemiBold"
    case bold = "Bold"
  }

  /// The standard text style closest to a point size.
  static func textStyle(_ size: CGFloat) -> Font.TextStyle {
    switch size {
    case 22...: .title
    case 17...: .title2
    case 15...: .title3
    case 13...: .body
    case 12...: .callout
    case 11...: .subheadline
    default: .footnote
    }
  }

  /// The system font at the standard text style for `size`.
  static func sans(_ size: CGFloat, weight: FontWeight = .regular) -> Font {
    .system(textStyle(size)).weight(weight.swiftUIWeight)
  }

  /// The system monospaced font, for paths, IDs, and numbers.
  static func mono(_ size: CGFloat, weight: FontWeight = .regular) -> Font {
    .system(textStyle(size), design: .monospaced).weight(weight.swiftUIWeight)
  }
}

private extension AIMTheme.FontWeight {
  var swiftUIWeight: Font.Weight {
    switch self {
    case .regular: .regular
    case .medium: .medium
    case .semibold: .semibold
    case .bold: .bold
    }
  }
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

/// A capsule usage bar. `usedPercent` drives the color (by the share left); "Show percentage used"
/// flips the fill to the used share. An unknown value shows an empty grey track. The fill is
/// clamped to the track, so overage never overflows.
struct UsageBar: View {
  let usedPercent: Double?
  var showsUsed = false
  var height: CGFloat = 6
  /// Even-pace marker as a 0...1 position.
  var tick: Double? = nil

  var body: some View {
    let used = usedPercent.map { min(max($0, 0), 100) }
    let color = UsageBarColor.color(leftPercent: used.map { 100 - $0 })
    let fill = used.map { (showsUsed ? $0 : 100 - $0) / 100 } ?? 0
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(AIMTheme.track)
        if let color, fill > 0 {
          Capsule().fill(color).frame(width: max(height, geometry.size.width * fill))
        }
        if let tick {
          Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1.5, height: height + 4)
            .offset(x: min(max(geometry.size.width * tick - 0.75, 0), geometry.size.width - 1.5))
        }
      }
      .frame(height: geometry.size.height, alignment: .leading)
    }
    .frame(height: height + (tick == nil ? 0 : 4))
    .accessibilityHidden(true)
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
      .font(AIMTheme.mono(11))
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
        Text("Copied").font(AIMTheme.sans(10, weight: .medium))
          .foregroundStyle(AIMTheme.green)
          .padding(.horizontal, 4).padding(.vertical, 2)
          .background(AIMTheme.panel)
          .offset(y: -14)
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

    var symbol: String {
      switch self {
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
  var size: CGFloat = 17

  var body: some View {
    Image(systemName: name.symbol)
      .font(.system(size: size, weight: .regular))
      .symbolRenderingMode(.monochrome)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

// MARK: - Cards

enum AIMPanelImportance {
  case primary, secondary
}

/// A grouped card: secondary system background, 10-point corners, a hairline border.
struct AIMPanel<Content: View>: View {
  let title: String
  var importance: AIMPanelImportance = .secondary
  var headerAccessories: AnyView? = nil
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(title)
          .font(.headline)
          .foregroundStyle(importance == .primary ? AIMTheme.ink : AIMTheme.muted)
        Spacer(minLength: 0)
        if let headerAccessories { headerAccessories }
      }
      .padding(.horizontal, AIMTheme.panelContentInset)
      .frame(height: 40)
      Divider()
      content
    }
    .aimCard()
  }
}

extension View {
  /// The card surface: secondary system background, 10-point corners, hairline border.
  func aimCard() -> some View {
    background(AIMTheme.panel)
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
      .overlay {
        RoundedRectangle(cornerRadius: AIMTheme.radius)
          .strokeBorder(AIMTheme.line, lineWidth: 0.5)
      }
  }
}

/// A native scroll view; kept as one name so pages share it.
struct AIMScrollView<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    ScrollView { content }
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
          .foregroundStyle(AIMTheme.ink))
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
