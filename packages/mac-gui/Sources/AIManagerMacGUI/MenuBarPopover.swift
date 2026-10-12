import AppKit
import AIManagerCore
import SwiftUI

struct MenuBarUsageSnapshot: Equatable, Sendable {
  struct Window: Equatable, Sendable {
    let title: String
    let used: Int?
    let resetsAt: Date?
    let minutes: Int?
  }
  let usedPercentage: Int?
  let secondaryUsedPercentage: Int?
  let resetsAt: Date?
  let secondaryResetsAt: Date?
  let fetchedAt: Date?
  let tokenPeriodLabel: String?
  let tokens: Int64?
  let apiPrice: CodexAPIPrice?
  /// Names of the first and second quota. Codex uses Session and Weekly; other providers use
  /// the titles of their first two windows.
  let primaryLabel: String
  let secondaryLabel: String
  /// Length of each window in minutes, when the service reports it. Short labels and the pace
  /// color depend on it.
  let primaryMinutes: Int?
  let secondaryMinutes: Int?
  /// Short amount text of a window, such as "620 / 1,000 requests".
  let primaryDetail: String?
  let secondaryDetail: String?
  /// One compact line for accounts that report only a balance, such as "$12.40".
  let balanceText: String?
  let providerWindows: [Window]?

  init(
    usedPercentage: Int?,
    secondaryUsedPercentage: Int? = nil,
    resetsAt: Date? = nil,
    secondaryResetsAt: Date? = nil,
    fetchedAt: Date? = nil,
    tokenPeriodLabel: String? = nil,
    tokens: Int64? = nil,
    apiPrice: CodexAPIPrice? = nil,
    primaryLabel: String = "Session",
    secondaryLabel: String = "Weekly",
    primaryMinutes: Int? = nil,
    secondaryMinutes: Int? = nil,
    primaryDetail: String? = nil,
    secondaryDetail: String? = nil,
    balanceText: String? = nil,
    providerWindows: [Window]? = nil
  ) {
    self.usedPercentage = usedPercentage.map { max($0, 0) }
    self.secondaryUsedPercentage = secondaryUsedPercentage.map { max($0, 0) }
    self.resetsAt = resetsAt
    self.secondaryResetsAt = secondaryResetsAt
    self.fetchedAt = fetchedAt
    self.tokenPeriodLabel = tokenPeriodLabel
    self.tokens = tokens
    self.apiPrice = apiPrice
    self.primaryLabel = primaryLabel
    self.secondaryLabel = secondaryLabel
    self.primaryMinutes = primaryMinutes
    self.secondaryMinutes = secondaryMinutes
    self.primaryDetail = primaryDetail
    self.secondaryDetail = secondaryDetail
    self.balanceText = balanceText
    self.providerWindows = providerWindows
  }

  /// First two windows of a non-Codex provider, session-like windows first. Nil when the usage
  /// has neither a percentage window nor a balance, so the card stays a plain header.
  init?(providerUsage usage: ProviderUsage) {
    func isSessionLike(_ window: UsageWindow) -> Bool {
      window.title.localizedCaseInsensitiveContains("session") || (window.windowMinutes ?? .max) <= 300
    }
    let windows = usage.windows
    let ordered = windows.filter(isSessionLike) + windows.filter { !isSessionLike($0) }
    let balance = usage.cost?.balance.map { Fmt.money($0, currency: usage.cost?.currency ?? "USD") }
    guard !ordered.isEmpty || balance != nil else { return nil }
    let first = ordered.first, second = ordered.dropFirst().first
    self.init(
      usedPercentage: first?.usedPercent.map { Int($0.rounded()) },
      secondaryUsedPercentage: second?.usedPercent.map { Int($0.rounded()) },
      resetsAt: first?.resetsAt,
      secondaryResetsAt: second?.resetsAt,
      fetchedAt: usage.fetchedAt,
      primaryLabel: first?.title ?? "Session",
      secondaryLabel: second?.title ?? "Weekly",
      primaryMinutes: first?.windowMinutes,
      secondaryMinutes: second?.windowMinutes,
      primaryDetail: first?.detail,
      secondaryDetail: second?.detail,
      balanceText: ordered.isEmpty ? balance : nil,
      providerWindows: ordered.map {
        Window(title: $0.title, used: $0.usedPercent.map { Int($0.rounded()) },
          resetsAt: $0.resetsAt, minutes: $0.windowMinutes)
      })
  }

