import AppKit
import AIManagerCore
import SwiftUI

/// Pure rules of the popover: labels, bar colors, countdown text, geometry, keyboard order.
/// Kept apart from the views so the contract can test them without a window.
enum MenuBarPresentation {
  /// The one inset from the popover edge: group headers, rows, separators, and the footer.
  static let inset: CGFloat = 12
  static let rowPaddingH: CGFloat = inset
  /// The list's scroll bar gutter lies inside the 12 pt inset on the right, so the right inset
  /// of the content is what remains of it.
  static let trailingInset: CGFloat = inset - AIMScroller.gutter
  static let rowPaddingV: CGFloat = 6
  /// How far the hover fill reaches above the first line of a row: midway between the earlier
  /// 10 pt and 2 pt. The fill then starts at the row's own top edge, never in the group header.
  static let hoverReach: CGFloat = 6
  /// Popover text that is not primary: the system secondary label color, never tertiary.
  static let secondaryInk = Color(nsColor: .secondaryLabelColor)
  static let tileSize: CGFloat = 16
  static let tileSpacing: CGFloat = 8
  static let headerHeight: CGFloat = 18
  static let groupHeaderHeight: CGFloat = 26
  static let accountGap: CGFloat = 8
  static let groupGap: CGFloat = 12
  static let expandedHeight: CGFloat = 40
  static let rowHighlight = Color.primary.opacity(0.06)
  static let rowHover = Color.primary.opacity(0.04)
  static let lineGap: CGFloat = 4
  static let lineHeight: CGFloat = 18
  static let signInHeight: CGFloat = 24
  static let lineSpacing: CGFloat = 0
  static let captionHeight: CGFloat = 14
  static let dividerHeight: CGFloat = 0
  static let labelWidth: CGFloat = 56
  static let percentWidth: CGFloat = 36
  static let resetWidth: CGFloat = 64
  static let separatorOpacity = 0.5
  static let separatorFade: CGFloat = 0.12
  static let hoverOverhang: CGFloat = 4
  static let signInSubtitle = "Sign in again to see usage"
  static let allowAccessSubtitle = "Allow access to see usage"

  enum FooterItem { case openSwitch, refresh, quit, settings }
  /// The footer from left to right: Open Switch, then the icon buttons Refresh, Quit, Settings.
  static let footerOrder: [FooterItem] = [.openSwitch, .refresh, .quit, .settings]

  /// Where every account's text starts, after the leading check column (a tile wide).
  static var textIndent: CGFloat { tileSize + tileSpacing }

  /// Gap between the Sign in button and the row's bottom. Collapsed, the button sits on the
  /// subtitle line (the row's bottom padding); expanded, it sits level with the action buttons
  /// (24 pt buttons centered in a 40 pt band).
  static func signInBottomInset(expansion: CGFloat) -> CGFloat {
    rowPaddingV + ((expandedHeight - signInHeight) / 2 - rowPaddingV) * expansion
  }

  static func groups(_ accounts: [MenuBarAccountSnapshot]) -> [[MenuBarAccountSnapshot]] {
    var groups: [[MenuBarAccountSnapshot]] = []
    for account in accounts.filter(\.showsUsage) {
      if let index = groups.firstIndex(where: { $0.first?.providerID == account.providerID }) {
        groups[index].append(account)
      } else { groups.append([account]) }
    }
    return groups
  }

  static func listHeight(_ accounts: [MenuBarAccountSnapshot], expandedID: UUID? = nil,
                        hasOpenTool: Bool = true) -> CGFloat {
    let groups = groups(accounts)
    guard !groups.isEmpty else { return 0 }
    return 24 + groups.reduce(CGFloat.zero) { height, group in
      height + groupHeaderHeight + group.map(rowHeight).reduce(0, +)
        + CGFloat(group.count - 1) * accountGap
    } + CGFloat(groups.count - 1) * groupGap
      + groups.flatMap { $0 }.filter { $0.id == expandedID }
        .map { expansionHeight($0, hasOpenTool: hasOpenTool) }.reduce(0, +)
  }

  static func actionHeight(_ account: MenuBarAccountSnapshot, hasOpenTool: Bool = true) -> CGFloat {
    !account.isVerified || showsSwitch(account) || (account.supportsLaunch && hasOpenTool) ? expandedHeight : 0
  }

