import AIManagerCore
import AppKit
import SwiftUI

// The toolbar search, beyond the Accounts list: result cards for the other kind (Settings on
// Accounts, Accounts on Settings), and the drop-down under the field on the other pages.

/// Motion of the search: rows and cards fade 0.18 s; the drop-down fades in 0.16 s and out 0.12 s.
enum AIMSearchMotion {
  static let filter = Animation.easeOut(duration: 0.18)
  static let panelIn = Animation.easeOut(duration: 0.16)
  static let panelOut = Animation.easeOut(duration: 0.12)
}

private struct AIMPageFadeKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
  /// Rows and cards of a page fade in and out when this changes (the search text).
  var aimPageFadeKey: String {
    get { self[AIMPageFadeKey.self] }
    set { self[AIMPageFadeKey.self] = newValue }
  }
}

enum AppSearch {
  /// The pages whose search shows the drop-down. Accounts and Settings filter their own content.
  static let dropdownPages: Set<AIManagerPage> = [.overview, .maintenance, .conversations]
  /// Offscreen preview runs have no key window, so the field never reports focus: `--search-open` keeps the panel up.
  static var keepsDropdownOpen: Bool {
    #if AI_MANAGER_PREVIEW
    CommandLine.arguments.contains("--search-open")
    #else
    false
    #endif
  }
  /// Where the drop-down is, in window coordinates from the top left, while it shows. The page
  /// views are AppKit subviews that sit above SwiftUI's overlay in hit testing, so they pass a click
  /// at this rect on (`AIMVisitedPageHost.Container.hitTest`) and the drop-down's rows get it.
  @MainActor static var panelFrame: CGRect?

  @MainActor static func isOverDropdown(windowPoint point: NSPoint, in window: NSWindow?) -> Bool {
    guard let panel = panelFrame, let height = window?.contentView?.bounds.height else { return false }
    return panel.contains(CGPoint(x: point.x, y: height - point.y))
  }
  static let matchLimit = 5
  static let dropdownLimit = 4
  /// The drop-down starts this far under the field.
  static let dropdownGap: CGFloat = 4
  /// The field is centered in the top bar, so its bottom edge is here.
  static var fieldBottom: CGFloat { (AIMTheme.topBarHeight + AIMTheme.controlHeight) / 2 }

  static func prompt(for page: AIManagerPage) -> String {
    switch page {
    case .accounts: AIManagerToolbar.searchPrompt
    case .settings: "Search settings…"
    default: "Search accounts and settings…"
    }
  }

  /// The VoiceOver name follows the prompt.
  static func label(for page: AIManagerPage) -> String { String(prompt(for: page).dropLast()) }

  static func isBlank(_ query: String) -> Bool { SettingsSearch.terms(query).isEmpty }

  /// Shows a page through the window's own navigation, so the search text stays.
  static func open(_ page: AIManagerPage) {
    NotificationCenter.default.post(name: AIManagerNavigation.request, object: page)
  }

  @MainActor static func open(_ account: AccountRecord, in model: AccountViewModel) {
    model.selectedAccountID = account.id
    open(.accounts)
  }

  @MainActor static func accounts(matching query: String, in model: AccountViewModel) -> [AccountRecord] {
    isBlank(query) ? [] : AccountSearch.filter(model.status?.accounts ?? [], query: query)
  }
}

// MARK: - Result cards

/// "2 matches", the Secondary count at the right of a result card's title row.
private struct SearchCount: View {
  let count: Int
  var body: some View { Text("\(count) \(count == 1 ? "match" : "matches")").aimText(.secondary) }
}

/// One 36 pt row of a result card: the content, then a chevron at the trailing edge. The pointer
/// fills the whole row (6 in from the card edges) like the Accounts table.
private struct SearchCardRow<Content: View>: View {
  let label: String
  let action: () -> Void
  @ViewBuilder var content: Content
  @State private var hovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous)
    Button(action: action) {
      HStack(spacing: 8) {
        content
        Spacer(minLength: 8)
        Image(systemName: AIMIcon.Name.chevron.symbol).aimFont(.secondary).foregroundStyle(.secondary)
      }
      .padding(.horizontal, AIMTheme.cardInset)
      .frame(height: AIMTheme.rowHeight)
      .frame(maxWidth: .infinity)
      .background {
        shape.fill(AIMTheme.rowHover).opacity(hovering ? 1 : 0)
          .padding(.horizontal, 6).padding(.vertical, AIMTheme.highlightInset)
          .animation(AIMMotion.fade(AIMMotion.hover), value: hovering)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 && !AIMScrollBarModel.isScrolling }
    .accessibilityLabel(label)
  }
}