  init?(
    bucket: CodexRateLimitBucketSnapshot,
    fetchedAt: Date,
    tokenPeriodLabel: String? = nil,
    tokens: Int64? = nil,
    apiPrice: CodexAPIPrice? = nil
  ) {
    // Shorter window first; a lone weekly window takes the primary slot.
    let rows = bucket.windowRows()
    guard let first = rows.first?.window else { return nil }
    let second = rows.dropFirst().first?.window
    self.init(
      usedPercentage: first.usedPercent,
      secondaryUsedPercentage: second?.usedPercent,
      resetsAt: first.resetsAt,
      secondaryResetsAt: second?.resetsAt,
      fetchedAt: fetchedAt,
      tokenPeriodLabel: tokenPeriodLabel,
      tokens: tokens,
      apiPrice: apiPrice,
      primaryLabel: second == nil && first.windowDurationMinutes == 10_080 ? "Weekly" : "Session",
      primaryMinutes: first.windowDurationMinutes.map(Int.init),
      secondaryMinutes: second?.windowDurationMinutes.map(Int.init))
  }

}

struct MenuBarAccountSnapshot: Identifiable, Equatable, Sendable {
  let id: UUID
  let providerID: ProviderID
  let identity: String
  let detail: String
  let isVerified: Bool
  let isActive: Bool
  let usage: MenuBarUsageSnapshot?
  let showsUsage: Bool

  init(
    id: UUID,
    identity: String,
    detail: String,
    isVerified: Bool,
    isActive: Bool,
    usage: MenuBarUsageSnapshot? = nil,
    showsUsage: Bool = true,
    providerID: ProviderID = .codex
  ) {
    self.id = id
    self.providerID = providerID
    self.identity = EmailPrivacy.display(identity)  // popover cards and the status-item tooltip
    self.detail = detail
    self.isVerified = isVerified
    self.isActive = isActive
    self.usage = showsUsage ? usage : nil
    self.showsUsage = showsUsage
  }

  /// Codex and every provider with a usage spec can be refreshed from the popover.
  var supportsUsageRefresh: Bool {
    providerID == .codex || ProviderCatalog.spec(providerID) != nil
  }

  /// Only the agent CLIs launch from Switch; generic providers have no tool to open.
  var supportsLaunch: Bool {
    [ProviderID.codex, .grokBuild, .claudeCode].contains(providerID)
  }

  var remainingPercentage: Int? {
    (usage?.usedPercentage ?? usage?.secondaryUsedPercentage).map { max(0, 100 - $0) }
  }

  func displayedPercentage(showsUsed: Bool) -> Int? {
    (usage?.usedPercentage ?? usage?.secondaryUsedPercentage).map {
      UsagePercentagePreferences.displayedPercentage(forUsed: $0, showsUsed: showsUsed)
    }
  }
}

struct MenuBarSnapshot: Equatable, Sendable {
  let accounts: [MenuBarAccountSnapshot]
  let lastRefreshedAt: Date?

  var statusAccounts: [MenuBarAccountSnapshot] {
    statusAccountGroups.flatMap { $0 }
  }

  var statusAccountGroups: [[MenuBarAccountSnapshot]] {
    var groups: [[MenuBarAccountSnapshot]] = []
    for account in accounts.filter(\.showsUsage).prefix(4) {
      if let index = groups.firstIndex(where: { $0.first?.providerID == account.providerID }) {
        groups[index].append(account)
      } else {
        groups.append([account])
      }
    }
    return groups
  }

  static let empty = MenuBarSnapshot(
    accounts: [], lastRefreshedAt: nil)

  init(
    accounts: [MenuBarAccountSnapshot],
    lastRefreshedAt: Date? = nil
  ) {
    self.accounts = accounts
    self.lastRefreshedAt = lastRefreshedAt ?? accounts.compactMap(\.usage?.fetchedAt).max()
  }
}

