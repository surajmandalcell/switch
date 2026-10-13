import AppKit
import AIManagerCore
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

/// AppKit's field editor is shared by plain and secure fields, including fields in sheets.
@MainActor
enum AIMNativeFocusPolicy {
  private static var observers: [NSObjectProtocol] = []
  private static let responders = NSMapTable<NSWindow, NSResponder>.weakToWeakObjects()
  private static let editorFields = NSMapTable<NSWindow, NSTextField>.weakToWeakObjects()
  static var observerCount: Int { observers.count }
  private(set) static var applicationCount = 0

  /// App lifetime ownership prevents pages and scroll hosts from multiplying observers.
  static func install() {
    guard observers.isEmpty else { return }
    for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification,
                 NSControl.textDidBeginEditingNotification, NSTextView.didBeginEditingNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
        MainActor.assumeIsolated {
          if let window = note.object as? NSWindow {
            update(window, force: note.name == NSWindow.didBecomeKeyNotification)
          } else if let view = note.object as? NSView {
            apply(view)
            // AppKit can reuse the same editor for another field and reset its attributes
            // after this notification. Reapply once on the next window update.
            if let window = view.window { responders.removeObject(forKey: window) }
          }
        }
      })
    }
  }

  /// Only the posting window's responder is inspected, with no view-tree traversal.
  private static func update(_ window: NSWindow, force: Bool) {
    let responder = window.firstResponder
    let field = (responder as? NSTextView)?.delegate as? NSTextField
    // Moving between fields can change the logical responder without replacing its shared editor.
    guard force || responders.object(forKey: window) !== responder
      || editorFields.object(forKey: window) !== field else { return }
    if let responder { responders.setObject(responder, forKey: window) }
    else { responders.removeObject(forKey: window) }
    if let field { editorFields.setObject(field, forKey: window) }
    else { editorFields.removeObject(forKey: window) }
    if let view = responder as? NSView { apply(view) }
  }

  private static func apply(_ view: NSView) {
    applicationCount += 1
    view.focusRingType = AIMFocus.ringType
    let editor: NSTextView?
    if let text = view as? NSTextView {
      editor = text
      if text.isFieldEditor, let field = text.delegate as? NSTextField {
        field.focusRingType = AIMFocus.ringType
      }
    } else {
      editor = (view as? NSTextField)?.currentEditor() as? NSTextView
    }
    guard let editor else { return }
    editor.focusRingType = AIMFocus.ringType
    let field = (view as? NSTextField) ?? (editor.delegate as? NSTextField)
    let dark = (field ?? editor).effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    if dark {
      editor.selectedTextAttributes = [
        .backgroundColor: NSColor(white: 1, alpha: 0.12), .foregroundColor: NSColor.labelColor
      ]
    }
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

/// Motion tokens (150-350 ms except the short state fades). Fades keep running with Reduce Motion;
/// anything that moves or scales does not: `scale`, `rise`, and `move` collapse to nothing.
enum AIMMotion {
  /// A short state change such as a switch knob or a notice.
  static let state = 0.10
  /// Row and button hover fade, and the press dim.
  static let hover = 0.12
  static let fill = 0.35
  static let roll = 0.30
  static let slide = 0.25
  static let appear = 0.25
  static let pressedScale: CGFloat = 0.97
  static let riseDistance: CGFloat = 6
  /// A card starts this opaque, so its first frame is already readable.
  static let appearOpacity = 0.4
  /// Every token, for the contract check (hover, state, and press fades are under 150 ms by design).
  static let all = [state, hover, fill, roll, slide, appear]

  /// False in offscreen render checks (`--contract-only`): they read the final frame at once.
  static let isLive = !CommandLine.arguments.contains("--contract-only")

  static func fade(_ duration: Double) -> Animation { .easeOut(duration: duration) }
  /// A soft spring for things that travel; nil under Reduce Motion.
  static func move(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .spring(duration: slide, bounce: 0.12)
  }
  static func scale(pressed: Bool, reduceMotion: Bool) -> CGFloat {
    pressed && !reduceMotion ? pressedScale : 1
  }
  static func rise(reduceMotion: Bool) -> CGFloat { reduceMotion ? 0 : riseDistance }
}

private struct AIMRolling<Value: Equatable>: ViewModifier {
  let value: Value
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .contentTransition(reduceMotion ? .opacity : .numericText())
      .animation(AIMMotion.fade(AIMMotion.roll), value: value)
  }
}

