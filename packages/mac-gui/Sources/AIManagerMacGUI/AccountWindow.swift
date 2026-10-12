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
  static let defaultSize = NSSize(width: 1080, height: 760)
  static let minimumSize = NSSize(width: 980, height: 620)
  static let frameAutosaveName = "AIManagerMainWindow"
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  /// SwiftUI resets the content minimum while it lays out; the window never reports less.
  override var contentMinSize: NSSize {
    get {
      let size = super.contentMinSize
      return NSSize(
        width: max(size.width, Self.minimumSize.width), height: max(size.height, Self.minimumSize.height))
    }
    set { super.contentMinSize = newValue }
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
    let host = NSHostingController(rootView: rootView)
    host.sizingOptions = []
    window.contentViewController = host
    window.contentMinSize = AIManagerWindow.minimumSize
    window.isReleasedWhenClosed = false
    window.setContentSize(defaultSize)
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

  @objc private func minimizeFromButton(_ sender: Any?) {
    AIManagerWindowBehavior.minimize(window)
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: AIManagerWindow.minimumSize)).size
    return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
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

  func windowWillClose(_ notification: Notification) { savePlacement() }

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
      EmailPrivacy.display(account.identity.accountLabel, hide: hideEmails),
      account.identity.providerID.guiName, account.identity.workspaceID ?? "",
    ].joined(separator: " ").lowercased()
    return terms.allSatisfy { haystack.contains($0) }
  }

  static func filter(_ accounts: [AccountRecord], query: String, hideEmails: Bool = false) -> [AccountRecord] {
    accounts.filter { matches($0, query: query, hideEmails: hideEmails) }
  }
}

/// The main window: a native sidebar (Overview, Accounts, Conversations, Maintenance, Settings), a
/// unified toolbar with account search, Add, and More, and the selected page.
struct AccountWindow: View {
  @ObservedObject var model: AccountViewModel
  @StateObject private var target = WindowTarget()
  @State private var page: AIManagerPage = .overview
  @State private var searchQuery = ""
  @State private var maintenanceSection: MaintenanceSection = .backup
  @FocusState private var searchFocused: Bool
  @AppStorage("appearanceMode") private var appearanceMode = "system"
  @Environment(\.colorScheme) private var systemScheme
  private var themeOverride: ColorScheme? {
    appearanceMode == "dark" ? .dark : (appearanceMode == "light" ? .light : nil)
  }
  private var dark: Bool { (themeOverride ?? systemScheme) == .dark }

  init(
    model: AccountViewModel, initialPageIndex: Int = 0, initialMaintenance: MaintenanceSection = .backup
  ) {
    self.model = model
    let pages = AIManagerPage.allCases
    _page = State(initialValue: pages.indices.contains(initialPageIndex) ? pages[initialPageIndex] : .overview)
    _maintenanceSection = State(initialValue: initialMaintenance)
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
    }
    // The content runs under the transparent title bar; the sidebar and top row clear the lights.
    .ignoresSafeArea()
    .sheet(isPresented: Binding(
      get: { model.showImport },
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
    }
    .environment(\.aimCopyPath, model.copyPath)
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
    .task(id: model.hasLoaded, priority: .utility) {
      if model.hasLoaded { await model.watchActivity() }
    }
  }

  private func show(_ next: AIManagerPage) {
    page = next
    NotificationCenter.default.post(name: AIManagerNavigation.didShowPage, object: next)
  }

  @ViewBuilder private var pageView: some View {
    switch page {
    case .overview:
      OverviewPage(model: model, query: searchQuery) { target in
        if target == .maintenance { maintenanceSection = .backup }
        show(target)
      }
    case .accounts: AccountsPage(model: model, query: searchQuery)
    case .conversations: HistoryPage(model: model)
    case .maintenance: MaintenancePage(model: model, section: $maintenanceSection)
    case .settings: SettingsPage(model: model)
    }
  }

  /// The content's top row, lightest to heaviest from left to right: Add, More, then the 300 pt
  /// account search at the right edge. Command-K focuses the search.
  private var pageHeader: AnyView {
    AnyView(
      VStack(spacing: 0) {
        topBar
        if let error = model.errorMessage, !model.showImport {
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
      AIMSearchField(text: $searchQuery, focus: $searchFocused, prompt: AIManagerToolbar.searchPrompt)
    }
    .frame(height: AIMTheme.topBarHeight)
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
    .buttonStyle(.borderless)
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
      AIMStateChip(text: "Default")
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

/// The account list (drag to reorder) beside the selected account's detail.
private struct AccountsPage: View {
  @ObservedObject var model: AccountViewModel
  let query: String
  @State private var pendingDeletion: AccountRecord?
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  @AppStorage(UsagePercentagePreferences.showsUsedKey) private var showsUsed = false

  private var accounts: [AccountRecord] {
    AccountSearch.filter(model.status?.accounts ?? [], query: query, hideEmails: hideEmails)
  }

  var body: some View {
    // Only the page scrolls: the table shows every row.
    AIMScrollPage {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        AccountsTableCard(
          accounts: accounts, total: model.status?.accounts.count ?? 0, query: query, model: model,
          focusedID: model.selectedAccountID, now: context.date, hideEmails: hideEmails,
          showsUsed: showsUsed,
          focus: { model.selectedAccountID = $0 },
          delete: { prepareDeletion(of: $0) },
          loading: !model.hasLoaded,
          onMove: query.isEmpty
            ? { id, target in Task { await model.moveAccount(id, to: target) } } : nil,
          contextMenu: { AnyView(accountContextMenu(for: $0)) })
      }
      if let account = model.selectedAccount {
        if account.usesGenericDetail {
          ProviderAccountDetail(account: account, model: model) {
            prepareDeletion(of: account)
          }
        } else {
          AccountDetail(account: account, model: model) {
            prepareDeletion(of: account)
          }
        }
      } else {
        EmptyAccountView(model: model)
      }
    }
    .accountDeletionAlert(model: model, pending: $pendingDeletion)
  }

  @ViewBuilder
  private func accountContextMenu(for account: AccountRecord) -> some View {
    let isDefault = model.status?.isDefault(account) == true
    Button(isDefault ? AccountActionCopy.usingDefault : AccountActionCopy.use) {
      Task { await model.switchDefault(to: account.id) }
    }
    .disabled(model.isBusy)
    if account.usesGenericDetail {
      Button("Refresh usage") {
        Task { await model.refreshProviderUsage(accountID: account.id) }
      }
      .disabled(model.isBusy || model.providerUsage[account.id]?.isRefreshing == true)
    } else {
      Button(
        isDefault
          ? AccountActionCopy.open(account.identity.providerID)
          : AccountActionCopy.useAndOpen(account.identity.providerID)
      ) {
        Task { await model.openAccount(account.id) }
      }
      .disabled(model.isBusy)
      Button(AccountActionCopy.check) {
        Task { await model.checkAccount(account.id) }
      }
      .disabled(model.isBusy)
      Button(account.identity.providerID == .claudeCode ? "Copy config path" : AccountActionCopy.copyAuthPath) {
        model.copySavedAuthPath(for: account.id)
      }
    }
    Divider()
    Button("Move up") {
      if let target = model.adjacentAccountID(to: account.id, offset: -1) {
        Task { await model.moveAccount(account.id, to: target) }
      }
    }.disabled(model.isBusy || model.adjacentAccountID(to: account.id, offset: -1) == nil)
    Button("Move down") {
      if let target = model.adjacentAccountID(to: account.id, offset: 1) {
        Task { await model.moveAccount(account.id, to: target) }
      }
    }.disabled(model.isBusy || model.adjacentAccountID(to: account.id, offset: 1) == nil)
    Divider()
    Button(AccountActionCopy.delete, role: .destructive) {
      prepareDeletion(of: account)
    }
    .disabled(model.isBusy || !model.canDeleteAccount(account.id))
  }

  private func prepareDeletion(of account: AccountRecord) {
    model.requestDeletion(of: account, into: $pendingDeletion)
  }
}
/// Drag-to-reorder math for the Accounts list.
enum AccountReorder {
  /// The account to move and the account whose position it takes, or nil when nothing changes.
  /// `destination` is SwiftUI's insertion offset in the list before the move.
  static func move(
    accountIDs: [UUID], from source: IndexSet, to destination: Int
  ) -> (accountID: UUID, targetID: UUID)? {
    guard source.count == 1, let from = source.first, accountIDs.indices.contains(from),
          (0...accountIDs.count).contains(destination) else { return nil }
    let to = destination > from ? destination - 1 : destination
    guard to != from, accountIDs.indices.contains(to) else { return nil }
    return (accountIDs[from], accountIDs[to])
  }
}

struct AccountListRow: View {
  let account: AccountRecord, selected: Bool, isDefault: Bool
  /// Open incident of the account's provider; a dot shows beside the provider name when it is minor or worse.
  var providerStatus: ProviderStatusEntry? = nil
  /// Only changes when "Hide email addresses" does, so the row redraws.
  var hidesEmails = false
  var body: some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      AccountCell(account: account, hideEmails: hidesEmails, providerStatus: providerStatus)
      Spacer(minLength: 4)
      if isDefault {
        AIMIcon(name: .check).aimText(.body).foregroundStyle(AIMTheme.green)
          .help("Default account")
      }
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityValue(
      [isDefault ? "Default account" : "Not the default account",
       ProviderStatusDot.text(providerStatus).map { "Provider status: \($0)" }]
        .compactMap { $0 }.joined(separator: ". "))
  }
}
private struct EmptyAccountView: View {
  @ObservedObject var model: AccountViewModel
  var body: some View {
    AIMDetailPage {
      AIMSection("Account") {
        if !model.hasLoaded {
          HStack(spacing: AIMTheme.rowSpacing) {
            ProgressView().controlSize(.small)
            Text("Loading accounts…").aimText(.body)
          }
        } else {
          VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
            Text("Add your first account").aimText(.section)
            Text(
              "Switch found no saved account. Sign in to Codex or Grok Build, or use Advanced Import for an existing Codex folder."
            ).aimText(.secondary)
            HStack(spacing: AIMTheme.rowSpacing) {
              AIMButton(title: "Add account", icon: .plus, tone: .primary, disabled: model.isBusy) {
                Task { await model.beginAddAccount() }
              }
              AIMButton(title: "Advanced Import…", icon: .folder, disabled: model.isBusy) {
                Task { await model.beginAdvancedImport() }
              }
            }
          }
        }
      }
    }
  }
}

private struct AccountDetail: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let delete: () -> Void
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var issues: [LinkedSettingsDivergence] {
    model.status?.linkedSettingsDivergences.filter { $0.accountID == account.id } ?? []
  }
  var body: some View {
    AIMDetailPage {
      AIMSection("Identity") {
        VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
          HStack(alignment: .firstTextBaseline, spacing: AIMTheme.rowSpacing) {
            Text(EmailPrivacy.display(account.identity.heroName, hide: hideEmails))
              .aimText(.title)
              .lineLimit(1).textSelection(.enabled)
            identityStatus
          }
          if let workspaceID = account.identity.workspaceID {
            Text(workspaceID).aimText(.secondary, monospaced: true).textSelection(.enabled)
          } else {
            Text("Personal workspace").aimText(.secondary).textSelection(.enabled)
          }
          if let entry = model.providerStatus[account.identity.providerID],
             entry.incident.severity != nil {
            HStack(spacing: 6) {
              ProviderStatusDot(entry: entry)
              Text(account.identity.providerID.guiName).aimText(.secondary)
            }
          }
          if account.verification.state.attentionLabel != nil {
            Text(EmailPrivacy.display(account.verification.detail)).aimText(.secondary)
              .textSelection(.enabled)
          }
          ViewThatFits(in: .horizontal) {
            HStack(spacing: AIMTheme.rowSpacing) { actions }
            VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) { actions }
          }
        }
      }
      if account.identity.providerID == .codex {
        AccountUsagePanel(account: account, model: model)
      } else if ProviderUsagePanel.applies(to: account, in: model) {
        ProviderUsagePanel(account: account, model: model)
      }
      if account.identity.providerID == .claudeCode {
        ClaudeActivityPanel(model: model)
      }
      AIMSection("Account details") {
        DetailRow(label: account.identity.providerID == .claudeCode ? "Profile config" : "Saved auth",
                  value: account.credentialFile.path)
        DetailRow(label: "Source", value: account.source.path)
        DetailRow(
          label: "\(account.identity.providerID.guiName) home",
          value: account.identity.providerID == .claudeCode ? account.home.path
            : account.identity.providerID == .grokBuild
              ? model.paths.grokHome.path : model.paths.defaultHome.path)
        DetailRow(
          label: "Imported",
          value: account.importedAt.formatted(date: .abbreviated, time: .shortened))
        DetailRow(
          label: "Last used",
          value: account.lastUsedAt?.formatted(date: .abbreviated, time: .shortened)
            ?? "Not launched yet")
      }
      if !issues.isEmpty {
        AIMSection("Account data needs repair") {
          ForEach(issues) { issue in
            HStack(spacing: AIMTheme.sectionSpacing) {
              AIMIcon(name: .warning).aimText(.body).foregroundStyle(AIMTheme.amber)
              VStack(alignment: .leading, spacing: 2) {
                AIMCopyablePath(path: issue.relativePath)
                AIMCopyablePath(path: issue.localPath.path)
              }
              Spacer()
              WarningCopyButton(label: "Copy repair warning") {
                model.copyWarnings([
                  "Account data needs repair: \(issue.relativePath)\nLocation: \(issue.localPath.path)"
                ])
              }
              AIMButton(title: "Back up and repair", tone: .danger, disabled: model.isBusy) {
                Task { await model.repairLinkedSetting(issue) }
              }
            }
          }
        }
      }
      if let notice = model.notice {
        AIMSection { Notice(text: notice, tone: AIMTheme.blue) }
          .transition(reduceMotion ? .identity : .opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.notice)
  }
  private var identityStatus: some View {
    HStack(spacing: 6) {
      if model.status?.isDefault(account) == true {
        Badge(text: "Default")
      }
      if let attention = account.verification.state.attentionLabel {
        Badge(text: attention, tint: account.verification.state.color)
      }
    }
  }
  @ViewBuilder private var actions: some View {
    if model.needsSignIn(account) {
      SignInButton(account: account, model: model)
    } else if model.status?.isDefault(account) != true {
      DefaultAccountButton(isDefault: false, disabled: model.isBusy) {
        Task { await model.switchDefault(to: account.id) }
      }
    }
    AIMButton(
      title: model.status?.isDefault(account) == true
        ? AccountActionCopy.open(account.identity.providerID)
        : AccountActionCopy.useAndOpen(account.identity.providerID),
      disabled: model.isBusy
    ) {
      Task { await model.openAccount(account.id) }
    }
    AccountMoreMenu(account: account, model: model, delete: delete)
  }
}