@MainActor
struct MenuBarPopoverActions {
  let openMainWindow: () -> Void
  let switchAccount: (UUID) async throws -> Void
  let refreshUsage: () async -> Void
  let copyText: ((String) -> Void)?
  let openSettings: () -> Void
  /// Launches the account's tool (Open Codex). Nil hides the row menu item.
  let openTool: ((UUID) async -> Void)?
  /// Refreshes one account. Nil falls back to the all-accounts refresh.
  let refreshAccount: ((UUID) async -> Void)?
  let signInAccount: ((UUID) async -> Void)?

  init(
    openMainWindow: @escaping () -> Void,
    switchAccount: @escaping (UUID) async throws -> Void,
    refreshUsage: @escaping () async -> Void = {},
    copyText: ((String) -> Void)? = nil,
    openSettings: @escaping () -> Void = {},
    openTool: ((UUID) async -> Void)? = nil,
    refreshAccount: ((UUID) async -> Void)? = nil,
    signInAccount: ((UUID) async -> Void)? = nil
  ) {
    self.openSettings = openSettings
    self.openMainWindow = openMainWindow
    self.switchAccount = switchAccount
    self.refreshUsage = refreshUsage
    self.copyText = copyText
    self.openTool = openTool
    self.refreshAccount = refreshAccount
    self.signInAccount = signInAccount
  }
}

@MainActor
final class MenuBarPopoverStore: ObservableObject {
  @Published private(set) var snapshot: MenuBarSnapshot
  @Published private(set) var switchingAccountID: UUID?
  @Published private(set) var isRefreshingUsage = false
  @Published private(set) var visibleScreenHeight: CGFloat
  @Published private(set) var rowErrors: [UUID: String] = [:]

  let actions: MenuBarPopoverActions
  var didSwitch: (() -> Void)?
  var didRequestDismissal: (() -> Void)?

  init(snapshot: MenuBarSnapshot, actions: MenuBarPopoverActions, visibleScreenHeight: CGFloat = 900) {
    self.snapshot = snapshot
    self.actions = actions
    self.visibleScreenHeight = visibleScreenHeight
  }

  func update(visibleScreenHeight: CGFloat) {
    if self.visibleScreenHeight != visibleScreenHeight { self.visibleScreenHeight = visibleScreenHeight }
  }

  func update(snapshot: MenuBarSnapshot) {
    self.snapshot = snapshot
    rowErrors = rowErrors.filter { error in
      snapshot.accounts.contains { $0.id == error.key }
    }
  }

  /// Accounts with Show in Menubar on, in saved order. These are the popover's rows.
  var rows: [MenuBarAccountSnapshot] { snapshot.accounts.filter(\.showsUsage) }

  func openMainWindow() {
    actions.openMainWindow()
    didRequestDismissal?()
  }

  func signIn(accountID: UUID) async {
    openMainWindow()
    await actions.signInAccount?(accountID)
  }

  func openSettings() {
    actions.openSettings()
    didRequestDismissal?()
  }

  var canRefreshUsage: Bool {
    !isRefreshingUsage && snapshot.accounts.contains { $0.showsUsage && $0.supportsUsageRefresh }
  }

  func refreshUsage() async {
    guard canRefreshUsage else { return }
    isRefreshingUsage = true
    defer { isRefreshingUsage = false }
    await actions.refreshUsage()
  }

  func refresh(_ account: MenuBarAccountSnapshot) async {
    guard account.supportsUsageRefresh, !isRefreshingUsage else { return }
    isRefreshingUsage = true
    defer { isRefreshingUsage = false }
    if let refreshAccount = actions.refreshAccount {
      await refreshAccount(account.id)
    } else {
      await actions.refreshUsage()
    }
  }

  func openTool(_ account: MenuBarAccountSnapshot) {
    guard account.supportsLaunch, let openTool = actions.openTool else { return }
    didRequestDismissal?()
    Task { await openTool(account.id) }
  }

  func copy(_ text: String) {
    if let copyText = actions.copyText {
      copyText(text)
      return
    }
    #if !AI_MANAGER_PREVIEW
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
  }

  func canSwitch(_ account: MenuBarAccountSnapshot) -> Bool {
    switchingAccountID == nil && account.isVerified && !account.isActive
  }