  static func canExpand(_ account: MenuBarAccountSnapshot, hasOpenTool: Bool = true) -> Bool {
    account.showsUsage && (actionHeight(account, hasOpenTool: hasOpenTool) > 0
      || lines(for: account, expanded: true).count > lines(for: account).count)
  }

  static func expansionHeight(_ account: MenuBarAccountSnapshot, hasOpenTool: Bool = true) -> CGFloat {
    guard canExpand(account, hasOpenTool: hasOpenTool) else { return 0 }
    let extra = max(0, lines(for: account, expanded: true).count - lines(for: account).count)
    return actionHeight(account, hasOpenTool: hasOpenTool) + CGFloat(extra) * lineHeight
  }

  struct Line: Equatable {
    /// Window name in the fixed first column.
    let label: String?
    /// Nil uses the reported amount text, without a percentage bar.
    let used: Int?
    let resetsAt: Date?
    let minutes: Int?
    /// Amount text for balance-only accounts, shown instead of a bar.
    let balance: String?
    var helpTitle: String? = nil
    /// The extra pool the window belongs to (Droid "Core", a model-only limit), from its title.
    var pool: String? = nil
    /// A heading row: the pool name, in the label column's start, over that pool's rows.
    var isHeading = false
  }

  /// A window title split into its extra pool and its full period word.
  struct WindowName: Equatable {
    let pool: String?
    let label: String
  }

  /// Words that describe the kind of amount, never a pool: "Monthly credits", "Weekly quota".
  private static let amountWords: Set<String> = [
    "credits", "credit", "quota", "limit", "usage", "budget", "allowance", "tokens", "requests", "window"]

  /// Full period word and the number of title words it spans, when the word at `index` names a period.
  private static func period(in words: [String], at index: Int) -> (name: String, length: Int)? {
    let word = words[index].lowercased()
    switch word {
    case "session", "5-hour", "5-hours", "5h", "5hour": return ("Session", 1)
    case "weekly", "7-day": return ("Weekly", 1)
    case "monthly": return ("Monthly", 1)
    case "daily": return ("Daily", 1)
    default: break
    }
    guard index + 1 < words.count else { return nil }
    let next = words[index + 1].lowercased()
    if word == "5", next.hasPrefix("hour") { return ("Session", 2) }
    if word.range(of: #"^\d+-(day|hour|minute)s?$"#, options: .regularExpression) != nil, next == "window" {
      return ("\(words[index]) window", 2)
    }
    return nil
  }

  /// Splits a window title into its pool and its period word, for every provider alike: the
  /// period word is the label, any other words (besides amount words) are the pool. "Core 5-hour"
  /// is pool Core, label Session; "Weekly Fable" is pool Fable, label Weekly; "Spark credits" is
  /// pool Spark, label Credits. A title with no period word keeps its own text.
  static func windowName(minutes: Int?, title: String) -> WindowName {
    let words = title.split(separator: " ").map(String.init)
    for index in words.indices {
      guard let period = period(in: words, at: index) else { continue }
      var rest = words
      rest.removeSubrange(index..<(index + period.length))
      let pool = rest.filter { !amountWords.contains($0.lowercased()) }.joined(separator: " ")
      return WindowName(pool: pool.isEmpty ? nil : pool, label: period.name)
    }
    if words.count > 1, words.last?.lowercased() == "credits" {
      return WindowName(pool: words.dropLast().joined(separator: " "), label: "Credits")
    }
    if title.isEmpty, let minutes { return WindowName(pool: nil, label: minutes == 300 ? "Session" : "Weekly") }
    return WindowName(pool: nil, label: title)
  }

  /// The main pool's rows first (no heading), then each extra pool under its heading, in the
  /// reported order. An account whose rows all share one pool needs no heading.
  static func grouped(_ rows: [Line]) -> [Line] {
    var pools: [String?] = []
    for row in rows where !pools.contains(where: { $0 == row.pool }) { pools.append(row.pool) }
    guard pools.count > 1 else { return rows }
    pools = pools.filter { $0 == nil } + pools.filter { $0 != nil }  // the main pool first
    return pools.flatMap { pool -> [Line] in
      let own = rows.filter { $0.pool == pool }
      guard let pool else { return own }
      return [Line(label: pool, used: nil, resetsAt: nil, minutes: nil, balance: nil, isHeading: true)] + own
    }
  }

