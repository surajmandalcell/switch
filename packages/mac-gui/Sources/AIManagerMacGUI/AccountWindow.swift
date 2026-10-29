import AIManagerCore
import AppKit
import CoreServices
import ServiceManagement
import SwiftUI

enum AIManagerLaunchContext {
  static func launchedAsLoginItem(
    event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
  ) -> Bool {
    event?.eventID == AEEventID(kAEOpenApplication)
      && event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
  }
}

/// The main window: a standard titled window with traffic lights over a full-size content view. It
/// has no toolbar bar; the content draws its own top row.
@MainActor final class AIManagerWindow: NSWindow {
  /// The width is fixed at 1200 pt; only the height resizes, from 800 pt up to the screen.
  static let defaultSize = NSSize(width: 1200, height: 900)
  static let minimumSize = NSSize(width: 1200, height: 800)
  static let maximumSize = NSSize(width: 1200, height: CGFloat.greatestFiniteMagnitude)
  static let frameAutosaveName = "AIManagerMainWindow"
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  private weak var pageHost: AIMHostingView?

  /// A wheel goes straight to the page's `AIMHostingView`, which picks the scroll view under the
  /// pointer. Through the normal path SwiftUI first hit-tests the whole page to find a target, then
  /// forwards the event to the same place, on every wheel tick.
  override func sendEvent(_ event: NSEvent) {
    if event.type == .scrollWheel, attachedSheet == nil, let host = wheelHost() {
      host.scrollWheel(with: event)
      return
    }
    super.sendEvent(event)
  }

  private func wheelHost() -> AIMHostingView? {
    if let host = pageHost, host.window === self, !host.isHiddenOrHasHiddenAncestor { return host }
    pageHost = contentView.flatMap(AIMHostingView.visible(in:))
    return pageHost
  }

  /// SwiftUI resets the content minimum while it lays out; the window never reports less.
  override var contentMinSize: NSSize {
    get {
      let size = super.contentMinSize
      return NSSize(
        width: max(size.width, Self.minimumSize.width), height: max(size.height, Self.minimumSize.height))
    }
    set { super.contentMinSize = newValue }
  }

  /// The same for the maximum: the width never grows past 1200 pt.
  override var contentMaxSize: NSSize {
    get { NSSize(width: Self.maximumSize.width, height: super.contentMaxSize.height) }
    set { super.contentMaxSize = newValue }
  }
}

enum AIManagerWindowBehavior {
  static let minimizeToTrayKey = "minimizeToTray"

  static func hidesOnMinimize(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: minimizeToTrayKey)
  }

  @MainActor static func minimize(_ window: NSWindow?, defaults: UserDefaults = .standard) {
    guard let window else { return }
    if hidesOnMinimize(defaults: defaults) {
      window.orderOut(nil)
    } else {
      window.miniaturize(nil)
    }
  }
}

@MainActor
final class AIManagerWindowController<Content: View>: NSWindowController, NSWindowDelegate {
  private let placementDefaults: UserDefaults
  private var preserveUnavailableDisplayPlacement = false
  private var unavailableDisplayFallbackFrame: NSRect?
  /// Runs after the window closes or hides to the menu bar, so the owner can release it and its pages.
  var onHide: (() -> Void)?

  init(title: String, rootView: Content, placementDefaults: UserDefaults = .standard) {
    self.placementDefaults = placementDefaults
    let defaultSize = AIManagerWindow.defaultSize
    let window = AIManagerWindow(
      contentRect: NSRect(origin: .zero, size: defaultSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = title
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .none
    // An empty unified toolbar makes macOS center the traffic lights in a 52 pt bar.
    let toolbar = NSToolbar(identifier: "SwitchWindowToolbar")
    toolbar.showsBaselineSeparator = false
    window.toolbar = toolbar
    window.toolbarStyle = .unified
    let host = NSHostingController(rootView: rootView)
    host.sizingOptions = []
    window.contentViewController = host
    window.contentMinSize = AIManagerWindow.minimumSize
    window.contentMaxSize = AIManagerWindow.maximumSize
    window.collectionBehavior.insert(.fullScreenNone)
    window.isReleasedWhenClosed = false
    // A new window opens 900 pt tall, or the screen's visible height when that is shorter, never below 800.
    let visibleHeight = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? defaultSize.height
    window.setContentSize(
      NSSize(width: defaultSize.width, height: max(AIManagerWindow.minimumSize.height, min(defaultSize.height, visibleHeight))))
    let restoreOutcome = AIManagerWindowPlacement.restore(
      window, autosaveName: AIManagerWindow.frameAutosaveName, defaults: placementDefaults)
    if restoreOutcome != .restored { window.center() }
    super.init(window: window)
    preserveUnavailableDisplayPlacement = restoreOutcome == .savedDisplayUnavailable
    unavailableDisplayFallbackFrame = preserveUnavailableDisplayPlacement ? window.frame : nil
    window.delegate = self
    // The yellow button follows the "Minimize to Menubar" setting like Window > Minimize.
    let minimizeButton = window.standardWindowButton(.miniaturizeButton)
    minimizeButton?.target = self
    minimizeButton?.action = #selector(minimizeFromButton(_:))
  }
  @available(*, unavailable) required init?(coder: NSCoder) { nil }

  @objc private func minimizeFromButton(_ sender: Any?) { minimize() }

  func minimize() {
    AIManagerWindowBehavior.minimize(window)
    if AIManagerWindowBehavior.hidesOnMinimize() {
      savePlacement()
      onHide?()
    }
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: AIManagerWindow.minimumSize)).size
    return NSSize(width: minimum.width, height: max(frameSize.height, minimum.height))
  }

  /// The green button zooms to the screen's full visible height and keeps the width and x position.
  func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
    let minimumHeight = window.frameRect(forContentRect: NSRect(origin: .zero, size: AIManagerWindow.minimumSize)).height
    return NSRect(
      x: window.frame.minX, y: newFrame.minY, width: window.frame.width, height: max(newFrame.height, minimumHeight))
  }

  func windowDidMove(_ notification: Notification) { windowFrameDidChange() }

  func windowDidEndLiveResize(_ notification: Notification) { windowFrameDidChange() }

  /// Zoom resizes without a live drag.
  func windowDidResize(_ notification: Notification) {
    if window?.inLiveResize != true { windowFrameDidChange() }
  }

  private func windowFrameDidChange() {
    if preserveUnavailableDisplayPlacement,
      let fallback = unavailableDisplayFallbackFrame,
      framesMatch(window?.frame, fallback)
    {
      return
    }
    preserveUnavailableDisplayPlacement = false
    unavailableDisplayFallbackFrame = nil
    savePlacement()
  }

  func windowWillClose(_ notification: Notification) {
    savePlacement()
    onHide?()
  }

  func savePlacement() {
    guard !preserveUnavailableDisplayPlacement, let window else { return }
    AIManagerWindowPlacement.save(window, defaults: placementDefaults)
  }

  private func framesMatch(_ left: NSRect?, _ right: NSRect) -> Bool {
    guard let left else { return false }
    return abs(left.minX - right.minX) < 1 && abs(left.minY - right.minY) < 1
      && abs(left.width - right.width) < 1 && abs(left.height - right.height) < 1
  }

  func present() {
    guard let window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    showWindow(nil)
    window.makeKeyAndOrderFront(nil)
  }
}

