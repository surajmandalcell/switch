import AppKit
import SwiftUI

private struct AIMFocusIndicatorsKey: EnvironmentKey {
  static let defaultValue = false
}

private struct AIMDarkModeKey: EnvironmentKey {
  static let defaultValue = false
}

private struct AIMAdaptiveColor: ShapeStyle, Hashable {
  let light: UInt32
  let dark: UInt32
  var lightHighContrast: UInt32?
  var darkHighContrast: UInt32?

  func resolve(in environment: EnvironmentValues) -> Color.Resolved {
    let highContrast = environment.colorSchemeContrast == .increased
    let hex = environment.colorScheme == .dark
      ? (highContrast ? darkHighContrast ?? dark : dark)
      : (highContrast ? lightHighContrast ?? light : light)
    return Color(hex: hex).resolve(in: environment)
  }
}

extension EnvironmentValues {
  var aimFocusIndicatorsEnabled: Bool {
    get { self[AIMFocusIndicatorsKey.self] }
    set { self[AIMFocusIndicatorsKey.self] = newValue }
  }

  var aimDarkMode: Bool {
    get { self[AIMDarkModeKey.self] }
    set { self[AIMDarkModeKey.self] = newValue }
  }
}

enum AIMTheme {
  enum Dark {
    static let rail: UInt32 = 0x141517
    static let canvas: UInt32 = 0x18191B
    static let panel: UInt32 = 0x202124
    static let raised: UInt32 = 0x27282B
    static let raisedSecondary: UInt32 = 0x2F3034
    static let hover: UInt32 = 0x303238
    static let selection: UInt32 = 0x393C43
    static let menuChrome: UInt32 = 0x18191B
  }

  static let radius: CGFloat = 3
  static let railWidth: CGFloat = 48
  static let railIconSize: CGFloat = 17
  static let historyRailIconSize: CGFloat = railIconSize * 0.75
  static let topbarHeight: CGFloat = 48
  static let listWidth: CGFloat = 200
  static let windowControlSize: CGFloat = 48
  static let modalTitlebarHeight: CGFloat = 48
  static let modalStepHeight: CGFloat = 28
  static let modalHeight: CGFloat = 648
  static let addAccountModalHeight: CGFloat = 480
  static let modalOuterInset: CGFloat = 24
  static let modalSectionSpacing: CGFloat = 16
  static let panelContentInset: CGFloat = 16

  static let canvas = dynamic(light: 0xECEBE7, dark: Dark.canvas)
  static let rail = dynamic(light: 0xF4F3EF, dark: Dark.rail)
  static let panel = dynamic(light: 0xFAF9F6, dark: Dark.panel)
  static let panel2 = dynamic(light: 0xF0EFEB, dark: Dark.raised)
  static let panel3 = dynamic(light: 0xE5E4DF, dark: Dark.raisedSecondary)
  static let menuChrome = dynamic(light: 0xF0EFEB, dark: Dark.menuChrome)
  static let listStripe = dynamic(
    light: 0xF0EFEB, dark: Dark.raised, lightHighContrast: 0xE4E3DD,
    darkHighContrast: 0x34363B)
  static let listHover = dynamic(light: 0xE5E4DF, dark: Dark.hover)
  static let listSelection = dynamic(
    light: 0xE1E2E0, dark: Dark.selection, lightHighContrast: 0xD4D7DC,
    darkHighContrast: 0x464A52)
  static let chatUserSurface = dynamic(light: 0xE7E9ED, dark: 0x2B2F36)
  static let chatCodeSurface = dynamic(light: 0xF0EFEB, dark: Dark.canvas)
  static let line = dynamic(
    light: 0xD4D3CE, dark: 0x4A4D54, lightHighContrast: 0xA7A69F,
    darkHighContrast: 0x777A82)
  static let lineSoft = dynamic(
    light: 0xE2E1DC, dark: 0x35373C, lightHighContrast: 0xB9B8B2,
    darkHighContrast: 0x5E6168)
  static let railLine = dynamic(light: 0xDAD9D5, dark: 0x292B2F)
  static let ink = dynamic(
    light: 0x1A1B1D, dark: 0xF2F2F3, lightHighContrast: 0x000000,
    darkHighContrast: 0xFFFFFF)
  static let muted = dynamic(light: 0x666970, dark: 0xB9BBC0)
  static let faint = dynamic(light: 0x75787F, dark: 0xA7A9AF)
  static let blue = dynamic(light: 0x566D95, dark: 0x9AADD0)
  static let green = dynamic(light: 0x557D68, dark: 0x8EB9A2)
  static let amber = dynamic(light: 0x856F43, dark: 0xD0B47A)
  static let red = dynamic(light: 0x8D5A60, dark: 0xD9959C)
  static let titleArt = dynamic(light: 0x657B98, dark: 0x7F95B5)
  static let active = dynamic(light: 0x3C4A61, dark: 0x445878)
  static let activeInk = dynamic(light: 0xF2F1ED, dark: 0xF2F1ED)
  static let historySelection = listSelection
  static let railIdle = dynamic(light: 0x5D6670, dark: 0xB0B7C2)
  static let statusInk = dynamic(light: 0xFFFFFF, dark: 0x0B0C0F)
  static let control = dynamic(light: 0xDEDCD6, dark: 0x34363B)
  static let controlHover = dynamic(light: 0xD3D1CA, dark: 0x3D4046)
  static let primaryHover = dynamic(light: 0x3A393B, dark: 0xCCCBC8)
  static let minimizeControl = dynamic(light: 0xD9D3C6, dark: 0x3A3732)
  static let minimizeHover = Color(hex: 0xFFD43B)
  static let closeHover = Color(hex: 0xFF453A)
  static let windowControlInk = Color(hex: 0x1A1B1D)
  static let disabledControl = dynamic(light: 0xE5E4DF, dark: 0x2C2E32)
  static let disabledInk = dynamic(light: 0x62656B, dark: 0xA6A8AD)