  /// The collapsed row shows the first two usage rows, with the heading of a pool above its rows.
  static func collapsed(_ lines: [Line]) -> [Line] {
    var result: [Line] = [], rows = 0
    for line in lines {
      if rows >= 2 { break }
      if !line.isHeading { rows += 1 }
      result.append(line)
    }
    return result
  }

  enum Content: Equatable { case signIn, lines([Line]) }

  static func content(for account: MenuBarAccountSnapshot, expanded: Bool = true) -> Content {
    guard !account.showsPrompt else { return .signIn }
    guard let usage = account.usage else {
      return .lines([])
    }
    if let providerWindows = usage.providerWindows, !providerWindows.isEmpty {
      let visible = providerWindows.filter { $0.used != nil || $0.balance?.isEmpty == false }
      let rows = grouped(visible.map {
        let name = windowName(minutes: $0.minutes, title: $0.title)
        return Line(label: name.label, used: $0.used, resetsAt: $0.resetsAt, minutes: $0.minutes,
          balance: $0.balance, helpTitle: $0.title, pool: name.pool)
      })
      return .lines(expanded ? rows : collapsed(rows))
    }
    var windows: [(title: String, used: Int?, reset: Date?, minutes: Int?, detail: String?)] = []
    if usage.usedPercentage != nil || usage.primaryDetail?.isEmpty == false {
      windows.append((usage.primaryLabel, usage.usedPercentage, usage.resetsAt, usage.primaryMinutes, usage.primaryDetail))
    }
    if usage.secondaryUsedPercentage != nil || usage.secondaryDetail?.isEmpty == false {
      windows.append((usage.secondaryLabel, usage.secondaryUsedPercentage, usage.secondaryResetsAt, usage.secondaryMinutes, usage.secondaryDetail))
    }
    if windows.isEmpty {
      guard let balance = usage.balanceText, !balance.isEmpty else { return .lines([]) }
      return .lines([Line(
        label: nil, used: nil, resetsAt: nil, minutes: nil, balance: balance)])
    }
    let rows = grouped(windows.map {
      let name = windowName(minutes: $0.minutes, title: $0.title)
      return Line(label: name.label, used: $0.used, resetsAt: $0.reset, minutes: $0.minutes,
        balance: $0.used == nil ? $0.detail : nil, pool: name.pool)
    })
    return .lines(expanded ? rows : collapsed(rows))
  }

  static func lines(for account: MenuBarAccountSnapshot, expanded: Bool = false) -> [Line] {
    if case .lines(let lines) = content(for: account, expanded: expanded) { return lines }
    return []
  }

  static func labelColumnWidth(_ account: MenuBarAccountSnapshot, expanded: Bool) -> CGFloat {
    lines(for: account, expanded: expanded).filter { !$0.isHeading }.compactMap(displayLabel).reduce(labelWidth) {
      max($0, measuredLabelWidth($1))
    }
  }

  /// Text measuring costs about 0.1 ms; the expansion asks for every label on every frame.
  private static var labelWidths: [String: CGFloat] = [:]
  private static func measuredLabelWidth(_ label: String) -> CGFloat {
    if let width = labelWidths[label] { return width }
    let font = NSFont.preferredFont(forTextStyle: .subheadline)
    let width = ceil((label as NSString).size(withAttributes: [.font: font]).width)
    labelWidths[label] = width
    return width
  }

  static func showsSwitch(_ account: MenuBarAccountSnapshot) -> Bool { !account.isActive }

  static func hasTokenCaption(_ account: MenuBarAccountSnapshot) -> Bool {
    guard account.isVerified, let usage = account.usage else { return false }
    return (usage.tokens ?? 0) > 0 && usage.tokenPeriodLabel != nil
      && (usage.usedPercentage != nil || usage.secondaryUsedPercentage != nil)
  }

  static func lineCount(_ account: MenuBarAccountSnapshot) -> Int {
    switch content(for: account, expanded: false) {
    case .signIn: 1
    case .lines(let lines): lines.count
    }
  }

  /// Height of one account row, hairline included. Zero when the account is hidden. It is what
  /// the row lays out: padding, the name, then the sign-in line or the usage lines (a row with
  /// no usage is the name alone), then the token caption. The popover height sums these, so
  /// the row view must add nothing else.
  static func rowHeight(_ account: MenuBarAccountSnapshot) -> CGFloat {
    guard account.showsUsage else { return 0 }
    var height = rowPaddingV * 2 + headerHeight + dividerHeight
    if account.showsPrompt {
      height += lineGap + signInHeight
    } else if lineCount(account) > 0 {
      let count = CGFloat(lineCount(account))
      height += lineGap + count * lineHeight + (count - 1) * lineSpacing
    }
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

  /// "24.1M", "3.2K", "950": one decimal at most, so the line stays short.
  static func compactTokens(_ tokens: Int64) -> String {
    guard tokens >= 1_000 else { return String(tokens) }
    for (size, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] {
      let value = (Double(tokens) / size * 10).rounded() / 10
      if value >= 1 {
        return (value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)) + suffix
      }
    }
    return String(tokens)
  }

