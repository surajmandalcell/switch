import AppKit
import AIManagerCore
import SwiftUI

/// Pure rules of the popover: labels, bar colors, countdown text, geometry, keyboard order.
/// Kept apart from the views so the contract can test them without a window.
enum MenuBarPresentation {
  static let rowPaddingH: CGFloat = 20
  static let rowPaddingV: CGFloat = 12
  static let tileSize: CGFloat = 40
  static let tileSpacing: CGFloat = 12
  static let headerHeight: CGFloat = 40
  static let lineGap: CGFloat = 2
  static let lineHeight: CGFloat = 22
  static let lineSpacing: CGFloat = 2
  static let captionHeight: CGFloat = 16
  static let dividerHeight: CGFloat = 1
  static let labelWidth: CGFloat = 48
  static let percentWidth: CGFloat = 44

  struct Line: Equatable {
    /// Short window name; nil when the account has a single window.
    let label: String?
    /// Nil is an unknown value: an empty track and an em dash.
    let used: Int?
    let resetsAt: Date?
    let minutes: Int?
    /// Amount text for balance-only accounts, shown instead of a bar.
    let balance: String?
  }

  enum Level: Equatable { case good, caution, low }

  /// "5h" for 300-minute windows, "Weekly" for 10080, else the window's own title.
  static func windowLabel(minutes: Int?, title: String) -> String {
    switch minutes {
    case 300: "5h"
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
        label: windows.count > 1 ? windowLabel(minutes: $0.minutes, title: $0.title) : nil,
        used: $0.used, resetsAt: $0.reset, minutes: $0.minutes, balance: nil)
    })
  }

  /// The reset in the row header: the first window's.
  static func headerReset(for account: MenuBarAccountSnapshot) -> Date? {
    guard case .lines(let lines) = content(for: account) else { return nil }
    return lines.first?.resetsAt
  }

  /// Used percent of the header window, for the past-reset wording.
  static func headerUsed(for account: MenuBarAccountSnapshot) -> Int? {
    guard case .lines(let lines) = content(for: account) else { return nil }
    return lines.first?.used
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
    if hasTokenCaption(account) { height += lineSpacing + captionHeight }
    return height
  }

  /// Bar color: green above 50% left, yellow from 20% to 50%, red below 20%. A pace verdict of
  /// close to the limit or running out can only make the color worse.
  static func level(used: Int, resetsAt: Date?, minutes: Int?, now: Date) -> Level {
    let left = max(0, 100 - used)
    var level: Level = left > 50 ? .good : left >= 20 ? .caution : .low
    let window = UsageWindow(
      id: "", title: "", usedPercent: Double(used), resetsAt: resetsAt, windowMinutes: minutes)
    switch UsagePace.meterState(window, now: now) {
    case .closeToLimit, .level(.warning, _):
      if level == .good { level = .caution }
    case .runningOut, .spent, .level(.critical, _):
      level = .low
    default:
      break
    }
    return level
  }

  static func color(_ level: Level) -> Color {
    switch level {
    case .good: .green
    case .caution: .yellow
    case .low: .red
    }
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
      if let reset = lines.first?.resetsAt {
        let text = resetText(reset, now: now, exact: exact, used: lines.first?.used)
        parts.append(reset > now ? "Resets " + text : text)
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
      Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: P.dividerHeight)
    }
    .frame(height: P.rowHeight(account))
    .background {
      RoundedRectangle(cornerRadius: 8)
        .fill(isFocused ? Color.accentColor.opacity(0.16) : hovered ? Color.primary.opacity(0.07) : .clear)
        .padding(.horizontal, 6).padding(.vertical, 3)
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .onTapGesture { store.select(account) }
    .contextMenu { menu }
    .accessibilityElement(children: account.isVerified ? .ignore : .contain)
    .accessibilityLabel(P.accessibilityLabel(account, showsUsed: showsUsed, now: now, exact: exact))
    .accessibilityAddTraits(.isButton)
    .accessibilityHint(store.canSwitch(account) ? "Switches to this account" : "")
    .accessibilityAction(named: "Switch") { store.select(account) }
  }

  private var header: some View {
    HStack(spacing: P.tileSpacing) {
      tile
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          Text(account.identity)
            .aimText(.section)
            .lineLimit(1).truncationMode(.middle)
            .help(account.identity)
          if account.isActive {
            Image(systemName: "checkmark")
              .aimFont(.secondary)
              .foregroundStyle(Color.accentColor)
              .help("Default for \(P.providerLabel(account))")
          }
        }
        Text(P.providerLabel(account))
          .aimText(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      trailing
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
          .help("\(error) Click to copy.")
          .accessibilityLabel("Copy account error")
        }
        if let reset = P.headerReset(for: account) {
          Text(P.resetText(reset, now: now, exact: exact,
            hourFormat: HourFormat(rawValue: hourFormat) ?? .auto, used: P.headerUsed(for: account)))
            .aimText(.secondary).monospacedDigit().lineLimit(1)
        }
      }
    }
  }

  private var tile: some View {
    Group {
      // Color marks on transparent SVG; the PNG marks carry a white square, so they use the glyph.
      if AIManagerBrand.providerArtwork.first(where: { $0.providerID == account.providerID })?
        .fileExtension == "svg", let image = AIManagerBrand.providerImage(for: account.providerID) {
        Image(nsImage: image).resizable().scaledToFit().padding(6)
      } else {
        Image(nsImage: AIManagerBrand.providerIcon(for: account.providerID))
          .resizable().scaledToFit().padding(10).foregroundStyle(.primary)
      }
    }
    .frame(width: P.tileSize, height: P.tileSize)
    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .accessibilityHidden(true)
  }

  @ViewBuilder private var content: some View {
    switch P.content(for: account) {
    case .signIn:
      Button("Sign in") { store.openMainWindow() }
        .buttonStyle(.bordered)
        .frame(height: P.lineHeight)
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
    HStack(spacing: 8) {
      if let label = line.label {
        Text(label).aimText(.secondary).lineLimit(1).frame(width: P.labelWidth, alignment: .leading)
      }
      if let balance = line.balance {
        Text("Balance").aimText(.secondary)
        Spacer(minLength: 0)
        Text(balance).aimText(.secondary).monospacedDigit()
      } else {
        UsageBar(
          usedPercent: line.used.map(Double.init), showsUsed: showsUsed,
          tint: line.used.map {
            P.color(P.level(used: $0, resetsAt: line.resetsAt, minutes: line.minutes, now: now))
          })
        Text(line.used.map {
          "\(UsagePercentagePreferences.displayedPercentage(forUsed: $0, showsUsed: showsUsed))%"
        } ?? "—")
          .aimText(.secondary).monospacedDigit()
          .frame(width: P.percentWidth, alignment: .trailing)
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
    HStack(spacing: AIMTheme.rowSpacing) {
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
      .buttonStyle(.bordered)
      .buttonBorderShape(.circle)
      .controlSize(.large)
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
      .buttonStyle(.bordered)
      .buttonBorderShape(.circle)
      .controlSize(.large)
      .help("Settings")
      .accessibilityLabel("Settings")

      Button {
        store.openMainWindow()
      } label: {
        Text("Open Switch")
          .frame(maxWidth: .infinity)
          .overlay(alignment: .trailing) {
            Text("⌘O").aimFont(.secondary).opacity(0.8)
          }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .keyboardShortcut("o", modifiers: .command)
      .help("Open Switch (⌘O)")
    }
    .padding(.horizontal, 16)
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
