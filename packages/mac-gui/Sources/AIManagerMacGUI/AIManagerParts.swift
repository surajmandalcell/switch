import AppKit
import SwiftUI

// The shared parts of the Sequoia-style window: Card, title row, column table, push buttons,
// square icon buttons, menu button, chip, search field, tile, sidebar. Geometry is in points and
// comes from specs/product.md section 4. Every font comes from the five text roles.

extension AIMTheme {
  /// Gap between cards and from a card to its neighbours.
  static let cardGap: CGFloat = 12
  /// Inset of a card's title, column headers, rows, and separators.
  static let cardInset: CGFloat = 16
  static let titleRowHeight: CGFloat = 44
  static let rowHeight: CGFloat = 36
  static let headerHeight: CGFloat = 28
  /// A tile sits 6 inside its card with a 4 radius; its text lines up with the 16 inset.
  static let tileInset: CGFloat = 6
  static let tileRadius: CGFloat = 4
  static let sidebarWidth: CGFloat = 220
  static let topBarHeight: CGFloat = 52
  /// Push button heights: in cards, and in table rows.
  static let controlHeight: CGFloat = 28
  static let rowControlHeight: CGFloat = 22
  /// Width shared by the Default chip and the Switch button.
  static let rowButtonWidth: CGFloat = 64

  private static func dynamic(light: NSColor, dark: NSColor) -> Color {
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
  static let cardBorder = dynamic(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.10))
  static let hairline = Color(nsColor: .separatorColor)
  static let tileFill = dynamic(light: NSColor(white: 0, alpha: 0.025), dark: NSColor(white: 1, alpha: 0.04))
  static let controlFill = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.12))
  static let controlPressed = dynamic(light: NSColor(white: 0.93, alpha: 1), dark: NSColor(white: 1, alpha: 0.2))
  static let controlBorder = dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.14))
  static let rowHighlight = Color.accentColor.opacity(0.12)
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

struct AIMHairline: View {
  @Environment(\.displayScale) private var scale
  var body: some View {
    Rectangle().fill(AIMTheme.hairline).frame(height: 1 / max(scale, 1)).accessibilityHidden(true)
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
  /// A well: the title and tiles sit in an inner body 6 in from every side, radius 4 (10 - 6).
  var well = false
  var accessory: Accessory
  var content: Content

  init(
    title: String? = nil, note: String? = nil, divider: Bool = false, edges: AIMCardEdges = .both,
    well: Bool = false,
    @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.note = note
    self.divider = divider
    self.edges = edges
    self.well = well
    self.accessory = accessory()
    self.content = content()
  }

  /// Names this card's lint groups, so the title row and the body edges are compared per card.
  @State private var cardID = UUID().uuidString.prefix(8).lowercased()

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: AIMTheme.radius, style: .continuous)
    let inset = well ? AIMTheme.tileInset : 0
    VStack(alignment: .leading, spacing: 0) {
      if let title {
        HStack(spacing: AIMTheme.rowSpacing) {
          Text(title).aimText(.section).uiLint(.align("\(cardID)-start", .start))
          if let note { Text(note).aimText(.secondary) }
          Spacer(minLength: AIMTheme.rowSpacing)
          accessory.uiLint(.align("\(cardID)-end", .end))
        }
        .padding(.horizontal, AIMTheme.cardInset - inset)
        .frame(height: AIMTheme.titleRowHeight)
        .accessibilityElement(children: .contain)
        if divider { AIMHairline() }
      }
      content
    }
    .environment(\.aimCardID, cardID)
    .modifier(WellBody(well: well))
    // 1 pt of bottom padding keeps a 22 pt control in a 36 pt last row 8 pt from the edge.
    .padding(.bottom, well ? 0 : 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AIMTheme.card, in: shape)
    .clipShape(shape)
    .overlay(shape.strokeBorder(AIMTheme.cardBorder, lineWidth: 0.5))
    .uiLint(.card(radius: AIMTheme.radius), fill: AIMTheme.card)
    .modifier(CardEdgeTags(edges: edges))
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
        .uiLint(.tile(radius: AIMTheme.tileRadius))
        .padding(AIMTheme.tileInset)
    } else { content }
  }
}

private struct CardEdgeTags: ViewModifier {
  let edges: AIMCardEdges
  @Environment(\.aimCardGroup) private var group

  @ViewBuilder func body(content: Content) -> some View {
    switch edges {
    case .both: content.uiLint(.align("\(group)-start", .start)).uiLint(.align("\(group)-end", .end))
    case .start: content.uiLint(.align("\(group)-start", .start))
    case .end: content.uiLint(.align("\(group)-end", .end))
    }
  }
}