  enum FontWeight: String {
    case regular = "Regular"
    case medium = "Medium"
    case semibold = "SemiBold"
  }

  static func sans(_ size: CGFloat, weight: FontWeight = .regular) -> Font {
    .custom("Inter-\(weight.rawValue)", size: size, relativeTo: .body)
  }

  static func mono(_ size: CGFloat, weight: FontWeight = .regular) -> Font {
    .custom("PTMono-Regular", size: size, relativeTo: .body)
      .weight(weight.swiftUIWeight)
  }

  private static func dynamic(
    light: UInt32, dark: UInt32, lightHighContrast: UInt32? = nil,
    darkHighContrast: UInt32? = nil
  ) -> Color {
    Color(AIMAdaptiveColor(
      light: light, dark: dark, lightHighContrast: lightHighContrast,
      darkHighContrast: darkHighContrast))
  }
}

private extension AIMTheme.FontWeight {
  var swiftUIWeight: Font.Weight {
    switch self {
    case .regular: .regular
    case .medium: .medium
    case .semibold: .semibold
    }
  }
}

enum AIMMotion {
  static let press = 0.055
  static let hover = 0.08
  static let state = 0.10
  static let navigation = 0.14
  static let modal = 0.14
  static let theme = 0.16
  static let minimize = 0.08
  static let scrollbarIn = 0.10
  static let scrollbarOut = 0.16
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255,
      opacity: 1
    )
  }
}

struct AIMVisualEffect: NSViewRepresentable {
  let material: NSVisualEffectView.Material
  let blendingMode: NSVisualEffectView.BlendingMode
  let darkMode: Bool

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
    view.blendingMode = blendingMode
    view.appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
  }
}

struct AIMIcon: View {
  enum Name: CaseIterable {
    case account, settings, history, backup, cleanup, search, plus, refresh, moon, sun, close, minimize
    case chevron, check, doubleCheck, square, checkSquare, folder, play, copy, trash, warning, info, success, terminal, openApp, menuBar

    var symbol: String {
      switch self {
      case .account: "person.crop.circle"
      case .settings: "gearshape"
      case .history: "bubble.left.and.bubble.right"
      case .backup: "archivebox"
      case .cleanup: "eraser"
      case .search: "magnifyingglass"
      case .plus: "plus"
      case .refresh: "arrow.clockwise"
      case .moon: "moon"
      case .sun: "sun.max"
      case .close: "xmark"
      case .minimize: "minus"
      case .chevron: "chevron.right"
      case .terminal: "terminal"
      case .openApp: "macwindow"
      case .menuBar: "menubar.rectangle"
      case .check, .doubleCheck: "checkmark"
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
    Group {
      if name == .doubleCheck {
        HStack(spacing: -size * 0.5) {
          Image(systemName: name.symbol)
          Image(systemName: name.symbol)
        }
      } else {
        Image(systemName: name.symbol)
      }
    }
      .font(.system(size: size, weight: .regular))
      .symbolRenderingMode(.monochrome)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

struct AIMPressButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> Body {
    Body(configuration: configuration)
  }

  struct Body: View {
    let configuration: Configuration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.aimFocusIndicatorsEnabled) private var focusIndicatorsEnabled
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      configuration.label
        .brightness(configuration.isPressed && isEnabled ? -0.035 : 0)
        .opacity(configuration.isPressed && isEnabled ? 0.92 : 1)
        .animation(
          reduceMotion ? nil : .easeOut(duration: AIMMotion.press),
          value: configuration.isPressed)
        .focusEffectDisabled(!focusIndicatorsEnabled)
    }
  }
}

enum AIMPanelImportance {
  case primary, secondary

