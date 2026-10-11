import AIManagerCore
import SwiftUI

// The Overview page, two cards: the focused account with its limits, and the accounts table.

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

/// "Sign in" for an account whose saved login stopped working: the Add Account flow for its provider.
struct SignInButton: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  /// False in a list row, where the view's one prominent action sits elsewhere.
  var prominent = true

  var body: some View {
    Button("Sign in") { Task { await model.beginSignIn(for: account.identity.providerID) } }
      .modifier(AIMButtonStyle(prominent: prominent))
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

/// The More menu of an account.
struct AccountMoreMenu: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let delete: () -> Void

  var body: some View {
    Menu {
      AccountMenuItems(account: account, model: model, delete: delete)
    } label: {
      Label("More", systemImage: AIMIcon.Name.more.symbol).labelStyle(.iconOnly)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("More actions for this account")
    .accessibilityLabel("More actions")
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

// MARK: - Page

struct OverviewPage: View {
  @ObservedObject var model: AccountViewModel
  let query: String
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
      // Two containers at the full content width: 20-point margins, 16 points between them.
      ScrollView {
        VStack(spacing: AIMTheme.sectionSpacing) {
          if let account = focused {
            OverviewHeader(
              account: account, accounts: accounts, model: model, now: context.date,
              hideEmails: hideEmails, showsUsed: showsUsed,
              focus: { focusedID = $0 },
              delete: { model.requestDeletion(of: account, into: $pendingDeletion) })
            OverviewAccountsCard(
              accounts: visibleAccounts, total: accounts.count, query: query, model: model,
              focusedID: account.id, now: context.date, hideEmails: hideEmails,
              showsUsed: showsUsed,
              focus: { focusedID = $0 },
              delete: { model.requestDeletion(of: $0, into: $pendingDeletion) })
          } else {
            OverviewEmptyCard(model: model)
          }
          if let notice = model.notice {
            AIMPanel { Notice(text: notice, tone: AIMTheme.blue).aimRow() }
          }
        }
        .padding(AIMTheme.pageMargin)
      }
    }
    .accountDeletionAlert(model: model, pending: $pendingDeletion)
    .onAppear { focusedID = focusedID ?? OverviewFocus.defaultAccountID(in: model.status) }
  }
}

// MARK: - Focused account card

/// One limit row of the focused card. The reset column takes the width of the longest reset text
/// and never shrinks; the bar gives way first.
struct OverviewWindowRow: View {
  let window: UsageWindow
  let showsUsed: Bool
  let now: Date

  /// The longest countdown the card shows.
  static let longestReset = "Resets in 6 days 23h 59m"
  static let resetWidth: CGFloat = {
    let font = NSFont.preferredFont(forTextStyle: .subheadline)
    return ceil((longestReset as NSString).size(withAttributes: [.font: font]).width) + 4
  }()

  var body: some View {
    HStack(spacing: AIMTheme.sectionSpacing) {
      Text(window.title).aimText(.body).lineLimit(1).frame(width: 130, alignment: .leading)
      UsageBar(usedPercent: window.usedPercent, showsUsed: showsUsed)
        .frame(minWidth: 40)
      Text(window.usedPercent.map {
        UsagePercentagePreferences.label(forUsed: Int($0.rounded()), showsUsed: showsUsed)
      } ?? "–")
        .aimText(.body).monospacedDigit().frame(width: 80, alignment: .trailing)
        .flipsUsedAndLeft(showsUsed)
      Group {
        if let reset = window.resetsAt {
          ResetTimeText(reset: reset, now: now, usedPercent: window.usedPercent)
        } else {
          Text("")
        }
      }
      .aimText(.secondary).lineLimit(1).fixedSize(horizontal: true, vertical: false)
      .frame(width: Self.resetWidth, alignment: .trailing)
      .layoutPriority(1)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct OverviewHeader: View {
  let account: AccountRecord
  let accounts: [AccountRecord]
  @ObservedObject var model: AccountViewModel
  let now: Date
  let hideEmails: Bool
  let showsUsed: Bool
  let focus: (UUID) -> Void
  let delete: () -> Void

  private var providerID: ProviderID { account.identity.providerID }
  private var name: String { EmailPrivacy.display(account.identity.accountLabel, hide: hideEmails) }
  private var isDefault: Bool { model.status?.isDefault(account) == true }

  var body: some View {
    let windows = AccountUsageSummary.windows(for: account, model: model)
    AIMPanel {
      HStack(alignment: .center, spacing: AIMTheme.sectionSpacing) {
        ProviderMark(providerID: providerID, size: 32)
        VStack(alignment: .leading, spacing: 2) {
          accountMenu
          HStack(spacing: AIMTheme.rowSpacing) {
            Text(providerID.guiName).aimText(.secondary)
            ProviderStatusDot(entry: model.providerStatus[providerID])
            statusBadge
          }
        }
        Spacer(minLength: AIMTheme.sectionSpacing)
        if model.needsSignIn(account) {
          SignInButton(account: account, model: model)
        } else {
          DefaultAccountButton(isDefault: isDefault, disabled: model.isBusy || !account.canSwitchDefault) {
            Task { await model.switchDefault(to: account.id) }
          }
        }
        if !account.usesGenericDetail {
          Button {
            Task { await model.openAccount(account.id) }
          } label: {
            Text(isDefault
              ? AccountActionCopy.open(providerID) : AccountActionCopy.useAndOpen(providerID))
          }
          .buttonStyle(.bordered)
          .disabled(model.isBusy)
        }
        AccountMoreMenu(account: account, model: model, delete: delete)
      }
      .aimRow()
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Focused account")
      Divider()
      if windows.isEmpty {
        Text(UsagePresentation.emptyUsageTitle(
          failure: model.usageError(for: account.id) ?? model.providerUsage[account.id]?.error,
          needsSignIn: account.verification.state == .needsSignIn))
          .aimText(.secondary).aimRow()
      } else {
        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
          if index > 0 { Divider() }
          OverviewWindowRow(window: window, showsUsed: showsUsed, now: now).aimRow()
        }
      }
    }
  }

  private var accountMenu: some View {
    Menu {
      ForEach(accounts) { item in
        Button {
          focus(item.id)
        } label: {
          let title = "\(EmailPrivacy.display(item.identity.accountLabel, hide: hideEmails)) · \(item.identity.providerID.guiName)"
          if item.id == account.id {
            Label(title, systemImage: AIMIcon.Name.check.symbol)
          } else {
            Text(title)
          }
        }
      }
    } label: {
      // A button-style menu draws its label as ordinary text, so the Title role applies.
      HStack(spacing: 4) {
        Text(name).aimText(.title).lineLimit(1)
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

// MARK: - Accounts table

private struct OverviewAccountsCard: View {
  let accounts: [AccountRecord]
  let total: Int
  let query: String
  @ObservedObject var model: AccountViewModel
  let focusedID: UUID
  let now: Date
  let hideEmails: Bool
  let showsUsed: Bool
  let focus: (UUID) -> Void
  let delete: (AccountRecord) -> Void

  /// Row and header height of the native table at its default size; the container sizes the table
  /// to its rows.
  static let rowHeight: CGFloat = 38
  static let headerHeight: CGFloat = 30

  var body: some View {
    AIMPanel(
      title: "Accounts",
      accessory: AnyView(
        Text("\(total) \(total == 1 ? "account" : "accounts")").aimText(.secondary))
    ) {
      if accounts.isEmpty {
        Text(query.isEmpty ? "No accounts yet." : "No accounts match “\(query)”.")
          .aimText(.secondary).aimRow()
      } else {
        Table(accounts, selection: Binding(
          get: { focusedID }, set: { if let id = $0 { focus(id) } })
        ) {
          TableColumn("Account") { account in
            AccountCell(
              account: account, hideEmails: hideEmails,
              providerStatus: model.providerStatus[account.identity.providerID])
          }
          .width(min: 180, ideal: 260)
          TableColumn("Usage") { account in
            let window = AccountUsageSummary.windows(for: account, model: model).first
            HStack(spacing: AIMTheme.rowSpacing) {
              UsageBar(usedPercent: window?.usedPercent, showsUsed: showsUsed)
                .frame(width: 90)
              Text(OverviewFormat.percent(window, showsUsed: showsUsed))
                .aimText(.body).monospacedDigit().frame(width: 42, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
          }
          .width(min: 140, ideal: 150)
          TableColumn("Resets") { account in
            let window = AccountUsageSummary.windows(for: account, model: model).first
            Text(window?.resetsAt.map { OverviewFormat.compactReset($0, now: now, usedPercent: window?.usedPercent) } ?? "–")
              .aimText(.secondary).lineLimit(1)
          }
          .width(min: 70, ideal: 90)
          TableColumn("") { account in
            switch OverviewFormat.rowAction(for: account, model: model) {
            case .isDefault:
              Badge(text: "Default")
            case .signIn:
              SignInButton(account: account, model: model, prominent: false)
            case .switchTo:
              Button("Switch") { Task { await model.switchDefault(to: account.id) } }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || !account.canSwitchDefault)
            }
          }
          .width(min: 70, ideal: 80)
        }
        .tableStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .contextMenu(forSelectionType: UUID.self) { ids in
          if let id = ids.first, let account = accounts.first(where: { $0.id == id }) {
            AccountMenuItems(account: account, model: model) { delete(account) }
          }
        }
        .frame(height: CGFloat(accounts.count) * Self.rowHeight + Self.headerHeight)
        .accessibilityLabel("Accounts")
      }
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
        Text(EmailPrivacy.display(account.identity.accountLabel, hide: hideEmails))
          .aimText(.body).lineLimit(1).truncationMode(.middle)
        HStack(spacing: 5) {
          Text(account.identity.providerID.guiName).aimText(.secondary).lineLimit(1)
          ProviderStatusDot(entry: providerStatus, size: 6)
        }
      }
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
