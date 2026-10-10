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

/// Provider icon tile used in lists: the official color mark on white, or the template glyph on a
/// neutral tile that follows the appearance.
struct ProviderMark: View {
  let providerID: ProviderID
  var size: CGFloat = 24

  var body: some View {
    Group {
      if let image = AIManagerBrand.providerImage(for: providerID) {
        Image(nsImage: image).resizable().scaledToFit().padding(size * 0.125)
          .frame(width: size, height: size).background(Color.white)
      } else {
        Image(nsImage: AIManagerBrand.providerIcon(for: providerID))
          .resizable().scaledToFit().padding(size * 0.22)
          .frame(width: size, height: size)
          .foregroundStyle(AIMTheme.ink)
          .background(AIMTheme.panel3)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 3))
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
  @AppStorage(ResetDisplay.exactKey) private var exact = false
  @AppStorage(ResetDisplay.hourFormatKey) private var hourFormat = HourFormat.auto.rawValue

  private func text(exact: Bool) -> String {
    UsageResetLabel.text(
      until: reset, now: now, exact: exact, hourFormat: HourFormat(rawValue: hourFormat) ?? .auto)
  }

  var body: some View {
    Text(text(exact: exact))
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
      HStack(spacing: 10) {
        Text(Self.text(count: count)).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
        Spacer(minLength: 8)
        AIMButton(title: "Show all") { hiddenRaw = "" }
      }
      .padding(.horizontal, 16).padding(.top, 8)
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
    AIMPanel(title: Self.title) {
      VStack(spacing: 0) {
        if let summary = model.claudeActivity {
          ForEach(Array(summary.rows.enumerated()), id: \.offset) { index, row in
            HStack(alignment: .firstTextBaseline, spacing: 16) {
              Text(row.label).font(AIMTheme.sans(11, weight: .medium)).frame(width: 118, alignment: .leading)
              Text("\(UsagePresentation.formatTokens(Int64(row.tokens))) tokens")
                .font(AIMTheme.mono(11)).monospacedDigit()
              Spacer(minLength: 8)
              Text(row.costUSD.map { "≈ \(Fmt.money($0))" } ?? "No price")
                .font(AIMTheme.mono(11, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 16).frame(minHeight: 40)
            .background(index.isMultiple(of: 2) ? Color.clear : AIMTheme.panel2.opacity(0.55))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.label)
            .accessibilityValue("\(UsagePresentation.exactTokens(Int64(row.tokens))) tokens, "
              + (row.costUSD.map { "\(Fmt.money($0)) \(Self.estimateLabel.lowercased())" } ?? "no price"))
            .help(row.detail)
          }
          VStack(alignment: .leading, spacing: 3) {
            Text("\(Self.estimateLabel). Covers every Claude Code profile on this Mac, not only this account.")
            if !summary.unpricedModels.isEmpty {
              Text("No price for \(summary.unpricedModels.joined(separator: ", ")). Their cost is not included.")
            }
          }
          .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16).padding(.vertical, 10)
        } else {
          UsageUnavailableRow(
            text: model.isClaudeActivityLoading
              ? "Scanning local Claude Code logs…" : "Claude Code activity is not available yet.")
        }
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
    AIMPanel(title: "Usage", importance: .primary) {
      VStack(spacing: 0) {
        if let usage {
          populated(usage)
        } else {
          emptyState
        }
      }
    }
  }

  // MARK: Populated

  @ViewBuilder private func populated(_ usage: ProviderUsage) -> some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text(usage.plan.map { $0.capitalized } ?? "\(account.identity.providerID.guiName) usage")
          .font(AIMTheme.sans(13, weight: .semibold))
        Spacer()
        status(usage)
      }
      .padding(.horizontal, 16).padding(.bottom, 14)

      let windows = HiddenUsageRows.visible(
        usage.windows, hidden: HiddenUsageRows.parse(hiddenRaw), id: \.id)
      ForEach(Array(stride(from: 0, to: windows.count, by: 2)), id: \.self) { start in
        let pair = Array(windows[start..<min(start + 2, windows.count)])
        TimelineView(.periodic(from: .now, by: 60)) { context in
          HStack(alignment: .top, spacing: 20) {
            ForEach(pair) { window in
              ProviderWindowMeter(window: window, now: context.date)
                .usageRowMenu(accountID: account.id, rowID: window.id) {
                  Task { await model.refreshProviderUsage(accountID: account.id) }
                }
            }
            if pair.count == 1 { Color.clear.frame(maxWidth: .infinity).frame(height: 0) }
          }
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background((start / 2).isMultiple(of: 2) ? AIMTheme.panel2 : AIMTheme.listStripe)
      }

      if let cost = usage.cost, ProviderCostRow.hasContent(cost) {
        ProviderCostRow(cost: cost)
          .padding(.vertical, 12).padding(.horizontal, 16)
          .background(AIMTheme.panel2)
      }

      ForEach(Array(usage.sections.enumerated()), id: \.offset) { _, section in
        ProviderSectionRows(section: section)
          .padding(.vertical, 10).padding(.horizontal, 16)
      }

      HiddenUsageRowsNote(accountID: account.id, rowIDs: usage.windows.map(\.id))

      if usage.windows.isEmpty, usage.cost.map(ProviderCostRow.hasContent) != true, usage.sections.isEmpty {
        UsageUnavailableRow(text: "No usage values returned")
      }
    }
    .padding(.vertical, 16)
  }

  @ViewBuilder private func status(_ usage: ProviderUsage) -> some View {
    HStack(spacing: 8) {
      if let failure = state?.error {
        Text("Outdated")
          .font(AIMTheme.sans(10, weight: .semibold)).foregroundStyle(AIMTheme.amber)
          .help(failure)
        Text(usage.fetchedAt.formatted(date: .omitted, time: .shortened))
          .font(AIMTheme.mono(9)).foregroundStyle(AIMTheme.muted)
        WarningCopyButton(label: "Copy usage error") { model.copyWarnings([failure]) }
      } else {
        Text("Updated").font(AIMTheme.sans(10, weight: .medium)).foregroundStyle(AIMTheme.muted)
        Text(usage.fetchedAt.formatted(date: .omitted, time: .shortened))
          .font(AIMTheme.mono(9)).foregroundStyle(AIMTheme.muted)
      }
      refreshButton
    }
  }

  // MARK: Empty, error, and sign-in states

  private var emptyState: some View {
    HStack(spacing: 12) {
      AIMIcon(name: .info, size: 15).foregroundStyle(AIMTheme.muted)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(AIMTheme.sans(12, weight: .semibold))
        if let failure = state?.error, !needsSignIn {
          Text(failure).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.amber)
        } else if needsSignIn {
          Text(state?.error ?? "Sign in again to check this account.")
            .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.amber)
        } else {
          Text("Refresh this saved account without changing the default account.")
            .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
        }
      }
      Spacer()
      if let failure = state?.error {
        WarningCopyButton(label: "Copy usage error") { model.copyWarnings([failure]) }
      }
      refreshButton
    }
    .padding(16)
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

  /// Colors follow the used share, never the Used or Left view.
  static func fill(for state: UsagePace.MeterState) -> Color {
    switch state {
    case .noData: AIMTheme.control
    case .level(.normal, _), .healthy: AIMTheme.blue
    case .level(.warning, _), .closeToLimit: AIMTheme.amber
    case .level(.critical, _), .runningOut, .spent: AIMTheme.red
    }
  }

  var body: some View {
    let state = meter
    let color = Self.fill(for: state)
    let tick = UsagePace.paceTick(window, now: now, showingLeft: !showsUsed)
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(window.title).font(AIMTheme.sans(11, weight: .medium)).lineLimit(1)
        if let label = UsagePace.label(state) {
          Text(label).font(AIMTheme.sans(9, weight: .bold)).foregroundStyle(color).lineLimit(1)
        }
        Spacer(minLength: 4)
        Text(used.map { UsagePercentagePreferences.label(forUsed: $0, showsUsed: showsUsed) } ?? "–")
          .font(AIMTheme.mono(10, weight: .semibold))
          .flipsUsedAndLeft(showsUsed)
      }
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Rectangle().fill(AIMTheme.control).frame(height: 4)
            .clipShape(RoundedRectangle(cornerRadius: 2))
          Rectangle().fill(color)
            .frame(width: geometry.size.width * CGFloat(displayed ?? 0) / 100, height: 4)
            .clipShape(RoundedRectangle(cornerRadius: 2))
          if let tick {
            Rectangle().fill(AIMTheme.ink.opacity(0.75)).frame(width: 1.5, height: 9)
              .offset(x: min(max(geometry.size.width * CGFloat(tick) - 0.75, 0), geometry.size.width - 1.5))
          }
        }
        .frame(height: geometry.size.height, alignment: .leading)
      }
      .frame(height: 9)
      .help(UsagePace.tooltip(state) ?? "")
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let reset = window.resetsAt {
          ResetTimeText(reset: reset, now: now)
            .font(AIMTheme.sans(9, weight: .bold)).foregroundStyle(AIMTheme.muted)
        }
        Spacer(minLength: 4)
        if let detail = window.detail {
          Text(detail).font(AIMTheme.mono(9)).foregroundStyle(AIMTheme.muted)
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
      parts.append(UsageResetLabel.text(until: reset, now: now, exact: resetIsExact))
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
      HStack(alignment: .top, spacing: 24) {
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
            until: reset, now: context.date, exact: resetIsExact)
            .replacingOccurrences(of: "Resets ", with: ""))
            .contentShape(Rectangle())
            .onTapGesture { resetIsExact.toggle() }
            .help("Click to switch between countdown and exact time")
            .accessibilityAddTraits(.isButton)
        }
        Spacer(minLength: 0)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let title = section.title {
        Text(title).font(AIMTheme.sans(10, weight: .medium)).foregroundStyle(AIMTheme.muted)
          .padding(.bottom, 4)
      }
      ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(row.label).font(AIMTheme.sans(11)).lineLimit(1)
          Spacer(minLength: 8)
          if let progress = row.progress {
            ProgressRail(fraction: progress).frame(width: 56)
          }
          Text(EmailPrivacy.display(row.value)).font(AIMTheme.mono(10)).foregroundStyle(AIMTheme.muted)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .frame(minHeight: 24)
      }
    }
  }
}

