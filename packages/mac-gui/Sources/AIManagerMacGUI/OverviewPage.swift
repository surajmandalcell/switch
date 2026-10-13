import AIManagerCore
import SwiftUI

// The Overview page: five cards (focused account, accounts table, current limits, recent
// activity, maintenance) on the shared parts in AIManagerParts.swift.

// MARK: - Focus and data

enum OverviewFocus {
  /// The default account that was switched most recently, else the first account.
  static func defaultAccountID(in status: ManagerStatus?) -> UUID? {
    guard let status else { return nil }
    let ordered = status.accounts.enumerated().filter { status.isDefault($0.element) }.sorted { left, right in
      let first = left.element.lastUsedAt ?? .distantPast
      let second = right.element.lastUsedAt ?? .distantPast
      return first != second ? first > second : left.offset < right.offset
    }
    return ordered.first?.element.id ?? status.accounts.first?.id
  }
}

enum OverviewFormat {
  /// "in 6d 8h", "in 1h 45m", or the exact time without its "Resets" prefix.
  static func compactReset(
    _ reset: Date, now: Date = Date(), exact: Bool? = nil, usedPercent: Double? = nil
  ) -> String {
    if reset <= now { return ResetDisplay.pastText(usedPercent: usedPercent) }
    if exact ?? ResetDisplay.isExact() {
      return UsageResetLabel.text(until: reset, now: now, exact: true)
        .replacingOccurrences(of: "Resets ", with: "")
    }
    let minutes = Int(max(0, reset.timeIntervalSince(now)) / 60)
    if minutes == 0 { return "in <1m" }
    let days = minutes / 1_440, hours = (minutes % 1_440) / 60, rest = minutes % 60
    if days > 0 { return "in \(days)d \(hours)h" }
    if hours > 0 { return "in \(hours)h \(rest)m" }
    return "in \(rest)m"
  }

  enum RowAction { case isDefault, signIn, switchTo }

  /// The last table column: the default marker, "Sign in" for a dead login, else "Switch".
  @MainActor static func rowAction(for account: AccountRecord, model: AccountViewModel) -> RowAction {
    if model.status?.isDefault(account) == true { return .isDefault }
    return model.needsSignIn(account) ? .signIn : .switchTo
  }

  static func percent(_ window: UsageWindow?, showsUsed: Bool) -> String {
    guard let used = window?.usedPercent else { return "–" }
    return "\(UsagePercentagePreferences.displayedPercentage(forUsed: Int(used.rounded()), showsUsed: showsUsed))%"
  }
}

/// Refreshes the saved account through an isolated, account-scoped sign-in.
struct SignInButton: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  /// False in a list row, where the view's one prominent action sits elsewhere.
  var prominent = true
  /// A fixed width, so the button matches the Default chip in a table row.
  var width: CGFloat? = nil

  var body: some View {
    Button("Sign in") { Task { await model.beginSignIn(for: account.id) } }
      .buttonStyle(AIMPushButtonStyle(prominent: prominent, width: width))
      .disabled(model.isBusy)
      .accessibilityHint("Signs in to \(account.identity.providerID.guiName) again")
  }
}

extension AccountRecord {
  /// A verified account can become the default.
  var canSwitchDefault: Bool {
    switch verification.state {
    case .imported, .verifiedLocally, .verifiedWithCodex: true
    case .needsSignIn, .unsupported: false
    }
  }
}

enum AccountUsageSummary {
  /// The visible usage windows of an account, primary first. Empty when usage is unknown or the
  /// account needs a new sign-in (stale values never sit beside that state).
  @MainActor static func windows(for account: AccountRecord, model: AccountViewModel) -> [UsageWindow] {
    if account.verification.state == .needsSignIn { return [] }
    if account.identity.providerID == .codex {
      guard let limits = model.usage(for: account.id)?.rateLimits else { return [] }
      let hidden = HiddenUsageRows.hidden(for: account.id)
      var seen = Set<String>()
      var result: [(window: UsageWindow, bucket: String)] = []
      func append(_ bucket: CodexRateLimitBucketSnapshot, key: String) {
        guard seen.insert(bucket.id ?? key).inserted else { return }
        let name = CodexBucketNaming.title(
          id: bucket.id, name: bucket.name, model: bucket.model, fallback: key)
        for row in bucket.windowRows(idPrefix: "\(key)/") where !hidden.contains(row.usage.id) {
          result.append((row.usage, name))
        }
      }
      if let bucket = limits.defaultBucket { append(bucket, key: bucket.id ?? "default") }
      for (key, bucket) in limits.buckets.sorted(by: {
        $0.key.localizedStandardCompare($1.key) == .orderedAscending
      }) { append(bucket, key: key) }
      // A window shares its title with another one only across buckets; name its bucket then.
      let titles = result.map(\.window.title)
      return result.map { item in
        var window = item.window
        if titles.filter({ $0 == window.title }).count > 1 { window.title = "\(item.bucket) · \(window.title)" }
        return window
      }
    }
    guard let state = model.providerUsage[account.id], !state.needsSignIn, let usage = state.usage else {
      return []
    }
    return HiddenUsageRows.applying(to: usage, for: account.id).windows
  }
}

