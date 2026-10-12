import AppKit
import AIManagerCore
import SwiftUI

/// Pure rules of the popover: labels, bar colors, countdown text, geometry, keyboard order.
/// Kept apart from the views so the contract can test them without a window.
enum MenuBarPresentation {
  static let rowPaddingH: CGFloat = 8
  static let rowPaddingV: CGFloat = 6
  static let tileSize: CGFloat = 16
  static let tileSpacing: CGFloat = 8
  static let headerHeight: CGFloat = 18
  static let groupHeaderHeight: CGFloat = 26
  static let accountGap: CGFloat = 8
  static let groupGap: CGFloat = 12
  static let expandedHeight: CGFloat = 40
  static let lineGap: CGFloat = 4
  static let lineHeight: CGFloat = 18
  static let signInHeight: CGFloat = 24
  static let lineSpacing: CGFloat = 0
  static let captionHeight: CGFloat = 14
  static let dividerHeight: CGFloat = 0
  static let labelWidth: CGFloat = 56
  static let percentWidth: CGFloat = 36
  static let resetWidth: CGFloat = 64

  static func groups(_ accounts: [MenuBarAccountSnapshot]) -> [[MenuBarAccountSnapshot]] {
    var groups: [[MenuBarAccountSnapshot]] = []
    for account in accounts.filter(\.showsUsage) {
      if let index = groups.firstIndex(where: { $0.first?.providerID == account.providerID }) {
        groups[index].append(account)
      } else { groups.append([account]) }
    }
    return groups
  }

  static func listHeight(_ accounts: [MenuBarAccountSnapshot], expandedID: UUID? = nil) -> CGFloat {
    let groups = groups(accounts)
    guard !groups.isEmpty else { return 0 }
    return 24 + groups.reduce(CGFloat.zero) { height, group in
      height + groupHeaderHeight + group.map(rowHeight).reduce(0, +)
        + CGFloat(group.count - 1) * accountGap
    } + CGFloat(groups.count - 1) * groupGap
      + (groups.flatMap { $0 }.contains(where: { $0.id == expandedID }) ? expandedHeight : 0)
  }

  struct Line: Equatable {
    /// Window name in the fixed first column.
    let label: String?
    /// Nil is an unknown value: an empty track and an em dash.
    let used: Int?
    let resetsAt: Date?
    let minutes: Int?
    /// Amount text for balance-only accounts, shown instead of a bar.
    let balance: String?
  }

  /// A shared short name for service windows.
  static func windowLabel(minutes: Int?, title: String) -> String {
    switch minutes {
    case 300: "Session"
    case 10_080: "Weekly"
    default: title
    }
  }

  enum Content: Equatable { case signIn, lines([Line]) }

  static func content(for account: MenuBarAccountSnapshot) -> Content {
    guard account.isVerified else { return .signIn }
    guard let usage = account.usage else {
      return .lines([Line(label: nil, used: nil, resetsAt: nil, minutes: nil, balance: nil)])
    }
    if let providerWindows = usage.providerWindows, !providerWindows.isEmpty {
      return .lines(providerWindows.map {
        Line(label: windowLabel(minutes: $0.minutes, title: $0.title), used: $0.used,
          resetsAt: $0.resetsAt, minutes: $0.minutes, balance: nil)
      })
    }
    var windows: [(title: String, used: Int, reset: Date?, minutes: Int?)] = []
    if let used = usage.usedPercentage {
      windows.append((usage.primaryLabel, used, usage.resetsAt, usage.primaryMinutes))
    }
    if let used = usage.secondaryUsedPercentage {
      windows.append((usage.secondaryLabel, used, usage.secondaryResetsAt, usage.secondaryMinutes))
    }
    if windows.isEmpty {
      return .lines([Line(
        label: nil, used: nil, resetsAt: nil, minutes: nil, balance: usage.balanceText)])
    }
    return .lines(windows.map {
      Line(
        label: windowLabel(minutes: $0.minutes, title: $0.title),
        used: $0.used, resetsAt: $0.reset, minutes: $0.minutes, balance: nil)
    })
  }

