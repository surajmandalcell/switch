import AppKit
import SwiftUI

// The shared parts of the Sequoia-style window: Card, title row, column table, push buttons,
// square icon buttons, menu button, search field, tile, sidebar. Geometry is in points and
// comes from specs/product.md section 4. Every font comes from the five text roles.

extension AIMTheme {
  /// Gap between cards and from a card to its neighbours.
  static let cardGap: CGFloat = 12
  /// Inset of a card's title, column headers, rows, and separators.
  static let cardInset: CGFloat = 16
  static let titleRowHeight: CGFloat = 44
  static let rowHeight: CGFloat = 36
  /// The Accounts table: a provider header row, account rows indented under its name, and a gap
  /// between groups. The tile is 16 pt with an 8 pt gap, so the indent lines up with the name.
  static let groupHeaderHeight: CGFloat = 32
  static let groupIndent: CGFloat = 24
  static let groupGap: CGFloat = 6
  /// Tiles share the card's inset, with a 12 pt gap and a 6 pt radius.
  static let tileInset: CGFloat = 16
  static let tileGap: CGFloat = 12
  static let tileRadius: CGFloat = 6
  /// A row highlight sits this far inside its 36 pt row, above and below.
  static let highlightInset: CGFloat = 2
  /// A titled card puts its first content 14 pt below the top edge, so its last content sits 14 pt
  /// above the bottom edge. Form rows (AIMRows) end with `contentInset`; a table of 22 pt controls
  /// and a list of text-only rows add what their 36 pt rows lack.
  static let contentInset: CGFloat = 14
  static let tableEndInset: CGFloat = 7
  static let textRowsEndInset: CGFloat = 4
  static let sidebarWidth: CGFloat = 220
  static let topBarHeight: CGFloat = 52
  /// Push button heights: in cards, and in table rows.
  static let controlHeight: CGFloat = 28
  static let rowControlHeight: CGFloat = 22
  /// Width shared by the disabled Default button and the Switch button.
  static let rowButtonWidth: CGFloat = 64

  static func dynamic(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
  }

  /// The light grey content background (dark grey in Dark Mode).
  /// This Mac reports windowBackgroundColor as white in light, so the light page uses the
  /// under-page grey (#F6F6F6) and the dark cards use it over the dark window background.
  static let page = dynamic(light: .underPageBackgroundColor, dark: .windowBackgroundColor)
  static let linkColor = Color(nsColor: .linkColor)

  /// Text in a tint (green, orange) darkened in light so it keeps 4.5:1 contrast on its fill.
  static func legible(_ tint: Color) -> Color {
    let base = NSColor(tint)
    return dynamic(light: base.blended(withFraction: 0.5, of: .black) ?? base, dark: base)
  }
  /// White cards in light; a little lighter than the page in dark.
  static let card = dynamic(light: .white, dark: .underPageBackgroundColor)
  /// One device pixel (see `aimPixel`). Dark is half the alpha of light: it keeps the look of the old half-point stroke.
  static let cardBorder = dynamic(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.05))
  static let hairline = Color(nsColor: .separatorColor)
  /// Table separators stay lighter than the card border (light 6% against 10%, dark 4% against 5%).
  static let tableSeparator = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.04))
  /// The outline guide line and elbows of a provider group: fainter than a border, still readable.
  static let guideLine = dynamic(light: NSColor(white: 0, alpha: 0.13), dark: NSColor(white: 1, alpha: 0.13))
  /// Pointer hover on a row: fainter than selection.
  static let rowHover = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.07))
  static let tileFill = dynamic(light: NSColor(white: 0, alpha: 0.025), dark: NSColor(white: 1, alpha: 0.04))
  static let controlFill = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.12))
  static let controlPressed = dynamic(light: NSColor(white: 0.93, alpha: 1), dark: NSColor(white: 1, alpha: 0.2))
  /// Light mode keeps a one-pixel rim; Dark Mode controls are flat fills only.
  static let controlBorder = dynamic(light: NSColor(white: 0, alpha: 0.14), dark: .clear)
  static let primaryBorder = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: .clear)
  static let controlShadow = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: .clear)
  /// The track of a segmented control and the fill of its selected segment.
  static let segmentTrack = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08))
  static let switchOff = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.18))
  static let segmentSelected = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.2))
  /// Keyboard focus: a faint fill in the control's own shape.
  static let focusTint = dynamic(light: .controlAccentColor.withAlphaComponent(0.16), dark: NSColor(white: 1, alpha: 0.08))
  static let rowHighlight = dynamic(light: .controlAccentColor.withAlphaComponent(0.12), dark: NSColor(white: 1, alpha: 0.12))
  static let sidebarSelection = dynamic(light: .controlAccentColor.withAlphaComponent(0.18), dark: NSColor(white: 1, alpha: 0.12))
  static let checkboxSelection = dynamic(light: .controlAccentColor.withAlphaComponent(0.22), dark: NSColor(white: 1, alpha: 0.12))
  static let checkedControlFill = dynamic(light: .controlAccentColor, dark: NSColor(white: 1, alpha: 0.2))
  static let passiveIcon = dynamic(light: .controlAccentColor, dark: .labelColor)
}

private struct AIMControlHeightKey: EnvironmentKey { static let defaultValue = AIMTheme.controlHeight }

extension EnvironmentValues {
  /// 28 in cards; table rows set 22.
  var aimControlHeight: CGFloat {
    get { self[AIMControlHeightKey.self] }
    set { self[AIMControlHeightKey.self] = newValue }
  }
}

// MARK: - Hairline

/// Every border and rule is exactly one device pixel: 1 pt at 1x, 0.5 pt at 2x. A 0.5 pt line at 1x
/// falls between pixels and smears, darkest at the rounded corners. Read it here and nowhere else.
extension EnvironmentValues {
  var aimPixel: CGFloat { 1 / max(displayScale, 1) }
}