/// A card or block fades in and rises a few points when it first shows.
private struct AIMAppear: ViewModifier {
  @State private var shown = !AIMMotion.isLive
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : AIMMotion.appearOpacity)
      .offset(y: shown ? 0 : AIMMotion.rise(reduceMotion: reduceMotion))
      .onAppear { withAnimation(AIMMotion.fade(AIMMotion.appear)) { shown = true } }
  }
}

extension View {
  /// Digits roll when `value` changes (a cross-fade under Reduce Motion).
  func aimRolling<Value: Equatable>(_ value: Value) -> some View { modifier(AIMRolling(value: value)) }
  func aimAppear() -> some View { modifier(AIMAppear()) }

  /// Dips to a faint opacity and fades back whenever `value` changes, so swapped content fades in
  /// instead of jumping. The view keeps its frame.
  @ViewBuilder func aimFadeOnChange<Value: Equatable>(_ value: Value) -> some View {
    if AIMMotion.isLive {
      keyframeAnimator(initialValue: 1.0, trigger: value) { view, opacity in
        view.opacity(opacity)
      } keyframes: { _ in
        KeyframeTrack {
          LinearKeyframe(AIMMotion.appearOpacity, duration: 0.01)
          CubicKeyframe(1, duration: AIMMotion.appear)
        }
      }
    } else { self }
  }
}

// MARK: - Usage bars

enum UsageBarColor {
  static func color(usedPercent: Double?, providerID: ProviderID) -> Color? {
    guard let usedPercent else { return nil }
    if usedPercent >= 90 { return AIMTheme.red }
    switch providerID.rawValue {
    case "claude-code": return Color(hex: 0xD97757)
    case "codex", "openai": return Color(hex: 0x10A37F)
    case "gemini-cli", "vertexai": return Color(hex: 0x4285F4)
    case "deepseek": return Color(hex: 0x4D6BFE)
    case "qwencloud": return Color(hex: 0x615CED)
    case "mistral": return Color(hex: 0xFF7000)
    case "groq": return Color(hex: 0xF55036)
    case "raycast": return Color(hex: 0xFF6363)
    case "warp": return Color(hex: 0x01A4FF)
    case "kiro": return Color(hex: 0x9046FF)
    default: return Color(nsColor: .labelColor)
    }
  }
}

/// The one usage bar: a 4-point capsule in the Overview, Accounts, the account detail, and the
/// popover. `usedPercent` drives the shared brand palette; "Show
/// percentage used" flips the fill to the used share. An unknown value shows an empty grey track.
/// The fill is clamped to the track, so overage never overflows. The pace tick draws over the bar
/// and never changes the layout height.
struct UsageBar: View {
  static let height: CGFloat = 4
  let usedPercent: Double?
  var showsUsed = false
  let providerID: ProviderID
  /// Even-pace marker as a 0...1 position.
  var tick: Double? = nil
  /// The share drawn now: nil until the bar first shows, then it eases to each new value.
  @State private var drawn: Double?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let used = usedPercent.map { min(max($0, 0), 100) }
    let color = UsageBarColor.color(usedPercent: used, providerID: providerID)
    let fill = used.map { (showsUsed ? $0 : 100 - $0) / 100 } ?? 0
    let shown = drawn ?? (AIMMotion.isLive ? 0 : fill)
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        if let color, fill > 0 {
          Capsule().fill(color).frame(width: max(Self.height, geometry.size.width * shown))
        }
        if let tick {
          Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1.5, height: Self.height + 4)
            .offset(x: min(max(geometry.size.width * tick - 0.75, 0), geometry.size.width - 1.5))
        }
      }
      .frame(height: geometry.size.height, alignment: .leading)
    }
    .frame(height: Self.height)
    .uiLint(.item)
    .accessibilityHidden(true)
    .onAppear { settle(to: fill) }
    .onChange(of: fill) { _, next in settle(to: next) }
  }

  /// Fills from empty on first show and eases between values; Reduce Motion sets it at once.
  private func settle(to fill: Double) {
    if reduceMotion { drawn = fill } else { withAnimation(AIMMotion.fade(AIMMotion.fill)) { drawn = fill } }
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

// MARK: - Focus

/// A click or a selection never draws a focus ring. Keyboard focus is a subtle tint in the
/// control's own shape, even with Full Keyboard Access on. System rings come back only with Increase Contrast.
enum AIMFocus {
  @MainActor static var showsSystemRings: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
  }

  @MainActor static var ringType: NSFocusRingType { showsSystemRings ? .default : .none }
}