  static func hasTokenCaption(_ account: MenuBarAccountSnapshot) -> Bool {
    guard account.isVerified, let usage = account.usage else { return false }
    return usage.tokens != nil && usage.tokenPeriodLabel != nil
      && (usage.usedPercentage != nil || usage.secondaryUsedPercentage != nil)
  }

  static func lineCount(_ account: MenuBarAccountSnapshot) -> Int {
    switch content(for: account) {
    case .signIn: 1
    case .lines(let lines): lines.count
    }
  }

  /// Height of one account row, hairline included. Zero when the account is hidden.
  static func rowHeight(_ account: MenuBarAccountSnapshot) -> CGFloat {
    guard account.showsUsage else { return 0 }
    let count = CGFloat(lineCount(account))
    var height = rowPaddingV * 2 + headerHeight + lineGap + count * lineHeight
      + (count - 1) * lineSpacing + dividerHeight
    if !account.isVerified { height += signInHeight - lineHeight }
    if hasTokenCaption(account) { height += lineGap + captionHeight }
    return height
  }

  /// "6d 8h", "1h 45m", "12m" as a countdown, or the exact clock time such as "5:30 PM" and
  /// "Thu 5:30 PM", following the Countdown or Exact-time setting.
  static func resetText(
    _ reset: Date, now: Date, exact: Bool, hourFormat: HourFormat = ResetDisplay.hourFormat(),
    used: Int? = nil
  ) -> String {
    guard reset > now else { return ResetDisplay.pastText(usedPercent: used.map(Double.init)) }
    if exact {
      let text = ResetDisplay.exactText(reset, now: now, hourFormat: hourFormat)
      return text.hasPrefix("Resets ") ? String(text.dropFirst(7)) : text
    }
    let minutes = Int(reset.timeIntervalSince(now) / 60)
    if minutes < 1 { return "<1m" }
    let days = minutes / 1_440, hours = (minutes % 1_440) / 60, rest = minutes % 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(rest)m" }
    return "\(rest)m"
  }

  /// Arrow-key order: the neighbor of `id`, clamped at both ends. Without a start, down picks
  /// the first row and up the last.
  static func neighbor(of id: UUID?, in ids: [UUID], step: Int) -> UUID? {
    guard !ids.isEmpty else { return nil }
    guard let id, let index = ids.firstIndex(of: id) else { return step > 0 ? ids.first : ids.last }
    return ids[min(max(index + step, 0), ids.count - 1)]
  }

  static func providerLabel(_ account: MenuBarAccountSnapshot) -> String {
    account.providerID.guiName
  }

  static func openToolTitle(_ account: MenuBarAccountSnapshot) -> String {
    "Open \(account.providerID == .codex ? "Codex" : account.providerID.displayName)"
  }

  static func tokenCaption(_ usage: MenuBarUsageSnapshot) -> String? {
    guard let tokens = usage.tokens, let period = usage.tokenPeriodLabel else { return nil }
    var text = "\(tokens.formatted(.number.notation(.compactName))) tokens \(period)"
    if let price = usage.apiPrice {
      text += " · ≈\(price.inputEquivalent(for: tokens).formatted(.currency(code: "USD").precision(.fractionLength(0)))) API"
    }
    return text
  }

  static func accessibilityLabel(
    _ account: MenuBarAccountSnapshot, showsUsed: Bool, now: Date, exact: Bool
  ) -> String {
    var parts = [account.identity, providerLabel(account)]
    if account.isActive { parts.append("Default") }
    switch content(for: account) {
    case .signIn:
      parts.append("Needs sign in")
    case .lines(let lines):
      for line in lines {
        let value = line.balance.map { "Balance \($0)" }
          ?? line.used.map { UsagePercentagePreferences.label(forUsed: $0, showsUsed: showsUsed) }
          ?? "Usage unknown"
        parts.append([line.label, value].compactMap { $0 }.joined(separator: " "))
      }
      for line in lines {
        if let reset = line.resetsAt {
          let text = resetText(reset, now: now, exact: exact, used: line.used)
          parts.append(reset > now ? "Resets " + text : text)
        }
      }
    }
    return parts.joined(separator: ", ")
  }
}