private struct AIMBorder<S: InsettableShape>: ViewModifier {
  @Environment(\.aimPixel) private var pixel
  let color: Color
  let shape: S
  func body(content: Content) -> some View {
    content.overlay(shape.strokeBorder(color, lineWidth: pixel).allowsHitTesting(false))
  }
}

extension View {
  /// A one-pixel border drawn inside `shape`.
  func aimBorder<S: InsettableShape>(_ color: Color, in shape: S) -> some View {
    modifier(AIMBorder(color: color, shape: shape))
  }
}

/// A one-pixel rule: horizontal by default, vertical when `vertical` (give it a height).
struct AIMHairline: View {
  @Environment(\.aimPixel) private var pixel
  var vertical = false
  var body: some View {
    Rectangle().fill(AIMTheme.hairline)
      .frame(width: vertical ? pixel : nil, height: vertical ? nil : pixel)
      .accessibilityHidden(true)
  }
}

// MARK: - Card

/// The one card: 10 radius, 16 inset, a hairline border. The optional title row is 44 tall, with
/// the Section title on the left and a Secondary count or an accent link on the right.
struct AIMCard<Accessory: View, Content: View>: View {
  var title: String? = nil
  /// A Secondary note after the title, such as "(Claude Code)".
  var note: String? = nil
  /// A hairline between the title row and the content.
  var divider = false
  var edges = AIMCardEdges.both
  /// A well: the title and tile row share the card's 16 pt inset.
  var well = false
  /// The content scrolls to the card's edges (a list), so the even-padding check skips it.
  var scrolls = false
  /// Space under the content. A title puts the first content 14 pt below the top edge, so a card
  /// that ends in rows adds what its last row lacks (see AIMTheme.rowsEndInset and friends).
  var bottomInset: CGFloat = 1
  var accessory: Accessory
  var content: Content
  private let source: (file: StaticString, line: UInt)

  init(
    title: String? = nil, note: String? = nil, divider: Bool = false, edges: AIMCardEdges = .both,
    well: Bool = false, scrolls: Bool = false, bottomInset: CGFloat = 1,
    file: StaticString = #fileID, line: UInt = #line,
    @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.note = note
    self.divider = divider
    self.edges = edges
    self.well = well
    self.scrolls = scrolls
    self.bottomInset = bottomInset
    self.source = (file, line)
    self.accessory = accessory()
    self.content = content()
  }

  /// Names this card's lint groups, so the title row and the body edges are compared per card.
  @State private var cardID = UUID().uuidString.prefix(8).lowercased()

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: AIMTheme.radius, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      if let title {
        HStack(spacing: AIMTheme.rowSpacing) {
          Text(title).aimText(.section).uiLint(.align("\(cardID)-start", .start))
          if let note { Text(note).aimText(.secondary) }
          Spacer(minLength: AIMTheme.rowSpacing)
          accessory.uiLint(.align("\(cardID)-end", .end))
        }
        .padding(.horizontal, AIMTheme.cardInset)
        .frame(height: AIMTheme.titleRowHeight)
        .accessibilityElement(children: .contain)
        if divider { AIMHairline() }
      }
      content
        .modifier(WellBody(well: well))
    }
    .environment(\.aimCardID, cardID)
    .padding(.bottom, bottomInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AIMTheme.card, in: shape)
    .clipShape(shape)
    .aimBorder(AIMTheme.cardBorder, in: shape)
    .uiLint(.card(radius: AIMTheme.radius), fill: AIMTheme.card, file: source.file, line: source.line)
    .modifier(CardScrollTag(scrolls: scrolls))
    .modifier(CardEdgeTags(edges: edges))
    .aimAppear()
  }
}

private struct CardScrollTag: ViewModifier {
  let scrolls: Bool

  @ViewBuilder func body(content: Content) -> some View {
    if scrolls { content.uiLint(.scrolls) } else { content }
  }
}

/// Which page margin a card touches. A full-width card touches both; the two cards that share a
/// row (Conversations) touch one each. The lint checks the edges.
enum AIMCardEdges { case both, start, end }

private struct WellBody: ViewModifier {
  let well: Bool

  @ViewBuilder func body(content: Content) -> some View {
    if well {
      content.frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .bottom], AIMTheme.tileInset)
    } else { content }
  }
}

private struct CardEdgeTags: ViewModifier {
  let edges: AIMCardEdges

  @ViewBuilder func body(content: Content) -> some View {
    switch edges {
    case .both: content.uiLint(.align("cards-start", .start)).uiLint(.align("cards-end", .end))
    case .start: content.uiLint(.align("cards-start", .start))
    case .end: content.uiLint(.align("cards-end", .end))
    }
  }
}

extension AIMCard where Accessory == EmptyView {
  init(
    title: String? = nil, note: String? = nil, divider: Bool = false, edges: AIMCardEdges = .both,
    well: Bool = false, scrolls: Bool = false, bottomInset: CGFloat = 1,
    file: StaticString = #fileID, line: UInt = #line, @ViewBuilder content: () -> Content
  ) {
    self.init(
      title: title, note: note, divider: divider, edges: edges, well: well, scrolls: scrolls,
      bottomInset: bottomInset, file: file, line: line, accessory: { EmptyView() }, content: content)
  }
}

/// An accent "View … →" link for a card's title row.
struct AIMCardLink: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title)
        Image(systemName: "arrow.right")
      }
      .aimFont(.body)
      .foregroundStyle(AIMTheme.linkColor)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }
}

// MARK: - Detail pages

/// An account detail: full-width cards 12 apart. The Accounts page scrolls it with the table.
struct AIMDetailPage<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: AIMTheme.cardGap) { content }
  }
}