private struct ProgressRail: View {
  let fraction: Double
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Rectangle().fill(AIMTheme.control)
        Rectangle().fill(AIMTheme.blue).frame(width: geometry.size.width * CGFloat(fraction))
      }
      .clipShape(RoundedRectangle(cornerRadius: 1.5))
    }
    .frame(height: 3)
    .accessibilityHidden(true)
  }
}

// MARK: - Generic account detail

struct ProviderAccountDetail: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let delete: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(EmailPrivacy.key) private var hideEmails = false

  private var spec: ProviderSpec? { ProviderCatalog.spec(account.identity.providerID) }
  private var state: ProviderUsageState? { model.providerUsage[account.id] }
  private var isDefault: Bool { model.status?.isDefault(account) == true }
  private var name: String {
    EmailPrivacy.display(
      account.identity.email ?? state?.usage?.email ?? account.identity.accountLabel, hide: hideEmails)
  }
  private var subtitle: String {
    [account.identity.providerID.guiName, state?.usage?.plan?.capitalized, state?.usage?.organization]
      .compactMap { $0 }.joined(separator: " · ")
  }

  var body: some View {
    AIMScrollView {
      VStack(spacing: 8) {
        AIMPanel(title: "Identity", importance: .primary, headerAccessories: AnyView(badges)) {
          VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text(name).font(AIMTheme.sans(20, weight: .semibold)).lineLimit(1).textSelection(.enabled)
              HStack(spacing: 6) {
                ProviderStatusDot(entry: model.providerStatus[account.identity.providerID])
                Text(subtitle).font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted)
                  .textSelection(.enabled)
              }
            }
            if account.verification.state.attentionLabel != nil {
              Text(EmailPrivacy.display(account.verification.detail)).font(AIMTheme.sans(11))
                .foregroundStyle(AIMTheme.muted).textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 4) { actions }
              VStack(alignment: .leading, spacing: 4) { actions }
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        ProviderUsagePanel(account: account, model: model)
        AIMPanel(title: "Account details") {
          VStack(spacing: 0) {
            DetailRow(label: "Saved sign-in", value: account.credentialFile.path)
            DetailRow(
              label: "Imported",
              value: account.importedAt.formatted(date: .abbreviated, time: .shortened), zebra: true)
            DetailRow(
              label: "Last switched",
              value: account.lastUsedAt?.formatted(date: .abbreviated, time: .shortened)
                ?? "Not switched yet")
          }
        }
        Group {
          if let notice = model.notice {
            Notice(text: notice, tone: AIMTheme.blue)
              .transition(reduceMotion ? .identity : .opacity)
          }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.notice)
      }.frame(maxWidth: .infinity)
    }.frame(maxWidth: .infinity)
  }

  private var badges: some View {
    HStack(spacing: 6) {
      if isDefault {
        Badge(text: "Default", color: AIMTheme.green.opacity(0.14), ink: AIMTheme.ink)
      }
      if let attention = account.verification.state.attentionLabel {
        Badge(text: attention, color: account.verification.state.color)
      } else if state?.needsSignIn == true {
        Badge(text: "Needs sign-in", color: VerificationState.needsSignIn.color)
      }
    }
  }

  @ViewBuilder private var actions: some View {
    AIMButton(
      title: isDefault ? AccountActionCopy.usingDefault : AccountActionCopy.use,
      icon: isDefault ? .doubleCheck : .check,
      tone: .primary,
      disabled: model.isBusy
    ) { Task { await model.switchDefault(to: account.id) } }
    AccountMenuBarUsageButton(accountID: account.id)
      .id(account.id).disabled(model.isBusy)
    AIMIconButton(
      icon: .refresh,
      label: state?.isRefreshing == true ? "Refreshing usage" : "Refresh usage",
      disabled: model.isBusy || state?.isRefreshing == true
    ) { Task { await model.refreshProviderUsage(accountID: account.id) } }
    if let dashboard = spec?.dashboard {
      AIMButton(title: "Open dashboard", icon: .link, disabled: model.isBusy) {
        model.openDashboard(dashboard)
      }
    }
    AIMIconButton(
      icon: .trash,
      label: AccountActionCopy.delete,
      tone: .danger,
      disabled: model.isBusy || !model.canDeleteAccount(account.id),
      action: delete)
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