struct MenuBarRow: View {
  let account: MenuBarAccountSnapshot
  let now: Date
  let showsUsed: Bool
  let isSwitching: Bool
  let isFocused: Bool
  let error: String?
  let store: MenuBarPopoverStore

  @AppStorage(ResetDisplay.exactKey) private var exact = false
  @AppStorage(ResetDisplay.hourFormatKey) private var hourFormat = HourFormat.auto.rawValue
  @State private var hovered = false

  private typealias P = MenuBarPresentation

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: P.lineGap) {
        header
        content
        if P.hasTokenCaption(account), let text = account.usage.flatMap(P.tokenCaption) {
          Text(text)
            .aimText(.secondary).monospacedDigit().lineLimit(1)
            .frame(height: P.captionHeight)
            .padding(.leading, P.tileSize + P.tileSpacing)
        }
      }
      .padding(.horizontal, P.rowPaddingH)
      .padding(.vertical, P.rowPaddingV)
      if store.expandedAccountID == account.id {
        HStack(spacing: 8) {
          Button("Switch") { store.select(account) }.disabled(!store.canSwitch(account))
          if account.supportsLaunch, store.actions.openTool != nil {
            Button(P.openToolTitle(account)) { store.openTool(account) }
          }
          Spacer(minLength: 0)
        }
        .buttonStyle(MenuBarButtonStyle()).focusEffectDisabled()
        .padding(.leading, P.rowPaddingH + P.tileSize + P.tileSpacing)
        .padding(.trailing, P.rowPaddingH)
        .frame(height: P.expandedHeight)
      }
    }
    .frame(height: P.rowHeight(account) + (store.expandedAccountID == account.id ? P.expandedHeight : 0))
    .uiLint(.align("menuBarRows", .start), .align("menuBarRowsEnd", .end))
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(isFocused || store.expandedAccountID == account.id ? Color.accentColor.opacity(0.12) : hovered ? Color.primary.opacity(0.07) : .clear)
        .padding(5)
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .onTapGesture { store.toggleExpanded(account) }
    .contextMenu { menu }
    .accessibilityElement(children: store.expandedAccountID == account.id || !account.isVerified ? .contain : .ignore)
    .accessibilityLabel(P.accessibilityLabel(account, showsUsed: showsUsed, now: now, exact: exact))
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Shows account actions")
    .accessibilityAction(named: "Show actions") { store.toggleExpanded(account) }
    .accessibilityAction(named: "Switch") { store.select(account) }
  }

  private var header: some View {
    HStack(spacing: P.tileSpacing) {
      Text(account.identity)
        .aimText(.body)
        .lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(account.identity)
      trailing
        .frame(width: 18, height: P.headerHeight)
    }
    .padding(.leading, P.tileSize + P.tileSpacing)
    .frame(height: P.headerHeight)
  }

  @ViewBuilder private var trailing: some View {
    if isSwitching {
      ProgressView().controlSize(.small).accessibilityLabel("Switching account")
    } else {
      HStack(spacing: 6) {
        if let error {
          Button { store.copy(error) } label: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
          }
          .buttonStyle(.plain)
          .focusEffectDisabled()
          .help("\(error) Click to copy.")
          .accessibilityLabel("Copy account error")
        } else if account.isActive {
          Image(systemName: "checkmark").aimFont(.secondary)
            .foregroundStyle(Color.accentColor)
            .help("Default for \(P.providerLabel(account))")
        }
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch P.content(for: account) {
    case .signIn:
      Button("Sign in") { Task { await store.signIn(accountID: account.id) } }
        .buttonStyle(MenuBarButtonStyle())
        .focusEffectDisabled()
        .frame(height: P.signInHeight)
        .padding(.leading, P.tileSize + P.tileSpacing)
        .help("Open Switch to sign in")
    case .lines(let lines):
      VStack(spacing: P.lineSpacing) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in lineView(line) }
      }
      .padding(.leading, P.tileSize + P.tileSpacing)
    }
  }

  private func lineView(_ line: P.Line) -> some View {
    HStack(spacing: 6) {
      if let label = line.label {
        Text(label).aimText(.secondary).lineLimit(1).frame(width: P.labelWidth, alignment: .leading)
      }
      if let balance = line.balance {
        Text("Balance").aimText(.secondary)
        Spacer(minLength: 0)
        Text(balance).aimText(.secondary).monospacedDigit()
      } else {
        UsageBar(usedPercent: line.used.map(Double.init), showsUsed: showsUsed,
          providerID: account.providerID)
        Text(line.used.map {
          "\(UsagePercentagePreferences.displayedPercentage(forUsed: $0, showsUsed: showsUsed))%"
        } ?? "—")
          .aimText(.secondary).monospacedDigit()
          .frame(width: P.percentWidth, alignment: .trailing)
        Text(line.resetsAt.map {
          P.resetText($0, now: now, exact: exact,
            hourFormat: HourFormat(rawValue: hourFormat) ?? .auto, used: line.used)
        } ?? "")
          .aimText(.secondary).monospacedDigit().lineLimit(1)
          .frame(width: P.resetWidth, alignment: .trailing)
      }
    }
    .frame(height: P.lineHeight)
  }

  @ViewBuilder private var menu: some View {
    Button("Switch") { store.select(account) }.disabled(!store.canSwitch(account))
    if account.supportsLaunch, store.actions.openTool != nil {
      Button(P.openToolTitle(account)) { store.openTool(account) }
    }
    Button("Refresh") { Task { await store.refresh(account) } }
      .disabled(!account.supportsUsageRefresh || store.isRefreshingUsage)
    Divider()
    Button("Copy name") { store.copy(account.identity) }
  }
}