private final class WindowTarget: ObservableObject { weak var window: NSWindow? }
private final class WindowResolver: NSView {
  var resolve: ((NSWindow) -> Void)?
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let window { resolve?(window) }
  }
}
private struct WindowReader: NSViewRepresentable {
  let resolve: (NSWindow) -> Void
  func makeNSView(context: Context) -> WindowResolver {
    let view = WindowResolver()
    view.resolve = resolve
    return view
  }
  func updateNSView(_ view: WindowResolver, context: Context) {
    view.resolve = resolve
    if let window = view.window { resolve(window) }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: WindowResolver, context: Context) -> CGSize? {
    proposal.replacingUnspecifiedDimensions(by: .zero)
  }
}
extension AIManagerPage {
  /// SF Symbol shown in the sidebar.
  var icon: AIMIcon.Name {
    switch self {
    case .overview: .overview
    case .accounts: .account
    case .conversations: .history
    case .maintenance: .maintenance
    case .settings: .settings
    }
  }
}

/// Toolbar geometry and the account search the toolbar drives.
enum AIManagerToolbar {
  static let searchWidth = AIMTheme.toolbarSearchWidth
  static let searchPrompt = "Search accounts…"
}

/// Filters every account list (Overview table and Accounts list) by name, email, provider, and workspace.
enum AccountSearch {
  static func matches(_ account: AccountRecord, query: String, hideEmails: Bool = false) -> Bool {
    let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace })
    guard !terms.isEmpty else { return true }
    let haystack = [
      account.identity.realAccountLabel, account.identity.email ?? "", account.identity.accountID ?? "",
      account.identity.userID ?? "",
      account.identity.providerID.guiName, account.identity.workspaceID ?? "",
    ].joined(separator: " ").lowercased()
    return terms.allSatisfy { haystack.contains($0) }
  }

  static func filter(_ accounts: [AccountRecord], query: String, hideEmails: Bool = false) -> [AccountRecord] {
    accounts.filter { matches($0, query: query, hideEmails: hideEmails) }
  }
}

/// The main window: a native sidebar (Overview, Accounts, Settings, Maintenance, Conversations), a
/// unified toolbar with account search, Add, and More, and the selected page.
struct AccountWindow: View {
  @ObservedObject var model: AccountViewModel
  @StateObject private var target = WindowTarget()
  @State private var page: AIManagerPage = .overview
  @State private var searchQuery = ""
  /// The drop-down row the arrow keys or the pointer are on; the first row after each new query.
  @State private var dropdownHighlight = 0
  @State private var dropdownHovered = false
  @State private var maintenanceSection: MaintenanceSection = .cleanup
  @FocusState private var searchFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(AppearanceOverride.key) private var appearanceMode = "system"
  @Environment(\.colorScheme) private var systemScheme
  private var themeOverride: ColorScheme? {
    appearanceMode == "dark" ? .dark : (appearanceMode == "light" ? .light : nil)
  }
  private var dark: Bool { (themeOverride ?? systemScheme) == .dark }

  /// A launch without an explicit page opens `launchPlace`: the last page and Maintenance tab
  /// (UserDefaults `lastPage`, `maintenanceTab`) or the Overview.
  init(
    model: AccountViewModel, initialPageIndex: Int? = nil, initialMaintenance: MaintenanceSection? = nil
  ) {
    self.model = model
    let pages = AIManagerPage.allCases
    if let initialPageIndex {
      _page = State(initialValue: pages.indices.contains(initialPageIndex) ? pages[initialPageIndex] : .overview)
    } else {
      _page = State(initialValue: AIMPlace.launchPage())
    }
    _maintenanceSection = State(initialValue: initialMaintenance ?? AIMPlace.maintenanceTab())
  }