/// A row of a card: the label (a title with an optional Secondary line) on the left, the control
/// or value on the right.
struct AIMLabeledContentStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .center, spacing: AIMTheme.sectionSpacing) {
      VStack(alignment: .leading, spacing: 2) { configuration.label }
      Spacer(minLength: AIMTheme.rowSpacing)
      configuration.content
    }
  }
}

/// A switch row: the label on the left, the switch on the right.
struct AIMToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .center, spacing: AIMTheme.sectionSpacing) {
      VStack(alignment: .leading, spacing: 2) { configuration.label }
      Spacer(minLength: AIMTheme.rowSpacing)
      Button { configuration.isOn.toggle() } label: { Color.clear }
        .buttonStyle(AIMSwitchButtonStyle(isOn: configuration.isOn))
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(configuration.isOn ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
  }
}

/// The flat switch: a 38 x 22 capsule track with a white knob. The system switch draws a light
/// rim in Dark Mode; this one is a fill only (the hairline rim and knob shadow are light only).
private struct AIMSwitchButtonStyle: ButtonStyle {
  let isOn: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var focused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    let track = Capsule()
    ZStack(alignment: isOn ? .trailing : .leading) {
      track.fill(isOn ? Color.accentColor : AIMTheme.switchOff)
      Circle().fill(Color.white).frame(width: 18, height: 18).padding(2)
        .shadow(color: AIMTheme.controlShadow, radius: 0.5, y: 0.5)
    }
    .frame(width: 38, height: 22)
    .overlay(track.fill(focused && isEnabled ? AIMTheme.focusTint : Color.clear))
    .aimBorder(AIMTheme.controlBorder, in: track)
    .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: isOn)
    .contentShape(track)
  }
}

/// A checkbox row: a 16 pt rounded box and its label. Flat fill in Dark Mode (the system checkbox
/// draws a light rim); the box fills with the accent and a white tick when on.
struct AIMCheckboxToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(spacing: 6) {
        Color.clear.frame(width: 16, height: 16)
        configuration.label
      }
    }
    .buttonStyle(AIMCheckboxButtonStyle(isOn: configuration.isOn))
    .accessibilityValue(configuration.isOn ? "Checked" : "Unchecked")
    .accessibilityAddTraits(.isToggle)
  }
}

private struct AIMCheckboxButtonStyle: ButtonStyle {
  let isOn: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var focused

  func makeBody(configuration: Configuration) -> some View {
    let box = RoundedRectangle(cornerRadius: 4, style: .continuous)
    configuration.label
      .overlay(alignment: .leading) {
        ZStack {
          box.fill(isOn ? AIMTheme.checkedControlFill : AIMTheme.controlFill)
          box.fill(focused && isEnabled ? AIMTheme.focusTint : Color.clear)
          Color.clear.aimBorder(isOn ? Color.clear : AIMTheme.controlBorder, in: box)
          if isOn {
            AIMIcon(name: .check).aimFont(.caption).fontWeight(.bold).foregroundStyle(Color.white)
          }
        }
        .frame(width: 16, height: 16)
        .opacity(configuration.isPressed ? 0.8 : 1)
      }
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(Rectangle())
  }
}

/// Lays its children out as the rows of a card: 16 inset, at least 36 tall, a hairline between.
/// The last row ends `contentInset` above the card's bottom edge whatever it holds, and without a
/// title the first row starts `contentInset` below the top edge, so top and bottom padding match.
private struct AIMRowsRoot: _VariadicView_UnaryViewRoot {
  var titled = true

  func body(children: _VariadicView.Children) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(children.enumerated()), id: \.offset) { index, child in
        let first = index == 0 && !titled, last = index == children.count - 1
        if index > 0 { AIMRowSeparator() }
        child
          .frame(maxWidth: .infinity, alignment: .leading)
          .aimBodyEdges()
          .padding(.horizontal, AIMTheme.cardInset)
          .padding(.top, first ? AIMTheme.contentInset : AIMTheme.rowSpacing)
          .padding(.bottom, last ? AIMTheme.contentInset : AIMTheme.rowSpacing)
          .frame(maxWidth: .infinity, minHeight: first || last ? 0 : AIMTheme.rowHeight, alignment: .leading)
      }
    }
  }
}

struct AIMRows<Content: View>: View {
  var titled = true
  @ViewBuilder var content: Content
  var body: some View { _VariadicView.Tree(AIMRowsRoot(titled: titled)) { content } }
}

/// A titled card of rows (the card replacement for a form Section). The title row holds an
/// optional Secondary accessory on the right.
struct AIMSection<Accessory: View, Content: View>: View {
  var title: String? = nil
  var accessory: Accessory
  var content: Content
  private let source: (file: StaticString, line: UInt)

  init(
    _ title: String? = nil, file: StaticString = #fileID, line: UInt = #line,
    @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.source = (file, line)
    self.accessory = accessory()
    self.content = content()
  }

  var body: some View {
    AIMCard(
      title: title, divider: title != nil, bottomInset: 0,
      file: source.file, line: source.line, accessory: { accessory }
    ) {
      AIMRows(titled: title != nil) { content }
        .labeledContentStyle(AIMLabeledContentStyle())
        .toggleStyle(AIMToggleStyle())
    }
  }
}

extension AIMSection where Accessory == EmptyView {
  init(
    _ title: String? = nil, file: StaticString = #fileID, line: UInt = #line,
    @ViewBuilder content: () -> Content
  ) {
    self.init(title, file: file, line: line, accessory: { EmptyView() }, content: content)
  }
}

private struct AIMPageHeaderKey: EnvironmentKey { static let defaultValue = AnyView(EmptyView()) }
private struct AIMCardIDKey: EnvironmentKey { static let defaultValue = "" }