// MARK: - Shared account actions

/// The items of an account's More menu and a table row's context menu: copy, menu-bar choice,
/// refresh, check, and delete.
struct AccountMenuItems: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let delete: () -> Void
  @Environment(\.aimCopyPath) private var copyPath

  var body: some View {
    Button("Copy Name") { _ = copyPath(account.identity.accountLabel) }
    if !account.usesGenericDetail {
      Button(account.identity.providerID == .claudeCode ? "Copy Config Path" : AccountActionCopy.copyAuthPath) {
        model.copySavedAuthPath(for: account.id)
      }
    }
    Divider()
    AccountMenuBarItems(accountID: account.id).id(account.id)
    Divider()
    Button("Refresh Usage") { Task { await model.refreshAnyUsage(accountID: account.id) } }
      .disabled(model.isBusy)
    if !account.usesGenericDetail {
      Button("Check Account") { Task { await model.checkAccount(account.id) } }
        .disabled(model.isBusy)
    }
    Divider()
    Button("Delete…", role: .destructive, action: delete)
      .disabled(model.isBusy || !model.canDeleteAccount(account.id))
  }
}

/// "Show in Menubar" (a checkmark item) and "Use Settings default".
struct AccountMenuBarItems: View {
  let accountID: UUID
  @AppStorage(MenuBarUsagePreferences.defaultKey) private var defaultShowUsage = true
  @State private var showsOverride: Bool?

  init(accountID: UUID) {
    self.accountID = accountID
    _showsOverride = State(initialValue: MenuBarUsagePreferences.explicitValue(for: accountID))
  }

  var body: some View {
    Toggle("Show in Menubar", isOn: Binding(
      get: { showsOverride ?? defaultShowUsage },
      set: { value in
        MenuBarUsagePreferences.setOverride(value, for: accountID)
        showsOverride = value
      }))
    Button("Use Settings Default") {
      MenuBarUsagePreferences.useDefault(for: accountID)
      showsOverride = nil
    }
    .disabled(showsOverride == nil)
  }
}

/// The More menu of an account: a square [⋯] button.
struct AccountMoreMenu: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let delete: () -> Void

  var body: some View {
    AIMIconMenu(icon: .ellipsis, label: "More actions") {
      AccountMenuItems(account: account, model: model, delete: delete)
    }
    .help("More actions for this account")
  }
}

/// Delete confirmation shared by the Overview and the Accounts page. The message names the
/// replacement default when the deleted account is one.
struct AccountDeletionAlert: ViewModifier {
  @ObservedObject var model: AccountViewModel
  @Binding var pending: AccountRecord?