  /// The value of the Tokens row, "24.1M since reset · ≈$96 API" (the price only when the usage
  /// has one). It starts at the bar column, stays on one line, and truncates at the tail.
  static func tokenCaption(_ usage: MenuBarUsageSnapshot) -> String? {
    guard let tokens = usage.tokens, tokens > 0, let period = usage.tokenPeriodLabel else { return nil }
    let price = usage.apiPrice.map {
      "≈\($0.inputEquivalent(for: tokens).formatted(.currency(code: "USD").precision(.fractionLength(0)))) API"
    }
    return ["\(compactTokens(tokens)) \(period)", price].compactMap { $0 }.joined(separator: " · ")
  }

  /// Lint groups of one account's bar column and its value-only rows (they share a left edge).
  /// Per account, because the label column width differs between accounts.
  static func barGroup(_ account: MenuBarAccountSnapshot) -> String { "menuBarBars-\(account.id)" }
  static func valueGroup(_ account: MenuBarAccountSnapshot) -> String { "menuBarValues-\(account.id)" }

  static let tokenLabel = "Tokens"
  static let balanceLabel = "Balance"

  /// The label column text of a line: its window name, or "Balance" for a value-only line with none.
  static func displayLabel(_ line: Line) -> String? { line.label ?? (line.balance == nil ? nil : balanceLabel) }