extension View {
  /// Marks the card body content whose leading and trailing edges must line up with the card's
  /// title row (16 inset). Put it on the 16-inset content of a titled card; the lint compares them.
  func aimBodyEdges() -> some View { modifier(AIMBodyEdges()) }
}

private struct AIMBodyEdges: ViewModifier {
  @Environment(\.aimCardID) private var id

  func body(content: Content) -> some View {
    content.uiLint(.align("\(id)-start", .start)).uiLint(.align("\(id)-end", .end))
  }
}

extension EnvironmentValues {
  var aimCardID: String {
    get { self[AIMCardIDKey.self] }
    set { self[AIMCardIDKey.self] = newValue }
  }

  /// The window's top row (Add, More, search) and error bar. A page draws it inside its own
  /// content, so it always has the cards' width, with legacy or overlay scroll bars.
  var aimPageHeader: AnyView {
    get { self[AIMPageHeaderKey.self] }
    set { self[AIMPageHeaderKey.self] = newValue }
  }
}

/// A scrolling page: the header pinned on top, then full-width cards 12 apart, all inside one
/// scroll view so the header and the cards share their left and right edges.
struct AIMScrollPage<Content: View>: View {
  @ViewBuilder var content: Content
  @Environment(\.aimPageHeader) private var header

  @Environment(\.aimPageName) private var pageName

  var body: some View {
    // The 20 pt page margin is the scroll bar's gutter, so the cards keep one width whether or not
    // the page scrolls.
    AIMScrollView(name: pageName, gutter: AIMTheme.pageMargin, topInset: AIMTheme.topBarHeight) {
      LazyVStack(spacing: AIMTheme.cardGap, pinnedViews: [.sectionHeaders]) {
        Section {
          content
        } header: {
          header.frame(maxWidth: .infinity).background(AIMTheme.page)
        }
      }
      .padding([.horizontal, .bottom], AIMTheme.pageMargin)
    }
    .modifier(PlainTopEdge())
    // A page (or Maintenance tab) with another name gets its own scroll view and remembered offset.
    .id(pageName)
  }
}

private struct AIMPageNameKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
  /// Names the page for its remembered scroll position.
  var aimPageName: String {
    get { self[AIMPageNameKey.self] }
    set { self[AIMPageNameKey.self] = newValue }
  }
}

// MARK: - Scroll bar

/// Reads a SwiftUI ScrollView's AppKit scroll view: hides the system indicators, reports the
/// offset and sizes, scrolls on request, and remembers the offset by name. `activity` counts user
/// scrolls (offset moves outside the quiet window after attach or a restore), so the hidden-at-rest
/// bar can fade in; content or viewport changes alone never bump it.
@MainActor final class AIMScrollBarModel: ObservableObject {
  @Published private(set) var activity = 0
  private var quietUntil = Date.distantPast
  @Published private(set) var offset: CGFloat = 0
  @Published private(set) var content: CGFloat = 0
  @Published private(set) var viewport: CGFloat = 0
  var name = ""
  private weak var scrollView: NSScrollView?
  private var observers: [NSObjectProtocol] = []
  private var pending: CGFloat?
  private var restoreDeadline = Date.distantPast

  var canScroll: Bool { viewport > 0 && content > viewport + 0.5 }
  var travel: CGFloat { max(0, content - viewport) }

  func attach(_ next: NSScrollView) {
    guard scrollView !== next else { return }
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    scrollView = next
    next.hasVerticalScroller = false
    next.hasHorizontalScroller = false
    let clip = next.contentView
    clip.postsBoundsChangedNotifications = true
    var watched: [NSView] = [clip]
    if let document = next.documentView {
      document.postsFrameChangedNotifications = true
      watched.append(document)
    }
    for view in watched {
      for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) {
          [weak self] _ in MainActor.assumeIsolated { self?.sync() }
        })
      }
    }
    if !name.isEmpty, let saved = AIMPlace.scroll[name], saved > 0 {
      pending = saved
      restoreDeadline = Date().addingTimeInterval(1.5)
    }
    quietUntil = Date().addingTimeInterval(0.3)
    sync()
  }

  private func sync() {
    guard let scrollView, let document = scrollView.documentView else { return }
    let clip = scrollView.contentView
    if let wanted = pending {
      if Date() > restoreDeadline { pending = nil }
      else if document.frame.height - clip.bounds.height >= wanted - 0.5 {
        pending = nil
        quietUntil = Date().addingTimeInterval(0.3)
        scroll(to: wanted)
      }
    }
    let next = (clip.bounds.minY, document.frame.height, clip.bounds.height)
    if abs(next.0 - offset) > 0.5, Date() >= quietUntil { activity &+= 1 }
    if abs(next.0 - offset) > 0.1 { offset = next.0 }
    if abs(next.1 - content) > 0.1 { content = next.1 }
    if abs(next.2 - viewport) > 0.1 { viewport = next.2 }
    if pending == nil, !name.isEmpty { AIMPlace.scroll[name] = next.0 }
  }

  func scroll(to y: CGFloat) {
    guard let scrollView else { return }
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(y, 0), travel)))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }
}

private struct AIMScrollBinder: NSViewRepresentable {
  let model: AIMScrollBarModel
  let name: String

  func makeNSView(context: Context) -> Probe {
    model.name = name
    let view = Probe()
    view.model = model
    return view
  }

  func updateNSView(_ view: Probe, context: Context) { view.model = model }

  final class Probe: NSView {
    var model: AIMScrollBarModel?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else { return }
      // The scroll view exists once SwiftUI has placed the content.
      DispatchQueue.main.async { [weak self] in
        guard let self, let scroll = self.enclosingScrollView else { return }
        MainActor.assumeIsolated { self.model?.attach(scroll) }
      }
    }
  }
}