extension AIMCard where Accessory == EmptyView {
  init(
    title: String? = nil, note: String? = nil, divider: Bool = false, edges: AIMCardEdges = .both,
    well: Bool = false, @ViewBuilder content: () -> Content
  ) {
    self.init(
      title: title, note: note, divider: divider, edges: edges, well: well, accessory: { EmptyView() },
      content: content)
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
      Toggle(isOn: configuration.$isOn) { EmptyView() }
        .toggleStyle(.switch).labelsHidden()
    }
    .accessibilityElement(children: .combine)
  }
}

/// Lays its children out as the rows of a card: 16 inset, at least 36 tall, a hairline between.
private struct AIMRowsRoot: _VariadicView_UnaryViewRoot {
  func body(children: _VariadicView.Children) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(children.enumerated()), id: \.offset) { index, child in
        if index > 0 { AIMRowSeparator() }
        child
          .frame(maxWidth: .infinity, alignment: .leading)
          .aimBodyEdges()
          .padding(.horizontal, AIMTheme.cardInset).padding(.vertical, AIMTheme.rowSpacing)
          .frame(maxWidth: .infinity, minHeight: AIMTheme.rowHeight, alignment: .leading)
      }
    }
  }
}

struct AIMRows<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View { _VariadicView.Tree(AIMRowsRoot()) { content } }
}

/// A titled card of rows (the card replacement for a form Section). The title row holds an
/// optional Secondary accessory on the right.
struct AIMSection<Accessory: View, Content: View>: View {
  var title: String? = nil
  var accessory: Accessory
  var content: Content

  init(
    _ title: String? = nil, @ViewBuilder accessory: () -> Accessory,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.accessory = accessory()
    self.content = content()
  }

  var body: some View {
    AIMCard(title: title, divider: title != nil, accessory: { accessory }) {
      AIMRows { content }
        .labeledContentStyle(AIMLabeledContentStyle())
        .toggleStyle(AIMToggleStyle())
    }
  }
}

extension AIMSection where Accessory == EmptyView {
  init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
    self.init(title, accessory: { EmptyView() }, content: content)
  }
}

private struct AIMPageHeaderKey: EnvironmentKey { static let defaultValue = AnyView(EmptyView()) }
private struct AIMCardGroupKey: EnvironmentKey { static let defaultValue = "cards" }
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

  /// The lint alignment group of a card's edges: "cards" for full-width pages (shared with the
  /// search field), "column" for the centered Settings column.
  var aimCardGroup: String {
    get { self[AIMCardGroupKey.self] }
    set { self[AIMCardGroupKey.self] = newValue }
  }

  /// The window's top row (Add, More, search) and error bar. A page draws it inside its own
  /// content, so it always has the cards' width, with legacy or overlay scroll bars.
  var aimPageHeader: AnyView {
    get { self[AIMPageHeaderKey.self] }
    set { self[AIMPageHeaderKey.self] = newValue }
  }
}

/// A scrolling page: the header pinned on top, then full-width cards 12 apart, all inside one
/// scroll view so the header and the cards share their left and right edges. `maxWidth` makes a
/// centered column (Settings).
struct AIMScrollPage<Content: View>: View {
  var maxWidth: CGFloat? = nil
  @ViewBuilder var content: Content
  @Environment(\.aimPageHeader) private var header

  var body: some View {
    ScrollView {
      LazyVStack(spacing: AIMTheme.cardGap, pinnedViews: [.sectionHeaders]) {
        Section {
          if let maxWidth {
            // The header stays full width; only the cards form the centered column.
            VStack(spacing: AIMTheme.cardGap) { content }
              .frame(maxWidth: maxWidth)
              .frame(maxWidth: .infinity)
              .environment(\.aimCardGroup, "column")
          } else {
            content
          }
        } header: {
          header.frame(maxWidth: .infinity).background(AIMTheme.page)
        }
      }
      .padding([.horizontal, .bottom], AIMTheme.pageMargin)
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
  /// A tile inside a card: 6 in from the card edge, 4 radius, text lined up with the 16 inset.
  func aimTile() -> some View {
    let shape = RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous)
    return padding(AIMTheme.cardInset - AIMTheme.tileInset)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AIMTheme.tileFill, in: shape)
      .overlay(shape.strokeBorder(AIMTheme.cardBorder, lineWidth: 0.5))
  }
}

// MARK: - Columns

/// One column of a table. The header and every row use the same list, so they share widths.
struct AIMColumn: Identifiable {
  let id: String
  let title: String
  /// Nil is the flexible column; a table has exactly one.
  var width: CGFloat? = nil
  var alignment: Alignment = .leading
}