/// Up to five accounts that match the search, on the Settings page.
struct SearchAccountsCard: View {
  let accounts: [AccountRecord]
  let open: (AccountRecord) -> Void
  // The names follow these choices, so the card redraws when one changes.
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  @AppStorage(EmailPrivacy.privacyModeKey) private var privacyMode = false
  @AppStorage(EmailPrivacy.domainsKey) private var showEmailDomains = false

  var body: some View {
    let shown = Array(accounts.prefix(AppSearch.matchLimit))
    AIMCard(title: "Matching accounts", bottomInset: 0, accessory: { SearchCount(count: accounts.count) }) {
      VStack(spacing: 0) {
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, account in
          if index > 0 { AIMRowSeparator() }
          SearchCardRow(
            label: "\(account.identity.accountLabel), \(account.identity.providerID.guiName)",
            action: { open(account) }
          ) {
            ProviderMark(providerID: account.identity.providerID, size: 16)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(account.identity.accountLabel).aimText(.body).lineLimit(1)
              Text(account.identity.providerID.guiName).aimText(.secondary).lineLimit(1)
            }
          }
        }
      }
      .padding(.bottom, AIMTheme.tableEndInset)
    }
  }
}

/// Up to five Settings rows that match the search, on the Accounts page. A click opens Settings.
struct SearchSettingsCard: View {
  let entries: [SettingsSearch.Entry]

  var body: some View {
    let shown = Array(entries.prefix(AppSearch.matchLimit))
    AIMCard(title: "Matching settings", bottomInset: 0, accessory: { SearchCount(count: entries.count) }) {
      VStack(spacing: 0) {
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
          if index > 0 { AIMRowSeparator() }
          SearchCardRow(
            label: "\(entry.title), \(entry.section)", action: { AppSearch.open(.settings) }
          ) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(entry.title).aimText(.body).lineLimit(1)
              Text("· \(entry.section)").aimText(.secondary).lineLimit(1)
            }
          }
        }
      }
      .padding(.bottom, AIMTheme.tableEndInset)
    }
  }
}

/// The Accounts page: fewer than three accounts match, so the best Settings matches follow the table.
struct AccountsSettingsMatches: View {
  let query: String
  let accountCount: Int

  var body: some View {
    let entries = accountCount < 3 && !AppSearch.isBlank(query) ? SettingsSearch.search(query) : []
    if !entries.isEmpty {
      SearchSettingsCard(entries: entries).transition(.opacity)
    }
  }
}

/// The end of the Settings page: when fewer than three settings match, the matching accounts, or
/// one empty card when nothing matches at all.
struct SettingsSearchCards: View {
  @ObservedObject var model: AccountViewModel
  let query: String

  var body: some View {
    if !AppSearch.isBlank(query) {
      let settingCount = SettingsSearch.search(query).count
      let accounts = AppSearch.accounts(matching: query, in: model)
      if settingCount < 3 {
        if settingCount == 0 && accounts.isEmpty {
          SearchEmptyCard(query: query).transition(.opacity)
        } else {
          if settingCount == 0 {
            AIMCard {
              Text("No settings match “\(query.trimmingCharacters(in: .whitespaces))”.")
                .aimText(.secondary).lineLimit(1)
                .padding(.horizontal, AIMTheme.cardInset)
                .frame(maxWidth: .infinity, minHeight: AIMTheme.rowHeight, alignment: .leading)
            }
            .transition(.opacity)
          }
          if !accounts.isEmpty {
            SearchAccountsCard(accounts: accounts) { AppSearch.open($0, in: model) }
              .transition(.opacity)
          }
        }
      }
    }
  }
}

/// Nothing matches a setting or an account.
private struct SearchEmptyCard: View {
  let query: String

