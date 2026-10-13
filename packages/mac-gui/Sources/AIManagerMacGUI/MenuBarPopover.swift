import AppKit
import AIManagerCore
import SwiftUI

struct MenuBarUsageSnapshot: Equatable, Sendable {
  struct Window: Equatable, Sendable {
    let title: String
    let used: Int?
    let resetsAt: Date?
    let minutes: Int?
    var balance: String? = nil
    var compactLabel: String? = nil
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
    var reported = ordered.map {
      Window(title: $0.title, used: $0.usedPercent.map { Int($0.rounded()) },
        resetsAt: $0.resetsAt, minutes: $0.windowMinutes, balance: $0.usedPercent == nil ? $0.detail : nil)
    }
    if let cost = usage.cost, let used = cost.used, let limit = cost.limit, limit > 0 {
      reported.append(Window(title: "\(cost.period ?? "Monthly") credits",
        used: Int((used / limit * 100).rounded()), resetsAt: cost.resetsAt, minutes: nil))
    }
    let balance = usage.cost?.balance.map { Fmt.money($0, currency: usage.cost?.currency ?? "USD") }
    guard !reported.isEmpty || balance != nil else { return nil }
    if let balance, !ordered.isEmpty {
      reported.append(Window(title: "Balance", used: nil, resetsAt: nil, minutes: nil, balance: balance))
    }
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
      providerWindows: reported)
  }

  init?(
    bucket: CodexRateLimitBucketSnapshot,
    additionalBuckets: [String: CodexRateLimitBucketSnapshot] = [:],
    extras: CodexWhamExtras? = nil,
    fetchedAt: Date,
    tokenPeriodLabel: String? = nil,
    tokens: Int64? = nil,
    apiPrice: CodexAPIPrice? = nil
  ) {
    // Shorter window first; a lone weekly window takes the primary slot.
    let windows = [bucket.primary, bucket.secondary].compactMap { $0 }
      .sorted { ($0.windowDurationMinutes ?? .max) < ($1.windowDurationMinutes ?? .max) }
    let first = windows.first
    let second = windows.dropFirst().first
    var reported = windows.enumerated().map { index, window in
      Window(title: CodexBucketNaming.windowTitle(minutes: window.windowDurationMinutes,
        fallback: index == 0 ? "Session" : "Weekly"), used: window.usedPercent,
        resetsAt: window.resetsAt, minutes: window.windowDurationMinutes.map(Int.init))
    }
    if let credits = UsagePresentation.credits(bucket.credits) {
      reported.append(Window(title: "Credits", used: nil, resetsAt: nil, minutes: nil, balance: credits))
    }
    var allBuckets = additionalBuckets
    var names = Set(additionalBuckets.map { CodexBucketNaming.title(id: $0.value.id ?? $0.key,
      name: $0.value.name, model: $0.value.model, fallback: $0.key) })
    for extra in extras?.additionalBuckets ?? [] {
      let id = extra.id ?? extra.model ?? extra.name ?? "Usage"
      let name = CodexBucketNaming.title(id: extra.id, name: extra.name, model: extra.model, fallback: id)
      if allBuckets[id] == nil, names.insert(name).inserted { allBuckets[id] = extra }
    }
    for (id, scoped) in allBuckets.sorted(by: { $0.key < $1.key })
      where scoped != bucket && (bucket.id == nil || (scoped.id ?? id) != bucket.id) {
      let name = CodexBucketNaming.title(id: scoped.id ?? id, name: scoped.name, model: scoped.model, fallback: id)
      for window in [scoped.primary, scoped.secondary].compactMap({ $0 }) {
        let period = CodexBucketNaming.windowTitle(minutes: window.windowDurationMinutes, fallback: "Usage")
        reported.append(Window(title: "\(name) \(period)", used: window.usedPercent,
          resetsAt: window.resetsAt, minutes: window.windowDurationMinutes.map(Int.init),
          compactLabel: MenuBarPresentation.windowLabel(minutes: nil, title: name)))
      }
      if let credits = UsagePresentation.credits(scoped.credits) {
        reported.append(Window(title: "\(name) credits", used: nil, resetsAt: nil, minutes: nil,
          balance: credits, compactLabel: MenuBarPresentation.windowLabel(minutes: nil, title: "\(name) credits")))
      }
    }
    if let monthly = extras?.monthlyCredits {
      let window = monthly.window
      reported.append(Window(title: window.title, used: window.usedPercent.map { Int($0.rounded()) },
        resetsAt: window.resetsAt, minutes: nil))
    }
    guard !reported.isEmpty else { return nil }
    self.init(
      usedPercentage: first?.usedPercent,
      secondaryUsedPercentage: second?.usedPercent,
      resetsAt: first?.resetsAt,
      secondaryResetsAt: second?.resetsAt,
      fetchedAt: fetchedAt,
      tokenPeriodLabel: tokenPeriodLabel,
      tokens: tokens,
      apiPrice: apiPrice,
      primaryLabel: second == nil && first?.windowDurationMinutes == 10_080 ? "Weekly" : "Session",
      primaryMinutes: first?.windowDurationMinutes.map(Int.init),
      secondaryMinutes: second?.windowDurationMinutes.map(Int.init), providerWindows: reported)
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
  let reservedRowHeight: CGFloat?

  init(
    id: UUID,
    identity: String,
    detail: String,
    isVerified: Bool,
    isActive: Bool,
    usage: MenuBarUsageSnapshot? = nil,
    showsUsage: Bool = true,
    providerID: ProviderID = .codex,
    identityIsFormatted: Bool = false,
    reservedRowHeight: CGFloat? = nil
  ) {
    self.id = id
    self.providerID = providerID
    self.identity = identityIsFormatted ? identity : EmailPrivacy.display(identity)
    self.detail = detail
    self.isVerified = isVerified
    self.isActive = isActive
    self.usage = showsUsage ? usage : nil
    self.showsUsage = showsUsage
    self.reservedRowHeight = reservedRowHeight
  }

  /// Codex and every provider with a usage spec can be refreshed from the popover.
  var supportsUsageRefresh: Bool {
    providerID == .codex || providerID == .droid || ProviderCatalog.spec(providerID) != nil
  }

  /// Only the agent CLIs launch from Switch; generic providers have no tool to open.
  var supportsLaunch: Bool {
    [ProviderID.codex, .grokBuild, .droid, .claudeCode].contains(providerID)
  }

  var remainingPercentage: Int? {
    quotaUsedPercentage.map { max(0, 100 - $0) }
  }

  var quotaUsedPercentage: Int? {
    usage?.usedPercentage ?? usage?.secondaryUsedPercentage ?? usage?.providerWindows?.compactMap(\.used).first
  }

  func displayedPercentage(showsUsed: Bool) -> Int? {
    quotaUsedPercentage.map {
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
    for account in accounts.filter({ $0.showsUsage && $0.isVerified && $0.remainingPercentage != nil }).prefix(4) {
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
  let quit: () -> Void
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
    quit: @escaping () -> Void = {},
    openTool: ((UUID) async -> Void)? = nil,
    refreshAccount: ((UUID) async -> Void)? = nil,
    signInAccount: ((UUID) async -> Void)? = nil
  ) {
    self.openSettings = openSettings
    self.quit = quit
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
  @Published private(set) var expandedAccountID: UUID?
  @Published private(set) var expansionAmounts: [UUID: CGFloat] = [:]

  let actions: MenuBarPopoverActions
  var didSwitch: (() -> Void)?
  var didRequestDismissal: (() -> Void)?
  var didChangeLayout: (() -> Void)?
  private let defaults: UserDefaults
  var animatesLayout = false
  var reduceMotion = false
  private var layoutTask: Task<Void, Never>?

  func expansionAmount(_ id: UUID) -> CGFloat {
    if reduceMotion { return expandedAccountID == id ? 1 : 0 }
    return revealAmount(id)
  }

  func revealAmount(_ id: UUID) -> CGFloat {
    expansionAmounts[id] ?? (expandedAccountID == id ? 1 : 0)
  }

  var contentHeight: CGFloat {
    let collapsed = MenuBarPresentation.listHeight(snapshot.accounts)
    let expanded = rows.reduce(CGFloat.zero) { $0 + MenuBarPresentation.expansionHeight($1) * expansionAmount($1.id) }
    let ideal = rows.isEmpty ? MenuBarPopover.minimumHeight : collapsed + expanded + MenuBarPopover.footerHeight
    return min(max(ideal.rounded(), MenuBarPopover.minimumHeight), max(MenuBarPopover.minimumHeight, floor(visibleScreenHeight * 0.8)))
  }

  init(snapshot: MenuBarSnapshot, actions: MenuBarPopoverActions, visibleScreenHeight: CGFloat = 900,
       defaults: UserDefaults = .standard) {
    self.snapshot = snapshot
    self.actions = actions
    self.visibleScreenHeight = visibleScreenHeight
    self.defaults = defaults
    expandedAccountID = defaults.string(forKey: MenuBarUsagePreferences.expandedAccountKey).flatMap(UUID.init(uuidString:))
      .flatMap { id in snapshot.accounts.contains(where: { $0.id == id && $0.showsUsage }) ? id : nil }
  }

  func update(visibleScreenHeight: CGFloat) {
    if self.visibleScreenHeight != visibleScreenHeight { self.visibleScreenHeight = visibleScreenHeight }
  }

  func update(snapshot: MenuBarSnapshot) {
    self.snapshot = MenuBarSnapshot(accounts: snapshot.accounts.map { account in
      guard !account.isVerified, let old = self.snapshot.accounts.first(where: { $0.id == account.id }) else { return account }
      return MenuBarAccountSnapshot(id: account.id, identity: account.identity, detail: account.detail,
        isVerified: false, isActive: account.isActive, usage: account.usage, showsUsage: account.showsUsage,
        providerID: account.providerID, identityIsFormatted: true,
        reservedRowHeight: old.reservedRowHeight ?? MenuBarPresentation.rowHeight(old))
    }, lastRefreshedAt: snapshot.lastRefreshedAt)
    rowErrors = rowErrors.filter { error in
      snapshot.accounts.contains { $0.id == error.key }
    }
    if !snapshot.accounts.contains(where: { $0.id == expandedAccountID && $0.showsUsage }) {
      expandedAccountID = defaults.string(forKey: MenuBarUsagePreferences.expandedAccountKey)
        .flatMap(UUID.init(uuidString:)).flatMap { id in
          snapshot.accounts.contains(where: { $0.id == id && $0.showsUsage }) ? id : nil
        }
    }
  }

  /// Accounts with Show in Menubar on, in saved order. These are the popover's rows.
  var rows: [MenuBarAccountSnapshot] { MenuBarPresentation.groups(snapshot.accounts).flatMap { $0 } }

  func toggleExpanded(_ account: MenuBarAccountSnapshot) {
    layoutTask?.cancel()
    let start = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, revealAmount($0.id)) })
    expandedAccountID = expandedAccountID == account.id ? nil : account.id
    defaults.set(expandedAccountID?.uuidString, forKey: MenuBarUsagePreferences.expandedAccountKey)
    guard animatesLayout else {
      expansionAmounts = [:]
      didChangeLayout?()
      return
    }
    expansionAmounts = start
    didChangeLayout?()
    let target = expandedAccountID
    layoutTask = Task { @MainActor [weak self] in
      let began = ContinuousClock.now
      while !Task.isCancelled {
        guard let self else { return }
        let elapsed = began.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let time = min(seconds / 0.25, 1)
        // A critically damped spring, normalized to settle on the final frame.
        let progress = CGFloat((1 - (1 + 8 * time) * exp(-8 * time)) / (1 - 9 * exp(-8.0)))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          var amounts = start
          for (id, amount) in start {
            amounts[id] = amount + ((id == target ? 1 : 0) - amount) * progress
          }
          self.expansionAmounts = time == 1 ? [:] : amounts
          self.didChangeLayout?()
        }
        if time == 1 { return }
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
      }
    }
  }

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
  static let darkSurface = Color(red: 0.15, green: 0.15, blue: 0.157)
  @ObservedObject var store: MenuBarPopoverStore
  @AppStorage(UsagePercentagePreferences.showsUsedKey) private var showsUsed = false
  @FocusState private var focusedID: UUID?
  @State private var keyboardActive = false
  @State private var scrollOffset: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme
  var previewHoveredID: UUID? = nil

  var body: some View {
    VStack(spacing: 0) {
      accountList
        .frame(height: store.contentHeight - Self.footerHeight, alignment: .top)
      MenuBarFooter(store: store)
    }
    .frame(width: Self.width, height: store.contentHeight, alignment: .top)
    .background {
      if colorScheme == .dark { Self.darkSurface.opacity(reduceTransparency ? 1 : 0.96) }
      else { Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : 0.82) }
    }
    .onAppear {
      store.animatesLayout = true
      store.reduceMotion = reduceMotion
    }
    .onChange(of: reduceMotion) { _, value in store.reduceMotion = value }
    .onDisappear { store.animatesLayout = false }
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
        AIMScrollView(name: "menu-bar") {
          TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 0) {
              ForEach(Array(MenuBarPresentation.groups(rows).enumerated()), id: \.offset) { index, group in
                if index > 0 {
                  MenuBarSeparator()
                    .padding(.horizontal, 8).frame(height: MenuBarPresentation.groupGap)
                }
                HStack(spacing: MenuBarPresentation.tileSpacing) {
                  ProviderMark(providerID: group[0].providerID, size: 16)
                  Text(group[0].providerID.guiName).aimText(.secondary).fontWeight(.semibold)
                    .uiLint(.align("menuBarGroupHeaderInk", .start))
                  Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: MenuBarPresentation.groupHeaderHeight)
                VStack(spacing: MenuBarPresentation.accountGap) {
                ForEach(group) { account in
                MenuBarRow(
                  account: account,
                  now: context.date,
                  showsUsed: showsUsed,
                  isSwitching: store.switchingAccountID == account.id,
                  isFocused: keyboardActive && focusedID == account.id,
                  error: store.rowErrors[account.id],
                  store: store, previewHovered: previewHoveredID == account.id)
                .id(account.id)
                .focusable()
                .focused($focusedID, equals: account.id)
                .focusEffectDisabled()
                }
                }
              }
            }
            .padding(.vertical, 12)
            .background(GeometryReader { geometry in
              Color.clear.preference(key: MenuBarScrollOffset.self,
                value: -geometry.frame(in: .named("menuBarList")).minY)
            })
          }
          .padding(.trailing, AIMScroller.gutter)
        }
        .coordinateSpace(name: "menuBarList")
        .onPreferenceChange(MenuBarScrollOffset.self) { scrollOffset = $0 }
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
      store.toggleExpanded(account)
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