struct MenuBarFooter: View {
  @ObservedObject var store: MenuBarPopoverStore
  private typealias P = MenuBarPresentation
  /// The icon box of the square footer buttons; the large control height gives the rest.
  private static let iconSide: CGFloat = 18

  var body: some View {
    HStack(spacing: 8) {
      Button {
        Task { await store.refreshUsage() }
      } label: {
        Group {
          if store.isRefreshingUsage {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .frame(width: Self.iconSide, height: Self.iconSide)
      }
      .buttonStyle(MenuBarButtonStyle())
      .focusEffectDisabled()
      .keyboardShortcut("r", modifiers: .command)
      .disabled(!store.canRefreshUsage)
      .help(refreshHelp)
      .accessibilityLabel("Refresh usage")

      Button {
        store.openSettings()
      } label: {
        Image(systemName: "gearshape")
          .frame(width: Self.iconSide, height: Self.iconSide)
      }
      .buttonStyle(MenuBarButtonStyle())
      .focusEffectDisabled()
      .help("Settings")
      .accessibilityLabel("Settings")

      Spacer(minLength: 8)

      Button {
        store.openMainWindow()
      } label: {
        HStack(spacing: 8) {
          Text("Open Switch").aimText(.body)
          Text("⌘O").aimText(.secondary)
        }
      }
      .buttonStyle(MenuBarButtonStyle())
      .focusEffectDisabled()
      .keyboardShortcut("o", modifiers: .command)
      .help("Open Switch (⌘O)")
    }
    .padding(.horizontal, 12)
    .frame(height: MenuBarPopover.footerHeight)
    .overlay(alignment: .top) {
      if store.rows.isEmpty { Divider() }
    }
  }

  private var refreshHelp: String {
    guard let at = store.snapshot.lastRefreshedAt else { return "Refresh usage (⌘R)" }
    return "Refresh usage (⌘R). Refreshed \(at.formatted(.relative(presentation: .numeric)))."
  }
}

/// Flat fills keep footer and sign-in controls quiet in both appearances.
private struct MenuBarButtonStyle: ButtonStyle {
  var height: CGFloat = 24
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .aimText(.body)
      .padding(.horizontal, 6)
      .frame(height: height)
      .background(RoundedRectangle(cornerRadius: 5).fill(
        isFocused ? Color.accentColor.opacity(0.16)
          : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.05)))
      .contentShape(RoundedRectangle(cornerRadius: 5))
      .opacity(isEnabled ? 1 : 0.45)
      .uiLint(.control)
  }
}