  var body: some View {
    HStack(spacing: 0) {
      AIMSidebar(selection: page, select: show)
      // Each page draws the top row inside its own content, so the row and the cards share one
      // width whatever the scroll bar style is.
      pageView
        .environment(\.aimPageHeader, pageHeader)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AIMTheme.page)
        .overlay(alignment: .topTrailing) { searchDropdown }
    }
    // The content runs under the transparent title bar; the sidebar and top row clear the lights.
    .ignoresSafeArea()
    // No focus rings or effects: a click never draws one. Keyboard focus is a tint in each
    // control's own shape; system rings come back only with Full Keyboard Access or Increase Contrast.
    .focusEffectDisabled(!AIMFocus.showsSystemRings)
    .sheet(isPresented: Binding(
      get: {
        #if AI_MANAGER_PREVIEW
        if CommandLine.arguments.contains("--contract-only") { return false }
        #endif
        return model.showImport
      },
      set: { if !$0 { model.closeAccountModal() } })
    ) {
      Group {
        switch model.accountModalMode {
        case .add: AddAccountFlow(model: model)
        case .advancedImport: ImportFlow(model: model)
        }
      }
      .frame(width: 680, height: 600)
      .interactiveDismissDisabled(model.isBusy)
      .environment(\.aimCopyPath, model.copyPath)
      .tint(AIMTheme.passiveIcon)
    }
    .environment(\.aimCopyPath, model.copyPath)
    .tint(AIMTheme.passiveIcon)
    .preferredColorScheme(themeOverride)
    .background(
      WindowReader { window in
        target.window = window
        applyAppearance(to: window)
      }
    )
    .onAppear { AIManagerBrand.installApplicationIcon(dark: dark) }
    .onChange(of: dark) { _, _ in
      if let window = target.window { applyAppearance(to: window) }
      AIManagerBrand.installApplicationIcon(dark: dark)
    }
    .onReceive(NotificationCenter.default.publisher(for: AIManagerNavigation.request)) { notification in
      guard let requestedPage = notification.object as? AIManagerPage else { return }
      show(requestedPage)
    }
    .onReceive(NotificationCenter.default.publisher(for: AIManagerNavigation.focusSearch)) { _ in
      searchFocused = true
    }
    .onChange(of: searchQuery) { dropdownHighlight = 0 }
    .onChange(of: maintenanceSection) { _, tab in
      UserDefaults.standard.set(tab.rawValue, forKey: AIMPlace.maintenanceTabKey)
    }
    .onChange(of: maintenanceSection, initial: true) { _, tab in AIMPlace.visibleMaintenance = tab }
    .onChange(of: page, initial: true) { _, shown in AIMPlace.visiblePage = shown }
    .task(id: model.hasLoaded, priority: .utility) {
      if model.hasLoaded { await model.watchActivity() }
    }
  }

  private func show(_ next: AIManagerPage) {
    page = next
    UserDefaults.standard.set(next.rawValue, forKey: AIMPlace.lastPageKey)
    NotificationCenter.default.post(name: AIManagerNavigation.didShowPage, object: next)
  }

  private var pageView: some View {
    AIMVisitedPageHost(
      page: page, query: searchQuery, maintenance: maintenanceSection,
      busy: model.isBusy, loaded: model.hasLoaded, error: model.errorMessage,
      importing: model.showImport, searchFocused: searchFocused
    ) { requested in
      AnyView(content(for: requested).environment(\.aimPageName, requested.rawValue))
    }
  }

  @ViewBuilder private func content(for requested: AIManagerPage) -> some View {
      switch requested {
      case .overview:
        OverviewPage(model: model) { target in
          if target == .maintenance { maintenanceSection = .backup }
          show(target)
        }
      case .accounts: AccountsPage(model: model, query: searchQuery)
      case .conversations: HistoryPage(model: model)
      case .maintenance: MaintenancePage(model: model, section: $maintenanceSection)
      case .settings: SettingsPage(model: model, query: searchQuery)
      }
  }

  /// The content's top row, lightest to heaviest from left to right: Add, More, then the 300 pt
  /// account search at the right edge. Command-K focuses the search.
  private var pageHeader: AnyView {
    AnyView(
      VStack(spacing: 0) {
        topBar
        if let error = model.displayedErrorMessage, !model.showImport {
          AIMPanel {
            ErrorBar(message: error, copy: { model.copyWarnings([error]) }) {
              model.errorMessage = nil
            }
          }
          .padding(.bottom, AIMTheme.cardGap)
        }
      })
  }

  private var topBar: some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      Spacer(minLength: 0)
      HStack(spacing: AIMTheme.rowSpacing) {
        AIMSquareButton(
          icon: .plus, label: "Add Account", disabled: model.isBusy || !model.hasLoaded
        ) { Task { await model.beginAddAccount() } }
        AIMIconMenu(icon: .ellipsis, label: "More") {
          Button("Refresh All Usage") { Task { await model.refreshAllUsage() } }
            .disabled(model.isBusy)
          Button("Add Account") { Task { await model.beginAddAccount() } }
            .disabled(model.isBusy || !model.hasLoaded)
          Button("Import…") { Task { await model.beginAdvancedImport() } }
            .disabled(model.isBusy || !model.hasLoaded)
          Divider()
          Button("Settings") { show(.settings) }
        }
      }
      .uiLint(.actions)
      AIMSearchField(
        text: $searchQuery, focus: $searchFocused, prompt: AppSearch.prompt(for: page),
        label: AppSearch.label(for: page),
        onMove: AppSearch.dropdownPages.contains(page) ? { moveDropdownHighlight($0) } : nil,
        onSubmit: submitSearch)
    }
    .frame(height: AIMTheme.topBarHeight)
  }

  // MARK: Search drop-down (Overview, Maintenance, Conversations)

  /// The drop-down shows while the field has focus (or the pointer is on the panel, since a click on a
  /// row first takes focus from the field) and the search has text.
  private var showsDropdown: Bool {
    AppSearch.dropdownPages.contains(page) && !AppSearch.isBlank(searchQuery)
      && (searchFocused || dropdownHovered || AppSearch.keepsDropdownOpen)
  }

  private var searchList: AppSearchList {
    AppSearchList(
      accounts: AppSearch.accounts(matching: searchQuery, in: model),
      settings: SettingsSearch.search(searchQuery))
  }

  private func moveDropdownHighlight(_ step: Int) {
    let count = searchList.rows.count
    guard count > 0 else { return }
    dropdownHighlight = min(max(dropdownHighlight + step, 0), count - 1)
  }

  private func chooseSearchRow(_ row: AppSearchRow) {
    searchFocused = false
    dropdownHovered = false
    switch row {
    case .account(let id):
      if let account = searchList.account(id) { AppSearch.open(account, in: model) }
    case .setting: show(.settings)
    case .showAll: show(.accounts)
    }
  }

  /// Return opens the highlighted drop-down row. On Accounts it selects the first match when the
  /// selected account is filtered out.
  private func submitSearch() {
    if showsDropdown {
      let rows = searchList.rows
      if rows.indices.contains(dropdownHighlight) { chooseSearchRow(rows[dropdownHighlight]) }
    } else if page == .accounts {
      let matches = AppSearch.accounts(matching: searchQuery, in: model)
      if let first = matches.first, !matches.contains(where: { $0.id == model.selectedAccountID }) {
        model.selectedAccountID = first.id
      }
    }
  }

  @ViewBuilder private var searchDropdown: some View {
    ZStack {
      if showsDropdown {
        AppSearchDropdown(
          list: searchList, highlight: dropdownHighlight,
          hover: { dropdownHighlight = $0 }, choose: chooseSearchRow
        )
        .onHover { dropdownHovered = $0 }
        .padding(.trailing, AIMTheme.pageMargin)
        .padding(.top, AppSearch.fieldBottom + AppSearch.dropdownGap)
        .transition(
          reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: -4)).combined(with: .scale(scale: 0.98, anchor: .top)))
      }
    }
    .animation(
      AIMMotion.isLive ? (showsDropdown ? AIMSearchMotion.panelIn : AIMSearchMotion.panelOut) : nil,
      value: showsDropdown)
  }

  private func applyAppearance(to window: NSWindow) {
    guard appearanceMode != "system" else {
      if window.appearance != nil { window.appearance = nil }
      return
    }
    let name: NSAppearance.Name = dark ? .darkAqua : .aqua
    if window.appearance?.name != name { window.appearance = NSAppearance(named: name) }
  }
}

/// Detached hosts keep their SwiftUI state without participating in layout, input, or accessibility.
struct AIMVisitedPageHost: NSViewRepresentable {
  let page: AIManagerPage
  let query: String
  let maintenance: MaintenanceSection
  let busy: Bool
  let loaded: Bool
  let error: String?
  let importing: Bool
  let searchFocused: Bool
  let content: (AIManagerPage) -> AnyView