  static func accessibilityLabel(
    _ account: MenuBarAccountSnapshot, showsUsed: Bool, now: Date, exact: Bool
  ) -> String {
    var parts = [account.identity, providerLabel(account)]
    if account.isActive { parts.append("Default") }
    switch content(for: account) {
    case .signIn:
      parts.append("Needs sign in")
    case .lines(let lines):
      for line in lines where !line.isHeading {
        let value = line.balance.map { "Balance \($0)" }
          ?? line.used.map { UsagePercentagePreferences.label(forUsed: $0, showsUsed: showsUsed) }
          ?? "Usage unknown"
        parts.append([line.pool, line.label, value].compactMap { $0 }.joined(separator: " "))
      }
      for line in lines where !line.isHeading {
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
  var previewHovered = false

  @AppStorage(ResetDisplay.exactKey) private var exact = false
  @AppStorage(ResetDisplay.hourFormatKey) private var hourFormat = HourFormat.auto.rawValue
  @State private var hovered = false
  @State private var barsVisible = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private typealias P = MenuBarPresentation
  private var canExpand: Bool { P.canExpand(account, hasOpenTool: store.actions.openTool != nil) }
  private var isExpanded: Bool { canExpand && store.expandedAccountID == account.id }
  private var expansion: CGFloat { canExpand ? store.expansionAmount(account.id) : 0 }
  private var reveal: CGFloat { canExpand ? store.revealAmount(account.id) : 0 }
  private var actionHeight: CGFloat { P.actionHeight(account, hasOpenTool: store.actions.openTool != nil) }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: P.lineGap) {
        header
        if P.lineCount(account) > 0 { content }
        if P.hasTokenCaption(account), let value = account.usage.flatMap(P.tokenCaption) {
          tokenLine(value)
        }
      }
      .padding(.leading, P.rowPaddingH)
      .padding(.trailing, P.trailingInset)
      .padding(.vertical, P.rowPaddingV)
      if actionHeight > 0 && (expansion > 0 || isExpanded) {
        HStack(spacing: 8) {
          if P.showsSwitch(account) {
            Button("Switch") { store.select(account) }.disabled(!store.canSwitch(account))
          }
          if account.supportsLaunch, store.actions.openTool != nil {
            Button(P.openToolTitle(account)) { store.openTool(account) }
          }
          Spacer(minLength: 0)
        }
        .buttonStyle(MenuBarButtonStyle()).focusEffectDisabled()
        .padding(.leading, P.rowPaddingH + P.tileSize + P.tileSpacing)
        .padding(.trailing, P.trailingInset)
        .frame(height: P.expandedHeight)
        .opacity(reveal)
        .offset(y: store.reduceMotion ? 0 : 4 * (1 - expansion))
        .frame(height: P.expandedHeight * expansion, alignment: .top)
        .clipped()
      }
    }
    .uiLint(.align("menuBarRows", .start), .align("menuBarRowsEnd", .end))
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(!canExpand ? .clear : isFocused || isExpanded ? P.rowHighlight : hovered || previewHovered ? P.rowHover : .clear)
        .uiLint(.align("menuBarHoverFill", .start))
        .padding(.leading, P.rowPaddingH - 4)
        .padding(.trailing, P.rowPaddingH - 4 - AIMScroller.gutter)
        .padding(.top, P.rowPaddingV - P.hoverReach)
        .padding(.bottom, -P.hoverOverhang)
        .allowsHitTesting(false)
    }
    .overlay(alignment: .bottomTrailing) {
      if account.showsPrompt {
        // Bottom-aligned: level with the subtitle, then with the action buttons once the row
        // expands (their 40 pt band centers a 24 pt button, 8 pt above the row's bottom).
        let allow = account.isVerified
        Button(allow ? "Allow access" : "Sign in") {
          Task {
            if allow { await store.allowAccess(accountID: account.id) } else { await store.signIn(accountID: account.id) }
          }
        }
          .buttonStyle(MenuBarButtonStyle()).focusEffectDisabled()
          .uiLint(.align("menuBarSignInTrailing", .end))
          .padding(.trailing, P.trailingInset)
          .padding(.bottom, P.signInBottomInset(expansion: expansion))
          .help(allow ? "Open Switch to allow access to Droid's login" : "Open Switch to sign in")
          .accessibilityLabel(allow ? "Allow access to \(account.identity)" : "Sign in to \(account.identity)")
      }
    }
    .contentShape(Rectangle())
    .onHover { hovered = canExpand && $0 }
    .animation(.easeOut(duration: 0.12), value: hovered)
    .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.9), value: account.isActive)
    .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .easeOut(duration: 0.3)) { barsVisible = true } }
    .onTapGesture { store.toggleExpanded(account) }
    .contextMenu { menu }
    .accessibilityElement(children: isExpanded || account.showsPrompt ? .contain : .ignore)
    .accessibilityLabel(P.accessibilityLabel(account, showsUsed: showsUsed, now: now, exact: exact))
    .accessibilityAddTraits(canExpand ? .isButton : [])
    .accessibilityRemoveTraits(canExpand ? [] : .isButton)
    .accessibilityHint(canExpand ? "Shows every usage window and account actions" : "")
    .accessibilityActions {
      if canExpand {
        Button("Show actions") { store.toggleExpanded(account) }
      }
      if store.canSwitch(account) {
        Button("Switch") { store.select(account) }
      }
    }
  }

  /// A label + value row: "Tokens" in the label column, the value from the bar column. One line.
  private func tokenLine(_ value: String) -> some View {
    HStack(spacing: 6) {
      labelText(P.tokenLabel)
      valueText(value)
    }
    .frame(height: P.captionHeight)
    .padding(.leading, P.textIndent)
  }

  private func labelText(_ label: String, help: String? = nil) -> some View {
    Text(label).aimText(.secondary, tint: P.secondaryInk)
      .fixedSize(horizontal: true, vertical: false)
      .uiLint(.align("menuBarUsageLabelInk", .start))
      .frame(width: P.labelColumnWidth(account, expanded: isExpanded), alignment: .leading)
      .uiLint(.align("menuBarUsageLabels", .start)).help(help ?? label)
  }

  /// A value without a bar: it starts at the bar column's left edge, one line, tail-truncated.
  private func valueText(_ value: String) -> some View {
    Text(value).aimText(.secondary, tint: P.secondaryInk).monospacedDigit()
      .lineLimit(1).truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      .uiLint(.align(P.valueGroup(account), .start))
      .help(value)
  }

  private var header: some View {
    HStack(spacing: P.tileSpacing) {
      // The check column: the default account's check sits left of the name; every name
      // starts after this column, check or not.
      ZStack {
        if account.isActive && !isSwitching {
          Image(systemName: "checkmark").aimFont(.secondary)
            .foregroundStyle(Color(nsColor: .labelColor))
            .help("Default for \(P.providerLabel(account))")
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
        }
      }
      .frame(width: P.tileSize, height: P.headerHeight)
      Text(account.identity)
        .aimText(.body)
        .lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(account.identity)
        .padding(.trailing, account.showsPrompt ? 54 : 0)
      trailing
        .frame(width: 18, height: P.headerHeight)
    }
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
        }
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch P.content(for: account, expanded: true) {
    case .signIn:
      Text(account.isVerified ? P.allowAccessSubtitle : P.signInSubtitle)
        .aimText(.secondary, tint: P.secondaryInk).lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: P.signInHeight)
        .uiLint(.align("menuBarSignInSubtitle", .start))
        .padding(.leading, P.tileSize + P.tileSpacing)
        .padding(.trailing, account.isVerified ? 90 : 60)
    case .lines(let lines):
      let shown = P.lines(for: account).count
      VStack(spacing: P.lineSpacing) {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
          lineView(line)
            .opacity(index < shown ? 1 : reveal)
            .offset(y: index < shown || store.reduceMotion ? 0 : 4 * (1 - expansion))
        }
      }
      .frame(height: CGFloat(shown) * P.lineHeight
        + CGFloat(max(0, lines.count - shown)) * P.lineHeight * expansion, alignment: .top)
      .clipped()
      .padding(.leading, P.tileSize + P.tileSpacing)
    }
  }

  private func lineView(_ line: P.Line) -> some View {
    HStack(spacing: 6) {
      if line.isHeading, let pool = line.label {
        // A pool heading spans the row; it never widens the label column.
        Text(pool).aimText(.caption, tint: P.secondaryInk).lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
          .uiLint(.align("menuBarUsageLabels", .start))
          .accessibilityAddTraits(.isHeader)
      } else if let label = P.displayLabel(line) { labelText(label, help: line.helpTitle) }
      if line.isHeading {
        EmptyView()
      } else if let balance = line.balance {
        valueText(balance)
      } else {
        ZStack {
          UsageBar(usedPercent: nil, providerID: account.providerID)
          UsageBar(usedPercent: line.used.map(Double.init), showsUsed: showsUsed,
            providerID: account.providerID)
            .mask(Rectangle().scaleEffect(x: barsVisible || reduceMotion ? 1 : 0, anchor: .leading))
            .opacity(reduceMotion && !barsVisible ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: line.used)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: showsUsed)
        }
        .frame(height: UsageBar.height)
        .uiLint(.align(P.barGroup(account), .start))
        Text(line.used.map {
          "\(UsagePercentagePreferences.displayedPercentage(forUsed: $0, showsUsed: showsUsed))%"
        } ?? "—")
          .aimText(.secondary, tint: P.secondaryInk).monospacedDigit()
          .contentTransition(reduceMotion ? .opacity : .numericText())
          .animation(.easeOut(duration: 0.24), value: line.used)
          .animation(.easeOut(duration: 0.24), value: showsUsed)
          .frame(width: P.percentWidth, alignment: .trailing)
        Text(line.resetsAt.map {
          P.resetText($0, now: now, exact: exact,
            hourFormat: HourFormat(rawValue: hourFormat) ?? .auto, used: line.used)
        } ?? "")
          .aimText(.secondary, tint: P.secondaryInk).monospacedDigit().lineLimit(1)
          .frame(width: P.resetWidth, alignment: .trailing)
      }
    }
    .frame(height: P.lineHeight)
  }

  @ViewBuilder private var menu: some View {
    if P.showsSwitch(account) {
      Button("Switch") { store.select(account) }.disabled(!store.canSwitch(account))
    }
    if account.supportsLaunch, store.actions.openTool != nil {
      Button(P.openToolTitle(account)) { store.openTool(account) }
    }
    Button("Refresh") { Task { await store.refresh(account) } }
      .disabled(!account.supportsUsageRefresh || store.isRefreshingUsage)
    Divider()
    Button("Copy name") { store.copy(account.realName) }
  }
}