/// The thin bar: a transparent track in a fixed gutter and a rounded thumb. It is hidden at rest,
/// fades in (4 -> 6 pt) while the user scrolls and widens to 8 pt on hover or drag, and fades out
/// 1 s after the last scroll or when the pointer leaves. It can be dragged, and a click on the
/// track jumps there.
private struct AIMScrollBar: View {
  @ObservedObject var model: AIMScrollBarModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false
  @State private var dragStart: CGFloat?
  @State private var shown = false
  @State private var hideTask: Task<Void, Never>?

  private func reveal() {
    withAnimation(.easeOut(duration: 0.15)) { shown = true }
    scheduleHide()
  }

  private func scheduleHide() {
    hideTask?.cancel()
    hideTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, !hovering, dragStart == nil else { return }
      withAnimation(.easeIn(duration: 0.3)) { shown = false }
    }
  }

  var body: some View {
    GeometryReader { geometry in
      let track = geometry.size.height
      let thumb = model.canScroll ? min(track, max(28, track * model.viewport / model.content)) : 0
      let free = max(1, track - thumb)
      let top = model.travel > 0 ? free * min(max(model.offset / model.travel, 0), 1) : 0
      ZStack(alignment: .top) {
        Color.clear
        if model.canScroll {
          let hot = hovering || dragStart != nil
          let width: CGFloat = reduceMotion ? (hot ? 8 : 6) : (!shown ? 4 : hot ? 8 : 6)
          Capsule()
            .fill(Color(nsColor: .labelColor).opacity(hot ? 0.4 : 0.25))
            .frame(width: width, height: thumb)
            .opacity(shown ? 1 : 0)
            // Before .offset so the thumb position never lags during a drag.
            .animation(.easeOut(duration: 0.15), value: hot)
            .offset(y: top)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .onChange(of: model.activity) { reveal() }
      .onHover { inside in
        hovering = inside && model.canScroll
        if hovering { reveal() } else { scheduleHide() }
      }
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { value in
          guard model.canScroll else { return }
          if dragStart == nil {
            let inside = value.startLocation.y >= top && value.startLocation.y <= top + thumb
            dragStart = inside ? model.offset : model.travel * min(max((value.startLocation.y - thumb / 2) / free, 0), 1)
            if !inside { model.scroll(to: dragStart ?? 0) }
          }
          model.scroll(to: (dragStart ?? 0) + (value.location.y - value.startLocation.y) / free * model.travel)
        }
        .onEnded { _ in dragStart = nil; scheduleHide() })
    }
    .accessibilityHidden(true)
  }
}

/// A vertical scroll view without system indicators. The thin bar sits in a trailing gutter of
/// `gutter` points that is always reserved (the bar itself is hidden at rest): the caller's content
/// already leaves that margin, so the content width never changes when the bar shows or hides.
struct AIMScrollView<Content: View>: View {
  var name = ""
  var gutter: CGFloat = AIMScroller.gutter
  /// Space above the bar's track, for a pinned top bar.
  var topInset: CGFloat = 0
  @ViewBuilder var content: Content
  @StateObject private var model = AIMScrollBarModel()

  var body: some View {
    ScrollView(.vertical) {
      content.background(AIMScrollBinder(model: model, name: name))
    }
    // `.hidden` still reserves a 17 pt legacy scroller strip beside the page; `.never` reserves none.
    .scrollIndicators(.never)
    .overlay(alignment: .trailing) {
      AIMScrollBar(model: model).frame(width: gutter).padding(.top, topInset)
    }
  }
}

/// Sheet forms share the page scroll policy; the footer remains outside the scroll host.
struct AIMSheetForm<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    AIMScrollView {
      VStack(alignment: .leading, spacing: AIMTheme.sectionSpacing) { content }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AIMTheme.pageMargin)
    }
    .textFieldStyle(AIMSheetTextFieldStyle())
    .buttonStyle(AIMPushButtonStyle())
    .focusEffectDisabled(!AIMFocus.showsSystemRings)
  }
}

struct AIMSheetTextFieldStyle: TextFieldStyle {
  @FocusState private var focused: Bool
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration.textFieldStyle(.plain).focused($focused).aimFieldChrome(focused: focused)
  }
}

/// The pinned header already paints the page color under the transparent title bar, so macOS 26's
/// automatic scroll edge effect (a tinted blur at the top) must not draw over it.
private struct PlainTopEdge: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.scrollEdgeEffectHidden(true, for: .top)
    } else {
      content
    }
  }
}

/// A page that does not scroll as a whole (Conversations): the header, then the content.
struct AIMFixedPage<Content: View>: View {
  @ViewBuilder var content: Content
  @Environment(\.aimPageHeader) private var header

  var body: some View {
    VStack(spacing: 0) {
      header
      content.padding(.top, AIMTheme.cardGap)
    }
    .padding([.horizontal, .bottom], AIMTheme.pageMargin)
  }
}

// MARK: - Tile

extension View {
  /// A tile inside a card, with its own readable content inset.
  func aimTile() -> some View {
    let shape = RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous)
    return padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AIMTheme.tileFill, in: shape)
      .aimBorder(AIMTheme.cardBorder, in: shape)
      .uiLint(.item, .tile(radius: AIMTheme.tileRadius))
  }
}

// MARK: - Columns

/// One column of a table. Every row uses the same list, so they share widths. Tables have no
/// header row: the rows explain themselves.
struct AIMColumn: Identifiable {
  let id: String
  /// Nil is the flexible column; a table has exactly one.
  var width: CGFloat? = nil
  var alignment: Alignment = .leading
}

enum AIMColumns {
  static let gap: CGFloat = 12
  /// No Provider column (the group header says it) and no Resets column (the usage cell ends in
  /// the reset time). The account name takes the free width.
  static let accounts: [AIMColumn] = [
    AIMColumn(id: "account"),
    AIMColumn(id: "usage", width: 340),
    AIMColumn(id: "actions", width: AIMTheme.rowButtonWidth + 8 + AIMTheme.rowControlHeight),
  ]
}

