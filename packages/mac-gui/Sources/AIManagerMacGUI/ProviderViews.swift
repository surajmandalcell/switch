import AIManagerCore
import AppKit
import SwiftUI

// Account detail and usage presentation for providers beyond Codex CLI: every generic provider,
// plus the usage section of Grok Build and Claude Code profiles.

extension AccountRecord {
  /// Accounts shown with the generic detail view. Codex, Grok Build, and Claude Code keep their own.
  var usesGenericDetail: Bool {
    ![ProviderID.codex, .grokBuild, .claudeCode].contains(identity.providerID)
  }
}

/// Provider icon tile used in lists: the official brand mark in its own colors on the brand's
/// tile (single-color marks flip with the appearance), or the template glyph on a neutral tile
/// for a provider with no official mark. All tiles share one corner radius and optical padding.
struct ProviderMark: View {
  @Environment(\.colorScheme) private var colorScheme
  let providerID: ProviderID
  var size: CGFloat = 24

  var body: some View {
    Group {
      if let brand = AIManagerBrand.providerBrand(for: providerID),
        let image = AIManagerBrand.providerImage(for: providerID)
      {
        let dark = colorScheme == .dark
        Image(nsImage: image).resizable().scaledToFit()
          .foregroundStyle(Color(hex: (dark ? brand.tint?.dark : brand.tint?.light) ?? 0))
          .padding(size * 0.2)
          .frame(width: size, height: size)
          .background(Color(hex: dark ? brand.tile.dark : brand.tile.light))
      } else {
        Image(nsImage: AIManagerBrand.providerIcon(for: providerID))
          .resizable().scaledToFit().padding(size * 0.22)
          .frame(width: size, height: size)
          .foregroundStyle(.primary)
          .background(AIMTheme.chatOtherSurface)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    .overlay {
      RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(AIMTheme.line, lineWidth: 0.5)
    }
    .uiLint(.item)
    .accessibilityHidden(true)
  }
}

/// Small monochrome glyph for dense rows.
struct ProviderGlyph: View {
  let providerID: ProviderID
  var size: CGFloat = 14

  var body: some View {
    Image(nsImage: AIManagerBrand.providerIcon(for: providerID))
      .resizable().scaledToFit()
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

// MARK: - Provider status

/// A small yellow (minor or maintenance) or red (major or critical) dot beside a provider name.
/// Nothing when the provider has no incident or its status is unknown. The tooltip and the
/// accessibility value hold the incident description and how recently it was updated.
struct ProviderStatusDot: View {
  let entry: ProviderStatusEntry?
  var size: CGFloat = 7

  /// Description plus "updated <relative time>", or nil when no dot shows.
  static func text(_ entry: ProviderStatusEntry?, now: Date = Date()) -> String? {
    guard let entry, entry.incident.severity != nil else { return nil }
    return entry.incident.summary(checkedAt: entry.checkedAt, now: now)
  }

  var body: some View {
    if let entry, let severity = entry.incident.severity, let text = Self.text(entry) {
      Circle()
        .fill(severity == .critical ? AIMTheme.red : AIMTheme.amber)
        .frame(width: size, height: size)
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Provider status")
        .accessibilityValue(text)
    }
  }
}

// MARK: - Reset time, headline, and row menu

/// A reset line. Click it to flip between the countdown and the exact time, everywhere at once.
/// Hovering shows the other format.
struct ResetTimeText: View {
  let reset: Date
  let now: Date
  let usedPercent: Double?
  @AppStorage(ResetDisplay.exactKey) private var exact = false
  @AppStorage(ResetDisplay.hourFormatKey) private var hourFormat = HourFormat.auto.rawValue

  private func text(exact: Bool) -> String {
    UsageResetLabel.text(
      until: reset, now: now, exact: exact, hourFormat: HourFormat(rawValue: hourFormat) ?? .auto,
      usedPercent: usedPercent)
  }

  var body: some View {
    Text(text(exact: exact))
      .aimText(.secondary)
      .contentShape(Rectangle())
      .onTapGesture { exact.toggle() }
      .help(text(exact: !exact))
      .accessibilityAddTraits(.isButton)
      .accessibilityHint(exact ? "Shows the countdown" : "Shows the exact time")
  }
}

extension View {
  /// Click a usage headline such as "52% left" to flip between left and used everywhere.
  func flipsUsedAndLeft(_ showsUsed: Bool) -> some View {
    self
      .contentShape(Rectangle())
      .onTapGesture {
        UserDefaults.standard.set(!showsUsed, forKey: UsagePercentagePreferences.showsUsedKey)
      }
      .help(showsUsed ? "Click to show the percentage left" : "Click to show the percentage used")
      .accessibilityAddTraits(.isButton)
  }
}

/// Right-click menu of a usage row: hide it, show every hidden row, refresh.
private struct UsageRowMenu: ViewModifier {
  let rowID: String
  let refresh: () -> Void
  @AppStorage private var hiddenRaw: String

  init(accountID: UUID, rowID: String, refresh: @escaping () -> Void) {
    self.rowID = rowID
    self.refresh = refresh
    _hiddenRaw = AppStorage(wrappedValue: "", HiddenUsageRows.key(for: accountID))
  }

  func body(content: Content) -> some View {
    content.contextMenu {
      Button("Hide this row") {
        hiddenRaw = HiddenUsageRows.encode(HiddenUsageRows.parse(hiddenRaw).union([rowID]))
      }
      Button("Show all hidden rows") { hiddenRaw = "" }.disabled(hiddenRaw.isEmpty)
      Divider()
      Button("Refresh usage", action: refresh)
    }
  }
}

extension View {
  func usageRowMenu(accountID: UUID, rowID: String, refresh: @escaping () -> Void) -> some View {
    modifier(UsageRowMenu(accountID: accountID, rowID: rowID, refresh: refresh))
  }
}

/// "2 hidden rows · Show all" under a Usage panel. Nothing when no row is hidden.
struct HiddenUsageRowsNote: View {
  /// Every row id the panel can show, so ids of rows that no longer exist are not counted.
  let rowIDs: [String]
  @AppStorage private var hiddenRaw: String

  init(accountID: UUID, rowIDs: [String]) {
    self.rowIDs = rowIDs
    _hiddenRaw = AppStorage(wrappedValue: "", HiddenUsageRows.key(for: accountID))
  }

  static func text(count: Int) -> String { "\(count) hidden \(count == 1 ? "row" : "rows")" }

  var body: some View {
    let count = HiddenUsageRows.parse(hiddenRaw).intersection(rowIDs).count
    if count > 0 {
      HStack(spacing: AIMTheme.rowSpacing) {
        Text(Self.text(count: count)).aimText(.secondary)
        Spacer(minLength: AIMTheme.rowSpacing)
        AIMButton(title: "Show all") { hiddenRaw = "" }
      }
    }
  }
}

// MARK: - Claude Code activity

/// Today, Yesterday, and the last 30 days of local Claude Code usage across every profile.
/// Never attributed to the selected account.
struct ClaudeActivityPanel: View {
  static let title = "Claude Code activity (all profiles)"
  static let estimateLabel = "API-equivalent estimate"
  @ObservedObject var model: AccountViewModel

  var body: some View {
    AIMSection(Self.title) {
      if let summary = model.claudeActivity {
        ForEach(Array(summary.rows.enumerated()), id: \.offset) { _, row in
          LabeledContent(row.label) {
            HStack(spacing: AIMTheme.sectionSpacing) {
              Text("\(UsagePresentation.formatTokens(Int64(row.tokens))) tokens").monospacedDigit()
              Text(row.costUSD.map { "≈ \(Fmt.money($0))" } ?? "No price").monospacedDigit()
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(row.label)
          .accessibilityValue("\(UsagePresentation.exactTokens(Int64(row.tokens))) tokens, "
            + (row.costUSD.map { "\(Fmt.money($0)) \(Self.estimateLabel.lowercased())" } ?? "no price"))
          .help(row.detail)
        }
        if let chart = summary.chart {
          UsageChartView(chart: chart)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text("\(Self.estimateLabel). Covers every Claude Code profile on this Mac, not only this account.")
          if !summary.unpricedModels.isEmpty {
            Text("No price for \(summary.unpricedModels.joined(separator: ", ")). Their cost is not included.")
          }
        }
        .aimText(.secondary)
      } else {
        UsageUnavailableRow(
          text: model.isClaudeActivityLoading
            ? "Scanning local Claude Code logs…" : "Claude Code activity is not available yet.")
      }
    }
  }
}

// MARK: - Usage panel

struct ProviderUsagePanel: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  /// Newline-joined ids of the rows this account hides (see `HiddenUsageRows`).
  @AppStorage private var hiddenRaw: String

  init(account: AccountRecord, model: AccountViewModel) {
    self.account = account
    self.model = model
    _hiddenRaw = AppStorage(wrappedValue: "", HiddenUsageRows.key(for: account.id))
  }

  /// Grok Build always shows the section; Claude Code profiles only once usage has arrived.
  static func applies(to account: AccountRecord, in model: AccountViewModel) -> Bool {
    switch account.identity.providerID {
    case .codex: false
    case .grokBuild: true
    case .claudeCode: model.providerUsage[account.id]?.usage != nil
    default: true
    }
  }

  private var state: ProviderUsageState? { model.providerUsage[account.id] }
  private var needsSignIn: Bool {
    state?.needsSignIn == true || account.verification.state == .needsSignIn
  }
  /// Stale values never sit beside a sign-in request.
  private var usage: ProviderUsage? { needsSignIn ? nil : state?.usage }
  private var isRefreshing: Bool { state?.isRefreshing == true }

  var body: some View {
    AIMSection("Usage") {
      if let usage {
        populated(usage)
      } else {
        emptyState
      }
    }
  }

  // MARK: Populated

  @ViewBuilder private func populated(_ usage: ProviderUsage) -> some View {
    LabeledContent(usage.plan.map { $0.capitalized } ?? "\(account.identity.providerID.guiName) usage") {
      status(usage)
    }

    let windows = HiddenUsageRows.visible(
      usage.windows, hidden: HiddenUsageRows.parse(hiddenRaw), id: \.id)
    ForEach(windows) { window in
      TimelineView(.periodic(from: .now, by: 60)) { context in
        ProviderWindowMeter(window: window, providerID: account.identity.providerID, now: context.date)
          .usageRowMenu(accountID: account.id, rowID: window.id) {
            Task { await model.refreshProviderUsage(accountID: account.id) }
          }
      }
    }

    if let cost = usage.cost, ProviderCostRow.hasContent(cost) {
      ProviderCostRow(cost: cost)
    }

    ForEach(usage.charts, id: \.id) { chart in
      UsageChartView(chart: chart)
    }

    ForEach(Array(usage.sections.enumerated()), id: \.offset) { _, section in
      ProviderSectionRows(section: section, providerID: account.identity.providerID)
    }

    HiddenUsageRowsNote(accountID: account.id, rowIDs: usage.windows.map(\.id))

    if usage.windows.isEmpty, usage.cost.map(ProviderCostRow.hasContent) != true, usage.sections.isEmpty,
       usage.charts.isEmpty {
      UsageUnavailableRow(text: "No usage values returned")
    }
  }

  @ViewBuilder private func status(_ usage: ProviderUsage) -> some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      if let failure = state?.error {
        Text("Outdated").aimText(.secondary, tint: AIMTheme.amber)
          .help(failure)
        Text(usage.fetchedAt.formatted(date: .omitted, time: .shortened))
          .aimText(.secondary).monospacedDigit()
        WarningCopyButton(label: "Copy usage error") { model.copyWarnings([failure]) }
      } else {
        Text("Updated").aimText(.secondary)
        Text(usage.fetchedAt.formatted(date: .omitted, time: .shortened))
          .aimText(.secondary).monospacedDigit()
      }
      refreshButton
    }
  }

  // MARK: Empty, error, and sign-in states

  private var emptyState: some View {
    HStack(spacing: AIMTheme.sectionSpacing) {
      AIMIcon(name: .info).aimText(.body).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).aimText(.body)
        if let failure = state?.error, !needsSignIn {
          Text(failure).aimText(.secondary, tint: AIMTheme.amber)
        } else if needsSignIn {
          Text(state?.error ?? "Sign in again to check this account.")
            .aimText(.secondary, tint: AIMTheme.amber)
        } else {
          Text("Refresh this saved account without changing the default account.")
            .aimText(.secondary)
        }
      }
      Spacer()
      if let failure = state?.error {
        WarningCopyButton(label: "Copy usage error") { model.copyWarnings([failure]) }
      }
      refreshButton
    }
  }

  private var title: String {
    if needsSignIn { return "Sign in to refresh usage" }
    if isRefreshing { return "Checking usage…" }
    return state?.error == nil ? "Usage has not been checked" : "Usage could not be refreshed"
  }

  @ViewBuilder private var refreshButton: some View {
    if isRefreshing {
      ProgressView().controlSize(.small).frame(width: 30, height: 30)
        .accessibilityLabel("Refreshing usage")
    } else {
      AIMIconButton(icon: .refresh, label: "Refresh usage", disabled: model.isBusy) {
        Task { await model.refreshProviderUsage(accountID: account.id) }
      }
    }
  }
}

// MARK: - Window meter with pace

struct ProviderWindowMeter: View {
  let window: UsageWindow
  let providerID: ProviderID
  let now: Date
  @AppStorage(UsagePercentagePreferences.showsUsedKey) private var showsUsed = false
  /// Read so the accessibility value redraws when the reset format changes.
  @AppStorage(ResetDisplay.exactKey) private var resetIsExact = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var meter: UsagePace.MeterState { UsagePace.meterState(window, now: now) }
  private var used: Int? { window.usedPercent.map { Int($0.rounded()) } }
  private var displayed: Int? {
    used.map { UsagePercentagePreferences.displayedPercentage(forUsed: $0, showsUsed: showsUsed) }
  }