enum AIMColumns {
  static let gap: CGFloat = 12
  static let accounts: [AIMColumn] = [
    AIMColumn(id: "account", title: "Account"),
    AIMColumn(id: "provider", title: "Provider", width: 112),
    AIMColumn(id: "usage", title: "Usage", width: 176),
    AIMColumn(id: "resets", title: "Resets", width: 88),
    AIMColumn(id: "actions", title: "Actions", width: AIMTheme.rowButtonWidth + 8 + AIMTheme.rowControlHeight),
  ]
  /// Recent activity: period, tokens, estimated cost.
  static let activity: [AIMColumn] = [
    AIMColumn(id: "period", title: "Period"),
    AIMColumn(id: "tokens", title: "Tokens", width: 200, alignment: .trailing),
    AIMColumn(id: "cost", title: "Cost", width: 140, alignment: .trailing),
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

/// The column header row: Secondary titles on the card's 16 inset.
struct AIMTableHeader: View {
  let columns: [AIMColumn]
  let group: String

  var body: some View {
    HStack(spacing: AIMColumns.gap) {
      ForEach(columns) { column in
        Text(column.title).aimText(.secondary).lineLimit(1)
          .aimColumn(column, group: group)
      }
    }
    .padding(.horizontal, AIMTheme.cardInset)
    .frame(height: AIMTheme.headerHeight)
    .accessibilityHidden(true)
  }
}

/// One 36 pt table row. Its cells sit on the same 16 inset as the header; a highlight sits 6 in
/// from the card edge with a 4 radius so the corners stay concentric.
struct AIMTableRow<Content: View>: View {
  var highlighted = false
  @ViewBuilder var content: Content

  var body: some View {
    HStack(spacing: AIMColumns.gap) { content }
      .padding(.horizontal, AIMTheme.cardInset)
      .frame(height: AIMTheme.rowHeight)
      .frame(maxWidth: .infinity)
      .background(alignment: .center) {
        if highlighted {
          RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous)
            .fill(AIMTheme.rowHighlight)
            .padding(.horizontal, AIMTheme.tileInset)
        }
      }
      .environment(\.aimControlHeight, AIMTheme.rowControlHeight)
  }
}

/// A hairline between rows, on the 16 inset.
struct AIMRowSeparator: View {
  var body: some View {
    AIMHairline().padding(.horizontal, AIMTheme.cardInset)
  }
}

// MARK: - Buttons

/// The Sequoia push button: a 28 pt tall (22 in table rows) rounded rectangle with Body text.
/// Prominent is the accent fill.
struct AIMPushButtonStyle: ButtonStyle {
  var prominent = false
  var square = false
  /// A fixed width, so a table row's Switch button matches the Default chip.
  var width: CGFloat? = nil
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.aimControlHeight) private var height

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    configuration.label
      .aimFont(.body)
      .foregroundStyle(prominent ? Color.white : Color.primary)
      .lineLimit(1)
      .padding(.horizontal, square ? 0 : (height < AIMTheme.controlHeight ? 10 : 12))
      .frame(width: square ? height : width, height: height)
      .background(shape.fill(fill(pressed: configuration.isPressed)))
      .overlay(shape.strokeBorder(prominent ? Color.black.opacity(0.12) : AIMTheme.controlBorder, lineWidth: 0.5))
      .shadow(color: .black.opacity(prominent || !isEnabled ? 0 : 0.06), radius: 0.5, y: 0.5)
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(shape)
      .uiLint(.control)
  }

  private func fill(pressed: Bool) -> Color {
    if prominent { return Color.accentColor.opacity(pressed ? 0.8 : 1) }
    return pressed ? AIMTheme.controlPressed : AIMTheme.controlFill
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

/// The green Default state chip: the Switch button's frame, Body text.
struct AIMStateChip: View {
  let text: String
  var tint: Color = AIMTheme.green
  @Environment(\.aimControlHeight) private var height

  var body: some View {
    Text(text).aimText(.body).foregroundStyle(AIMTheme.legible(tint)).lineLimit(1)
      .frame(width: AIMTheme.rowButtonWidth, height: height)
      .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .uiLint(.control)
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
    .overlay(shape.strokeBorder(AIMTheme.controlBorder, lineWidth: 0.5))
    .uiLint(.control)
    .uiLint(.align("cards-end", .end))
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
      Rectangle().fill(AIMTheme.hairline).frame(width: 1 / 2).accessibilityHidden(true)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sidebar")
  }

  private func row(_ page: AIManagerPage) -> some View {
    let selected = page == selection
    return Button { select(page) } label: {
      HStack(spacing: 10) {
        Image(systemName: page.icon.symbol).aimFont(.body)
          .foregroundStyle(Color.accentColor)
          .frame(width: 20)
        Text(page.rawValue).aimText(.body)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(
        selected ? Color.accentColor.opacity(0.18) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("sidebar-\(page.rawValue)")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