extension View {
  /// Gives a cell its column's width and alignment, and tags it for the lint's column groups.
  @ViewBuilder func aimColumn(_ column: AIMColumn, group: String) -> some View {
    if let width = column.width {
      frame(width: width, alignment: column.alignment)
        .uiLint(.align("\(group)-col-\(column.id)", column.alignment == .trailing ? .end : .start))
    } else {
      frame(maxWidth: .infinity, alignment: column.alignment)
        .uiLint(.align("\(group)-col-\(column.id)", column.alignment == .trailing ? .end : .start))
    }
  }
}

/// One 36 pt table row on the card's 16 inset. A highlight sits 6 in from the card edge with a 6
/// radius. Selection, hover, and keyboard focus are fills that fade in and out, never outlines.
struct AIMTableRow<Content: View>: View {
  var highlighted = false
  /// Keyboard focus: a fainter fill in the same shape. Selection is a fill, never an outline.
  var focused = false
  /// Draws the hover fill without a pointer, for Preview screenshots.
  var previewHovering = false
  /// Extra leading space for rows under a group header. The highlight then starts 8 pt left of the
  /// content and ends 8 pt right of it, instead of 6 pt from the card edges.
  var indent: CGFloat = 0
  @ViewBuilder var content: Content
  @State private var pointerInside = false

  var body: some View {
    let hovering = pointerInside || previewHovering
    let shape = RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous)
    let wash = indent > 0 ? AIMTheme.cardInset - 8 : 6
    HStack(spacing: AIMColumns.gap) { content }
      .padding(.leading, AIMTheme.cardInset + indent)
      .padding(.trailing, AIMTheme.cardInset)
      .frame(height: AIMTheme.rowHeight)
      .frame(maxWidth: .infinity)
      .background(alignment: .center) {
        ZStack {
          shape.fill(AIMTheme.rowHover).opacity(hovering && !highlighted ? 1 : 0)
          shape.fill(AIMTheme.focusTint).opacity(focused && !highlighted ? 1 : 0)
          shape.fill(AIMTheme.rowHighlight).opacity(highlighted ? 1 : 0)
        }
        .padding(.leading, wash + indent)
        .padding(.trailing, wash)
        .padding(.vertical, AIMTheme.highlightInset)
        .animation(AIMMotion.fade(AIMMotion.hover), value: hovering)
        .animation(AIMMotion.fade(AIMMotion.hover), value: highlighted)
        .allowsHitTesting(false)
      }
      .contentShape(Rectangle())
      .onHover { pointerInside = $0 }
      .environment(\.aimControlHeight, AIMTheme.rowControlHeight)
  }
}

/// A lighter-than-border rule between rows, on the 16 inset (`indent` moves its start in).
struct AIMRowSeparator: View {
  @Environment(\.aimPixel) private var pixel
  var indent: CGFloat = 0
  var body: some View {
    Rectangle().fill(AIMTheme.tableSeparator).frame(height: pixel)
      .padding(.leading, AIMTheme.cardInset + indent)
      .padding(.trailing, AIMTheme.cardInset)
      .accessibilityHidden(true)
  }
}

// MARK: - Buttons

/// The Sequoia push button: a 28 pt tall (22 in table rows) rounded rectangle with Body text.
/// Prominent is the accent fill.
struct AIMPushButtonStyle: ButtonStyle {
  var prominent = false
  var square = false
  /// A fixed width, so a table row's Switch button matches the disabled Default button.
  var width: CGFloat? = nil

  func makeBody(configuration: Configuration) -> some View {
    AIMPushButtonFace(configuration: configuration, prominent: prominent, square: square, width: width)
  }
}

/// The button's face. It owns the hover state, so the fill fades in and out and a press dims and
/// shrinks it a little (the shrink is skipped with Reduce Motion).
private struct AIMPushButtonFace: View {
  let configuration: ButtonStyleConfiguration
  let prominent: Bool
  let square: Bool
  let width: CGFloat?
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var focused
  @Environment(\.aimControlHeight) private var height
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    let pressed = configuration.isPressed
    // A disabled button dims each part, not the whole face: a group opacity makes Core Animation
    // draw the face through an offscreen layer as large as the card (9 rows cost about 40 ms).
    let dim = isEnabled ? 1.0 : 0.45
    configuration.label
      .labelStyle(AIMButtonLabelStyle())
      .aimFont(.body)
      .foregroundStyle((prominent ? Color.white : Color.primary).opacity(dim))
      .lineLimit(1)
      .padding(.horizontal, square ? 0 : (height < AIMTheme.controlHeight ? 10 : 12))
      .frame(width: square ? height : width, height: height)
      .background(shape.fill(fill(pressed: pressed).opacity(dim)))
      .overlay(shape.fill(focused && isEnabled ? AIMTheme.focusTint : Color.clear))
      .overlay(shape.fill(hovering && isEnabled && !pressed ? hoverTint : Color.clear))
      // The rim is light-mode only; Dark Mode controls are flat fills. No drop shadow: a half-point
      // blur falls between pixels at 1x and smears the edge.
      .aimBorder((prominent ? AIMTheme.primaryBorder : AIMTheme.controlBorder).opacity(dim), in: shape)
      .contentShape(shape)
      .uiLint(.control)
      .onHover { hovering = $0 }
      .scaleEffect(AIMMotion.scale(pressed: pressed && isEnabled, reduceMotion: reduceMotion))
      .animation(AIMMotion.fade(AIMMotion.hover), value: hovering)
      .animation(AIMMotion.fade(AIMMotion.hover), value: pressed)
  }

  private var hoverTint: Color { prominent ? Color.white.opacity(0.14) : AIMTheme.rowHover }

  private func fill(pressed: Bool) -> Color {
    if prominent { return Color.accentColor.opacity(pressed ? 0.8 : 1) }
    return pressed ? AIMTheme.controlPressed : AIMTheme.controlFill
  }
}