  struct Inputs: Equatable {
    let query: String
    let maintenance: MaintenanceSection
    let busy: Bool
    let loaded: Bool
    let error: String?
    let importing: Bool
    let searchFocused: Bool
    // The cached root copies the hosted environment values, including temporary disabled states.
    let enabled: Bool
    let scheme: ColorScheme
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let contrast: ColorSchemeContrast
    let scale: CGFloat
    let direction: LayoutDirection
    let lintSuppressed: Bool
  }

  func makeNSView(context: Context) -> Container {
    let container = Container()
    container.identifier = NSUserInterfaceItemIdentifier("visited-page-host")
    return container
  }

  func updateNSView(_ container: Container, context: Context) {
    let environment = context.environment
    let inputs = Inputs(
      query: query, maintenance: maintenance, busy: busy, loaded: loaded, error: error,
      importing: importing, searchFocused: searchFocused, enabled: environment.isEnabled,
      scheme: environment.colorScheme,
      reduceMotion: environment.accessibilityReduceMotion,
      reduceTransparency: environment.accessibilityReduceTransparency,
      contrast: environment.colorSchemeContrast, scale: environment.displayScale,
      direction: environment.layoutDirection, lintSuppressed: environment.uiLintSuppressed)
    let hosted = AIMHostedEnvironment(environment)
    container.show(page, inputs: inputs) { requested, active in
      AnyView(content(requested).modifier(hosted).ignoresSafeArea()
        .disabled(!active).allowsHitTesting(active).accessibilityHidden(!active))
    }
    container.needsLayout = true
  }

  final class Container: NSView {
    private var hosts: [AIManagerPage: AIMHostingView] = [:]
    private var inputs: [AIManagerPage: Inputs] = [:]
    private(set) var current: AIManagerPage?
    private var makePage: ((AIManagerPage, Bool) -> AnyView)?
    private var prewarmed: Set<AIManagerPage> = []
    private var latestInputs: Inputs?
    private var warming = false

    /// Fills its space whatever the page inside needs (the hosts use autoresizing, frame = bounds): the
    /// notice from a page host stops here instead of making the window root measure every page.
    @objc(_informContainerThatSubviewsNeedUpdateConstraints)
    func informContainerThatSubviewsNeedUpdateConstraints() { noticeStop.run() }

    private lazy var noticeStop = AIMConstraintNoticeStop(self)

    /// The search drop-down is SwiftUI content over this view; a click on it must reach the window's own hosting view.
    override func hitTest(_ point: NSPoint) -> NSView? {
      if AppSearch.isOverDropdown(windowPoint: superview?.convert(point, to: nil) ?? .zero, in: window) { return nil }
      return super.hitTest(point)
    }

    func show(_ page: AIManagerPage, inputs next: Inputs, root: @escaping (AIManagerPage, Bool) -> AnyView) {
      makePage = root
      latestInputs = next
      let host: AIMHostingView
      if let existing = hosts[page] {
        host = existing
        let wasPrewarmed = prewarmed.remove(page) != nil
        if inputs[page] != next || wasPrewarmed { host.rootView = root(page, true) }
      } else {
        host = AIMHostingView(rootView: root(page, true))
        host.sizingOptions = []
        // Cached pages fill the container; attachment must not invalidate their safe area.
        host.safeAreaRegions = []
        host.focusRingType = .none
        host.autoresizingMask = [.width, .height]
        hosts[page] = host
      }
      inputs[page] = next
      guard current != page else { return }
      if let previous = current.flatMap({ hosts[$0] }) {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: previous) {
          window?.makeFirstResponder(nil)
        }
        previous.removeFromSuperview()
      }
      current = page
      host.setAccessibilityHidden(false)
      host.frame = bounds
      addSubview(host)
    }

    override func layout() {
      super.layout()
      if let current { hosts[current]?.frame = bounds }
      if !warming, bounds.width > 0, bounds.height > 0 {
        warming = true
        scheduleWarmPage()
      }
    }

    private func scheduleWarmPage() {
      // Start after the first frame; warm one detached page per idle run-loop turn.
      RunLoop.main.perform(inModes: [.default]) { [weak self] in
        MainActor.assumeIsolated { self?.warmPage() }
      }
    }

    private func warmPage() {
      guard let makePage, let latestInputs,
        let page = AIManagerPage.allCases.first(where: { hosts[$0] == nil }) else { return }
      let host = AIMHostingView(rootView: makePage(page, false))
      host.sizingOptions = []
      host.safeAreaRegions = []
      host.focusRingType = .none
      host.autoresizingMask = [.width, .height]
      host.frame = bounds
      hosts[page] = host
      prewarmed.insert(page)
      inputs[page] = latestInputs
      // Hosting views realize their native controls only after joining a window.
      host.setAccessibilityHidden(true)
      host.frame.origin.x = bounds.maxX
      addSubview(host)
      host.layoutSubtreeIfNeeded()
      if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
      }
      host.removeFromSuperview()
      host.frame = bounds
      scheduleWarmPage()
    }
  }
}

/// A standard button. `primary` is the prominent (accent) style and `danger` a destructive one.
enum ButtonTone { case normal, primary, danger }
struct AIMButton: View {
  let title: String
  var icon: AIMIcon.Name?
  var tone: ButtonTone = .normal
  var disabled = false
  var active = false
  let action: () -> Void

  var body: some View {
    Button(role: tone == .danger ? .destructive : nil, action: action) {
      if let icon {
        Label(title, systemImage: icon.symbol)
      } else {
        Text(title)
      }
    }
    .modifier(AIMButtonStyle(prominent: tone == .primary))
    .disabled(disabled)
    .help(title)
    .accessibilityAddTraits(active ? .isSelected : [])
  }
}

/// The accent-filled prominent style for a primary action, else the bordered style.
struct AIMButtonStyle: ViewModifier {
  let prominent: Bool
  func body(content: Content) -> some View {
    content.buttonStyle(AIMPushButtonStyle(prominent: prominent))
  }
}

/// An icon-only borderless button with an accessible name and a tooltip.
struct AIMIconButton: View {
  let icon: AIMIcon.Name
  let label: String
  var tone: ButtonTone = .normal
  var disabled = false
  var active = false
  let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(role: tone == .danger ? .destructive : nil, action: action) {
      AIMIcon(name: icon).aimText(.body)
    }
    .buttonStyle(AIMIconButtonStyle())
    .foregroundStyle(tone == .danger ? AIMTheme.red : (active ? AIMTheme.blue : Color.secondary))
    .background {
      if icon == .copy { AIMCopyCursor(enabled: isEnabled && !disabled).allowsHitTesting(false) }
    }
    .disabled(disabled)
    .help(label)
    .accessibilityLabel(label)
  }
}