enum UsagePresentation {
  struct Fact: Identifiable, Equatable {
    let label: String
    let value: String
    var help: String? = nil
    var id: String { label }
  }

  struct ActivityDay: Identifiable, Equatable {
    let date: Date
    let tokens: Int64
    var id: Date { date }
  }

  static func accountFacts(_ snapshot: CodexAccountUsageSnapshot) -> [Fact] {
    var facts: [Fact] = []
    if let allowed = snapshot.rateLimits?.ordinaryUsageAllowed {
      facts.append(Fact(label: "Ordinary usage", value: allowed ? "Available" : "Restricted"))
    }
    if snapshot.account != nil {
      facts.append(Fact(label: "Authentication", value: "Signed in"))
    } else if let required = snapshot.requiresOpenAIAuthentication {
      facts.append(Fact(
        label: "Authentication", value: required ? "Sign-in required" : "Not required"))
    }
    if let fact = resetCreditsFact(snapshot.extras?.resetCredits) { facts.append(fact) }
    if let balance = snapshot.extras?.creditsBalance, !hasBucketCredits(snapshot),
       let text = CodexCreditsText.text(balance: balance) {
      facts.append(Fact(label: "Credits", value: text))
    }
    return facts
  }

  /// "Reset credits: 2" with the soonest expiry; the tooltip lists every expiry.
  static func resetCreditsFact(_ credits: CodexResetCredits?) -> Fact? {
    credits.map { Fact(label: "Reset credits", value: $0.summary, help: $0.expiryList) }
  }

  private static func hasBucketCredits(_ snapshot: CodexAccountUsageSnapshot) -> Bool {
    let buckets = [snapshot.rateLimits?.defaultBucket].compactMap { $0 }
      + (snapshot.rateLimits.map { Array($0.buckets.values) } ?? [])
    return buckets.contains { credits($0.credits) != nil }
  }

  static func summaryFacts(_ summary: CodexUsageSummarySnapshot?) -> [Fact] {
    guard let summary else { return [] }
    var facts: [Fact] = []
    if let value = summary.lifetimeTokens {
      facts.append(Fact(label: "Lifetime", value: formatTokens(value)))
    }
    if let value = summary.peakDailyTokens {
      facts.append(Fact(label: "Peak day", value: formatTokens(value)))
    }
    if let value = summary.currentStreakDays {
      facts.append(Fact(label: "Current streak", value: formatDays(value)))
    }
    if let value = summary.longestStreakDays {
      facts.append(Fact(label: "Longest streak", value: formatDays(value)))
    }
    if let value = summary.longestRunningTurnSeconds {
      facts.append(Fact(label: "Longest turn", value: formatDuration(value)))
    }
    return facts
  }

  static func credits(_ credits: CodexCreditsSnapshot?) -> String? {
    guard let credits else { return nil }
    if credits.unlimited == true { return "Unlimited" }
    if let balance = nonempty(credits.balance) {
      // Codex sends a fixed-point string such as "796.4009760000".
      return CodexCreditsText.text(balance: balance) ?? balance
    }
    if let hasCredits = credits.hasCredits { return hasCredits ? "Available" : "None" }
    return nil
  }

  static func spendControl(_ reached: Bool?) -> String? {
    reached.map { $0 ? "Reached" : "Not reached" }
  }

  static func hasWindow(_ window: CodexRateLimitWindowSnapshot?) -> Bool {
    window?.usedPercent != nil
  }

  static func hasContent(_ bucket: CodexRateLimitBucketSnapshot) -> Bool {
    hasWindow(bucket.primary) || hasWindow(bucket.secondary) || credits(bucket.credits) != nil
      || spendControl(bucket.spendControlReached) != nil
  }

  static func hasRateLimits(_ bucket: CodexRateLimitBucketSnapshot) -> Bool {
    hasWindow(bucket.primary) || hasWindow(bucket.secondary)
  }

  static func emptyUsageTitle(failure: String?, needsSignIn: Bool) -> String {
    if needsSignIn { return "Sign in to refresh usage" }
    return failure == nil ? "Usage has not been checked" : "Usage could not be refreshed"
  }

  static func activityDays(
    _ rows: [CodexDailyUsageSnapshot],
    endingAt endDate: Date,
    dayCount: Int
  ) -> [ActivityDay] {
    let calendar = activityCalendar
    let end = calendar.startOfDay(for: endDate)
    let count = min(max(dayCount, 1), 366)
    let start = calendar.date(byAdding: .day, value: -(count - 1), to: end) ?? end
    var tokensByDay: [Date: Int64] = [:]
    for row in rows {
      guard let startDate = nonempty(row.startDate),
            let date = activityDate(startDate),
            let tokens = row.tokens,
            date >= start,
            date <= end
      else { continue }
      let value = max(0, tokens)
      let current = tokensByDay[date, default: 0]
      let (sum, overflow) = current.addingReportingOverflow(value)
      tokensByDay[date] = overflow ? Int64.max : sum
    }
    return (0..<count).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
      return ActivityDay(date: date, tokens: tokensByDay[date, default: 0])
    }
  }

  static func exactTokens(_ value: Int64) -> String {
    value.formatted(.number)
  }

  static func activityWeeks(for days: [ActivityDay]) -> [[ActivityDay?]] {
    guard let first = days.first else { return [] }
    let weekday = activityCalendar.component(.weekday, from: first.date)
    var padded = Array(repeating: Optional<ActivityDay>.none, count: weekday - 1)
    padded.append(contentsOf: days.map(Optional.some))
    while !padded.count.isMultiple(of: 7) { padded.append(nil) }
    return stride(from: 0, to: padded.count, by: 7).map {
      Array(padded[$0..<$0 + 7])
    }
  }

  static func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
  }

  static func formatTokens(_ value: Int64) -> String {
    value.formatted(.number.notation(.compactName))
  }

  static func formatCurrency(_ value: Double) -> String {
    if value >= 1_000 {
      return "$" + (value / 1_000).formatted(
        .number.precision(.fractionLength(0...1))) + "K"
    }
    return "$" + value.formatted(
      .number.precision(.fractionLength(value < 10 ? 0...2 : 0...0)))
  }

  private static func formatDays(_ value: Int64) -> String {
    "\(value) day\(value == 1 ? "" : "s")"
  }

  private static func formatDuration(_ seconds: Int64) -> String {
    Duration.seconds(seconds).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
  }

  private static let activityCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  private static func activityDate(_ value: String) -> Date? {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
          let date = activityCalendar.date(from: DateComponents(
            calendar: activityCalendar, timeZone: activityCalendar.timeZone,
            year: year, month: month, day: day))
    else { return nil }
    let components = activityCalendar.dateComponents([.year, .month, .day], from: date)
    return components.year == year && components.month == month && components.day == day
      ? date : nil
  }
}