  var tintOpacity: Double { self == .primary ? 0.70 : 0.28 }
}

struct AIMPanel<Content: View>: View {
  let title: String
  var importance: AIMPanelImportance = .secondary
  var headerAccessories: AnyView? = nil
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(title)
          .font(AIMTheme.sans(12, weight: .medium))
          .foregroundStyle(importance == .primary ? AIMTheme.ink : AIMTheme.muted)
          .padding(.horizontal, AIMTheme.panelContentInset)
          .frame(height: 40)
        Spacer(minLength: 0)
        if let headerAccessories {
          headerAccessories.padding(.trailing, 10)
        }
      }
      .frame(height: 40)
      .background {
        ZStack(alignment: .trailing) {
          LinearGradient(
            colors: [AIMTheme.green.opacity(0.16), .clear, AIMTheme.titleArt.opacity(0.24)],
            startPoint: .leading,
            endPoint: .trailing
          ).opacity(importance.tintOpacity)
          AIMTitleArt()
        }.allowsHitTesting(false)
      }
      .background(AIMTheme.panel2.opacity(importance.tintOpacity))
      content
    }
    .background(AIMTheme.panel)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }
}

private struct AIMTitleArt: View {
  var body: some View {
    Canvas { context, size in
      let trailingAnchor = size.width - 13
      for radius in stride(from: CGFloat(24), through: 60, by: 9) {
        context.stroke(
          Path(ellipseIn: CGRect(
            x: trailingAnchor - radius, y: 47 - radius,
            width: radius * 2, height: radius * 2)),
          with: .color(AIMTheme.titleArt.opacity(0.24)), lineWidth: 0.65)
        context.stroke(
          Path(ellipseIn: CGRect(
            x: trailingAnchor - 59 - radius, y: -23 - radius,
            width: radius * 2, height: radius * 2)),
          with: .color(AIMTheme.titleArt.opacity(0.145)), lineWidth: 0.65)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
    .mask {
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.22), location: 0),
          .init(color: .black.opacity(0.60), location: 0.55),
          .init(color: .black, location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing)
    }
    .accessibilityHidden(true)
  }
}

struct AIMScrollView<Content: View>: View {
  @ViewBuilder let content: Content
  @Environment(\.aimDarkMode) private var darkMode
  @Environment(\.aimFocusIndicatorsEnabled) private var focusIndicatorsEnabled

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    AIMNativeScrollView(
      content: AnyView(
        content.environment(\.colorScheme, darkMode ? .dark : .light)
          .environment(\.aimDarkMode, darkMode)
          .environment(\.aimFocusIndicatorsEnabled, focusIndicatorsEnabled)
          .foregroundStyle(AIMTheme.ink)
          .focusEffectDisabled(!focusIndicatorsEnabled)))
  }
}