/// The Default badge for the default account, else "Make Default" (the prominent button).
struct DefaultAccountButton: View {
  let isDefault: Bool
  var disabled = false
  /// False where another button on the screen is the primary action.
  var prominent = true
  let action: () -> Void

  var body: some View {
    if isDefault {
      Button("Default") {}
        .buttonStyle(AIMPushButtonStyle(width: AIMTheme.rowButtonWidth))
        .disabled(true)
        .accessibilityLabel(AccountActionCopy.usingDefault)
        .accessibilityHint("This account is already the default.")
    } else {
      Button(action: action) { Text(AccountActionCopy.use) }
        .modifier(AIMButtonStyle(prominent: prominent))
        .disabled(disabled)
    }
  }
}

enum AccountActionCopy {
  static let use = "Make Default"
  static let usingDefault = "Using as default"
  static func open(_ providerID: ProviderID) -> String {
    "Open \(providerID == .codex ? "Codex" : providerID.displayName)"
  }
  static func useAndOpen(_ providerID: ProviderID) -> String {
    "Use & Open \(providerID == .codex ? "Codex" : providerID.displayName)"
  }
  static let check = "Check account files"
  static let copyAuthPath = "Copy auth path"
  static let delete = "Delete account"
}

struct WarningCopyButton: View {
  let label: String
  var showsTitle = false
  let action: () -> Void
  @State private var copied = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      action()
      withAnimation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state)) { copied = true }
      Task {
        try? await Task.sleep(for: .milliseconds(900))
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state)) { copied = false }
      }
    } label: {
      HStack(spacing: 5) {
        AIMIcon(name: copied ? .check : .copy)
        if showsTitle {
          Text(copied ? "Copied" : "Copy warnings")
        }
      }
      .aimFont(.body)
      .foregroundStyle(copied ? AIMTheme.green : AIMTheme.amber)
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(label)
    .accessibilityLabel(label)
  }
}

private struct WarningList: View {
  let warnings: [String]
  let copy: ([String]) -> Void

  var body: some View {
    Group {
      HStack {
        Text("\(warnings.count) item\(warnings.count == 1 ? "" : "s") need attention")
          .aimText(.secondary)
        Spacer()
        WarningCopyButton(label: "Copy all warnings", showsTitle: true) { copy(warnings) }
      }
      ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
        HStack(alignment: .top, spacing: AIMTheme.sectionSpacing) {
          AIMIcon(name: .warning).aimFont(.body).foregroundStyle(AIMTheme.amber)
          Text(warning).aimText(.body).textSelection(.enabled)
          Spacer(minLength: 0)
        }
      }
    }
  }
}