/// A borderless icon-only button: a faint fill fades in on hover, and a press dims and shrinks it.
struct AIMIconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    AIMIconButtonFace(configuration: configuration)
  }
}

private struct AIMIconButtonFace: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var focused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    let pressed = configuration.isPressed
    configuration.label
      .padding(4)
      .background(shape.fill(hovering && isEnabled ? AIMTheme.rowHover : (focused && isEnabled ? AIMTheme.focusTint : Color.clear)))
      .padding(-4)
      .opacity(pressed ? 0.7 : 1)
      .contentShape(shape)
      .onHover { hovering = $0 }
      .scaleEffect(AIMMotion.scale(pressed: pressed && isEnabled, reduceMotion: reduceMotion))
      .animation(AIMMotion.fade(AIMMotion.hover), value: hovering)
      .animation(AIMMotion.fade(AIMMotion.hover), value: pressed)
  }
}

/// An icon and a title 6 pt apart, the same in every button.
struct AIMButtonLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon
      configuration.title
    }
  }
}

/// A square icon-only button with an accessible name and a tooltip.
struct AIMSquareButton: View {
  let icon: AIMIcon.Name
  let label: String
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) { AIMIcon(name: icon) }
      .buttonStyle(AIMPushButtonStyle(square: true))
      .disabled(disabled)
      .help(label)
      .accessibilityLabel(label)
  }
}

/// A square icon-only menu button.
struct AIMIconMenu<Items: View>: View {
  let icon: AIMIcon.Name
  let label: String
  @ViewBuilder var items: Items

  var body: some View {
    Menu { items } label: { AIMIcon(name: icon) }
      .menuStyle(.button)
      .buttonStyle(AIMPushButtonStyle(square: true))
      .menuIndicator(.hidden)
      .fixedSize()
      .help(label)
      .accessibilityLabel(label)
  }
}

// MARK: - Search field

/// The 300 pt "Search accounts…" field with a ⌘K hint.
struct AIMSearchField: View {
  @Binding var text: String
  var focus: FocusState<Bool>.Binding
  let prompt: String

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").aimFont(.body).foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .aimFont(.body)
        .focused(focus)
        .onExitCommand { text = ""; focus.wrappedValue = false }
        .accessibilityLabel("Search accounts")
        .accessibilityIdentifier("toolbar-search")
      if text.isEmpty {
        Text("⌘K").aimText(.secondary)
          .padding(.horizontal, 6)
          .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          .accessibilityHidden(true).allowsHitTesting(false)
      } else {
        Button { text = "" } label: { Image(systemName: "xmark.circle.fill").aimFont(.body) }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .help("Clear search").accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 8)
    .frame(width: AIMTheme.toolbarSearchWidth, height: AIMTheme.controlHeight)
    .background(AIMTheme.controlFill, in: shape)
    .overlay(shape.fill(focus.wrappedValue ? AIMTheme.focusTint : Color.clear).allowsHitTesting(false))
    .aimBorder(AIMTheme.controlBorder, in: shape)
    .contentShape(shape)
    // Clicking the icon, the hint, or the padding focuses the field.
    .onTapGesture { focus.wrappedValue = true }
    .uiLint(.control)
    .uiLint(.align("cards-end", .end))
  }
}

/// The 28 pt text field of cards and sheets: a flat fill (hairline rim in light mode only), 8 pt
/// side padding, keyboard focus as a tint. Use with `.textFieldStyle(.plain)`.
struct AIMFieldChrome: ViewModifier {
  var focused = false
  var width: CGFloat? = nil

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    content
      .aimFont(.body)
      .padding(.horizontal, 8)
      .frame(width: width, height: AIMTheme.controlHeight)
      .background(AIMTheme.controlFill, in: shape)
      .overlay(shape.fill(focused ? AIMTheme.focusTint : Color.clear).allowsHitTesting(false))
      .aimBorder(AIMTheme.controlBorder, in: shape)
      .uiLint(.control)
  }
}

extension View {
  func aimFieldChrome(focused: Bool = false, width: CGFloat? = nil) -> some View {
    modifier(AIMFieldChrome(focused: focused, width: width))
  }
}

/// A pop-up menu button in the push-button look (the system pop-up draws a light rim in Dark Mode).
struct AIMPopUp<Option: Hashable>: View {
  let options: [Option]
  @Binding var selection: Option
  let accessibilityLabel: String
  /// A divider follows these options.
  var separatorAfter: Set<Option> = []
  let label: (Option) -> String

  var body: some View {
    Menu {
      ForEach(options, id: \.self) { option in
        Button { selection = option } label: {
          if option == selection {
            Label(label(option), systemImage: AIMIcon.Name.check.symbol)
          } else {
            Text(label(option))
          }
        }
        if separatorAfter.contains(option) { Divider() }
      }
    } label: {
      HStack(spacing: 6) {
        Text(label(selection))
        Image(systemName: "chevron.up.chevron.down").aimFont(.secondary).foregroundStyle(.secondary)
      }
    }
    .menuStyle(.button)
    .buttonStyle(AIMPushButtonStyle())
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(accessibilityLabel)
  }
}

/// A date field in the push-button look (the system date field draws a light rim in Dark Mode).
/// It opens a calendar popover. `after` is the earliest date allowed.
struct AIMDateField: View {
  let title: String
  @Binding var selection: Date
  var after: Date? = nil
  @State private var open = false