extension View {
  /// A faint fill in the view's own rounded shape while it has keyboard focus. It never changes layout.
  func aimKeyboardTint(_ focused: Bool, radius: CGFloat = 6) -> some View {
    background(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(focused ? AIMTheme.focusTint : Color.clear))
  }
}

/// Scroll offsets by scroll view name. They live in UserDefaults, so a page opens where it was left
/// after a restart. Writes are batched (a scroll fires many), and the last one is flushed on quit.
@MainActor final class AIMScrollMemory {
  static let key = "scrollOffsets"
  private let defaults: UserDefaults
  private var offsets: [String: CGFloat]
  private var flush: DispatchWorkItem?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    offsets = (defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]).mapValues { CGFloat($0) }
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.save() } }
  }

  subscript(name: String) -> CGFloat? {
    get { offsets[name] }
    set {
      guard offsets[name] != newValue else { return }
      offsets[name] = newValue
      flush?.cancel()
      let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
      flush = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
  }

  func save() { defaults.set(offsets.mapValues { Double($0) }, forKey: Self.key) }
}

/// What each page remembers while the app runs, and the UserDefaults keys that survive a launch.
@MainActor enum AIMPlace {
  static let lastPageKey = "lastPage"
  static let maintenanceTabKey = "maintenanceTab"
  static let launchPlaceKey = "launchPlace"
  static let accountsFocusKey = "accountsFocus"
  static let scroll = AIMScrollMemory()
  /// The Accounts page restores its selection once per launch.
  static var accountsFocusRestored = false

  /// The account the Accounts page had selected, when it still exists in `accounts`.
  static func accountsFocus(in accounts: [UUID], defaults: UserDefaults = .standard) -> UUID? {
    defaults.string(forKey: accountsFocusKey).flatMap(UUID.init(uuidString:)).flatMap {
      accounts.contains($0) ? $0 : nil
    }
  }

  static func saveAccountsFocus(_ id: UUID?, defaults: UserDefaults = .standard) {
    defaults.set(id?.uuidString, forKey: accountsFocusKey)
  }
  /// The page and Maintenance tab the window shows now, so a render check can compare them with
  /// the page it asked for.
  static var visiblePage: AIManagerPage?
  static var visibleMaintenance: MaintenanceSection?

  /// The page shown at launch: the last page (default) or the Overview.
  static func launchPage(defaults: UserDefaults = .standard) -> AIManagerPage {
    guard defaults.string(forKey: launchPlaceKey) != "overview",
      let name = defaults.string(forKey: lastPageKey), let page = AIManagerPage(rawValue: name)
    else { return .overview }
    return page
  }