struct UsageActivityCalendar: View {
  let rows: [CodexDailyUsageSnapshot]
  @ObservedObject var model: AccountViewModel
  @AppStorage("usageTokenPeriod") private var storedPeriod = CodexTokenPeriod.yearly.rawValue
  @State private var selectedDate: Date?
  @State private var projects: [CodexProjectDailyActivity] = []
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var period: CodexTokenPeriod {
    get { CodexTokenPeriod(rawValue: storedPeriod) ?? .yearly }
    nonmutating set { storedPeriod = newValue.rawValue }
  }

  private var periodSelection: Binding<CodexTokenPeriod> {
    Binding(get: { period }, set: { period = $0 })
  }

  var body: some View {
    let endDate = period.dateRange(endingAt: Date())?.upperBound ?? Date()
    let days = UsagePresentation.activityDays(rows, endingAt: endDate, dayCount: period.dayCount)
    let maximumTokens = days.lazy.map(\.tokens).max() ?? 0
    let selectedDay = days.first { $0.date == selectedDate }
    let weeks = UsagePresentation.activityWeeks(for: days)
    VStack(alignment: .leading, spacing: AIMTheme.sectionSpacing) {
      HStack(spacing: AIMTheme.rowSpacing) {
        if let selectedDay {
          Text(selectedDay.date.formatted(date: .abbreviated, time: .omitted))
            .aimText(.secondary)
          Text("\(UsagePresentation.exactTokens(selectedDay.tokens)) tokens")
            .aimText(.body).monospacedDigit()
        }
        Spacer()
        TokenPeriodPicker(selection: periodSelection)
      }
      TokenStatistic(
        period: period,
        tokens: period.tokens(in: rows, endingAt: Date()),
        price: model.apiPrice)
      if period.dayCount <= 7 {
        HStack(spacing: 6) {
          ForEach(days) { day in
            VStack(spacing: 5) {
              Text(day.date.formatted(.dateTime.weekday(.narrow)))
                .aimText(.secondary)
              ActivityCell(
                day: day, maximumTokens: maximumTokens,
                selected: selectedDate == day.date, size: 18
              ) { selectedDate = day.date }
            }
          }
          Spacer()
        }
      } else {
        // The calendar shrinks its cells to fit narrow windows.
        ViewThatFits(in: .horizontal) {
          ForEach([cellSize, 8, 7, 6, 5], id: \.self) { size in
            HStack(alignment: .top, spacing: 0) {
              ActivityHeatmap(weeks: weeks, maximumTokens: maximumTokens,
                selectedDate: selectedDate, size: size) { selectedDate = $0 }
              Spacer(minLength: 0)
            }
          }
        }
      }
      if !projects.isEmpty {
        VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
          Text("Projects in this Codex home")
            .aimText(.body)
            .help("Recorded from local conversation token events. These shared-home totals are separate from account usage.")
          ForEach(projects, id: \.project) { project in
            HStack(spacing: AIMTheme.sectionSpacing) {
              if project.project.hasPrefix("/") {
                AIMCopyablePath(path: project.project)
              } else { Text(project.project).aimText(.body) }
              Spacer()
              Text("\(UsagePresentation.exactTokens(project.tokens)) tokens")
                .aimText(.secondary).monospacedDigit()
              if !project.isComplete {
                AIMIcon(name: .info).aimFont(.secondary).foregroundStyle(AIMTheme.amber)
                  .help("Some source records are incomplete. Previously recorded totals were retained.")
              }
            }
          }
        }
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: period)
    .onChange(of: storedPeriod) { _, _ in
      if let selectedDate, !days.contains(where: { $0.date == selectedDate }) {
        self.selectedDate = nil
      }
    }
    .onChange(of: model.selectedAccountID) { _, _ in
      selectedDate = nil
      projects = []
    }
    .task(id: selectedDate) {
      projects = []
      guard let selectedDate else { return }
      let result = await model.projectActivity(on: selectedDate)
      guard !Task.isCancelled else { return }
      projects = result
    }
  }

  private var cellSize: CGFloat { period == .yearly ? 9 : 13 }
}

struct ActivityHeatmap: View {
  let weeks: [[UsagePresentation.ActivityDay?]]
  let maximumTokens: Int64
  let selectedDate: Date?
  let size: CGFloat
  let select: (Date) -> Void
  @State private var hovered = CGPoint.zero
  @State private var pointerInside = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  private var pitch: CGFloat { size + 3 }
  func day(at point: CGPoint) -> UsagePresentation.ActivityDay? {
    guard point.x >= 15, point.y >= 0 else { return nil }
    let column = Int((point.x - 15) / pitch), row = Int(point.y / pitch)
    guard weeks.indices.contains(column), (0..<7).contains(row),
      (point.x - 15).truncatingRemainder(dividingBy: pitch) < size,
      point.y.truncatingRemainder(dividingBy: pitch) < size else { return nil }
    return weeks[column][row]
  }

  func selection(after key: KeyEquivalent) -> Date? {
    let days = weeks.flatMap { $0 }.compactMap { $0 }
    guard !days.isEmpty else { return nil }
    let offset: Int
    switch key {
    case .leftArrow: offset = -7
    case .rightArrow: offset = 7
    case .upArrow: offset = -1
    case .downArrow: offset = 1
    default: return nil
    }
    let index = days.firstIndex { $0.date == selectedDate } ?? days.count - 1
    return days[min(max(index + offset, 0), days.count - 1)].date
  }

  var body: some View {
    let hoverDay = pointerInside && isEnabled ? day(at: hovered) : nil
    Canvas { context, _ in
      for row in [1, 3, 5] {
        context.draw(Text(row == 1 ? "M" : row == 3 ? "W" : "F")
          .font(AIMTextRole.secondary.font).foregroundStyle(.secondary),
          at: CGPoint(x: 5, y: CGFloat(row) * pitch + size / 2))
      }
      for (column, week) in weeks.enumerated() {
        for (row, day) in week.enumerated() {
          guard let day else { continue }
          let rect = CGRect(x: 15 + CGFloat(column) * pitch, y: CGFloat(row) * pitch,
                            width: size, height: size)
          let path = Path(roundedRect: rect, cornerRadius: max(1, size * 0.18))
          let intensity = maximumTokens > 0
            ? 0.24 + 0.70 * sqrt(Double(day.tokens) / Double(maximumTokens)) : 0
          context.fill(path, with: .color(day.tokens > 0
            ? AIMTheme.green.opacity(intensity) : AIMTheme.track))
          if selectedDate == day.date {
            context.stroke(path, with: .color(.primary), lineWidth: 1)
          }
        }
      }
    }
    .frame(width: 15 + CGFloat(weeks.count) * pitch - 3, height: 7 * pitch - 3)
    .overlay(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: max(1, size * 0.18))
        .fill(Color.primary).frame(width: size, height: size)
        .opacity(hoverDay == nil ? 0 : 0.07)
        .offset(x: 15 + floor(max(0, hovered.x - 15) / pitch) * pitch,
                y: floor(max(0, hovered.y) / pitch) * pitch)
        .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      switch phase {
      case .active(let point):
        pointerInside = isEnabled && day(at: point) != nil
        if pointerInside { hovered = point }
      case .ended: pointerInside = false
      }
    }
    .gesture(SpatialTapGesture().onEnded { event in
      if isEnabled, let day = day(at: event.location) { select(day.date) }
    })
    .help(hoverDay.map {
      "\($0.date.formatted(date: .complete, time: .omitted)): \(UsagePresentation.exactTokens($0.tokens)) tokens"
    } ?? "Daily token activity. Select a day for details.")
    .focusable()
    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { event in
      guard isEnabled, let date = selection(after: event.key) else { return .ignored }
      select(date)
      return .handled
    }
    .accessibilityRepresentation {
      HStack(alignment: .top, spacing: 3) {
        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
          VStack(spacing: 3) {
            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
              if let day {
                Button { select(day.date) } label: { Color.clear.frame(width: size, height: size) }
                  .buttonStyle(.plain)
                  .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                  .accessibilityValue("\(UsagePresentation.exactTokens(day.tokens)) tokens")
                  .accessibilityAddTraits(selectedDate == day.date ? .isSelected : [])
              } else {
                Color.clear.frame(width: size, height: size).accessibilityHidden(true)
              }
            }
          }
        }
      }.padding(.leading, 15)
    }
  }
}

private struct ActivityCell: View {
  let day: UsagePresentation.ActivityDay
  let maximumTokens: Int64
  let selected: Bool
  let size: CGFloat
  let select: () -> Void
  private var fill: Color {
    guard day.tokens > 0, maximumTokens > 0 else {
      return AIMTheme.track
    }
    let intensity = 0.24 + 0.70 * sqrt(Double(day.tokens) / Double(maximumTokens))
    return AIMTheme.green.opacity(intensity)
  }