  func body(content: Content) -> some View {
    content.alert(
      "Delete \(pending?.identity.accountLabel ?? "account")?",
      isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
      presenting: pending
    ) { account in
      Button("Delete account", role: .destructive) {
        Task { await model.deleteAccount(account.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { account in
      Text(Self.message(for: account, model: model))
    }
  }

  static func message(for account: AccountRecord, model: AccountViewModel) -> String {
    let removal = "Remove this account's saved sign-in from Switch. Conversations and settings stay."
    if model.status?.isDefault(account) == true,
       let replacement = model.deletionReplacement(for: account.id) {
      return "\(removal) \(replacement.identity.accountLabel) will become the default for new \(account.identity.providerID.guiName) sessions."
    }
    return removal
  }
}

extension View {
  func accountDeletionAlert(model: AccountViewModel, pending: Binding<AccountRecord?>) -> some View {
    modifier(AccountDeletionAlert(model: model, pending: pending))
  }
}

extension AccountViewModel {
  /// Starts the delete confirmation, or explains why the account cannot be deleted.
  func requestDeletion(of account: AccountRecord, into pending: Binding<AccountRecord?>) {
    guard canDeleteAccount(account.id) else {
      errorMessage = "No saved account is available as a replacement."
      return
    }
    pending.wrappedValue = account
  }
}

// MARK: - Recent activity data

/// Today, Yesterday, and the last 30 days of local history for the focused account's tool.
enum OverviewActivity {
  struct Row: Identifiable, Equatable {
    let label: String
    let icon: AIMIcon.Name
    let tokens: Int64
    /// An estimated API-equivalent cost; nil when no price is known.
    let cost: Double?
    let detail: String
    var id: String { label }
  }

  enum Source: Equatable {
    case rows([Row])
    /// One Secondary line: loading, or no local history for this tool.
    case message(String)
  }

  private static let icons: [AIMIcon.Name] = [.chart, .clock, .calendar]

  @MainActor static func source(
    for account: AccountRecord, model: AccountViewModel, now: Date = Date()
  ) -> Source {
    let provider = account.identity.providerID
    switch provider {
    case .claudeCode:
      if let summary = model.claudeActivity {
        return .rows(summary.rows.enumerated().map { index, row in
          Row(label: row.label, icon: icons[min(index, 2)], tokens: Int64(row.tokens),
            cost: row.costUSD, detail: row.detail)
        })
      }
      return .message(model.isClaudeActivityLoading
        ? "Scanning local Claude Code logs…" : "Claude Code activity is not available yet.")
    case .codex:
      let days = model.dailyUsage(for: account.id)
      guard !days.isEmpty else { return .message("No local history for Codex CLI yet.") }
      let periods: [(String, CodexTokenPeriod)] = [
        ("Today", .today), ("Yesterday", .yesterday), ("Last 30 days", .monthly),
      ]
      return .rows(periods.enumerated().map { index, item in
        let tokens = item.1.tokens(in: days, endingAt: now)
        return Row(
          label: item.0, icon: icons[index], tokens: tokens,
          cost: model.apiPrice?.inputEquivalent(for: tokens),
          detail: "\(UsagePresentation.exactTokens(tokens)) tokens. The cost is an input-rate comparison, not billed spend.")
      })
    default:
      return .message("\(provider.guiName) keeps no local history that Switch can read.")
    }
  }
}

// MARK: - Page

struct OverviewPage: View {
  @ObservedObject var model: AccountViewModel
  let query: String
  /// Goes to another page; the "View all limits", "View full history", and "Open Backup" links use it.
  var navigate: (AIManagerPage) -> Void = { page in
    NotificationCenter.default.post(name: AIManagerNavigation.request, object: page)
  }
  @State private var focusedID: UUID?
  @State private var pendingDeletion: AccountRecord?
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  @AppStorage(UsagePercentagePreferences.showsUsedKey) private var showsUsed = false

  private var accounts: [AccountRecord] { model.status?.accounts ?? [] }
  private var visibleAccounts: [AccountRecord] {
    AccountSearch.filter(accounts, query: query, hideEmails: hideEmails)
  }
  private var focused: AccountRecord? {
    accounts.first { $0.id == focusedID }
      ?? accounts.first { $0.id == OverviewFocus.defaultAccountID(in: model.status) }
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      // Five cards at the full content width: 20-point margins, 12 points between them.
      AIMScrollPage {
          if let account = focused {
            FocusedAccountCard(
              account: account, accounts: accounts, model: model, now: context.date,
              hideEmails: hideEmails, showsUsed: showsUsed,
              focus: { focusedID = $0 },
              delete: { model.requestDeletion(of: account, into: $pendingDeletion) })
            AccountsTableCard(
              accounts: visibleAccounts, total: accounts.count, query: query, model: model,
              focusedID: account.id, now: context.date, hideEmails: hideEmails,
              showsUsed: showsUsed,
              focus: { focusedID = $0 },
              delete: { model.requestDeletion(of: $0, into: $pendingDeletion) })
            CurrentLimitsCard(
              account: account, model: model, now: context.date, showsUsed: showsUsed
            ) { navigate(.accounts) }
            RecentActivityCard(account: account, model: model, now: context.date) {
              navigate(.conversations)
            }
            MaintenanceStatusCard(model: model) { navigate(.maintenance) }
          } else {
            OverviewEmptyCard(model: model)
          }
          if let notice = model.notice {
            AIMPanel { Notice(text: notice, tone: AIMTheme.blue).aimRow() }
          }
      }
    }
    .accountDeletionAlert(model: model, pending: $pendingDeletion)
    // The page remembers its focused account while the app runs.
    .onChange(of: focusedID) { _, id in AIMPlace.overviewFocus = id }
    #if AI_MANAGER_PREVIEW
    .onChange(of: model.selectedAccountID) { _, id in
      if PreviewArguments.value("select") != nil { focusedID = id }
    }
    #endif
    .onAppear {
      focusedID = focusedID ?? AIMPlace.overviewFocus ?? OverviewFocus.defaultAccountID(in: model.status)
      #if AI_MANAGER_PREVIEW
      // Preview screenshots: `--select=claude-code` also focuses that account here.
      if PreviewArguments.value("select") != nil, let id = model.selectedAccountID { focusedID = id }
      #endif
    }
  }
}

// MARK: - Card 1: focused account

struct FocusedAccountCard: View {
  let account: AccountRecord
  let accounts: [AccountRecord]
  @ObservedObject var model: AccountViewModel
  let now: Date
  let hideEmails: Bool
  let showsUsed: Bool
  let focus: (UUID) -> Void
  let delete: () -> Void
  @Environment(\.aimCopyPath) private var copyPath

  private var providerID: ProviderID { account.identity.providerID }
  private var name: String { account.identity.accountLabel }
  private var isDefault: Bool { model.status?.isDefault(account) == true }

  var body: some View {
    let windows = AccountUsageSummary.windows(for: account, model: model)
    AIMCard {
      VStack(alignment: .leading, spacing: AIMTheme.cardInset) {
        HStack(alignment: .center, spacing: AIMTheme.cardInset) {
          HStack(spacing: 12) {
            ProviderMark(providerID: providerID, size: 44)
            VStack(alignment: .leading, spacing: 2) {
              accountMenu
              HStack(spacing: AIMTheme.rowSpacing) {
                Text(providerID.guiName).aimText(.secondary)
                incidentBadge
                statusBadge
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          AIMHairline(vertical: true).frame(height: 44)
          primaryWindow(windows.first)
            .frame(minWidth: 240, maxWidth: 420)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focused account")
        actionRow
      }
      .padding(AIMTheme.cardInset)
    }
  }

  @ViewBuilder private func primaryWindow(_ window: UsageWindow?) -> some View {
    if let window {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: AIMTheme.rowSpacing) {
          Text(window.title).aimText(.body).lineLimit(1)
          Spacer(minLength: AIMTheme.rowSpacing)
          Text(window.usedPercent.map {
            UsagePercentagePreferences.label(forUsed: Int($0.rounded()), showsUsed: showsUsed)
          } ?? "–")
            .aimText(.body).monospacedDigit().lineLimit(1)
            .flipsUsedAndLeft(showsUsed)
            .uiLint(.number)
        }
        UsageBar(usedPercent: window.usedPercent, showsUsed: showsUsed, providerID: providerID)
        if let reset = window.resetsAt {
          ResetTimeText(reset: reset, now: now, usedPercent: window.usedPercent).lineLimit(1)
        }
      }
      .accessibilityElement(children: .combine)
    } else {
      Text(UsagePresentation.emptyUsageTitle(
        failure: model.usageError(for: account.id) ?? model.providerUsage[account.id]?.error,
        needsSignIn: account.verification.state == .needsSignIn))
        .aimText(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var actionRow: some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      HStack(spacing: AIMTheme.rowSpacing) {
        if model.needsSignIn(account) {
          SignInButton(account: account, model: model)
        } else if isDefault {
          Button {} label: { Label(AccountActionCopy.usingDefault, systemImage: AIMIcon.Name.check.symbol) }
            .buttonStyle(AIMPushButtonStyle(prominent: true))
            .accessibilityLabel(AccountActionCopy.usingDefault)
            .accessibilityHint("This account is already the default.")
        } else {
          Button(AccountActionCopy.use) { Task { await model.switchDefault(to: account.id) } }
            .buttonStyle(AIMPushButtonStyle(prominent: true))
            .disabled(model.isBusy || !account.canSwitchDefault)
        }
        if !account.usesGenericDetail {
          Button {
            Task { await model.openAccount(account.id) }
          } label: {
            Label(
              isDefault ? AccountActionCopy.open(providerID) : AccountActionCopy.useAndOpen(providerID),
              systemImage: AIMIcon.Name.play.symbol)
          }
          .buttonStyle(AIMPushButtonStyle())
          .disabled(model.isBusy)
        } else if let dashboard = ProviderCatalog.spec(providerID)?.dashboard {
          // Generic accounts open their provider's dashboard, as their detail page used to.
          Button {
            model.openDashboard(dashboard)
          } label: {
            Label("Open dashboard", systemImage: AIMIcon.Name.arrowRight.symbol)
          }
          .buttonStyle(AIMPushButtonStyle())
          .disabled(model.isBusy)
        }
      }
      .uiLint(.actions)
      Spacer(minLength: AIMTheme.rowSpacing)
      HStack(spacing: AIMTheme.rowSpacing) {
        Button { _ = copyPath(account.identity.accountLabel) } label: {
          Label("Copy", systemImage: AIMIcon.Name.copy.symbol)
        }
        .buttonStyle(AIMPushButtonStyle())
        .help("Copy the account name")
        AccountMoreMenu(account: account, model: model, delete: delete)
      }
      .uiLint(.actions)
    }
  }

  private var accountMenu: some View {
    Menu {
      ForEach(accounts) { item in
        Button {
          focus(item.id)
        } label: {
          let title = "\(item.identity.accountLabel) · \(item.identity.providerID.guiName)"
          if item.id == account.id {
            Label(title, systemImage: AIMIcon.Name.check.symbol)
          } else {
            Text(title)
          }
        }
      }
    } label: {
      // A button-style menu draws its label as ordinary text, so the Title role applies.
      HStack(spacing: 6) {
        Text(name).aimText(.title).lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.down").aimFont(.secondary).foregroundStyle(.secondary)
      }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    // No ring at rest; the menu stays focusable and opens with Space or Return.
    .focusEffectDisabled()
    .accessibilityLabel("Focused account: \(name)")
    .accessibilityHint("Choose another account")
  }

  /// A provider incident: a small orange "Incident" badge with the incident text as its tooltip.
  /// The hero keeps its one green Active dot; table rows show the small dot instead.
  @ViewBuilder private var incidentBadge: some View {
    if let text = ProviderStatusDot.text(model.providerStatus[providerID]) {
      Badge(text: "Incident", tint: AIMTheme.amber)
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Provider status")
        .accessibilityValue(text)
    }
  }

  /// A green "Active" dot for a healthy default account, else the attention state.
  @ViewBuilder private var statusBadge: some View {
    if let attention = account.verification.state.attentionLabel {
      Badge(text: attention, tint: account.verification.state.color)
    } else if model.providerUsage[account.id]?.needsSignIn == true {
      Badge(text: "Needs sign-in", tint: VerificationState.needsSignIn.color)
    } else if isDefault {
      HStack(spacing: 5) {
        Circle().fill(AIMTheme.green).frame(width: 8, height: 8)
        Text("Active").aimText(.secondary)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

// MARK: - Card 2: accounts table

/// The accounts table: header and rows share `AIMColumns.accounts` and the card's 16 inset.
/// Clicking a row focuses it. `onMove` turns on drag-and-drop reordering.
struct AccountsTableCard: View {
  let accounts: [AccountRecord]
  let total: Int
  let query: String
  @ObservedObject var model: AccountViewModel
  let focusedID: UUID?
  let now: Date
  let hideEmails: Bool
  let showsUsed: Bool
  let focus: (UUID) -> Void
  let delete: (AccountRecord) -> Void
  var loading = false
  var onMove: ((UUID, UUID) -> Void)? = nil
  var contextMenu: ((AccountRecord) -> AnyView)? = nil

  static let group = "accounts"

  var body: some View {
    AIMCard(
      title: "Accounts", bottomInset: AIMTheme.tableEndInset,
      accessory: {
        Text("\(total) \(total == 1 ? "account" : "accounts")").aimText(.secondary)
      }
    ) {
      if loading {
        HStack(spacing: AIMTheme.rowSpacing) {
          ProgressView().controlSize(.small)
          Text("Loading accounts…").aimText(.secondary)
        }
        .aimRow()
      } else if accounts.isEmpty {
        Text(query.isEmpty ? "No accounts yet." : "No accounts match “\(query)”.")
          .aimText(.secondary).aimRow()
      } else {
        VStack(spacing: 0) {
          AIMTableHeader(columns: AIMColumns.accounts, group: Self.group)
          AIMHairline()
          rows
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accounts")
      }
    }
  }

  /// One group per provider, in the order each provider first appears.
  private var groups: [(provider: ProviderID, accounts: [AccountRecord])] {
    var order: [ProviderID] = []
    var byProvider: [ProviderID: [AccountRecord]] = [:]
    for account in accounts {
      let provider = account.identity.providerID
      if byProvider[provider] == nil { order.append(provider) }
      byProvider[provider, default: []].append(account)
    }
    return order.map { ($0, byProvider[$0] ?? []) }
  }

  /// The 24 pt label row above a group: a 12 pt provider glyph and "Codex CLI · 2".
  private func groupLabel(_ provider: ProviderID, count: Int) -> some View {
    HStack(spacing: 6) {
      ProviderGlyph(providerID: provider, size: 12).foregroundStyle(.secondary)
      Text("\(provider.guiName) · \(count)").aimText(.secondary).lineLimit(1)
    }
    .aimColumn(AIMColumns.accounts[0], group: Self.group)
    .padding(.horizontal, AIMTheme.cardInset)
    .frame(height: AIMTheme.groupLabelHeight)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private var rows: some View {
    VStack(spacing: 0) {
      ForEach(Array(groups.enumerated()), id: \.element.provider) { groupIndex, group in
        if groupIndex > 0 { AIMRowSeparator() }
        groupLabel(group.provider, count: group.accounts.count)
        ForEach(Array(group.accounts.enumerated()), id: \.element.id) { index, account in
          if index > 0 { AIMRowSeparator() }
          AccountsTableRow(
            account: account, model: model, selected: account.id == focusedID, now: now,
            hideEmails: hideEmails, showsUsed: showsUsed,
            focus: { focus(account.id) }, delete: { delete(account) },
            onMove: onMove, contextMenu: contextMenu)
        }
      }
    }
  }
}

private struct AccountsTableRow: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let selected: Bool
  let now: Date
  let hideEmails: Bool
  let showsUsed: Bool
  let focus: () -> Void
  let delete: () -> Void
  let onMove: ((UUID, UUID) -> Void)?
  let contextMenu: ((AccountRecord) -> AnyView)?

  @FocusState private var keyboardFocus: Bool
  private var name: String { account.identity.accountLabel }

  var body: some View {
    let columns = AIMColumns.accounts
    let group = AccountsTableCard.group
    let window = AccountUsageSummary.windows(for: account, model: model).first
    let isDefault = model.status?.isDefault(account) == true
    let row = AIMTableRow(highlighted: selected, focused: keyboardFocus) {
      // The group label above says the provider; a status dot follows the name only for an incident.
      HStack(spacing: AIMTheme.rowSpacing) {
        Text(name).aimText(.body).lineLimit(1).truncationMode(.middle)
        ProviderStatusDot(entry: model.providerStatus[account.identity.providerID], size: 6)
      }
      .aimColumn(columns[0], group: group)
      HStack(spacing: AIMTheme.rowSpacing) {
        UsageBar(usedPercent: window?.usedPercent, showsUsed: showsUsed,
          providerID: account.identity.providerID).frame(minWidth: 40)
        Text(OverviewFormat.percent(window, showsUsed: showsUsed))
          .aimText(.body).monospacedDigit().lineLimit(1)
          .frame(width: 44, alignment: .trailing)
          .uiLint(.number)
      }
      .accessibilityElement(children: .combine)
      .aimColumn(columns[1], group: group)
      Text(window?.resetsAt.map { OverviewFormat.compactReset($0, now: now, usedPercent: window?.usedPercent) } ?? "–")
        .aimText(.secondary).lineLimit(1)
        .aimColumn(columns[2], group: group)
      HStack(spacing: AIMTheme.rowSpacing) {
        switch OverviewFormat.rowAction(for: account, model: model) {
        case .isDefault:
          AIMStateChip(text: "Default")
        case .signIn:
          SignInButton(account: account, model: model, prominent: false, width: AIMTheme.rowButtonWidth)
        case .switchTo:
          Button("Switch") { Task { await model.switchDefault(to: account.id) } }
            .buttonStyle(AIMPushButtonStyle(width: AIMTheme.rowButtonWidth))
            .disabled(model.isBusy || !account.canSwitchDefault)
        }
        AccountMoreMenu(account: account, model: model, delete: delete)
      }
      .uiLint(.actions)
      .aimColumn(columns[3], group: group)
    }
    row
      .contentShape(Rectangle())
      .onTapGesture(perform: focus)
      // Keyboard focus only (Tab with Full Keyboard Access): a click selects, it never focuses.
      .focusable(true, interactions: .activate)
      .focused($keyboardFocus)
      .onKeyPress(.return) { focus(); return .handled }
      .contextMenu {
        if let contextMenu { contextMenu(account) } else {
          AccountMenuItems(account: account, model: model, delete: delete)
        }
      }
      .modifier(AccountRowReorder(account: account, onMove: onMove))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(name)
      .accessibilityValue(isDefault ? "Default account" : "Not the default account")
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityAction(named: "Focus account", focus)
  }
}

/// Drag a row onto another row to move it there (the Accounts page).
private struct AccountRowReorder: ViewModifier {
  let account: AccountRecord
  let onMove: ((UUID, UUID) -> Void)?

  func body(content: Content) -> some View {
    if let onMove {
      content
        .draggable(account.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
          guard let id = items.first.flatMap(UUID.init(uuidString:)), id != account.id else { return false }
          onMove(id, account.id)
          return true
        }
    } else {
      content
    }
  }
}

/// The account cell of every account list: a 20-point icon tile, the name in Body, and the
/// provider (with its status dot) in Secondary.
struct AccountCell: View {
  let account: AccountRecord
  var hideEmails = false
  var providerStatus: ProviderStatusEntry? = nil

  var body: some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      ProviderMark(providerID: account.identity.providerID, size: 20)
      VStack(alignment: .leading, spacing: 0) {
        Text(account.identity.accountLabel)
          .aimText(.body).lineLimit(1).truncationMode(.middle)
        HStack(spacing: 5) {
          Text(account.identity.providerID.guiName).aimText(.secondary).lineLimit(1)
          ProviderStatusDot(entry: providerStatus, size: 6)
        }
      }
    }
  }
}

// MARK: - Card 3: current limits

struct CurrentLimitsCard: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let now: Date
  let showsUsed: Bool
  let viewAll: () -> Void

  var body: some View {
    let windows = Array(AccountUsageSummary.windows(for: account, model: model).prefix(3))
    AIMCard(
      title: "Current limits", well: !windows.isEmpty, bottomInset: 0,
      accessory: { AIMCardLink(title: "View all limits", action: viewAll) }
    ) {
      if windows.isEmpty {
        Text(UsagePresentation.emptyUsageTitle(
          failure: model.usageError(for: account.id) ?? model.providerUsage[account.id]?.error,
          needsSignIn: account.verification.state == .needsSignIn))
          .aimText(.secondary)
          .padding(.horizontal, AIMTheme.cardInset).padding(.bottom, AIMTheme.cardInset)
      } else {
        HStack(alignment: .top, spacing: AIMTheme.tileGap) {
          ForEach(windows) { window in
            LimitTile(window: window, providerID: account.identity.providerID,
              showsUsed: showsUsed, now: now)
          }
        }
        .uiLint(.stack)
      }
    }
  }
}

private struct LimitTile: View {
  let window: UsageWindow
  let providerID: ProviderID
  let showsUsed: Bool
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: AIMTheme.rowSpacing) {
        Text(window.title).aimText(.body).lineLimit(1)
        Spacer(minLength: AIMTheme.rowSpacing)
        Text(window.usedPercent.map {
          UsagePercentagePreferences.label(forUsed: Int($0.rounded()), showsUsed: showsUsed)
        } ?? "–")
          .aimText(.body).monospacedDigit().lineLimit(1)
          .flipsUsedAndLeft(showsUsed)
          .uiLint(.number)
      }
      UsageBar(usedPercent: window.usedPercent, showsUsed: showsUsed, providerID: providerID)
      if let reset = window.resetsAt {
        ResetTimeText(reset: reset, now: now, usedPercent: window.usedPercent).lineLimit(1)
      } else {
        Text(" ").aimText(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .aimTile()
  }
}

// MARK: - Card 4: recent activity

struct RecentActivityCard: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let now: Date
  let viewHistory: () -> Void

  static let group = "activity"

  var body: some View {
    let source = OverviewActivity.source(for: account, model: model, now: now)
    AIMCard(
      title: "Recent activity", note: "(\(account.identity.providerID.guiName))", divider: true,
      bottomInset: AIMTheme.textRowsEndInset,
      accessory: { AIMCardLink(title: "View full history", action: viewHistory) }
    ) {
      switch source {
      case .message(let text):
        Text(text).aimText(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, AIMTheme.cardInset)
          .frame(height: AIMTheme.rowHeight)
      case .rows(let rows):
        VStack(spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 { AIMRowSeparator() }
            ActivityRow(row: row)
          }
        }
      }
    }
  }
}

private struct ActivityRow: View {
  let row: OverviewActivity.Row

  var body: some View {
    let columns = AIMColumns.activity
    let group = RecentActivityCard.group
    AIMTableRow {
      HStack(spacing: 10) {
        AIMIcon(name: row.icon).aimFont(.body).foregroundStyle(.secondary).frame(width: 20)
        Text(row.label).aimText(.body).lineLimit(1)
      }
      .aimColumn(columns[0], group: group)
      HStack(spacing: 4) {
        Text(UsagePresentation.formatTokens(row.tokens))
          .aimText(.body).monospacedDigit().uiLint(.number)
        Text("tokens").aimText(.secondary)
      }
      .aimColumn(columns[1], group: group)
      Text(row.cost.map { "≈ \(Fmt.money($0))" } ?? "No price")
        .aimText(.body).monospacedDigit().lineLimit(1).uiLint(.number)
        .aimColumn(columns[2], group: group)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.label)
    .accessibilityValue("\(UsagePresentation.exactTokens(row.tokens)) tokens, "
      + (row.cost.map { "\(Fmt.money($0)) API-equivalent estimate" } ?? "no price"))
    .help(row.detail)
  }
}

// MARK: - Card 5: maintenance

struct MaintenanceStatusCard: View {
  @ObservedObject var model: AccountViewModel
  let openBackup: () -> Void

  private var pending: Int { model.status?.pendingRecovery.count ?? 0 }

  var body: some View {
    AIMCard(title: "Maintenance", divider: true, bottomInset: 0) {
      HStack(spacing: 12) {
        ZStack {
          Circle().fill(pending == 0 ? AIMTheme.green : AIMTheme.yellow).frame(width: 28, height: 28)
            .uiLint(.item)
          Image(systemName: pending == 0 ? "checkmark" : "exclamationmark")
            .aimFont(.section).foregroundStyle(.white)
        }
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(pending == 0 ? "All systems operational" : "Backup work is pending").aimText(.body)
          Text(pending == 0
            ? "No pending backup work."
            : "\(pending) interrupted \(pending == 1 ? "operation needs" : "operations need") attention.")
            .aimText(.secondary)
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: AIMTheme.rowSpacing)
        Button(action: openBackup) {
          Label("Open Backup", systemImage: AIMIcon.Name.database.symbol)
        }
        .buttonStyle(AIMPushButtonStyle())
      }
      .padding(.horizontal, AIMTheme.cardInset)
      // The title text sits 14 pt below the top edge; the content ends 14 pt above the bottom.
      .padding(.vertical, 14)
    }
  }
}

// MARK: - Empty state

private struct OverviewEmptyCard: View {
  @ObservedObject var model: AccountViewModel

  var body: some View {
    AIMPanel {
      VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
        if !model.hasLoaded {
          HStack(spacing: AIMTheme.rowSpacing) {
            ProgressView().controlSize(.small)
            Text("Loading accounts…").aimText(.body)
          }
        } else {
          Text("Add your first account").aimText(.section)
          Text("Switch found no saved account. Sign in to Codex or Grok Build, or use Advanced Import for an existing Codex folder.")
            .aimText(.secondary)
          HStack(spacing: AIMTheme.rowSpacing) {
            AIMButton(title: "Add Account", icon: .plus, tone: .primary, disabled: model.isBusy) {
              Task { await model.beginAddAccount() }
            }
            AIMButton(title: "Advanced Import…", icon: .folder, disabled: model.isBusy) {
              Task { await model.beginAdvancedImport() }
            }
          }
        }
      }
      .aimRow()
    }
  }
}