  static func maintenanceTab(defaults: UserDefaults = .standard) -> MaintenanceSection {
    defaults.string(forKey: maintenanceTabKey).flatMap(MaintenanceSection.init(rawValue:)) ?? .cleanup
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
  @FocusState private var focused: Bool

  var body: some View {
    Text(path)
      .aimText(.secondary, monospaced: true)
      .lineLimit(1).truncationMode(.middle)
      .contentShape(Rectangle())
      .highPriorityGesture(TapGesture().onEnded { copy() })
      .focusable(true, interactions: .activate)
      .focused($focused)
      .aimKeyboardTint(focused, radius: 3)
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
      case .overview: "house.fill"
      case .link: "arrow.up.right.square"
      case .account: "person.2.fill"
      case .settings: "gearshape.fill"
      case .history: "ellipsis.message.fill"
      case .maintenance: "wrench.and.screwdriver.fill"
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
  var file: StaticString = #fileID
  var line: UInt = #line

  var body: some View {
    AIMCard(title: title, file: file, line: line, accessory: { accessory ?? AnyView(EmptyView()) }) {
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
  /// Names this list's remembered scroll position; nil forgets it.
  let restoreKey: String?
  let rowContent: (Item) -> AnyView
  @Environment(\.aimCopyPath) private var copyPath

  init(
    items: [Item], rowSpacing: CGFloat = 0, fixedRowHeight: CGFloat? = nil,
    contentRevision: Int = 0,
    restoreKey: String? = nil,
    onReachEnd: (() -> Void)? = nil,
    rowContent: @escaping (Item) -> AnyView
  ) {
    self.items = items
    self.rowSpacing = rowSpacing
    self.fixedRowHeight = fixedRowHeight
    self.contentRevision = contentRevision
    self.restoreKey = restoreKey
    self.onReachEnd = onReachEnd
    self.rowContent = rowContent
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> AIMOwnedScrollView {
    let scrollView = AIMOwnedScrollView(frame: .zero)
    scrollView.onReachEnd = onReachEnd
    scrollView.restoreKey = restoreKey
    let tableView = AIMVirtualTableView(frame: .zero)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.style = .plain
    tableView.selectionHighlightStyle = .none
    tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    tableView.focusRingType = AIMFocus.ringType
    tableView.delegate = context.coordinator
    tableView.dataSource = context.coordinator
    scrollView.documentView = tableView
    context.coordinator.tableView = tableView
    scrollView.onWidthChange = { [weak coordinator = context.coordinator] width in
      coordinator?.widthChanged(width)
    }
    updateCoordinator(context.coordinator)
    tableView.reloadData()
    return scrollView
  }

  func updateNSView(_ scrollView: AIMOwnedScrollView, context: Context) {
    scrollView.onReachEnd = onReachEnd
    updateCoordinator(context.coordinator)
    context.coordinator.widthChanged(scrollView.contentSize.width)
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
    private var width: CGFloat = 0
    /// Measured row heights by item, width, and content revision.
    private var heights: [HeightKey: CGFloat] = [:]
    private let measurer = NSHostingController(rootView: AnyView(EmptyView()))

    private struct HeightKey: Hashable {
      let id: Item.ID
      let width: Int
      let revision: Int
    }

    /// The column follows the scroll view's width; rows that wrap are measured again at the new width.
    func widthChanged(_ next: CGFloat) {
      guard let tableView, next > 0, abs(next - width) > 0.5 else { return }
      width = next
      tableView.tableColumns.first?.width = next
      heights.removeAll(keepingCapacity: true)
      if fixedRowHeight == nil, !items.isEmpty {
        // Row heights jump to the new width at once, never through an animation.
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0
          context.allowsImplicitAnimation = false
          tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
        }
      }
      (tableView.enclosingScrollView as? AIMOwnedScrollView)?.restorePosition()
    }

    /// The height of a row at the column width. Auto layout measures a hosted SwiftUI text at its
    /// ideal single-line width, which clips wrapped messages, so the height comes from the hosting
    /// controller at the real width.
    private func measuredHeight(_ item: Item) -> CGFloat {
      guard width > 0 else { return 24 }
      let key = HeightKey(id: item.id, width: Int(width.rounded()), revision: contentRevision)
      if let cached = heights[key] { return cached }
      guard let rowContent else { return 24 }
      if heights.count > 4_000 { heights.removeAll(keepingCapacity: true) }
      measurer.rootView = AnyView(
        rowContent(item).environment(\.aimCopyPath, copyPath).environment(\.uiLintSuppressed, true)
          .foregroundStyle(.primary).id(item.id))
      let size = measurer.sizeThatFits(in: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
      let height = max(1, ceil(size.height))
      heights[key] = height
      return height
    }

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
      tableView.usesAutomaticRowHeights = false
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
      if let fixedRowHeight { return fixedRowHeight }
      guard items.indices.contains(row), rowContent != nil else { return 24 }
      return measuredHeight(items[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      guard items.indices.contains(row), let rowContent else { return nil }
      let identifier = NSUserInterfaceItemIdentifier("AIMVirtualCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? AIMVirtualCell
        ?? AIMVirtualCell(identifier: identifier)
      // The id gives a recycled cell fresh view state for its new item.
      cell.host.rootView = AnyView(
        rowContent(items[row])
          .environment(\.aimCopyPath, copyPath)
          .foregroundStyle(.primary)
          .id(items[row].id))
      return cell
    }
  }
}

final class AIMVirtualTableView: NSTableView {
  /// Never a ring, except with Full Keyboard Access or Increase Contrast.
  override var focusRingType: NSFocusRingType {
    get { AIMFocus.ringType }
    set {}
  }
}

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

/// The thin scroll bar of every AppKit scroll view: a legacy-style scroller with a fixed 10 pt
/// gutter that is always reserved, no slot or border, and a rounded knob in the label color. The knob
/// is hidden at rest: a user scroll (`reveal()`) fades it in at 6 pt, hover or drag widens it to 8 pt
/// and strengthens it, and it fades out 1 s after the last scroll or when the pointer leaves.
final class AIMScroller: NSScroller {
  static let gutter: CGFloat = 10
  @objc dynamic var knobWidth: CGFloat = 4 { didSet { needsDisplay = true } }
  @objc dynamic var knobAlpha: CGFloat = 0 { didSet { needsDisplay = true } }
  private var shown = false
  private var hovering = false
  private var dragging = false
  private var hideWork: DispatchWorkItem?

  override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
    key == "knobWidth" || key == "knobAlpha" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
  }

  /// Fades the knob in (when the content can scroll) and schedules the fade-out.
  func reveal() {
    guard isEnabled, knobProportion < 1 else { return }
    shown = true
    restyle()
    scheduleHide()
  }

  private func scheduleHide() {
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.hovering, !self.dragging else { return }
      self.shown = false
      self.restyle()
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
  }

  private func restyle() {
    let hot = hovering || dragging
    let alpha: CGFloat = !shown && !hot ? 0 : hot ? 0.4 : 0.25
    let width: CGFloat = !shown && !hot ? 4 : hot ? 8 : 6
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      knobWidth = hot ? 8 : 6
      NSAnimationContext.runAnimationGroup { context in
        context.duration = alpha > 0 ? 0.15 : 0.3
        animator().knobAlpha = alpha
      }
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = alpha > 0 ? 0.15 : 0.3
      context.timingFunction = CAMediaTimingFunction(name: alpha > 0 ? .easeOut : .easeIn)
      animator().knobAlpha = alpha
      animator().knobWidth = width
    }
  }

  override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
    gutter
  }

  override var focusRingType: NSFocusRingType { get { .none } set {} }

  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

  override func draw(_ dirtyRect: NSRect) { drawKnob() }

  override func drawKnob() {
    guard isEnabled, knobProportion < 1, knobAlpha > 0 else { return }
    let knob = rect(for: .knob)
    guard knob.height > 0 else { return }
    let bar = NSRect(x: knob.midX - knobWidth / 2, y: knob.minY + 1, width: knobWidth, height: max(0, knob.height - 2))
    NSColor.labelColor.withAlphaComponent(knobAlpha).setFill()
    NSBezierPath(roundedRect: bar, xRadius: knobWidth / 2, yRadius: knobWidth / 2).fill()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { hovering = true; reveal() }
  override func mouseExited(with event: NSEvent) { hovering = false; restyle(); scheduleHide() }

  override func mouseDown(with event: NSEvent) {
    dragging = true
    restyle()
    super.mouseDown(with: event)
    dragging = false
    restyle()
    scheduleHide()
  }
}

/// The scroll view of the virtual lists, with the thin hidden-at-rest scroller in a fixed gutter.
/// A wheel or trackpad scroll fades the scroller in; programmatic pins and restores do not.
/// `onReachEnd` fires near the bottom so long conversations page in.
final class AIMOwnedScrollView: NSScrollView {
  var onReachEnd: (() -> Void)?
  var onWidthChange: ((CGFloat) -> Void)?
  /// Names the remembered scroll position; nil forgets it.
  var restoreKey: String?
  private var restored = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    drawsBackground = false
    borderType = .noBorder
    hasHorizontalScroller = false
    scrollerStyle = .legacy
    verticalScroller = AIMScroller()
    hasVerticalScroller = true
    autohidesScrollers = false
  }

  @available(*, unavailable) required init?(coder: NSCoder) { nil }

  override func scrollWheel(with event: NSEvent) {
    super.scrollWheel(with: event)
    (verticalScroller as? AIMScroller)?.reveal()
  }

  override func layout() {
    super.layout()
    onWidthChange?(contentSize.width)
  }

  /// Puts a remembered offset back once, after the first measured layout.
  func restorePosition() {
    guard !restored else { return }
    restored = true
    guard let restoreKey, let saved = AIMPlace.scroll[restoreKey], let documentView else { return }
    let travel = max(0, documentView.frame.height - contentView.bounds.height)
    contentView.scroll(to: NSPoint(x: 0, y: min(max(saved, 0), travel)))
    reflectScrolledClipView(contentView)
  }

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    if restored, let restoreKey { AIMPlace.scroll[restoreKey] = clipView.bounds.minY }
    guard let documentView, documentView.isFlipped,
          documentView.frame.height > 0, clipView.bounds.height > 0,
          documentView.frame.height - clipView.bounds.maxY < 180 else { return }
    onReachEnd?()
  }
}