/// A notice row: an icon and a message in Body. Put it in a form Section or an `AIMPanel`.
struct Notice: View {
  let text: String, tone: Color
  var icon: AIMIcon.Name = .info
  var copy: (() -> Void)? = nil
  var body: some View {
    HStack(alignment: .top, spacing: AIMTheme.rowSpacing) {
      AIMIcon(name: icon).aimFont(.body).foregroundStyle(tone)
      Text(text).aimText(.body).textSelection(.enabled)
      Spacer()
      if let copy {
        WarningCopyButton(label: "Copy warning", action: copy)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
private struct ErrorBar: View {
  let message: String
  let copy: () -> Void
  let dismiss: () -> Void
  var body: some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      AIMIcon(name: .warning).aimFont(.body).foregroundStyle(AIMTheme.red)
      Text(message).aimText(.body).lineLimit(2).textSelection(.enabled)
        .help(message)
      Spacer()
      WarningCopyButton(label: "Copy error", action: copy)
      AIMButton(title: "Dismiss", action: dismiss)
    }.aimRow()
  }
}

struct AddAccountFlow: View {
  @ObservedObject var model: AccountViewModel
  @State private var grokAuthorizationCode = ""
  /// The generic provider whose credentials page is open, before any sign-in session exists.
  @State private var genericProviderID: ProviderID?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var step: Int {
    if model.accountLoginState == .completed { return 3 }
    return model.accountLoginSession == nil && genericProviderID == nil ? 1 : 2
  }

  private var genericSpec: ProviderSpec? {
    model.accountLoginSession == nil ? genericProviderID.flatMap(ProviderCatalog.spec) : nil
  }

  private var stepLabels: [String] {
    ["Provider", genericSpec?.style == .secret ? "Credentials" : "Sign in", "Done"]
  }

  private var selectedProviderName: String {
    model.selectedProviderID.guiName
  }

  private func continueFromProvider() {
    let id = model.selectedProviderID
    if id == .droid {
      genericProviderID = id
    } else if !ProviderChoices.builtIn.contains(id), ProviderCatalog.spec(id) != nil {
      genericProviderID = id
    } else {
      Task { await model.startAccountLogin() }
    }
  }

  private var selectedIsDefault: Bool {
    guard let account = model.selectedAccount else { return false }
    return model.status?.isDefault(account) == true
  }

  private var hasGrokAuthorizationCode: Bool {
    !grokAuthorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func submitGrokAuthorizationCode() {
    let input = grokAuthorizationCode
    Task {
      if await model.submitGrokAuthorizationCode(input) {
        grokAuthorizationCode = ""
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      ImportHeader(
        title: step == 1 ? "Add Account"
          : (step == 2 ? (genericSpec?.style == .secret ? "Credentials" : "Sign In") : "Account Ready"))
      Group {
        switch step {
        case 1:
          ProviderChooserPage(model: model, step: step, onContinue: continueFromProvider)
        case 2:
          if let spec = genericSpec {
            if spec.style == .secret {
              SecretCredentialsPage(spec: spec, model: model) { genericProviderID = nil }
            } else {
              FilesCredentialsPage(spec: spec, model: model) { genericProviderID = nil }
            }
          } else {
            signInPage
          }
        default: completedPage
        }
      }
      .disabled(model.isBusy)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environment(\.aimCancelSheet, { model.closeAccountModal() })
    #if AI_MANAGER_PREVIEW
    .onAppear {
      if let id = PreviewArguments.value("add-provider") {
        model.selectedProviderID = ProviderID(rawValue: id)
        genericProviderID = ProviderID(rawValue: id)
      }
    }
    #endif
    .overlay(alignment: .bottom) {
      if let error = model.displayedErrorMessage {
        AIMPanel {
          ErrorBar(message: error, copy: { model.copyWarnings([error]) }) {
            model.errorMessage = nil
          }
        }
        .padding(.horizontal, AIMTheme.pageMargin)
        .padding(.bottom, 52)
      } else if model.isBusy {
        HStack(spacing: AIMTheme.rowSpacing) {
          ProgressView().controlSize(.small)
          Text("Checking account…").aimText(.secondary)
        }
        .padding(.bottom, 58)
      }
    }
  }

  private var signInPage: some View {
    VStack(spacing: 0) {
      AIMSheetForm {
        Section("\(selectedProviderName) sign-in") {
          if model.selectedProviderID == .droid {
            // A new account name is typed input and stays real. An existing account's name is a label, so
            // Privacy mode shows the made-up name and locks the field.
            let namesExisting = model.signInAccountID != nil
            TextField("Account name", text: Binding(
              get: {
                namesExisting && EmailPrivacy.isPrivacyMode()
                  ? EmailPrivacy.fakeName(seed: model.droidAccountName) : model.droidAccountName
              },
              set: { model.droidAccountName = $0 }))
              .disabled(namesExisting)
              .help(namesExisting ? "Rename this account from its More menu on Accounts." : "")
              .accessibilityHint("Name this encrypted login, for example Droid personal.")
            if model.accountLoginSession == nil {
              SecureField("Factory API key (optional, for usage)", text: $model.droidAPIKey)
              HStack(spacing: AIMTheme.rowSpacing) {
                AIMButton(title: "Import current sign-in", tone: .primary, disabled: model.isBusy) {
                  Task { await model.importDroidAccount() }
                }
                AIMButton(title: "Sign in another account", disabled: model.isBusy) {
                  Task { await model.startAccountLogin() }
                }
              }
            }
            Text("Switch saves the encrypted login and checks Droid's masked email. Equal masks can belong to different people. Type /login in Terminal when adding another account.")
              .aimText(.secondary)
          }
          HStack(alignment: .top, spacing: AIMTheme.sectionSpacing) {
            AIMIcon(name: model.accountLoginState == .needsAttention ? .warning : .account)
              .aimFont(.section)
              .foregroundStyle(
                model.accountLoginState == .needsAttention ? AIMTheme.amber : AIMTheme.blue)
            VStack(alignment: .leading, spacing: 2) {
              Text("Finish signing in to \(selectedProviderName)").aimText(.section)
              Text(
                "Sign in through a private temporary home. The saved account becomes available to \(selectedProviderName) after you finish."
              )
              .aimText(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
          if model.selectedProviderID == .grokBuild {
            SecureField(
              "Authorization code or callback URL", text: $grokAuthorizationCode,
              prompt: Text("Paste from the Grok browser page")
            )
            .privacySensitive()
            .onSubmit(submitGrokAuthorizationCode)
            .accessibilityHint(
              "Use this when the browser displays a code instead of returning to Switch.")
            LabeledContent {
              AIMButton(
                title: "Submit Code",
                disabled: model.isBusy || !hasGrokAuthorizationCode,
                action: submitGrokAuthorizationCode
              )
            } label: {
              Text("Switch sends this once to the waiting Grok CLI and does not save it.")
                .aimText(.secondary)
            }
          }
          Notice(
            text: model.displayedAccountLoginMessage
              ?? "Finish signing in to \(selectedProviderName), then return here and choose Check Now.",
            tone: model.accountLoginState == .needsAttention ? AIMTheme.amber : AIMTheme.blue
          )
          if model.accountLoginState == .credentialChoiceRequired {
            VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
              Text("This account is already saved with different access.").aimText(.body)
              HStack(spacing: AIMTheme.rowSpacing) {
                AIMButton(title: "Use new sign-in", tone: .primary) {
                  Task { await model.checkAccountLogin(credentialChoice: .useImported) }
                }
                AIMButton(title: "Keep saved access") {
                  Task { await model.checkAccountLogin(credentialChoice: .keepShared) }
                }
              }
            }
          } else {
            Text(ProviderChoices.builtIn.contains(model.selectedProviderID)
              ? "When the browser reports success, return to Switch and check the account."
              : "When the sign-in finishes in Terminal, return to Switch and check the account.")
              .aimText(.secondary)
          }
        }
      }

      ImportFooter(step: step, labels: ["Provider", "Sign in", "Done"], showsCancel: false) {
        EmptyView()
      } trailing: {
        // Cancel ends the sign-in session, not only the sheet.
        Button("Cancel") { Task { await model.cancelAccountLogin(); genericProviderID = nil } }
          .buttonStyle(AIMPushButtonStyle())
          .keyboardShortcut(.cancelAction)
        if model.accountLoginState != .credentialChoiceRequired {
          AIMButton(title: "Check Now", icon: .refresh, tone: .primary, disabled: model.accountLoginSession == nil) {
            Task { await model.checkAccountLogin() }
          }
          .keyboardShortcut(.defaultAction)
        }
      }
      .padding(AIMTheme.pageMargin)
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .task(id: model.accountLoginSession?.id) {
      guard model.accountLoginSession?.providerID == .droid else { return }
      for _ in 0..<120 {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        guard model.accountLoginSession?.providerID == .droid,
              model.accountLoginState == .waitingForLogin else { return }
        await model.checkAccountLogin()
        if model.errorMessage != nil { return }
      }
      model.accountLoginMessage = "Automatic checks stopped after ten minutes. Finish /login, then choose Check Now."
    }
  }

  private var completedPage: some View {
    VStack(spacing: 0) {
      AIMSheetForm {
        Section("Ready") {
          HStack(spacing: AIMTheme.rowSpacing) {
            AIMIcon(name: .success).aimFont(.section).foregroundStyle(AIMTheme.green)
            Text(model.selectedAccount?.identity.accountLabel ?? "\(selectedProviderName) account")
              .aimText(.section)
          }
          Text(model.displayedAccountLoginMessage ?? "The account is saved and ready to use.")
            .aimText(.secondary)
          Text(model.selectedProviderID == .codex
            ? "The account is ready for new Codex sessions. Shared settings and chats stay in place."
            : model.selectedProviderID == .claudeCode
              ? "The account is ready in its own Claude Code profile. Your usual Claude session stays in place."
              : model.selectedProviderID == .grokBuild
                ? "The account is ready in Grok Build. Its settings and sessions stay in the shared Grok home."
                : "The account is saved. Its usage appears in Switch, and Set as Default makes it the one that \(selectedProviderName) uses.")
            .aimText(.secondary)
          HStack(spacing: AIMTheme.rowSpacing) {
            DefaultAccountButton(isDefault: selectedIsDefault, disabled: model.isBusy, prominent: false) {
              Task { await model.switchDefault() }
            }
            if ProviderChoices.builtIn.contains(model.selectedProviderID) {
              AIMButton(
                title: AccountActionCopy.open(model.selectedProviderID),
                icon: .play,
                disabled: model.isBusy
              ) {
                Task { await model.openAccount() }
              }
            }
          }
        }
      }
      ImportFooter(step: step, labels: ["Provider", "Sign in", "Done"], showsCancel: false) {
        if let accountID = model.selectedAccountID {
          AIMButton(title: "Refresh usage", icon: .refresh, disabled: model.isBusy) {
            Task { await model.refreshAnyUsage(accountID: accountID) }
          }
        }
      } trailing: {
        AIMButton(title: "Done", tone: .primary) { model.closeAccountModal() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(AIMTheme.pageMargin)
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

struct ImportFlow: View {
  @ObservedObject var model: AccountViewModel
  var body: some View {
    VStack(spacing: 0) {
      ImportHeader(title: title)
      Group {
        if let result = model.importResult {
          ImportResultPage(result: result, model: model)
        } else if let plan = model.importPlan {
          ImportReviewPage(plan: plan, model: model)
        } else {
          SourcePage(model: model)
        }
      }
      .disabled(model.isBusy)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environment(\.aimCancelSheet, { model.closeAccountModal() })
    .overlay(alignment: .bottom) {
      if let error = model.displayedErrorMessage {
        AIMPanel {
          ErrorBar(message: error, copy: { model.copyWarnings([error]) }) {
            model.errorMessage = nil
          }
        }
        .padding(.horizontal, AIMTheme.pageMargin)
        .padding(.bottom, 52)
      } else if model.isBusy {
        HStack(spacing: AIMTheme.rowSpacing) {
          ProgressView().controlSize(.small)
          Text("Working…").aimText(.secondary)
        }
        .padding(.bottom, 58)
      }
    }
  }
  private var step: Int { model.importResult != nil ? 3 : model.importPlan != nil ? 2 : 1 }
  private var title: String {
    step == 1 ? "Import Account" : step == 2 ? "Review Import" : "Import Result"
  }
}

/// The sheet title. Sheets have no close button: every step has its own Cancel.
private struct ImportHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .aimText(.title)
      .lineLimit(1)
      .help(title)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding([.horizontal, .top], AIMTheme.pageMargin)
      .padding(.bottom, 4)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("import-modal-titlebar")
  }
}

/// The sheet's buttons and a small step indicator. The standard Cancel (Escape) closes the sheet.
struct ImportFooter<Leading: View, Trailing: View>: View {
  let step: Int
  var labels = ["Source", "Review", "Done"]
  var showsCancel = true
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing
  @Environment(\.aimCancelSheet) private var cancel

  var body: some View {
    ZStack {
      HStack(spacing: 8) {
        leading
        Spacer(minLength: 16)
        if showsCancel {
          Button("Cancel", action: cancel).buttonStyle(AIMPushButtonStyle()).keyboardShortcut(.cancelAction)
        }
        trailing
      }
      ImportSteps(step: step, labels: labels)
        .allowsHitTesting(false)
    }
    .accessibilityIdentifier("import-modal-footer")
  }
}

private struct ImportSteps: View {
  let step: Int
  let labels: [String]
  var body: some View {
    let index = min(max(step, 1), labels.count) - 1
    Text("Step \(index + 1) of \(labels.count) · \(labels[index])")
      .aimText(.secondary)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Step \(step) of \(labels.count)")
      .accessibilityIdentifier("import-modal-steps")
  }
}

private struct SourcePage: View {
  @ObservedObject var model: AccountViewModel
  @Environment(\.isEnabled) private var isEnabled
  var body: some View {
    VStack(spacing: 0) {
      AIMSheetForm {
        Section {
          Text("Choose a provider and one of its data folders.").aimText(.secondary)
          AIMPopUp(options: [ProviderID.codex], selection: $model.selectedProviderID,
            accessibilityLabel: "Provider", label: { $0.guiName })
        }
        Section("Source") {
          if model.discoveries.isEmpty {
            Text("No Codex accounts found. Refresh or choose another folder.")
              .aimText(.secondary)
          }
          ForEach(model.discoveries, id: \.id) { source in
            let supported = source.support == .supportedChatGPT
            let selected = source.id == model.selectedSourceID
            Button {
              model.selectedSourceID = source.id
            } label: {
              HStack(alignment: .top, spacing: AIMTheme.sectionSpacing) {
                AIMIcon(name: .check).aimFont(.body)
                  .foregroundStyle(AIMTheme.passiveIcon)
                  .opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                  Text(source.identity?.displayName ?? source.support.label).aimText(.body)
                  AIMCopyablePath(path: source.path.path)
                  Text(
                    "\(source.settings.count) settings · \(source.history.activeTranscripts) active · \(source.history.archivedTranscripts) archived"
                  ).aimText(.secondary).monospacedDigit()
                  if let reason = source.inspectionError, !supported {
                    Text(reason).aimText(.secondary, tint: AIMTheme.amber)
                      .lineLimit(2)
                      .help(reason)
                  }
                }
                Spacer()
                Badge(
                  text: source.support.label,
                  tint: source.support == .supportedChatGPT ? AIMTheme.green : AIMTheme.amber
                )
              }
              .contentShape(Rectangle())
              .opacity(isEnabled && supported ? 1 : 0.58)
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(selected ? AIMTheme.rowHighlight : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .disabled(!supported)
            .help(source.inspectionError ?? source.path.path)
          }
        }
        Section("Import scope") {
          AIMPopUp(options: [ImportMode.authOnly, .full], selection: $model.importMode,
            accessibilityLabel: "Import scope",
            label: { $0 == .authOnly ? "Account access only" : "Account access, settings, and chats" })
          Text(
            model.importMode == .authOnly
              ? "Saves account access. Settings and chats stay in the current Codex home. The source stays unchanged."
              : "Reviews Codex-home conflicts and adds source chats to the merged library. Everything affected is backed up first."
          ).aimText(.secondary)
        }
      }
      ImportFooter(step: 1) {
        HStack(spacing: AIMTheme.rowSpacing) {
          AIMButton(title: "Choose Codex folder…", icon: .folder) {
            Task { await model.chooseSource() }
          }
          AIMIconButton(icon: .refresh, label: "Refresh sources") { Task { await model.discover() } }
        }
      } trailing: {
        AIMButton(
          title: "Review import", tone: .primary,
          disabled: model.selectedSourceID == nil
            || model.discoveries.first(where: { $0.id == model.selectedSourceID })?.support
              != .supportedChatGPT
        ) { Task { await model.reviewImport() } }
      }
      .padding(AIMTheme.pageMargin)
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

private struct ImportReviewPage: View {
  let plan: ImportPlan
  @ObservedObject var model: AccountViewModel
  private var complete: Bool {
    plan.conflicts.allSatisfy {
      model.conflictChoices[$0.relativePath] != nil
        && (model.conflictChoices[$0.relativePath] != .useImported || $0.externalTarget == nil
          || $0.externalTargetBytes != nil)
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      AIMSheetForm {
        Section("Plan") {
          DetailRow(label: "Account", value: plan.identity.displayName)
          DetailRow(label: "Saved auth", value: plan.credentialDestination.path)
          if plan.mode == .full {
            DetailRow(label: "Shared Codex home", value: plan.sharedDestination.path)
            DetailRow(label: "Imported account data", value: plan.destination.path)
          }
          DetailRow(label: "Backup", value: plan.backup.path)
          DetailRow(
            label: "Space needed",
            value: ByteCountFormatter.string(
              fromByteCount: plan.requiredBytes, countStyle: .file))
        }
        if !plan.warnings.isEmpty {
          Section("Warnings") {
            WarningList(warnings: plan.warnings) { model.copyWarnings($0) }
          }
        }
        if !plan.conflicts.isEmpty {
          Section("Conflicts") {
            ForEach(plan.conflicts) { conflict in
              VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
                AIMCopyablePath(path: conflict.relativePath)
                Text(
                  conflict.affectsAllAccounts
                    ? "This settings choice affects every account opened from this Mac."
                    : "The saved credential differs from this source."
                ).aimText(.secondary)
                HStack(spacing: AIMTheme.rowSpacing) {
                  AIMSegmentedPicker(options: [Optional(ConflictChoice.keepShared), .useImported], selection: Binding(
                    get: { model.conflictChoices[conflict.relativePath] },
                    set: { model.conflictChoices[conflict.relativePath] = $0 }
                  ), accessibilityLabel: "Choice", label: {
                    $0 == .useImported ? "Use imported" : (conflict.affectsAllAccounts ? "Keep shared" : "Keep saved")
                  })
                  .fixedSize()
                  if conflict.externalTarget != nil
                    && model.conflictChoices[conflict.relativePath] == .useImported
                    && conflict.externalTargetBytes == nil
                  {
                    AIMButton(title: "Review linked data", disabled: model.isBusy) {
                      Task { await model.reviewExternalSetting(conflict.relativePath) }
                    }
                  }
                }
              }
            }
          }
        }
        Section("Manifest · \(plan.manifest.filter(\.selected).count) selected") {
          ForEach(plan.manifest) { entry in
            HStack(spacing: AIMTheme.rowSpacing) {
              AIMIcon(name: entry.selected ? .check : .minimize).aimFont(.body)
                .foregroundStyle(entry.selected ? AIMTheme.green : Color.secondary)
              AIMCopyablePath(path: entry.relativePath)
              Spacer()
              Text(entry.disposition).aimText(.secondary)
            }
          }
        }
      }
      ImportFooter(step: 2) {
        AIMButton(title: "Back") { model.resetImport() }
      } trailing: {
        AIMButton(title: "Import account", tone: .primary, disabled: !complete || model.isBusy) {
          Task { await model.commitImport() }
        }
      }
      .padding(AIMTheme.pageMargin)
    }
  }
}
private struct ImportResultPage: View {
  let result: ImportResult
  @ObservedObject var model: AccountViewModel
  var body: some View {
    VStack(spacing: 0) {
      AIMSheetForm {
        Section(result.unresolved.isEmpty ? "Import complete" : "Review required") {
          HStack(spacing: AIMTheme.sectionSpacing) {
            AIMIcon(name: result.unresolved.isEmpty ? .check : .warning).aimFont(.section)
              .foregroundStyle(result.unresolved.isEmpty ? AIMTheme.green : AIMTheme.amber)
            VStack(alignment: .leading, spacing: 2) {
              Text(result.account.identity.accountLabel).aimText(.section)
              Text(EmailPrivacy.display(result.verification.detail)).aimText(.secondary)
            }
            Spacer()
          }
        }
        Section("Result") {
          DetailRow(label: "Saved auth", value: result.account.credentialFile.path)
          DetailRow(label: "Backup", value: result.backup.path)
          DetailRow(
            label: "Imported",
            value: "\(result.importedFiles) files and \(result.importedChats) chats")
        }
        if !result.unresolved.isEmpty {
          Section("Unresolved items") {
            WarningList(warnings: result.unresolved) { model.copyWarnings($0) }
          }
        }
        Section {
          Notice(
            text:
              "The imported account is ready. Choose Use for new Codex sessions when you want to switch.",
            tone: AIMTheme.blue, icon: .success)
        }
      }
      ImportFooter(step: 3) {
        AIMButton(title: "Refresh usage", icon: .refresh, disabled: model.isBusy) {
          Task { await model.refreshUsage(accountID: result.account.id) }
        }
      } trailing: {
        AIMButton(title: "Done", tone: .primary) {
          model.closeAccountModal()
        }
      }
      .padding(AIMTheme.pageMargin)
    }
  }
}

extension AccountIdentity {
  fileprivate var heroName: String { accountLabel }
  fileprivate var displayName: String {
    if providerID == .droid { return accountLabel }
    if let email, let workspaceID { return "\(EmailPrivacy.display(email)) · \(workspaceID)" }
    if EmailPrivacy.isPrivacyMode() { return accountLabel }
    return email.map { EmailPrivacy.display($0) } ?? accountID ?? "Unresolved account"
  }
}
extension VerificationState {
  var attentionLabel: String? {
    switch self {
    case .imported: "Check required"
    case .needsSignIn: "Needs sign-in"
    case .verifiedLocally, .verifiedWithCodex: nil
    case .unsupported: "Unsupported"
    }
  }
  var color: Color {
    switch self {
    case .verifiedLocally, .verifiedWithCodex: AIMTheme.green
    case .needsSignIn: AIMTheme.amber
    case .unsupported: AIMTheme.red
    case .imported: AIMTheme.blue
    }
  }
}
extension SourceSupport {
  fileprivate var label: String {
    switch self {
    case .supportedChatGPT: "ChatGPT account"
    case .supportedOAuth: "Subscription OAuth"
    case .apiKey: "API key"
    case .missingAuth: "Missing auth"
    case .malformedAuth: "Malformed auth"
    case .keychainOnly: "Keychain only"
    case .unknown: "Unknown format"
    }
  }
}