  var body: some View {
    AIMCard {
      VStack(spacing: 6) {
        AIMIcon(name: .search).aimText(.section).foregroundStyle(.secondary)
        Text("No results for “\(query.trimmingCharacters(in: .whitespaces))”")
          .aimText(.body).lineLimit(1)
        Text("Try a setting such as Appearance, or an account name.").aimText(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 24)
      .padding(.horizontal, AIMTheme.cardInset)
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Drop-down

enum AppSearchRow: Hashable {
  case account(UUID)
  case setting(String)
  /// "Show all N in Accounts".
  case showAll(Int)
}

/// What the drop-down lists: up to four accounts (and a "Show all" row after them), then up to four
/// settings. `rows` is the keyboard order.
struct AppSearchList {
  let accounts: [AccountRecord]
  let settings: [SettingsSearch.Entry]

  var accountRows: [AppSearchRow] {
    var rows = accounts.prefix(AppSearch.dropdownLimit).map { AppSearchRow.account($0.id) }
    if accounts.count > AppSearch.dropdownLimit { rows.append(.showAll(accounts.count)) }
    return rows
  }
  var settingRows: [AppSearchRow] { settings.prefix(AppSearch.dropdownLimit).map { .setting($0.id) } }
  var rows: [AppSearchRow] { accountRows + settingRows }

  func account(_ id: UUID) -> AccountRecord? { accounts.first { $0.id == id } }
  func setting(_ id: String) -> SettingsSearch.Entry? { settings.first { $0.id == id } }
}

/// The solid panel under the search field on Overview, Maintenance, and Conversations. The same
/// 300 pt width as the field, 6 pt inside its edge, rows 28 pt. The highlight is neutral gray in Dark Mode.
struct AppSearchDropdown: View {
  static let rowHeight: CGFloat = 28
  /// A solid surface close to the system menu tone in Dark Mode; no wallpaper shows through.
  static let surface = AIMTheme.dynamic(
    light: .white, dark: NSColor(srgbRed: 0.15, green: 0.15, blue: 0.157, alpha: 1))

  let list: AppSearchList
  let highlight: Int
  let hover: (Int) -> Void
  let choose: (AppSearchRow) -> Void
  @Environment(\.colorScheme) private var scheme
  // The names follow these choices, so the panel redraws when one changes.
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  @AppStorage(EmailPrivacy.privacyModeKey) private var privacyMode = false
  @AppStorage(EmailPrivacy.domainsKey) private var showEmailDomains = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    let accountRows = list.accountRows
    VStack(alignment: .leading, spacing: 0) {
      if list.rows.isEmpty {
        Text("No accounts or settings match").aimText(.secondary).lineLimit(1)
          .padding(.horizontal, 8).frame(height: Self.rowHeight)
      }
      if !accountRows.isEmpty {
        header("Accounts")
        ForEach(Array(accountRows.enumerated()), id: \.element) { index, row in line(row, index: index) }
      }
      let settingRows = list.settingRows
      if !settingRows.isEmpty {
        header("Settings").padding(.top, accountRows.isEmpty ? 0 : 6)
        ForEach(Array(settingRows.enumerated()), id: \.element) { index, row in
          line(row, index: accountRows.count + index)
        }
      }
    }
    .padding(6)
    .frame(width: AIMTheme.toolbarSearchWidth, alignment: .leading)
    .background(Self.surface, in: shape)
    .aimBorder(AIMTheme.hairline, in: shape)
    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.16), radius: 14, x: 0, y: 6)
    // The AppKit page under the panel would take the click first; it asks for this rect (see AppSearch.panelFrame).
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { AppSearch.panelFrame = $0 }
    .onDisappear { AppSearch.panelFrame = nil }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Search results")
  }

  private func header(_ title: String) -> some View {
    Text(title).aimText(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
      .padding(.horizontal, 8).frame(height: 22, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder private func line(_ row: AppSearchRow, index: Int) -> some View {
    let selected = index == highlight
    let shape = RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous)
    Button { choose(row) } label: {
      HStack(spacing: 8) { content(row) }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.rowHeight)
        .background(shape.fill(selected ? AIMTheme.rowHighlight : Color.clear))
        .contentShape(shape)
    }
    .buttonStyle(.plain)
    .onHover { if $0 { hover(index) } }
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder private func content(_ row: AppSearchRow) -> some View {
    switch row {
    case .account(let id):
      if let account = list.account(id) {
        ProviderMark(providerID: account.identity.providerID, size: 16)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(account.identity.accountLabel).aimText(.body).lineLimit(1)
          Text(account.identity.providerID.guiName).aimText(.secondary).lineLimit(1)
        }
      }
    case .setting(let id):
      if let entry = list.setting(id) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(entry.title).aimText(.body).lineLimit(1)
          Text("· \(entry.section)").aimText(.secondary).lineLimit(1)
        }
      }
    case .showAll(let count):
      Text("Show all \(count) in Accounts").aimText(.secondary).lineLimit(1)
    }
  }
}