struct MenuBarFooter: View {
  @ObservedObject var store: MenuBarPopoverStore
  private typealias P = MenuBarPresentation
  /// The icon box of the square footer buttons; the large control height gives the rest.
  private static let iconSide: CGFloat = 24
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var refreshTurn = false

  private var openSwitch: some View {
      Button {
        store.openMainWindow()
      } label: {
        HStack(spacing: 8) {
          Text("Open Switch").aimText(.body)
          Text("⌘O").aimText(.secondary, tint: P.secondaryInk)
        }
      }
      .buttonStyle(MenuBarButtonStyle())
      .focusEffectDisabled()
      .keyboardShortcut("o", modifiers: .command)
      .help("Open Switch (⌘O)")
  }

  private var refresh: some View {
      Button {
        Task { await store.refreshUsage() }
      } label: {
        Image(systemName: "arrow.clockwise")
        .rotationEffect(.degrees(refreshTurn && !reduceMotion ? 360 : 0))
        .opacity(store.isRefreshingUsage && reduceMotion ? 0.5 : 1)
        .animation(store.isRefreshingUsage && !reduceMotion ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .easeOut(duration: 0.12), value: refreshTurn)
        .frame(width: Self.iconSide, height: Self.iconSide)
      }
      .buttonStyle(MenuBarButtonStyle(horizontalPadding: 0))
      .uiLint(.align("menuBarFooterRefresh", .start))
      .focusEffectDisabled()
      .keyboardShortcut("r", modifiers: .command)
      .disabled(!store.canRefreshUsage)
      .help("Refresh usage")
      .accessibilityLabel("Refresh usage")
  }