  var body: some View {
    Button(action: select) {
      RoundedRectangle(cornerRadius: max(1, size * 0.18))
        .fill(fill)
        .overlay {
          if selected {
            RoundedRectangle(cornerRadius: max(1, size * 0.18)).stroke(Color.primary, lineWidth: 1)
          }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("\(day.date.formatted(date: .complete, time: .omitted)): \(UsagePresentation.exactTokens(day.tokens)) tokens")
    .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
    .accessibilityValue("\(UsagePresentation.exactTokens(day.tokens)) tokens")
  }
}

private struct AccountUsagePanel: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel

  private var snapshot: CodexAccountUsageSnapshot? { model.usage(for: account.id) }
  private var cached: CachedCodexAccountUsage? { model.cachedUsage(for: account.id) }
  private var isRefreshing: Bool { model.usageRefreshAccountID == account.id }
  private var usageFailure: String? {
    model.usageError(for: account.id) ?? cached?.failureMessage
  }

  private var limitBuckets: [(key: String, value: CodexRateLimitBucketSnapshot)] {
    var result: [(String, CodexRateLimitBucketSnapshot)] = []
    var seen = Set<String>()
    if let limits = snapshot?.rateLimits {
      if let bucket = limits.defaultBucket {
        let key = bucket.id ?? "default"
        if UsagePresentation.hasContent(bucket) {
          seen.insert(key)
          result.append((key, bucket))
        }
      }
      for (key, bucket) in limits.buckets.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
        let identity = bucket.id ?? key
        guard seen.insert(identity).inserted else { continue }
        if UsagePresentation.hasContent(bucket) { result.append((key, bucket)) }
      }
    }
    // Model buckets such as Spark from the ChatGPT backend, when the app-server did not list them.
    let titles = Set(result.map { Self.title(of: $0.1, key: $0.0) })
    for bucket in snapshot?.extras?.additionalBuckets ?? [] {
      let key = bucket.id ?? bucket.name ?? "extra"
      guard seen.insert(key).inserted, !titles.contains(Self.title(of: bucket, key: key)) else { continue }
      result.append((key, bucket))
    }
    return result
  }

  static func title(of bucket: CodexRateLimitBucketSnapshot, key: String) -> String {
    CodexBucketNaming.title(id: bucket.id, name: bucket.name, model: bucket.model, fallback: key)
  }

  private var monthlyCredits: CodexMonthlyCredits? { snapshot?.extras?.monthlyCredits }

  var body: some View {
    AIMSection("Usage") {
      if let snapshot {
        LabeledContent(CodexPlanNames.display(snapshot.account?.plan) ?? "Codex usage") {
          usageStatus
        }

        ForEach(limitBuckets, id: \.key) { item in
          UsageBucket(
            bucket: item.value,
            fallbackName: item.key,
            accountID: account.id,
            refresh: { Task { await model.refreshUsage(accountID: account.id) } }
          )
        }

        if let monthlyCredits {
          MonthlyCreditsRow(accountID: account.id, credits: monthlyCredits) {
            Task { await model.refreshUsage(accountID: account.id) }
          }
        }

        HiddenUsageRowsNote(
          accountID: account.id,
          rowIDs: limitBuckets.flatMap { item in
            ["primary", "secondary"].map { "\(item.key)/\($0)" }
          } + (monthlyCredits == nil ? [] : [MonthlyCreditsRow.rowID]))

        if monthlyCredits == nil, !limitBuckets.contains(where: { UsagePresentation.hasRateLimits($0.value) }) {
          UsageUnavailableRow(text: "Rate limits unavailable")
        }
      } else {
        HStack(spacing: AIMTheme.sectionSpacing) {
          AIMIcon(name: .info).aimText(.body).foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(UsagePresentation.emptyUsageTitle(
              failure: usageFailure, needsSignIn: account.verification.state == .needsSignIn))
              .aimText(.body)
            if let failure = usageFailure {
              Text(failure).aimText(.secondary, tint: AIMTheme.amber)
            } else {
              Text("Refresh this saved account without changing the default account.")
                .aimText(.secondary)
            }
          }
          Spacer()
          if let failure = usageFailure {
            WarningCopyButton(label: "Copy usage error") { model.copyWarnings([failure]) }
          }
          refreshButton
        }
      }
    }
    if let snapshot {
      let accountFacts = UsagePresentation.accountFacts(snapshot)
      let summaryFacts = UsagePresentation.summaryFacts(snapshot.usage)
      if !accountFacts.isEmpty || !summaryFacts.isEmpty {
        AIMSection("Usage facts") {
          ForEach(accountFacts) { fact in
            UsageFact(label: fact.label, value: fact.value, help: fact.help)
          }
          ForEach(summaryFacts) { fact in
            UsageFact(label: fact.label, value: fact.value)
          }
        }
      }
    }
    if !model.dailyUsage(for: account.id).isEmpty {
      AIMSection("Daily activity") {
        UsageActivityCalendar(rows: model.dailyUsage(for: account.id), model: model)
      }
    }
  }

  @ViewBuilder private var usageStatus: some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      if let failure = usageFailure {
        Text(failure).aimText(.secondary, tint: AIMTheme.amber).lineLimit(1)
          .help(failure)
        WarningCopyButton(label: "Copy usage error") {
          model.copyWarnings([failure])
        }
      } else if let fetchedAt = snapshot?.fetchedAt {
        Text(cached?.isStale == true ? "Cached" : "Updated")
          .aimText(.secondary)
        Text(fetchedAt.formatted(date: .omitted, time: .shortened))
          .aimText(.secondary).monospacedDigit()
      }
      refreshButton
    }
  }

  private var refreshButton: some View {
    AIMIconButton(
      icon: .refresh,
      label: isRefreshing ? "Refreshing usage" : "Refresh usage",
      disabled: model.usageRefreshAccountID != nil || model.isBusy
    ) {
      Task { await model.refreshUsage(accountID: account.id) }
    }
  }

}

private struct UsageBucket: View {
  let bucket: CodexRateLimitBucketSnapshot
  let fallbackName: String
  let accountID: UUID
  let refresh: () -> Void
  @AppStorage private var hiddenRaw: String

  init(
    bucket: CodexRateLimitBucketSnapshot, fallbackName: String, accountID: UUID,
    refresh: @escaping () -> Void
  ) {
    self.bucket = bucket
    self.fallbackName = fallbackName
    self.accountID = accountID
    self.refresh = refresh
    _hiddenRaw = AppStorage(wrappedValue: "", HiddenUsageRows.key(for: accountID))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AIMTheme.sectionSpacing) {
      HStack(alignment: .firstTextBaseline, spacing: AIMTheme.sectionSpacing) {
        Text(AccountUsagePanel.title(of: bucket, key: fallbackName))
          .aimText(.section).lineLimit(1)
        if let model = bucket.model, !model.isEmpty {
          Text(model).aimText(.secondary, monospaced: true).lineLimit(1)
        }
        Spacer()
        if let plan = CodexPlanNames.display(UsagePresentation.nonempty(bucket.plan)) {
          Text(plan).aimText(.secondary)
        }
      }
      let rows = bucket.windowRows(idPrefix: "\(fallbackName)/")
      if !rows.isEmpty {
        let hidden = HiddenUsageRows.parse(hiddenRaw)
        ForEach(rows.filter { !hidden.contains($0.id) }) { row in
          UsageMeter(window: row.usage)
            .usageRowMenu(accountID: accountID, rowID: row.id, refresh: refresh)
        }
      }
      let credits = UsagePresentation.credits(bucket.credits)
      let spendControl = UsagePresentation.spendControl(bucket.spendControlReached)
      if credits != nil || spendControl != nil {
        VStack(spacing: AIMTheme.rowSpacing) {
          if let credits { UsageFact(label: "Credits", value: credits) }
          if let spendControl { UsageFact(label: "Spend control", value: spendControl) }
        }
      }
    }
  }
}

struct UsageUnavailableRow: View {
  let text: String
  var body: some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      AIMIcon(name: .info).aimText(.secondary)
      Text(text).aimText(.secondary)
      Spacer()
    }
  }
}

/// A Codex window drawn with the same pace tick, colors, and tooltip as generic providers.
private struct UsageMeter: View {
  let window: UsageWindow

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      ProviderWindowMeter(window: window, now: context.date)
    }
  }
}

/// The team or enterprise monthly credit pool from the account's `individual_limit`.
private struct MonthlyCreditsRow: View {
  static let rowID = "monthly-credits"
  let accountID: UUID
  let credits: CodexMonthlyCredits
  let refresh: () -> Void
  @AppStorage private var hiddenRaw: String

  init(accountID: UUID, credits: CodexMonthlyCredits, refresh: @escaping () -> Void) {
    self.accountID = accountID
    self.credits = credits
    self.refresh = refresh
    _hiddenRaw = AppStorage(wrappedValue: "", HiddenUsageRows.key(for: accountID))
  }

  var body: some View {
    if !HiddenUsageRows.parse(hiddenRaw).contains(Self.rowID) {
      UsageMeter(window: credits.window)
        .usageRowMenu(accountID: accountID, rowID: Self.rowID, refresh: refresh)
    }
  }
}

struct AIMSegmentedPicker<Option: Hashable>: View {
  let options: [Option]
  @Binding var selection: Option
  let accessibilityLabel: String
  let label: (Option) -> String