  var body: some View {
    HStack(spacing: 6) {
      Text(title).aimText(.body)
      Button { open.toggle() } label: {
        Text(selection.formatted(date: .abbreviated, time: .omitted)).monospacedDigit()
      }
      .buttonStyle(AIMPushButtonStyle())
      .accessibilityLabel(title)
      .accessibilityValue(selection.formatted(date: .long, time: .omitted))
      .popover(isPresented: $open, arrowEdge: .bottom) {
        DatePicker(title, selection: $selection, in: (after ?? .distantPast)..., displayedComponents: .date)
          .datePickerStyle(.graphical).labelsHidden().padding(8)
      }
    }
  }
}

/// A two-state chip that reads as a push button and fills with the accent when on.
struct AIMChipToggleStyle: ToggleStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var focused

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    Button { configuration.isOn.toggle() } label: {
      configuration.label
        .aimFont(.body)
        .padding(.horizontal, 10)
        .frame(height: AIMTheme.rowControlHeight)
        .background(shape.fill(configuration.isOn ? AIMTheme.checkboxSelection : AIMTheme.controlFill))
        .overlay(shape.fill(focused ? AIMTheme.focusTint : Color.clear))
        .aimBorder(AIMTheme.controlBorder, in: shape)
        .contentShape(shape)
        .uiLint(.control)
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.45)
    .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
  }
}

// MARK: - Sidebar

struct AIMVisualEffect: NSViewRepresentable {
  var material: NSVisualEffectView.Material

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// The translucent 220 pt sidebar: traffic lights over the "Switch" heading, then one row per page.
struct AIMSidebar: View {
  let selection: AIManagerPage
  let select: (AIManagerPage) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Switch").aimText(.section)
        .padding(.leading, 76)
        .frame(height: AIMTheme.topBarHeight, alignment: .leading)
      ForEach(AIManagerPage.allCases, id: \.self) { page in
        row(page)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(width: AIMTheme.sidebarWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .background {
      ZStack {
        AIMTheme.page
        AIMVisualEffect(material: .sidebar)
      }
    }
    .overlay(alignment: .trailing) {
      AIMHairline(vertical: true)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sidebar")
  }

  private func row(_ page: AIManagerPage) -> some View {
    let selected = page == selection
    return Button { select(page) } label: {
      HStack(spacing: 10) {
        Image(systemName: page.icon.symbol).aimFont(.body)
          .foregroundStyle(AIMTheme.passiveIcon)
          .frame(width: 20)
        Text(page.rawValue).aimText(.body)
        Spacer(minLength: 0)
      }
    }
    .buttonStyle(AIMSidebarRowStyle(selected: selected))
    .accessibilityIdentifier("sidebar-\(page.rawValue)")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// A sidebar row: selection is an accent fill, keyboard focus a fainter fill, never an outline.
private struct AIMSidebarRowStyle: ButtonStyle {
  let selected: Bool

  func makeBody(configuration: Configuration) -> some View {
    AIMSidebarRowFace(configuration: configuration, selected: selected)
  }
}

private struct AIMSidebarRowFace: View {
  let configuration: ButtonStyleConfiguration
  let selected: Bool
  @Environment(\.isFocused) private var focused
  @State private var hovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    configuration.label
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background {
        ZStack {
          shape.fill(AIMTheme.rowHover).opacity(hovering && !selected ? 1 : 0)
          shape.fill(AIMTheme.focusTint).opacity(focused && !selected ? 1 : 0)
          shape.fill(AIMTheme.sidebarSelection).opacity(selected ? 1 : 0)
        }
        // Only hover fades. The page swaps in one frame, so the selection fill must too; a fade
        // keeps the old row lit for the first frame of the new page.
        .animation(AIMMotion.fade(AIMMotion.hover), value: hovering)
      }
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}

struct AIMSegmentedPicker<Option: Hashable>: View {
  let options: [Option]
  @Binding var selection: Option
  let accessibilityLabel: String
  let label: (Option) -> String
  /// A fixed segment width, and a 14 pt icon before each title. Icons use the label color.
  var segmentWidth: CGFloat? = nil
  var icon: ((Option) -> AIMIcon.Name)? = nil
  @Namespace private var indicator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// A flat segmented control for compact mutually exclusive choices: a 28 pt track with a filled
  /// selected segment (the system control draws a light rim in Dark Mode). The selected fill slides
  /// between segments; with Reduce Motion it just fades.
  var body: some View {
    let track = RoundedRectangle(cornerRadius: 7, style: .continuous)
    let segment = RoundedRectangle(cornerRadius: 5, style: .continuous)
    HStack(spacing: 2) {
      ForEach(options, id: \.self) { option in
        let selected = option == selection
        Button { withAnimation(AIMMotion.move(reduceMotion: reduceMotion)) { selection = option } } label: {
          HStack(spacing: 6) {
            if let icon {
              AIMIcon(name: icon(option)).aimFont(.body).foregroundStyle(Color.primary)
                .frame(width: 14, height: 14)
            }
            Text(label(option)).aimFont(.body).lineLimit(1)
          }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, segmentWidth == nil ? 12 : 0)
            .frame(width: segmentWidth, height: AIMTheme.controlHeight - 4)
            .background {
              if selected {
                segment.fill(AIMTheme.segmentSelected)
                  .aimBorder(AIMTheme.controlBorder, in: segment)
                  .matchedGeometryEffect(id: "selected", in: indicator)
              }
            }
            .contentShape(segment)
        }
        .buttonStyle(AIMSegmentFocusStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(2)
    .frame(height: AIMTheme.controlHeight)
    .background(AIMTheme.segmentTrack, in: track)
    .uiLint(.control)
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct AIMSegmentFocusStyle: ButtonStyle {
  @Environment(\.isFocused) private var focused
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.overlay {
      RoundedRectangle(cornerRadius: 5).fill(focused ? AIMTheme.focusTint : Color.clear)
        .allowsHitTesting(false)
    }
  }
}