  /// The pace verdict colors: green ahead of the limit, yellow close, red running out.
  static func fill(for state: UsagePace.MeterState) -> Color {
    switch state {
    case .noData: AIMTheme.track
    case .level(.normal, _), .healthy: AIMTheme.green
    case .level(.warning, _), .closeToLimit: AIMTheme.yellow
    case .level(.critical, _), .runningOut, .spent: AIMTheme.red
    }
  }

  var body: some View {
    let state = meter
    let color = Self.fill(for: state)
    let tick = UsagePace.paceTick(window, now: now, showingLeft: !showsUsed)
    VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
      HStack(alignment: .firstTextBaseline, spacing: AIMTheme.rowSpacing) {
        Text(window.title).aimText(.body).lineLimit(1)
        if let label = UsagePace.label(state) {
          Badge(text: label, tint: color)
        }
        Spacer(minLength: 4)
        Text(used.map { UsagePercentagePreferences.label(forUsed: $0, showsUsed: showsUsed) } ?? "–")
          .aimText(.body).monospacedDigit()
          .flipsUsedAndLeft(showsUsed)
      }
      UsageBar(usedPercent: window.usedPercent, showsUsed: showsUsed, providerID: providerID, tick: tick)
        .help(UsagePace.tooltip(state) ?? "")
      HStack(alignment: .firstTextBaseline, spacing: AIMTheme.rowSpacing) {
        if let reset = window.resetsAt {
          ResetTimeText(reset: reset, now: now, usedPercent: window.usedPercent)
        }
        Spacer(minLength: 4)
        if let detail = window.detail {
          Text(detail).aimText(.secondary).monospacedDigit()
            .lineLimit(1).truncationMode(.tail)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: displayed)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(window.title)
    .accessibilityValue(accessibilityValue(state))
    .accessibilityAction(named: "Switch between used and left") {
      UserDefaults.standard.set(!showsUsed, forKey: UsagePercentagePreferences.showsUsedKey)
    }
    .accessibilityAction(named: "Switch between countdown and exact reset time") {
      UserDefaults.standard.set(!ResetDisplay.isExact(), forKey: ResetDisplay.exactKey)
    }
  }

  private func accessibilityValue(_ state: UsagePace.MeterState) -> String {
    var parts: [String] = []
    if let used { parts.append(UsagePercentagePreferences.label(forUsed: used, showsUsed: showsUsed)) }
    if let reset = window.resetsAt {
      parts.append(UsageResetLabel.text(
        until: reset, now: now, exact: resetIsExact, usedPercent: window.usedPercent))
    }
    if let detail = window.detail { parts.append(detail) }
    if let tip = UsagePace.tooltip(state) { parts.append(tip) }
    return parts.joined(separator: ", ")
  }
}

// MARK: - Cost and detail rows

struct ProviderCostRow: View {
  let cost: UsageCost
  @AppStorage(ResetDisplay.exactKey) private var resetIsExact = false