  func select(_ account: MenuBarAccountSnapshot) {
    guard canSwitch(account) else { return }

    switchingAccountID = account.id
    rowErrors[account.id] = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await actions.switchAccount(account.id)
        switchingAccountID = nil
        didSwitch?()
      } catch {
        switchingAccountID = nil
        rowErrors[account.id] = error.localizedDescription
      }
    }
  }

}

/// The popover: native material from the hosting NSPopover, about 360 pt wide, one row per
/// account, and a fixed footer. The material, fonts, and colors all come from the system.
struct MenuBarPopover: View {
  static let width: CGFloat = 360
  static let minimumHeight: CGFloat = 94
  static let footerHeight: CGFloat = 44
  static let listInset: CGFloat = 8
  static let cardSpacing: CGFloat = 8

  static func accountRowHeight(_ account: MenuBarAccountSnapshot) -> CGFloat {
    MenuBarPresentation.rowHeight(account)
  }

  @ObservedObject var store: MenuBarPopoverStore
  @AppStorage(UsagePercentagePreferences.showsUsedKey) private var showsUsed = false
  @FocusState private var focusedID: UUID?
  @State private var keyboardActive = false
  @State private var scrollOffset: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      accountList
      MenuBarFooter(store: store)
    }
    .frame(width: Self.width, height: AIManagerStatusItemController.contentSize(
      accounts: store.snapshot.accounts,
      visibleScreenHeight: store.visibleScreenHeight).height)
    .onKeyPress(phases: .down) { press in handle(press) }
    .simultaneousGesture(TapGesture().onEnded { keyboardActive = false })
  }

  @ViewBuilder
  private var accountList: some View {
    let rows = store.rows
    if rows.isEmpty {
      VStack(spacing: 4) {
        Text("No accounts yet").aimText(.section)
        Text("Open Switch to add an account.").aimText(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: Self.cardSpacing) {
              ForEach(rows) { account in
                MenuBarRow(
                  account: account,
                  now: context.date,
                  showsUsed: showsUsed,
                  isSwitching: store.switchingAccountID == account.id,
                  isFocused: keyboardActive && focusedID == account.id,
                  error: store.rowErrors[account.id],
                  store: store)
                .id(account.id)
                .focusable()
                .focused($focusedID, equals: account.id)
                .focusEffectDisabled()
              }
            }
            .padding(.vertical, Self.listInset + Self.cardSpacing / 2)
            .background(GeometryReader { geometry in
              Color.clear.preference(key: MenuBarScrollOffset.self,
                value: -geometry.frame(in: .named("menuBarList")).minY)
            })
          }
          .padding(.trailing, 6)
        }
        .coordinateSpace(name: "menuBarList")
        .scrollIndicators(.hidden)
        .onPreferenceChange(MenuBarScrollOffset.self) { scrollOffset = $0 }
        .overlay(alignment: .trailing) {
          GeometryReader { geometry in
            let contentHeight = rows.map(Self.accountRowHeight).reduce(0, +)
            let viewport = geometry.size.height
            if contentHeight > viewport {
              let thumbHeight = max(20, viewport * viewport / contentHeight)
              Capsule().fill(Color.primary.opacity(0.25))
                .frame(width: 3, height: thumbHeight)
                .offset(x: geometry.size.width - 4,
                  y: min(max(scrollOffset / (contentHeight - viewport), 0), 1) * (viewport - thumbHeight))
            }
          }
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: focusedID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
      .onAppear {
        // Start on the default account so Return never switches by surprise.
        focusedID = rows.first(where: \.isActive)?.id
      }
    }
  }

  private func handle(_ press: KeyPress) -> KeyPress.Result {
    let rows = store.rows
    switch press.key {
    case .tab:
      keyboardActive = true
      return .ignored
    case .downArrow, .upArrow:
      keyboardActive = true
      guard let next = MenuBarPresentation.neighbor(
        of: focusedID, in: rows.map(\.id), step: press.key == .downArrow ? 1 : -1)
      else { return .ignored }
      focusedID = next
      return .handled
    case .return, .space:
      guard let id = focusedID, let account = rows.first(where: { $0.id == id }) else { return .ignored }
      store.select(account)
      return .handled
    default:
      return .ignored
    }
  }
}

private struct MenuBarScrollOffset: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