  private var quit: some View {
      Button {
        store.actions.quit()
      } label: {
        Image(systemName: "power")
          .frame(width: Self.iconSide, height: Self.iconSide)
      }
      .buttonStyle(MenuBarButtonStyle(horizontalPadding: 0))
      .uiLint(.align("menuBarFooterQuit", .start))
      .focusEffectDisabled()
      .help("Quit Switch")
      .accessibilityLabel("Quit Switch")
  }

  private var settings: some View {
      Button { store.openSettings() } label: {
        Image(systemName: "gearshape").frame(width: Self.iconSide, height: Self.iconSide)
      }
      .buttonStyle(MenuBarButtonStyle(horizontalPadding: 0)).focusEffectDisabled()
      .uiLint(.align("menuBarFooterSettings", .start))
      .help("Settings").accessibilityLabel("Settings")
  }

  var body: some View {
    // Visual, keyboard, and accessibility order agree: P.footerOrder, Open Switch at the left.
    HStack(spacing: 6) {
      ForEach(P.footerOrder, id: \.self) { item in
        switch item {
        case .openSwitch:
          openSwitch
          Spacer(minLength: 8)
        case .refresh: refresh
        case .quit: quit
        case .settings: settings
        }
      }
    }
    .padding(.horizontal, P.inset)
    .frame(height: MenuBarPopover.footerHeight)
    .uiLint(.align("menuBarFooter", .end))
    .onChange(of: store.isRefreshingUsage) { _, refreshing in refreshTurn = refreshing }
    .onChange(of: reduceMotion) { _, _ in refreshTurn = store.isRefreshingUsage }
    .overlay(alignment: .top) {
      if store.rows.isEmpty { MenuBarSeparator() }
    }
  }

}

/// Flat fills keep footer and sign-in controls quiet in both appearances.
private struct MenuBarButtonStyle: ButtonStyle {
  var height: CGFloat = 24
  var horizontalPadding: CGFloat = 6
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .aimText(.body)
      .foregroundStyle(Color(nsColor: .labelColor))
      .padding(.horizontal, horizontalPadding)
      .frame(height: height)
      // The system flat fill (Dark and Light), with a light veil for hover and press.
      .background(RoundedRectangle(cornerRadius: 5).fill(
        isFocused ? AIMTheme.focusTint : Color(nsColor: .secondarySystemFill)))
      .overlay(RoundedRectangle(cornerRadius: 5).fill(
        Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.06 : 0)))
      .contentShape(RoundedRectangle(cornerRadius: 5))
      .opacity(isEnabled ? 1 : 0.45)
      .onHover { hovered = $0 }
      .animation(.easeOut(duration: 0.12), value: hovered)
      .animation(.easeOut(duration: AIMMotion.state), value: configuration.isPressed)
      .uiLint(.control)
  }
}

struct MenuBarSeparator: View {
  var body: some View {
    AIMHairline().opacity(MenuBarPresentation.separatorOpacity)
      .mask(LinearGradient(stops: [
        .init(color: .clear, location: 0),
        .init(color: .black, location: MenuBarPresentation.separatorFade),
        .init(color: .black, location: 1 - MenuBarPresentation.separatorFade),
        .init(color: .clear, location: 1)
      ], startPoint: .leading, endPoint: .trailing))
  }
}