  static func hasContent(_ cost: UsageCost) -> Bool {
    cost.used != nil || cost.balance != nil || cost.limit != nil
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      VStack(spacing: AIMTheme.rowSpacing) {
        if let used = cost.used {
          UsageFact(label: cost.period.map { "Spent · \($0)" } ?? "Spent", value: spent(used))
        } else if let limit = cost.limit {
          UsageFact(label: cost.period.map { "Limit · \($0)" } ?? "Limit",
                    value: Fmt.money(limit, currency: cost.currency))
        }
        if let balance = cost.balance {
          UsageFact(label: "Balance", value: Fmt.money(balance, currency: cost.currency))
        }
        if let reset = cost.resetsAt {
          UsageFact(label: "Resets", value: UsageResetLabel.text(
            until: reset, now: context.date, exact: resetIsExact, usedPercent: cost.used)
            .replacingOccurrences(of: "Resets ", with: ""))
            .contentShape(Rectangle())
            .onTapGesture { resetIsExact.toggle() }
            .help("Click to switch between countdown and exact time")
            .accessibilityAddTraits(.isButton)
        }
      }
    }
  }

  private func spent(_ used: Double) -> String {
    let amount = Fmt.money(used, currency: cost.currency)
    guard let limit = cost.limit else { return amount }
    return "\(amount) of \(Fmt.money(limit, currency: cost.currency))"
  }
}

struct ProviderSectionRows: View {
  let section: UsageSection
  let providerID: ProviderID

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let title = section.title {
        Text(title).aimText(.secondary)
          .padding(.bottom, 4)
      }
      ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
        HStack(alignment: .firstTextBaseline, spacing: AIMTheme.sectionSpacing) {
          Text(row.label).aimText(.body).lineLimit(1)
          Spacer(minLength: AIMTheme.rowSpacing)
          if let progress = row.progress {
            UsageBar(usedPercent: (1 - progress) * 100, providerID: providerID)
              .frame(width: 56)
          }
          Text(EmailPrivacy.display(row.value)).aimText(.secondary).monospacedDigit()
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
      }
    }
  }
}

// MARK: - Generic account detail

struct ProviderAccountDetail: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let delete: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(EmailPrivacy.key) private var hideEmails = false

  var body: some View {
    AIMDetailPage {
      ProviderUsagePanel(account: account, model: model)
      AIMSection("Account details") {
        DetailRow(label: "Saved sign-in", value: account.credentialFile.path)
        DetailRow(
          label: "Imported",
          value: account.importedAt.formatted(date: .abbreviated, time: .shortened))
        DetailRow(
          label: "Last switched",
          value: account.lastUsedAt?.formatted(date: .abbreviated, time: .shortened)
            ?? "Not switched yet")
      }
      if let notice = model.notice {
        AIMSection { Notice(text: notice, tone: AIMTheme.blue) }
          .transition(reduceMotion ? .identity : .opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.notice)
  }
}

#if AI_MANAGER_PREVIEW
/// Launch arguments that open a Preview build on a given screen, such as `--add-query=gem`.
enum PreviewArguments {
  static func value(_ name: String) -> String? {
    CommandLine.arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
  }
}
#endif