struct AIMVirtualList<Item: Identifiable & Equatable>: NSViewRepresentable
where Item.ID: Hashable {
  let items: [Item]
  let rowSpacing: CGFloat
  let fixedRowHeight: CGFloat?
  let contentRevision: Int
  let rowContent: (Item) -> AnyView
  @Environment(\.aimDarkMode) private var darkMode
  @Environment(\.aimFocusIndicatorsEnabled) private var focusIndicatorsEnabled

  init(
    items: [Item], rowSpacing: CGFloat = 0, fixedRowHeight: CGFloat? = nil,
    contentRevision: Int = 0,
    rowContent: @escaping (Item) -> AnyView
  ) {
    self.items = items
    self.rowSpacing = rowSpacing
    self.fixedRowHeight = fixedRowHeight
    self.contentRevision = contentRevision
    self.rowContent = rowContent
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> AIMOwnedScrollView {
    let scrollView = AIMOwnedScrollView(frame: .zero)
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
      darkMode: darkMode,
      focusIndicatorsEnabled: focusIndicatorsEnabled)
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: NSTableView?
    private var items: [Item] = []
    private var fixedRowHeight: CGFloat?
    private var contentRevision = 0
    private var rowContent: ((Item) -> AnyView)?
    private var darkMode = false
    private var focusIndicatorsEnabled = false

    func update(
      items nextItems: [Item], rowSpacing: CGFloat, fixedRowHeight: CGFloat?,
      contentRevision nextContentRevision: Int,
      rowContent: @escaping (Item) -> AnyView,
      darkMode: Bool, focusIndicatorsEnabled: Bool
    ) {
      let appearanceChanged = self.darkMode != darkMode
        || self.focusIndicatorsEnabled != focusIndicatorsEnabled
      let oldItems = items
      items = nextItems
      self.fixedRowHeight = fixedRowHeight
      self.rowContent = rowContent
      let contentChanged = contentRevision != nextContentRevision
      contentRevision = nextContentRevision
      self.darkMode = darkMode
      self.focusIndicatorsEnabled = focusIndicatorsEnabled
      guard let tableView else { return }
      tableView.intercellSpacing = NSSize(width: 0, height: rowSpacing)
      tableView.usesAutomaticRowHeights = fixedRowHeight == nil
      if let fixedRowHeight { tableView.rowHeight = fixedRowHeight }
      let sameIDs = oldItems.map(\.id) == nextItems.map(\.id)
      if sameIDs, !appearanceChanged {
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
          .environment(\.colorScheme, darkMode ? .dark : .light)
          .environment(\.aimDarkMode, darkMode)
          .environment(\.aimFocusIndicatorsEnabled, focusIndicatorsEnabled)
          .foregroundStyle(AIMTheme.ink)
          .focusEffectDisabled(!focusIndicatorsEnabled))
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

final class AIMThinScroller: NSScroller {
  override class var isCompatibleWithOverlayScrollers: Bool { true }
  override var scrollerStyle: NSScroller.Style {
    get { super.scrollerStyle }
    set { super.scrollerStyle = .overlay }
  }

  override class func scrollerWidth(
    for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style
  ) -> CGFloat { 3 }

  override func drawKnob() {
    let knob = rect(for: .knob)
    guard !knob.isEmpty else { return }
    NSColor.secondaryLabelColor.withAlphaComponent(0.52).setFill()
    NSBezierPath(
      roundedRect: NSRect(x: bounds.midX - 1.5, y: knob.minY, width: 3, height: knob.height),
      xRadius: 1.5,
      yRadius: 1.5
    ).fill()
  }

  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

final class AIMOwnedScrollView: NSScrollView {
  private var hideTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovered = false
  private var isScrolling = false
  private var isScrollerVisible = false

  override var scrollerStyle: NSScroller.Style {
    get { super.scrollerStyle }
    set { super.scrollerStyle = .overlay }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    drawsBackground = false
    borderType = .noBorder
    hasHorizontalScroller = false
    hasVerticalScroller = true
    autohidesScrollers = true
    verticalScroller = AIMThinScroller(frame: NSRect(x: 0, y: 0, width: 3, height: 100))
    super.scrollerStyle = .overlay
    verticalScroller?.scrollerStyle = .overlay
    verticalScroller?.controlSize = .mini
    verticalScroller?.wantsLayer = true
    verticalScroller?.alphaValue = 0
    observers = [
      NotificationCenter.default.addObserver(
        forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: .main
      ) { [weak self] _ in
        self?.isScrolling = true
        self?.showScroller()
      },
      NotificationCenter.default.addObserver(
        forName: NSScrollView.didEndLiveScrollNotification, object: self, queue: .main
      ) { [weak self] _ in
        self?.isScrolling = false
        self?.scheduleHide()
      },
    ]
  }

  @available(*, unavailable) required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
      userInfo: nil)
    addTrackingArea(trackingArea)
    hoverTrackingArea = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    showScroller()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    scheduleHide()
  }

  override func scrollWheel(with event: NSEvent) {
    showScroller()
    super.scrollWheel(with: event)
    if event.phase == .ended || event.phase == [] { scheduleHide() }
  }

  private func showScroller() {
    hideTask?.cancel()
    setScrollerVisible(true)
  }

  private func scheduleHide() {
    guard !isHovered, !isScrolling else { return }
    hideTask?.cancel()
    hideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled else { return }
      self?.setScrollerVisible(false)
    }
  }

  private func setScrollerVisible(_ visible: Bool) {
    guard visible != isScrollerVisible, let scroller = verticalScroller else { return }
    isScrollerVisible = visible
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ? 0 : (visible ? AIMMotion.scrollbarIn : AIMMotion.scrollbarOut)
      scroller.animator().alphaValue = visible ? 1 : 0
    }
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
    hideTask?.cancel()
  }
}

private struct AIMNativeScrollView: NSViewRepresentable {
  let content: AnyView

  final class Coordinator {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> AIMOwnedScrollView {
    let scrollView = AIMOwnedScrollView(frame: .zero)
    let host = context.coordinator.host
    host.translatesAutoresizingMaskIntoConstraints = false
    host.focusRingType = .none
    host.rootView = content
    scrollView.documentView = host
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
      host.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
      host.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
    ])
    return scrollView
  }

  func updateNSView(_ scrollView: AIMOwnedScrollView, context: Context) {
    context.coordinator.host.rootView = content
  }
}