  /// The native segmented control, for compact mutually exclusive choices.
  var body: some View {
    Picker(accessibilityLabel, selection: $selection) {
      ForEach(options, id: \.self) { option in
        Text(label(option)).tag(option)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct TokenPeriodPicker: View {
  @Binding var selection: CodexTokenPeriod

  var body: some View {
    // Five periods are too many for a segmented control, so they sit in a pop-up menu.
    Picker("Token period", selection: $selection) {
      ForEach(CodexTokenPeriod.allCases, id: \.self) { period in
        Text(period.label).tag(period)
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .fixedSize()
    .accessibilityLabel("Token period")
  }
}

private struct TokenStatistic: View {
  let period: CodexTokenPeriod
  let tokens: Int64
  let price: CodexAPIPrice?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: AIMTheme.rowSpacing) {
      Text(UsagePresentation.formatTokens(tokens))
        .aimText(.body)
        .monospacedDigit()
      Text("tokens").aimText(.secondary)
      if let price {
        Text("·").aimText(.secondary)
        Text("≈\(UsagePresentation.formatCurrency(price.inputEquivalent(for: tokens))) API input rate")
          .aimText(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(period.label)
    .accessibilityValue(detail)
    .help(detail)
  }

  private var detail: String {
    var value = "\(UsagePresentation.exactTokens(tokens)) tokens"
    guard let price else { return value }
    value += ". API equivalents for \(price.model): "
      + "input \(UsagePresentation.formatCurrency(price.inputEquivalent(for: tokens))), "
      + "cached input \(price.cachedInputEquivalent(for: tokens).map(UsagePresentation.formatCurrency) ?? "unavailable"), "
      + "output \(UsagePresentation.formatCurrency(price.outputEquivalent(for: tokens))). "
      + "These are rate comparisons, not billed spend."
    return value
  }
}

struct UsageFact: View {
  let label: String
  let value: String
  var help: String? = nil
  var body: some View {
    LabeledContent(label) {
      Text(value).monospacedDigit().foregroundStyle(.secondary)
    }
    .help(help ?? "")
  }
}

/// One fact of a grouped form: the label in Body and the value on the trailing side. Paths use
/// the monospaced Secondary style and copy on click.
struct DetailRow: View {
  let label: String, value: String
  var body: some View {
    LabeledContent(label) {
      // Paths use the system monospaced font; other values read in the system font.
      if value.hasPrefix("/") || value.hasPrefix("~/") {
        AIMCopyablePath(path: value)
      } else {
        Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          .textSelection(.enabled).help(value)
      }
    }
  }
}

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
            DatePicker("From", selection: $from, displayedComponents: .date)
            DatePicker("Through", selection: $through, in: from..., displayedComponents: .date)
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
                })).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
            }
            if visibleSamples.isEmpty { Text("No cached samples in this date range.").aimText(.secondary) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        Toggle("Shared conversation index · \(sizeText(sizes.conversationBytes))", isOn: $clearIndex)
          .toggleStyle(.checkbox).disabled(range != .all || sizes.conversationBytes == 0)
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
                  })).toggleStyle(.checkbox).lineLimit(1)
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
              })).toggleStyle(.checkbox).disabled(selectable.isEmpty).help(project)
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
    Picker("Time range", selection: $selection) {
      ForEach(CleanupDateRange.allCases) { option in
        Text(option.rawValue).tag(option)
        if option == .month || option == .olderYear { Divider() }
      }
    }
    .pickerStyle(.menu)
    .fixedSize()
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

@MainActor
final class LaunchAtLoginSettings: ObservableObject {
  @Published private(set) var status: SMAppService.Status
  @Published private(set) var errorMessage: String?
  private let service: SMAppService

  init(service: SMAppService = .mainApp) {
    self.service = service
    status = service.status
  }

  var isOn: Bool {
    switch status {
    case .enabled, .requiresApproval: true
    default: false
    }
  }

  var canChange: Bool {
    switch status {
    case .notFound: false
    default: true
    }
  }

  var requiresApproval: Bool {
    if case .requiresApproval = status { true } else { false }
  }

  var detail: String {
    if let errorMessage { return "Switch couldn’t update its login item: \(errorMessage)" }
    return Self.detail(for: status)
  }

  static func detail(for status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "Open Switch in the menu bar when you sign in."
    case .enabled: "Switch opens in the menu bar when you sign in."
    case .requiresApproval: "Approval is required in System Settings before Switch can open at login."
    case .notFound: "This build cannot be registered as a login item."
    @unknown default: "Login-item status is unavailable."
    }
  }

  func setEnabled(_ enabled: Bool) {
    errorMessage = nil
    do {
      if enabled {
        try service.register()
      } else {
        try service.unregister()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    refresh(clearError: false)
  }

  func refresh(clearError: Bool = true) {
    status = service.status
    if clearError { errorMessage = nil }
  }

  func openLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

/// Titles and help text of the Settings rows that features add, shared with the GUI contract.
enum SettingsCopy {
  static let checkProviderStatus = "Check provider status"
  static let checkProviderStatusHelp = "Show a dot beside a provider that reports an incident."
  static let claudeShell = "Use the selected Claude account in terminals"
  static let claudeShellHelp =
    "Adds one line to ~/.zshrc so a plain claude command uses the default Claude account. A backup is kept."
  static let hideEmails = "Hide email addresses"
  static let hideEmailsHelp = "Mask account emails everywhere, such as a••••@example.com."
  static let resetTimes = "Reset times"
  static let resetTimesHelp = "Show a countdown or the exact time. Click any reset text to switch."
  static let timeFormat = "Time format"
  static let timeFormatHelp = "Hour style for exact reset times."
  static let menuShortcut = "Menu shortcut"
  static let menuShortcutHelp = "Open or close the menu popover from anywhere. Off until you record one."
  static let refreshOnOpen = "Refresh when the menu opens"
  static let refreshOnOpenHelp = "Check usage each time the popover opens."
  static let resetSettings = "Reset settings"
  static let resetSettingsHelp =
    "Return every Settings choice, hidden usage row, and the menu shortcut to its default. Accounts stay."
  static let notificationsTitle = "Notifications"
  /// Title, help text, and the UserDefaults key of each toggle. All off by default.
  static let notificationRows: [(title: String, help: String, key: String)] = [
    ("Almost Out", "Alert when a usage window drops below 10% left.", QuotaNotificationSettings.almostOutKey),
    ("Pace alerts", "Alert when usage will finish close to the limit or run out before the reset.",
     QuotaNotificationSettings.paceKey),
    ("Available again", "Alert when a used-up window resets and the account can be used again.",
     QuotaNotificationSettings.availableAgainKey),
    ("Sign in again", "Alert once when an account needs a new sign-in.", QuotaNotificationSettings.signInAgainKey),
  ]
}

struct SettingsPage: View {
  @ObservedObject var model: AccountViewModel
  @StateObject private var launchAtLogin = LaunchAtLoginSettings()
  @StateObject private var notificationPermission = QuotaNotificationPermission()
  @AppStorage(ProviderStatusPoller.enabledKey) private var checkProviderStatus = true
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  @AppStorage(QuotaNotificationSettings.almostOutKey) private var notifyAlmostOut = false
  @AppStorage(QuotaNotificationSettings.paceKey) private var notifyPace = false
  @AppStorage(QuotaNotificationSettings.availableAgainKey) private var notifyAvailable = false
  @AppStorage(QuotaNotificationSettings.signInAgainKey) private var notifySignIn = false
  @AppStorage(AIManagerWindowBehavior.minimizeToTrayKey) private var minimizeToTray = false
  @AppStorage(MenuBarUsagePreferences.defaultKey) private var defaultShowUsage = true
  @AppStorage(MenuBarTokenPeriod.preferenceKey) private var menuTokenPeriod = MenuBarTokenPeriod.sinceReset.rawValue
  @AppStorage(UsagePercentagePreferences.showsUsedKey) private var showUsageAsUsed = false
  @AppStorage(ResetDisplay.exactKey) private var resetIsExact = false
  @AppStorage(ResetDisplay.hourFormatKey) private var hourFormat = HourFormat.auto.rawValue
  @AppStorage(PopoverRefreshPreference.key) private var refreshOnOpen = false
  @State private var confirmsReset = false
  @State private var resetCount = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    // A centered column of cards: every card shares the column's left and right edges.
    AIMScrollPage(maxWidth: 720) {
      AIMSection("App behavior") {
        launchAtLoginRow
        Toggle(isOn: $minimizeToTray) {
          Text("Minimize to Menubar")
          Text("Hide the window and keep Switch available from its menu-bar icon.")
            .aimText(.secondary)
        }
        Toggle(isOn: $showUsageAsUsed) {
          Text("Show percentage used")
          Text("Turn off to show the percentage left in every usage view.").aimText(.secondary)
        }
        Toggle(isOn: $checkProviderStatus) {
          Text(SettingsCopy.checkProviderStatus)
          Text(SettingsCopy.checkProviderStatusHelp).aimText(.secondary)
        }
        LabeledContent {
          Picker("Reset time format", selection: $resetIsExact) {
            Text("Countdown").tag(false)
            Text("Exact time").tag(true)
          }
          .pickerStyle(.segmented).labelsHidden().fixedSize()
          .accessibilityLabel("Reset time format")
        } label: {
          Text(SettingsCopy.resetTimes)
          Text(SettingsCopy.resetTimesHelp).aimText(.secondary)
        }
        LabeledContent {
          Picker("Hour format", selection: $hourFormat) {
            ForEach(HourFormat.allCases, id: \.rawValue) { format in
              Text(format.label).tag(format.rawValue)
            }
          }
          .pickerStyle(.segmented).labelsHidden().fixedSize()
          .accessibilityLabel("Hour format")
        } label: {
          Text(SettingsCopy.timeFormat)
          Text(SettingsCopy.timeFormatHelp).aimText(.secondary)
        }
        LabeledContent {
          ShortcutRecorder().id(resetCount)
        } label: {
          Text(SettingsCopy.menuShortcut)
          Text(SettingsCopy.menuShortcutHelp).aimText(.secondary)
        }
        Toggle(isOn: $refreshOnOpen) {
          Text(SettingsCopy.refreshOnOpen)
          Text(SettingsCopy.refreshOnOpenHelp).aimText(.secondary)
        }
      }
      AIMSection(SettingsCopy.notificationsTitle) {
        ForEach(Array(SettingsCopy.notificationRows.enumerated()), id: \.offset) { _, row in
          Toggle(isOn: notificationBinding(row.key)) {
            Text(row.title)
            Text(row.help).aimText(.secondary)
          }
        }
        if notificationPermission.isDenied, notifyAlmostOut || notifyPace || notifyAvailable || notifySignIn {
          LabeledContent {
            AIMButton(title: "Open System Settings", action: notificationPermission.openSystemSettings)
          } label: {
            Label("Notifications are turned off for Switch in System Settings.",
                  systemImage: AIMIcon.Name.warning.symbol)
              .foregroundStyle(AIMTheme.amber)
          }
        }
      }
      AIMSection("Claude Code") {
        Toggle(isOn: Binding(
          get: { model.claudeShellIntegrationOn },
          set: { enabled in Task { await model.setClaudeShellIntegration(enabled) } })
        ) {
          Text(SettingsCopy.claudeShell)
          Text(SettingsCopy.claudeShellHelp).aimText(.secondary)
          if let error = model.claudeShellIntegrationError {
            Text(error).aimText(.secondary, tint: AIMTheme.red)
          }
        }
      }
      AIMSection("Privacy") {
        Toggle(isOn: $hideEmails) {
          Text(SettingsCopy.hideEmails)
          Text(SettingsCopy.hideEmailsHelp).aimText(.secondary)
        }
      }
      AIMSection("Reset") {
        LabeledContent {
          AIMButton(title: "Reset settings…", tone: .danger) { confirmsReset = true }
        } label: {
          Text(SettingsCopy.resetSettings)
          Text(SettingsCopy.resetSettingsHelp).aimText(.secondary)
        }
      }
      AIMSection("Menubar defaults") {
        Toggle(isOn: $defaultShowUsage) {
          Text("Show account usage")
          Text("Accounts without their own choice show cached usage in Menubar.")
            .aimText(.secondary)
        }
        LabeledContent {
          Picker("Menubar token period", selection: $menuTokenPeriod) {
            ForEach(MenuBarTokenPeriod.allCases) { period in
              Text(period.label).tag(period.rawValue)
            }
          }
          .pickerStyle(.menu).labelsHidden().fixedSize()
          .accessibilityLabel("Menubar token period")
        } label: {
          Text("Token summary")
          Text("Choose the period shown beside each account’s usage.").aimText(.secondary)
        }
      }
      #if AI_MANAGER_PREVIEW
      if model.isDemo {
        AIMSection("Demo states") {
          HStack(spacing: AIMTheme.rowSpacing) {
            AIMButton(title: "Sample accounts") { model.reset(to: .demo) }
            AIMButton(title: "Empty state") { model.reset(to: .empty) }
            AIMButton(title: "Issues and backups") { model.reset(to: .allStates) }
            Spacer()
          }
          HStack(spacing: AIMTheme.rowSpacing) {
            AIMButton(title: "Refresh demo data", icon: .refresh, disabled: model.isBusy) {
              Task { await model.refresh() }
            }
            Spacer()
            AIMButton(title: "Show demo error", tone: .danger) { model.showDemoError() }
          }
        }
      }
      #endif
      AIMSection("Data locations") {
        DataLocationRow(
          title: "Codex home",
          detail: "Settings, plugins, conversations, and databases stay here when accounts change.",
          path: model.paths.defaultHome.path
        ) {
          model.showDataLocation(model.paths.defaultHome, name: "Codex home")
        }
        DataLocationRow(
          title: "Codex account vault",
          detail: "Private Codex auth.json snapshots.",
          path: model.paths.credentialStore.path
        ) {
          model.showDataLocation(model.paths.credentialStore, name: "Codex account vault")
        }
        DataLocationRow(
          title: "Grok Build home",
          detail: "Grok configuration, rules, plugins, sessions, and the active login.",
          path: model.paths.grokHome.path
        ) {
          model.showDataLocation(model.paths.grokHome, name: "Grok Build home")
        }
        DataLocationRow(
          title: "Grok Build account vault",
          detail: "Private Grok subscription OAuth snapshots.",
          path: model.paths.grokCredentialStore.path
        ) {
          model.showDataLocation(model.paths.grokCredentialStore, name: "Grok Build account vault")
        }
      }
      if let notice = model.notice {
        AIMSection { Notice(text: notice, tone: AIMTheme.blue) }
          .transition(reduceMotion ? .identity : .opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.notice)
    .onAppear { launchAtLogin.refresh() }
    .confirmationDialog(
      "Reset every setting to its default?", isPresented: $confirmsReset, titleVisibility: .visible
    ) {
      Button("Reset settings", role: .destructive, action: resetSettings)
    } message: {
      Text("Accounts, saved sign-ins, and Open at Login stay as they are.")
    }
    .onChange(of: checkProviderStatus) { model.providerStatusSettingChanged() }
    .task {
      await notificationPermission.refresh()
      await model.loadClaudeShellIntegration()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      launchAtLogin.refresh()
      Task { await notificationPermission.refresh() }
    }
  }

  private func resetSettings() {
    SettingsReset.reset()
    GlobalShortcut.shared.apply(nil)
    resetCount += 1
    model.providerStatusSettingChanged()
  }

  /// A toggle that asks macOS for notification permission the first time it turns on.
  private func notificationBinding(_ key: String) -> Binding<Bool> {
    let stored: Binding<Bool>
    switch key {
    case QuotaNotificationSettings.almostOutKey: stored = $notifyAlmostOut
    case QuotaNotificationSettings.paceKey: stored = $notifyPace
    case QuotaNotificationSettings.availableAgainKey: stored = $notifyAvailable
    default: stored = $notifySignIn
    }
    return Binding(
      get: { stored.wrappedValue },
      set: { enabled in
        stored.wrappedValue = enabled
        if enabled { notificationPermission.requestIfNeeded() }
      })
  }

  @ViewBuilder private var launchAtLoginRow: some View {
    Toggle(isOn: Binding(
      get: { launchAtLogin.isOn },
      set: launchAtLogin.setEnabled)
    ) {
      Text("Open at Login")
      Text(launchAtLogin.detail).aimText(.secondary)
    }
    .disabled(!launchAtLogin.canChange)
    if launchAtLogin.requiresApproval {
      LabeledContent("Approval needed") {
        AIMButton(title: "Open Login Items", action: launchAtLogin.openLoginItems)
      }
    }
  }
}

private struct DataLocationRow: View {
  let title: String
  let detail: String
  let path: String
  let reveal: () -> Void

  var body: some View {
    LabeledContent {
      AIMButton(title: "Reveal", icon: .folder, action: reveal)
    } label: {
      Text(title)
      Text(detail).aimText(.secondary)
      AIMCopyablePath(path: path)
    }
  }
}

enum HistoryHeaderLayout {
  static let height: CGFloat = 40
  static let countWidth: CGFloat = 128
  static let warningWidth: CGFloat = 32
}

private struct HistoryPage: View {
  @ObservedObject var model: AccountViewModel
  @State private var threadQuery = ""

  var body: some View {
    // Two cards: the thread list and the selected conversation.
    AIMFixedPage {
      HStack(spacing: AIMTheme.cardGap) {
        AIMCard(edges: .start) { threadList.frame(maxHeight: .infinity) }
          .frame(width: 300)
        AIMCard(edges: .end) {
          ChatDetailPane(model: model)
            .id(model.selectedChatID)
            .frame(maxHeight: .infinity)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { await model.refreshChatHistory(query: threadQuery) }
    .task(id: threadQuery) { await model.searchChatHistory(query: threadQuery) }
  }

  private var threadList: some View {
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          Text("Conversations").aimText(.section)
          Spacer(minLength: AIMTheme.rowSpacing)
          if model.chatHistory.skippedFileCount > 0 || model.chatHistory.unreadableRecordCount > 0 {
            WarningCopyButton(label: "Copy history warning") {
              model.copyWarnings([historyIssueText])
            }
            .help(historyIssueText)
            .frame(width: HistoryHeaderLayout.warningWidth, height: HistoryHeaderLayout.height)
          }
          Group {
            if model.isChatHistoryLoading && model.chatHistory.threads.isEmpty {
              ProgressView().controlSize(.small)
            } else {
              HStack(spacing: 6) {
                if let error = model.chatHistoryError {
                  Circle().fill(AIMTheme.red).frame(width: 6, height: 6)
                    .help(error)
                    .accessibilityLabel(error)
                }
                Text(historyCountText)
                  .aimText(.secondary)
                  .monospacedDigit()
                  .contentTransition(.numericText())
              }
            }
          }
          .frame(width: HistoryHeaderLayout.countWidth,
            height: HistoryHeaderLayout.height, alignment: .trailing)
        }
        .padding(.leading, AIMTheme.sectionSpacing)
        .padding(.trailing, AIMTheme.rowSpacing)
        .frame(height: HistoryHeaderLayout.height)

        HistorySearchField(text: $threadQuery, placeholder: "Search conversations")
          .padding(.horizontal, AIMTheme.sectionSpacing)
          .padding(.bottom, AIMTheme.rowSpacing)

        if model.isChatHistoryLoading && model.chatHistory.threads.isEmpty {
          VStack(spacing: AIMTheme.rowSpacing) {
            ProgressView().controlSize(.small)
            Text("Reading chat library").aimText(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.chatHistory.threads.isEmpty {
          VStack(spacing: 4) {
            AIMIcon(name: .history).aimText(.section).foregroundStyle(.secondary)
            Text(threadQuery.isEmpty ? "No conversations yet" : "No matching conversations")
              .aimText(.body)
            Text(threadQuery.isEmpty ? "New Codex chats appear here." : "Try another word or thread ID.")
              .aimText(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(model.chatHistory.threads, selection: Binding(
            get: { model.selectedChatID },
            set: { if let id = $0 { Task { await model.selectChat(id) } } })
          ) { thread in
            ChatThreadRow(thread: thread)
          }
          .listStyle(.inset)
          .scrollContentBackground(.hidden)
        }
      }
  }

  private var historyCountText: String {
    let result = model.chatHistory
    if threadQuery.isEmpty { return "\(result.totalThreadCount.formatted()) conversations" }
    return "\(result.matchingThreadCount.formatted()) of \(result.totalThreadCount.formatted()) conversations"
  }

  private var historyIssueText: String {
    let result = model.chatHistory
    var parts: [String] = []
    if result.skippedFileCount > 0 {
      parts.append(
        "\(result.skippedFileCount) transcript file\(result.skippedFileCount == 1 ? " was" : "s were") skipped")
    }
    if result.unreadableRecordCount > 0 {
      parts.append(
        "\(result.unreadableRecordCount) oversized or malformed record\(result.unreadableRecordCount == 1 ? " was" : "s were") skipped")
    }
    return parts.joined(separator: "; ") + "."
  }
}

private struct HistorySearchField: View {
  @Binding var text: String
  let placeholder: String

  var body: some View {
    TextField(placeholder, text: $text)
      .textFieldStyle(.roundedBorder)
      .overlay(alignment: .trailing) {
        if !text.isEmpty {
          Button { text = "" } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.borderless)
          .padding(.trailing, AIMTheme.rowSpacing)
          .help("Clear search")
          .accessibilityLabel("Clear search")
        }
      }
  }
}

private struct ChatThreadRow: View {
  let thread: ChatThreadSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(thread.title)
        .aimText(.body)
        .lineLimit(1)
      Text(projectLabel)
        .aimText(.secondary)
        .lineLimit(1)
    }
    .accessibilityLabel("\(thread.title), \(projectLabel)")
  }

  private var projectLabel: String {
    guard let directory = thread.workingDirectory else { return "Codex" }
    let name = URL(fileURLWithPath: directory).lastPathComponent
    return name.isEmpty ? "Codex" : name
  }
}

enum ChatFilterPersistence {
  static let defaultsKey = "chat.messageFilterMask"

  static func load(from defaults: UserDefaults = .standard) -> ChatMessageFilter {
    guard defaults.object(forKey: defaultsKey) != nil else { return .all }
    return normalized(defaults.integer(forKey: defaultsKey))
  }

  static func save(_ filter: ChatMessageFilter, to defaults: UserDefaults = .standard) {
    defaults.set(normalized(filter.rawValue).rawValue, forKey: defaultsKey)
  }

  static func normalized(_ rawValue: Int) -> ChatMessageFilter {
    ChatMessageFilter(rawValue: rawValue & ChatMessageFilter.all.rawValue)
  }
}

private struct ChatDetailPane: View {
  @ObservedObject var model: AccountViewModel
  @State private var messageQuery = ""
  @State private var messageFilter: ChatMessageFilter
  @State private var isSearching = false
  @State private var presentations: [String: ChatMessagePresentation] = [:]
  @State private var presentationRevision = 0

  init(model: AccountViewModel) {
    self.model = model
    _messageFilter = State(initialValue: ChatFilterPersistence.load())
  }

  var body: some View {
    VStack(spacing: 0) {
      if let thread = selectedSummary {
        HStack(alignment: .bottom, spacing: AIMTheme.sectionSpacing) {
          VStack(alignment: .leading, spacing: 2) {
            Text(thread.title).aimText(.section).lineLimit(1)
            Text(threadContext(thread)).aimText(.secondary).lineLimit(1)
          }
          Spacer(minLength: AIMTheme.rowSpacing)
          HStack(spacing: 6) {
            Text("\(thread.messageCount.formatted()) messages")
            if let tokens = thread.totalTokens {
              Text("·")
              Text("\(tokens.formatted(.number.notation(.compactName))) tokens")
                .help("\(tokens.formatted()) recorded tokens")
            }
          }
          .aimText(.secondary)
          .monospacedDigit()
          .lineLimit(1)
        }
        .padding(.horizontal, AIMTheme.sectionSpacing)
        .padding(.vertical, AIMTheme.rowSpacing)
        .frame(height: 58)
      } else {
        Color.clear.frame(height: 58)
      }
      Divider()

      VStack(spacing: AIMTheme.rowSpacing) {
        HStack(spacing: AIMTheme.rowSpacing) {
          HistorySearchField(text: $messageQuery, placeholder: "Search this chat")
          if isSearching {
            ProgressView().controlSize(.small)
          } else if let detail = model.selectedChat, messageFilter != .all || !messageQuery.isEmpty {
            Text(messageCountText(detail))
              .aimText(.secondary)
              .monospacedDigit()
              .contentTransition(.numericText())
          }
          if let detail = model.selectedChat {
            ChatFilteredCopyButton(messages: displayedMessages(detail))
          }
        }

        HStack(spacing: 6) {
          Text("Show").aimText(.secondary)
          ForEach(ChatFilterChoice.allCases) { choice in
            ChatFilterButton(
              choice: choice,
              selected: messageFilter.contains(choice.filter)) {
                toggleFilter(choice.filter)
              }
          }
          Spacer(minLength: 0)
        }
      }
      .padding(.horizontal, AIMTheme.sectionSpacing)
      .padding(.vertical, AIMTheme.rowSpacing)
      Divider()

      if model.isChatLoading {
        VStack(spacing: AIMTheme.rowSpacing) {
          ProgressView().controlSize(.small)
          Text("Opening chat").aimText(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let detail = model.selectedChat {
        AIMVirtualList(
          items: detailItems(detail), rowSpacing: 0,
          contentRevision: presentationRevision,
          onReachEnd: { Task { await model.loadMoreChatMessages() } }
        ) { item in
          AnyView(detailRow(item))
        }
      } else {
        VStack(spacing: 4) {
          AIMIcon(name: .history).aimText(.section).foregroundStyle(.secondary)
          Text("Select a chat").aimText(.body)
          Text("Messages open here without changing the transcript.")
            .aimText(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: searchKey) { await updateMessageSearch() }
    .task(id: presentationKey) { await updatePresentations() }
    .onChange(of: messageFilter.rawValue) { _, _ in
      ChatFilterPersistence.save(messageFilter)
    }
  }

  private var selectedSummary: ChatThreadSummary? {
    model.selectedChat?.thread
      ?? model.chatHistory.threads.first { $0.id == model.selectedChatID }
  }

  private var searchKey: ChatMessageSearchKey {
    ChatMessageSearchKey(
      threadID: model.selectedChatID,
      query: messageQuery,
      filterMask: messageFilter.rawValue,
      fileByteCount: model.selectedChat?.thread.fileByteCount ?? 0)
  }

  private var presentationKey: ChatPresentationKey {
    ChatPresentationKey(
      threadID: model.selectedChatID,
      fileByteCount: model.selectedChat?.thread.fileByteCount ?? 0,
      messageIDs: model.selectedChat?.messages.map(\.id) ?? [])
  }

  private func displayedMessages(_ detail: ChatThreadDetail) -> [ChatMessage] {
    filteredMessages(detail.messages)
  }

  private func filteredMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
    messages.filter { messageFilter.includes($0.role) }
  }

  private func toggleFilter(_ filter: ChatMessageFilter) {
    if messageFilter.contains(filter) {
      messageFilter.remove(filter)
    } else {
      messageFilter.insert(filter)
    }
  }

  private func detailItems(_ detail: ChatThreadDetail) -> [ChatDetailListItem] {
    var items: [ChatDetailListItem] = []
    let messages = displayedMessages(detail)
    if messages.isEmpty && !isSearching {
      let hasQuery = !messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      items.append(.empty(hasQuery ? "No matching messages" : "No messages in this filter"))
    } else {
      items.append(contentsOf: messages.enumerated().map { index, message in
        .message(
          message,
          separated: index == 0 || messages[index - 1].role != message.role)
      })
    }
    if detail.nextOffset != nil { items.append(.loadMore) }
    items.append(.bottomSpace)
    return items
  }

  @ViewBuilder
  private func detailRow(_ item: ChatDetailListItem) -> some View {
    switch item {
    case let .message(message, separated):
      ChatMessageRow(
        message: message,
        presentation: presentations[message.id],
        fallbackText: model.renderedChatMessages[message.id] ?? AttributedString(message.text),
        separated: separated)
    case let .empty(text):
      VStack(spacing: 6) {
        AIMIcon(name: .search).aimText(.section).foregroundStyle(.secondary)
        Text(text).aimText(.body)
      }
      .frame(maxWidth: .infinity, minHeight: 120)
      .padding(.horizontal, 12)
    case .bottomSpace:
      Color.clear.frame(height: 8)
    case .loadMore:
      HStack(spacing: 6) {
        if model.isChatPageLoading { ProgressView().controlSize(.mini) }
        AIMButton(title: model.isChatPageLoading ? "Loading messages" : "Load more messages",
          disabled: model.isChatPageLoading) { Task { await model.loadMoreChatMessages() } }
      }
      .frame(maxWidth: .infinity, minHeight: 32)
    }
  }

  private func messageCountText(_ detail: ChatThreadDetail) -> String {
    if messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let count = detail.matchingMessageCount
      return messageFilter == .all
        ? "\(count.formatted()) messages"
        : "\(count.formatted()) shown"
    }
    return "\(detail.matchingMessageCount.formatted()) matches"
  }

  private func threadContext(_ thread: ChatThreadSummary) -> String {
    var parts: [String] = []
    if let directory = thread.workingDirectory {
      let project = URL(fileURLWithPath: directory).lastPathComponent
      if !project.isEmpty { parts.append(project) }
    }
    parts.append(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
    if thread.archived { parts.append("Archived") }
    return parts.joined(separator: "  ·  ")
  }

  @MainActor
  private func updatePresentations() async {
    guard let detail = model.selectedChat else {
      presentations = [:]
      return
    }
    do {
      let rendered = try await ChatMessagePresenter.render(messages: detail.messages.filter { presentations[$0.id] == nil })
      guard !Task.isCancelled,
        model.selectedChatID == detail.thread.id,
        model.selectedChat?.thread.fileByteCount == detail.thread.fileByteCount
      else { return }
      let ids = Set(detail.messages.map(\.id))
      presentations = presentations.filter { ids.contains($0.key) }
      presentations.merge(rendered) { _, new in new }
      presentationRevision &+= 1
    } catch is CancellationError {
      return
    } catch {
      presentations = [:]
    }
  }

  @MainActor
  private func updateMessageSearch() async {
    guard model.selectedChat != nil else {
      isSearching = false
      return
    }
    isSearching = true
    do {
      try await Task.sleep(for: .milliseconds(120))
      await model.searchChatMessages(query: messageQuery, filter: messageFilter)
      guard !Task.isCancelled else { return }
      isSearching = false
    } catch is CancellationError {
      return
    } catch {
      isSearching = false
    }
  }
}

private enum ChatDetailListItem: Identifiable, Equatable {
  case message(ChatMessage, separated: Bool)
  case empty(String)
  case bottomSpace
  case loadMore

  var id: String {
    switch self {
    case let .message(message, _): "message:\(message.id)"
    case let .empty(text): "empty:\(text)"
    case .bottomSpace: "bottom-space"
    case .loadMore: "load-more"
    }
  }
}

private struct ChatMessageSearchKey: Hashable {
  let threadID: String?
  let query: String
  let filterMask: Int
  let fileByteCount: Int64
}

private struct ChatPresentationKey: Hashable {
  let threadID: String?
  let fileByteCount: Int64
  let messageIDs: [String]
}

private enum ChatFilterChoice: String, CaseIterable, Identifiable {
  case prompts = "Prompts"
  case responses = "Responses"
  case tools = "Tools"
  case other = "Other"

  var id: String { rawValue }

  var filter: ChatMessageFilter {
    switch self {
    case .prompts: .prompts
    case .responses: .responses
    case .tools: .tools
    case .other: .other
    }
  }
}

private struct ChatFilterButton: View {
  let choice: ChatFilterChoice
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Toggle(choice.rawValue, isOn: Binding(get: { selected }, set: { _ in action() }))
      .toggleStyle(.button)
      .accessibilityLabel("Show \(choice.rawValue.lowercased())")
  }
}

private struct ChatFilteredCopyButton: View {
  let messages: [ChatMessage]
  @State private var copied = false

  var body: some View {
    Button {
      let text = ChatTranscriptExport.text(for: messages)
      #if !AI_MANAGER_PREVIEW
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      #endif
      copied = true
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.2))
        copied = false
      }
    } label: {
      Label(copied ? "Copied" : "Copy shown",
        systemImage: copied ? AIMIcon.Name.check.symbol : AIMIcon.Name.copy.symbol)
    }
    .buttonStyle(.bordered)
    .disabled(messages.isEmpty)
    .help("Copy the messages currently shown")
    .accessibilityLabel(copied ? "Copied" : "Copy shown messages")
  }
}

private struct ChatMessageRow: View {
  let message: ChatMessage
  let presentation: ChatMessagePresentation?
  let fallbackText: AttributedString
  let separated: Bool
  @State private var hovered = false

  var body: some View {
    VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
      HStack(spacing: 5) {
        Text(message.role.displayName)
        if let timestamp = message.timestamp {
          Text("·")
          Text(timestamp, style: .time).monospacedDigit()
        }
        ChatCopyButton(text: message.text, label: "Copy message", emphasized: hovered)
      }
      .aimText(.secondary)

      ChatMessageBlocks(presentation: presentation, fallbackText: fallbackText)
        .padding(.horizontal, AIMTheme.sectionSpacing)
        .padding(.vertical, AIMTheme.rowSpacing + 2)
        .frame(maxWidth: message.role == .user ? 460 : 620, alignment: .leading)
        .background(messageSurface)
        .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
    }
    .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
    .padding(.horizontal, AIMTheme.sectionSpacing)
    .padding(.top, separated ? 10 : 4)
    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    .onHover { hovered = $0 }
  }

  private var messageSurface: Color {
    switch message.role {
    case .user: AIMTheme.chatUserSurface
    case .assistant: AIMTheme.chatAssistantSurface
    case .tool: AIMTheme.chatCodeSurface
    case .other: AIMTheme.chatOtherSurface
    }
  }
}

private struct ChatMessageBlocks: View {
  let presentation: ChatMessagePresentation?
  let fallbackText: AttributedString

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let presentation {
        ForEach(presentation.blocks) { block in
          ChatPresentationBlockView(block: block)
        }
        if presentation.sourceWasTruncated {
          Text("This long message is shortened in the reader.")
            .aimText(.secondary, tint: AIMTheme.amber)
        }
      } else {
        Text(fallbackText)
          .aimText(.body)
          .lineSpacing(4)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ChatPresentationBlockView: View {
  let block: ChatPresentationBlock

  @ViewBuilder var body: some View {
    switch block {
    case let .paragraph(_, text):
      readable(text)
    case let .heading(_, level, text):
      // Markdown heading levels all read in the Section role.
      Text(text)
        .aimText(.section)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case let .quote(_, text):
      HStack(alignment: .top, spacing: 9) {
        Rectangle().fill(AIMTheme.line).frame(width: 2)
        readable(text).foregroundStyle(.secondary)
      }
    case let .unorderedList(_, items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: AIMTheme.rowSpacing) {
            Text("•").aimText(.body)
            readable(item)
          }
        }
      }
    case let .orderedList(_, items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: AIMTheme.rowSpacing) {
            Text("\(index + 1).")
              .aimText(.body).monospacedDigit()
              .frame(width: 24, alignment: .trailing)
            readable(item)
          }
        }
      }
    case let .code(_, language, preview, expanded, sourceWasTruncated):
      ChatCodeBlock(
        language: language, preview: preview, expandedText: expanded,
        sourceWasTruncated: sourceWasTruncated)
    case .divider:
      Divider().padding(.vertical, 2)
    }
  }

  private func readable(_ text: AttributedString) -> some View {
    Text(text)
      .aimText(.body)
      .lineSpacing(4)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ChatCodeBlock: View {
  let language: String?
  let preview: String
  let expandedText: String?
  let sourceWasTruncated: Bool
  @State private var expanded = false

  private var visibleText: String { expanded ? (expandedText ?? preview) : preview }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: AIMTheme.rowSpacing) {
        Text(language?.uppercased() ?? "CODE")
          .aimText(.secondary, monospaced: true)
        Spacer()
        ChatCopyButton(text: expandedText ?? preview, label: "Copy code", emphasized: true)
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(AIMTheme.chatOtherSurface)

      Text(visibleText)
        .aimText(.secondary, monospaced: true, tint: .primary)
        .lineSpacing(3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)

      if expandedText != nil {
        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
          .buttonStyle(.borderless)
          .padding(.horizontal, 10)
          .padding(.bottom, 9)
      } else if sourceWasTruncated {
        Text("Code shortened")
          .aimText(.secondary, tint: AIMTheme.amber)
          .padding(.horizontal, 10)
          .padding(.bottom, 9)
      }
    }
    .background(AIMTheme.chatCodeSurface)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }
}

private struct ChatCopyButton: View {
  let text: String
  let label: String
  let emphasized: Bool
  @State private var copied = false

  var body: some View {
    Button {
      #if !AI_MANAGER_PREVIEW
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      #endif
      copied = true
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.2))
        copied = false
      }
    } label: {
      AIMIcon(name: copied ? .check : .copy)
        .aimFont(.secondary)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(copied ? AIMTheme.green : Color.secondary)
    .opacity(emphasized || copied ? 1 : 0.48)
    .help(copied ? "Copied" : label)
    .accessibilityLabel(copied ? "Copied" : label)
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

/// Maintenance: backup and recovery, and Cleanup.
enum MaintenanceSection: String, CaseIterable {
  case backup = "Backup"
  case cleanup = "Cleanup"
}

private struct MaintenancePage: View {
  @ObservedObject var model: AccountViewModel
  @Binding var section: MaintenanceSection

  var body: some View {
    // One scrolling page at full content width: the picker sits on the card edge, then the cards.
    AIMScrollPage {
      HStack {
        AIMSegmentedPicker(
          options: MaintenanceSection.allCases, selection: $section,
          accessibilityLabel: "Maintenance section", label: \.rawValue)
        Spacer(minLength: 0)
      }
      switch section {
      case .backup: BackupPage(model: model)
      case .cleanup: CleanupPage(model: model)
      }
    }
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
      Spacer()
      WarningCopyButton(label: "Copy error", action: copy)
      AIMButton(title: "Dismiss", action: dismiss)
    }.aimRow()
  }
}

private struct AddAccountFlow: View {
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
    if !ProviderChoices.builtIn.contains(id), ProviderCatalog.spec(id) != nil {
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
      if let error = model.errorMessage {
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
      Form {
        Section("\(selectedProviderName) sign-in") {
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
            text: model.accountLoginMessage
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
      .formStyle(.grouped)

      ImportFooter(step: step, labels: ["Provider", "Sign in", "Done"], showsCancel: false) {
        EmptyView()
      } trailing: {
        // Cancel ends the sign-in session, not only the sheet.
        Button("Cancel") { Task { await model.cancelAccountLogin() } }
          .keyboardShortcut(.cancelAction)
        if model.accountLoginState != .credentialChoiceRequired {
          AIMButton(title: "Check Now", icon: .refresh, tone: .primary) {
            Task { await model.checkAccountLogin() }
          }
          .keyboardShortcut(.defaultAction)
        }
      }
      .padding(AIMTheme.pageMargin)
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private var completedPage: some View {
    VStack(spacing: 0) {
      Form {
        Section("Ready") {
          HStack(spacing: AIMTheme.rowSpacing) {
            AIMIcon(name: .success).aimFont(.section).foregroundStyle(AIMTheme.green)
            Text(model.selectedAccount?.identity.heroName ?? "\(selectedProviderName) account")
              .aimText(.section)
          }
          Text(model.accountLoginMessage ?? "The account is saved and ready to use.")
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
      .formStyle(.grouped)
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

private struct ImportFlow: View {
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
      if let error = model.errorMessage {
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
          Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
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
      Form {
        Section {
          Text("Choose a provider and one of its data folders.").aimText(.secondary)
          Picker("Provider", selection: $model.selectedProviderID) {
            Text("Codex").tag(ProviderID.codex)
          }
          .pickerStyle(.menu)
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
                  .foregroundStyle(AIMTheme.blue)
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
            .accessibilityAddTraits(selected ? .isSelected : [])
            .disabled(!supported)
            .help(source.inspectionError ?? source.path.path)
          }
        }
        Section("Import scope") {
          Picker("Import scope", selection: $model.importMode) {
            Text("Account access only").tag(ImportMode.authOnly)
            Text("Account access, settings, and chats").tag(ImportMode.full)
          }
          .pickerStyle(.menu)
          Text(
            model.importMode == .authOnly
              ? "Saves account access. Settings and chats stay in the current Codex home. The source stays unchanged."
              : "Reviews Codex-home conflicts and adds source chats to the merged library. Everything affected is backed up first."
          ).aimText(.secondary)
        }
      }
      .formStyle(.grouped)
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
      Form {
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
                  Picker("Choice", selection: Binding(
                    get: { model.conflictChoices[conflict.relativePath] },
                    set: { model.conflictChoices[conflict.relativePath] = $0 })
                  ) {
                    Text(conflict.affectsAllAccounts ? "Keep shared" : "Keep saved")
                      .tag(Optional(ConflictChoice.keepShared))
                    Text("Use imported").tag(Optional(ConflictChoice.useImported))
                  }
                  .pickerStyle(.segmented)
                  .labelsHidden()
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
      .formStyle(.grouped)
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
      Form {
        Section(result.unresolved.isEmpty ? "Import complete" : "Review required") {
          HStack(spacing: AIMTheme.sectionSpacing) {
            AIMIcon(name: result.unresolved.isEmpty ? .check : .warning).aimFont(.section)
              .foregroundStyle(result.unresolved.isEmpty ? AIMTheme.green : AIMTheme.amber)
            VStack(alignment: .leading, spacing: 2) {
              Text(result.account.identity.heroName).aimText(.section)
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
      .formStyle(.grouped)
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
    if let email, let workspaceID { return "\(EmailPrivacy.display(email)) · \(workspaceID)" }
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
