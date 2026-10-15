import AIManagerCore
import AppKit
import SwiftUI

/// The account list (drag to reorder) beside the selected account's detail.
struct AccountsPage: View {
  @ObservedObject var model: AccountViewModel
  let query: String
  @State private var pendingDeletion: AccountRecord?
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  @AppStorage(UsagePercentagePreferences.showsUsedKey) private var showsUsed = false

  private var accounts: [AccountRecord] {
    AccountSearch.filter(model.status?.accounts ?? [], query: query, hideEmails: hideEmails)
  }

  var body: some View {
    // Only the page scrolls: the table shows every row.
    AIMScrollPage {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        AccountsTableCard(
          accounts: accounts, query: query, model: model,
          focusedID: model.selectedAccountID, now: context.date, hideEmails: hideEmails,
          showsUsed: showsUsed,
          focus: { model.selectedAccountID = $0 },
          delete: { prepareDeletion(of: $0) },
          loading: !model.hasLoaded,
          onMove: query.isEmpty
            ? { id, target in Task { await model.moveAccount(id, to: target) } } : nil,
          contextMenu: { AnyView(accountContextMenu(for: $0)) })
      }
      if let account = model.selectedAccount {
        // The Overview's focused-account card, for the selected account.
        TimelineView(.periodic(from: .now, by: 60)) { context in
          FocusedAccountCard(
            account: account, model: model, now: context.date, hideEmails: hideEmails,
            showsUsed: showsUsed, delete: { prepareDeletion(of: account) })
        }
        .aimFadeOnChange(account.id)
        Group {
          if account.usesGenericDetail {
            ProviderAccountDetail(account: account, model: model) {
              prepareDeletion(of: account)
            }
          } else {
            AccountDetail(account: account, model: model) {
              prepareDeletion(of: account)
            }
          }
        }
        .aimFadeOnChange(account.id)
      } else {
        EmptyAccountView(model: model)
      }
    }
    .accountDeletionAlert(model: model, pending: $pendingDeletion)
    // The page restores its selection once per launch, then remembers each change.
    .onChange(of: model.hasLoaded, initial: true) { _, loaded in
      guard loaded, !AIMPlace.accountsFocusRestored else { return }
      AIMPlace.accountsFocusRestored = true
      let ids = model.status?.accounts.map(\.id) ?? []
      if let saved = AIMPlace.accountsFocus(in: ids) { model.selectedAccountID = saved }
    }
    .onChange(of: model.selectedAccountID) { _, id in
      if AIMPlace.accountsFocusRestored { AIMPlace.saveAccountsFocus(id) }
    }
  }

  @ViewBuilder
  private func accountContextMenu(for account: AccountRecord) -> some View {
    let isDefault = model.status?.isDefault(account) == true
    Button(isDefault ? AccountActionCopy.usingDefault : AccountActionCopy.use) {
      Task { await model.switchDefault(to: account.id) }
    }
    .disabled(model.isBusy)
    if account.usesGenericDetail {
      Button("Refresh usage") {
        Task { await model.refreshProviderUsage(accountID: account.id) }
      }
      .disabled(model.isBusy || model.providerUsage[account.id]?.isRefreshing == true)
    } else {
      Button(
        isDefault
          ? AccountActionCopy.open(account.identity.providerID)
          : AccountActionCopy.useAndOpen(account.identity.providerID)
      ) {
        Task { await model.openAccount(account.id) }
      }
      .disabled(model.isBusy)
      Button(AccountActionCopy.check) {
        Task { await model.checkAccount(account.id) }
      }
      .disabled(model.isBusy)
      Button(account.identity.providerID == .claudeCode ? "Copy config path" : AccountActionCopy.copyAuthPath) {
        model.copySavedAuthPath(for: account.id)
      }
    }
    Divider()
    Button("Move up") {
      if let target = model.adjacentAccountID(to: account.id, offset: -1) {
        Task { await model.moveAccount(account.id, to: target) }
      }
    }.disabled(model.isBusy || model.adjacentAccountID(to: account.id, offset: -1) == nil)
    Button("Move down") {
      if let target = model.adjacentAccountID(to: account.id, offset: 1) {
        Task { await model.moveAccount(account.id, to: target) }
      }
    }.disabled(model.isBusy || model.adjacentAccountID(to: account.id, offset: 1) == nil)
    Divider()
    Button(AccountActionCopy.delete, role: .destructive) {
      prepareDeletion(of: account)
    }
    .disabled(model.isBusy || !model.canDeleteAccount(account.id))
  }

  private func prepareDeletion(of account: AccountRecord) {
    model.requestDeletion(of: account, into: $pendingDeletion)
  }
}
/// Drag-to-reorder math for the Accounts list.
enum AccountReorder {
  /// The account to move and the account whose position it takes, or nil when nothing changes.
  /// `destination` is SwiftUI's insertion offset in the list before the move.
  static func move(
    accountIDs: [UUID], from source: IndexSet, to destination: Int
  ) -> (accountID: UUID, targetID: UUID)? {
    guard source.count == 1, let from = source.first, accountIDs.indices.contains(from),
          (0...accountIDs.count).contains(destination) else { return nil }
    let to = destination > from ? destination - 1 : destination
    guard to != from, accountIDs.indices.contains(to) else { return nil }
    return (accountIDs[from], accountIDs[to])
  }
}

struct AccountListRow: View {
  let account: AccountRecord, selected: Bool, isDefault: Bool
  /// Open incident of the account's provider; a dot shows beside the provider name when it is minor or worse.
  var providerStatus: ProviderStatusEntry? = nil
  /// Only changes when "Hide email addresses" does, so the row redraws.
  var hidesEmails = false
  var body: some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      AccountCell(account: account, hideEmails: hidesEmails, providerStatus: providerStatus)
      Spacer(minLength: 4)
      if isDefault {
        AIMIcon(name: .check).aimText(.body).foregroundStyle(AIMTheme.green)
          .help("Default account")
      }
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityValue(
      [isDefault ? "Default account" : "Not the default account",
       ProviderStatusDot.text(providerStatus).map { "Provider status: \($0)" }]
        .compactMap { $0 }.joined(separator: ". "))
  }
}
private struct EmptyAccountView: View {
  @ObservedObject var model: AccountViewModel
  var body: some View {
    AIMDetailPage {
      AIMSection("Account") {
        if !model.hasLoaded {
          HStack(spacing: AIMTheme.rowSpacing) {
            ProgressView().controlSize(.small)
            Text("Loading accounts…").aimText(.body)
          }
        } else {
          VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
            Text("Add your first account").aimText(.section)
            Text(
              "Switch found no saved account. Sign in to Codex or Grok Build, or use Advanced Import for an existing Codex folder."
            ).aimText(.secondary)
            HStack(spacing: AIMTheme.rowSpacing) {
              AIMButton(title: "Add account", icon: .plus, tone: .primary, disabled: model.isBusy) {
                Task { await model.beginAddAccount() }
              }
              AIMButton(title: "Advanced Import…", icon: .folder, disabled: model.isBusy) {
                Task { await model.beginAdvancedImport() }
              }
            }
          }
        }
      }
    }
  }
}

private struct AccountDetail: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let delete: () -> Void
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  private var issues: [LinkedSettingsDivergence] {
    model.status?.linkedSettingsDivergences.filter { $0.accountID == account.id } ?? []
  }
  var body: some View {
    AIMDetailPage {
      if account.identity.providerID == .codex {
        AccountUsagePanel(account: account, model: model)
      } else if ProviderUsagePanel.applies(to: account, in: model) {
        ProviderUsagePanel(account: account, model: model)
      }
      if account.identity.providerID == .claudeCode {
        ClaudeActivityPanel(model: model)
      }
      if account.identity.providerID == .droid {
        DroidUsageKeyPanel(account: account, model: model)
      }
      AIMSection("Account details") {
        DetailRow(label: account.identity.providerID == .claudeCode ? "Profile config" : "Saved auth",
                  value: account.credentialFile.path)
        DetailRow(label: "Source", value: account.source.path)
        DetailRow(
          label: "\(account.identity.providerID.guiName) home",
          value: account.identity.providerID == .claudeCode ? account.home.path
            : account.identity.providerID == .droid ? model.paths.droidHome.path
            : account.identity.providerID == .grokBuild
              ? model.paths.grokHome.path : model.paths.defaultHome.path)
        DetailRow(
          label: "Imported",
          value: account.importedAt.formatted(date: .abbreviated, time: .shortened))
        DetailRow(
          label: "Last used",
          value: account.lastUsedAt?.formatted(date: .abbreviated, time: .shortened)
            ?? "Not launched yet")
      }
      if !issues.isEmpty {
        AIMSection("Account data needs repair") {
          ForEach(issues) { issue in
            HStack(spacing: AIMTheme.sectionSpacing) {
              AIMIcon(name: .warning).aimText(.body).foregroundStyle(AIMTheme.amber)
              VStack(alignment: .leading, spacing: 2) {
                AIMCopyablePath(path: issue.relativePath)
                AIMCopyablePath(path: issue.localPath.path)
              }
              Spacer()
              WarningCopyButton(label: "Copy repair warning") {
                model.copyWarnings([
                  "Account data needs repair: \(issue.relativePath)\nLocation: \(issue.localPath.path)"
                ])
              }
              AIMButton(title: "Back up and repair", tone: .danger, disabled: model.isBusy) {
                Task { await model.repairLinkedSetting(issue) }
              }
            }
          }
        }
      }
    }
  }
}

enum UsagePresentation {
  struct Fact: Identifiable, Equatable {
    let label: String
    let value: String
    var help: String? = nil
    var id: String { label }
  }

  struct ActivityDay: Identifiable, Equatable {
    let date: Date
    let tokens: Int64
    var id: Date { date }
  }

  static func accountFacts(_ snapshot: CodexAccountUsageSnapshot) -> [Fact] {
    var facts: [Fact] = []
    if let allowed = snapshot.rateLimits?.ordinaryUsageAllowed {
      facts.append(Fact(label: "Ordinary usage", value: allowed ? "Available" : "Restricted"))
    }
    if snapshot.account != nil {
      facts.append(Fact(label: "Authentication", value: "Signed in"))
    } else if let required = snapshot.requiresOpenAIAuthentication {
      facts.append(Fact(
        label: "Authentication", value: required ? "Sign-in required" : "Not required"))
    }
    if let fact = resetCreditsFact(snapshot.extras?.resetCredits) { facts.append(fact) }
    if let balance = snapshot.extras?.creditsBalance, !hasBucketCredits(snapshot),
       let text = CodexCreditsText.text(balance: balance) {
      facts.append(Fact(label: "Credits", value: text))
    }
    return facts
  }

  /// "Reset credits: 2" with the soonest expiry; the tooltip lists every expiry.
  static func resetCreditsFact(_ credits: CodexResetCredits?) -> Fact? {
    credits.map { Fact(label: "Reset credits", value: $0.summary, help: $0.expiryList) }
  }

  private static func hasBucketCredits(_ snapshot: CodexAccountUsageSnapshot) -> Bool {
    let buckets = [snapshot.rateLimits?.defaultBucket].compactMap { $0 }
      + (snapshot.rateLimits.map { Array($0.buckets.values) } ?? [])
    return buckets.contains { credits($0.credits) != nil }
  }

  static func summaryFacts(_ summary: CodexUsageSummarySnapshot?) -> [Fact] {
    guard let summary else { return [] }
    var facts: [Fact] = []
    if let value = summary.lifetimeTokens {
      facts.append(Fact(label: "Lifetime", value: formatTokens(value)))
    }
    if let value = summary.peakDailyTokens {
      facts.append(Fact(label: "Peak day", value: formatTokens(value)))
    }
    if let value = summary.currentStreakDays {
      facts.append(Fact(label: "Current streak", value: formatDays(value)))
    }
    if let value = summary.longestStreakDays {
      facts.append(Fact(label: "Longest streak", value: formatDays(value)))
    }
    if let value = summary.longestRunningTurnSeconds {
      facts.append(Fact(label: "Longest turn", value: formatDuration(value)))
    }
    return facts
  }

  static func credits(_ credits: CodexCreditsSnapshot?) -> String? {
    guard let credits else { return nil }
    if credits.unlimited == true { return "Unlimited" }
    if let balance = nonempty(credits.balance) {
      // Codex sends a fixed-point string such as "796.4009760000".
      return CodexCreditsText.text(balance: balance) ?? balance
    }
    if let hasCredits = credits.hasCredits { return hasCredits ? "Available" : "None" }
    return nil
  }

  static func spendControl(_ reached: Bool?) -> String? {
    reached.map { $0 ? "Reached" : "Not reached" }
  }

  static func hasWindow(_ window: CodexRateLimitWindowSnapshot?) -> Bool {
    window?.usedPercent != nil
  }

  static func hasContent(_ bucket: CodexRateLimitBucketSnapshot) -> Bool {
    hasWindow(bucket.primary) || hasWindow(bucket.secondary) || credits(bucket.credits) != nil
      || spendControl(bucket.spendControlReached) != nil
  }

  static func hasRateLimits(_ bucket: CodexRateLimitBucketSnapshot) -> Bool {
    hasWindow(bucket.primary) || hasWindow(bucket.secondary)
  }

  static func emptyUsageTitle(failure: String?, needsSignIn: Bool) -> String {
    if needsSignIn { return "Sign in to see usage" }
    return failure.map { "Couldn't check usage: \($0)" } ?? "Not checked yet"
  }

  static func activityDays(
    _ rows: [CodexDailyUsageSnapshot],
    endingAt endDate: Date,
    dayCount: Int
  ) -> [ActivityDay] {
    let calendar = activityCalendar
    let end = calendar.startOfDay(for: endDate)
    let count = min(max(dayCount, 1), 366)
    let start = calendar.date(byAdding: .day, value: -(count - 1), to: end) ?? end
    var tokensByDay: [Date: Int64] = [:]
    for row in rows {
      guard let startDate = nonempty(row.startDate),
            let date = activityDate(startDate),
            let tokens = row.tokens,
            date >= start,
            date <= end
      else { continue }
      let value = max(0, tokens)
      let current = tokensByDay[date, default: 0]
      let (sum, overflow) = current.addingReportingOverflow(value)
      tokensByDay[date] = overflow ? Int64.max : sum
    }
    return (0..<count).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
      return ActivityDay(date: date, tokens: tokensByDay[date, default: 0])
    }
  }

  static func exactTokens(_ value: Int64) -> String {
    value.formatted(.number)
  }

  static func activityWeeks(for days: [ActivityDay]) -> [[ActivityDay?]] {
    guard let first = days.first else { return [] }
    let weekday = activityCalendar.component(.weekday, from: first.date)
    var padded = Array(repeating: Optional<ActivityDay>.none, count: weekday - 1)
    padded.append(contentsOf: days.map(Optional.some))
    while !padded.count.isMultiple(of: 7) { padded.append(nil) }
    return stride(from: 0, to: padded.count, by: 7).map {
      Array(padded[$0..<$0 + 7])
    }
  }

  static func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
  }

  static func formatTokens(_ value: Int64) -> String {
    value.formatted(.number.notation(.compactName))
  }

  static func formatCurrency(_ value: Double) -> String {
    if value >= 1_000 {
      return "$" + (value / 1_000).formatted(
        .number.precision(.fractionLength(0...1))) + "K"
    }
    return "$" + value.formatted(
      .number.precision(.fractionLength(value < 10 ? 0...2 : 0...0)))
  }

  private static func formatDays(_ value: Int64) -> String {
    "\(value) day\(value == 1 ? "" : "s")"
  }

  private static func formatDuration(_ seconds: Int64) -> String {
    Duration.seconds(seconds).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
  }

  private static let activityCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  private static func activityDate(_ value: String) -> Date? {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
          let date = activityCalendar.date(from: DateComponents(
            calendar: activityCalendar, timeZone: activityCalendar.timeZone,
            year: year, month: month, day: day))
    else { return nil }
    let components = activityCalendar.dateComponents([.year, .month, .day], from: date)
    return components.year == year && components.month == month && components.day == day
      ? date : nil
  }
}

struct UsageActivityCalendar: View {
  /// The remembered activity range (UserDefaults), shared by every account.
  static let periodKey = "usageTokenPeriod"
  let rows: [CodexDailyUsageSnapshot]
  @ObservedObject var model: AccountViewModel
  @AppStorage(UsageActivityCalendar.periodKey) private var storedPeriod = CodexTokenPeriod.yearly.rawValue
  @State private var selectedDate: Date?
  @State private var projects: [CodexProjectDailyActivity] = []
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var period: CodexTokenPeriod {
    get { CodexTokenPeriod(rawValue: storedPeriod) ?? .yearly }
    nonmutating set { storedPeriod = newValue.rawValue }
  }

  private var periodSelection: Binding<CodexTokenPeriod> {
    Binding(get: { period }, set: { period = $0 })
  }

  var body: some View {
    let endDate = period.dateRange(endingAt: Date())?.upperBound ?? Date()
    let days = UsagePresentation.activityDays(rows, endingAt: endDate, dayCount: period.dayCount)
    let maximumTokens = days.lazy.map(\.tokens).max() ?? 0
    let selectedDay = days.first { $0.date == selectedDate }
    let weeks = UsagePresentation.activityWeeks(for: days)
    VStack(alignment: .leading, spacing: AIMTheme.sectionSpacing) {
      HStack(spacing: AIMTheme.rowSpacing) {
        if let selectedDay {
          Text(selectedDay.date.formatted(date: .abbreviated, time: .omitted))
            .aimText(.secondary)
          Text("\(UsagePresentation.exactTokens(selectedDay.tokens)) tokens")
            .aimText(.body).monospacedDigit()
        }
        Spacer()
        TokenPeriodPicker(selection: periodSelection)
      }
      TokenStatistic(
        period: period,
        tokens: period.tokens(in: rows, endingAt: Date()),
        price: model.apiPrice)
      if period.dayCount <= 7 {
        HStack(spacing: 6) {
          ForEach(days) { day in
            VStack(spacing: 5) {
              Text(day.date.formatted(.dateTime.weekday(.narrow)))
                .aimText(.secondary)
              ActivityCell(
                day: day, maximumTokens: maximumTokens,
                selected: selectedDate == day.date, size: 18
              ) { selectedDate = day.date }
            }
          }
          Spacer()
        }
      } else {
        // The calendar shrinks its cells to fit narrow windows.
        ViewThatFits(in: .horizontal) {
          ForEach([cellSize, 8, 7, 6, 5], id: \.self) { size in
            HStack(alignment: .top, spacing: 0) {
              ActivityHeatmap(weeks: weeks, maximumTokens: maximumTokens,
                selectedDate: selectedDate, size: size) { selectedDate = $0 }
              Spacer(minLength: 0)
            }
          }
        }
      }
      if !projects.isEmpty {
        VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
          Text("Projects in this Codex home")
            .aimText(.body)
            .help("Recorded from local conversation token events. These shared-home totals are separate from account usage.")
          ForEach(projects, id: \.project) { project in
            HStack(spacing: AIMTheme.sectionSpacing) {
              if project.project.hasPrefix("/") {
                AIMCopyablePath(path: project.project)
              } else { Text(project.project).aimText(.body) }
              Spacer()
              Text("\(UsagePresentation.exactTokens(project.tokens)) tokens")
                .aimText(.secondary).monospacedDigit()
              if !project.isComplete {
                AIMIcon(name: .info).aimFont(.secondary).foregroundStyle(AIMTheme.amber)
                  .help("Some source records are incomplete. Previously recorded totals were retained.")
              }
            }
          }
        }
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: period)
    .onChange(of: storedPeriod) { _, _ in
      if let selectedDate, !days.contains(where: { $0.date == selectedDate }) {
        self.selectedDate = nil
      }
    }
    .onChange(of: model.selectedAccountID) { _, _ in
      selectedDate = nil
      projects = []
    }
    .task(id: selectedDate) {
      projects = []
      guard let selectedDate else { return }
      let result = await model.projectActivity(on: selectedDate)
      guard !Task.isCancelled else { return }
      projects = result
    }
  }

  private var cellSize: CGFloat { period == .yearly ? 9 : 13 }
}

struct ActivityHeatmap: View {
  let weeks: [[UsagePresentation.ActivityDay?]]
  let maximumTokens: Int64
  let selectedDate: Date?
  let size: CGFloat
  let select: (Date) -> Void
  @State private var hovered = CGPoint.zero
  @State private var pointerInside = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  private var pitch: CGFloat { size + 3 }
  func day(at point: CGPoint) -> UsagePresentation.ActivityDay? {
    guard point.x >= 15, point.y >= 0 else { return nil }
    let column = Int((point.x - 15) / pitch), row = Int(point.y / pitch)
    guard weeks.indices.contains(column), (0..<7).contains(row),
      (point.x - 15).truncatingRemainder(dividingBy: pitch) < size,
      point.y.truncatingRemainder(dividingBy: pitch) < size else { return nil }
    return weeks[column][row]
  }

  func selection(after key: KeyEquivalent) -> Date? {
    let days = weeks.flatMap { $0 }.compactMap { $0 }
    guard !days.isEmpty else { return nil }
    let offset: Int
    switch key {
    case .leftArrow: offset = -7
    case .rightArrow: offset = 7
    case .upArrow: offset = -1
    case .downArrow: offset = 1
    default: return nil
    }
    let index = days.firstIndex { $0.date == selectedDate } ?? days.count - 1
    return days[min(max(index + offset, 0), days.count - 1)].date
  }

  var body: some View {
    let hoverDay = pointerInside && isEnabled ? day(at: hovered) : nil
    Canvas { context, _ in
      for row in [1, 3, 5] {
        context.draw(Text(row == 1 ? "M" : row == 3 ? "W" : "F")
          .font(AIMTextRole.secondary.font).foregroundStyle(.secondary),
          at: CGPoint(x: 5, y: CGFloat(row) * pitch + size / 2))
      }
      for (column, week) in weeks.enumerated() {
        for (row, day) in week.enumerated() {
          guard let day else { continue }
          let rect = CGRect(x: 15 + CGFloat(column) * pitch, y: CGFloat(row) * pitch,
                            width: size, height: size)
          let path = Path(roundedRect: rect, cornerRadius: max(1, size * 0.18))
          let intensity = maximumTokens > 0
            ? 0.24 + 0.70 * sqrt(Double(day.tokens) / Double(maximumTokens)) : 0
          context.fill(path, with: .color(day.tokens > 0
            ? AIMTheme.green.opacity(intensity) : AIMTheme.track))
          if selectedDate == day.date {
            context.stroke(path, with: .color(.primary), lineWidth: 1)
          }
        }
      }
    }
    .frame(width: 15 + CGFloat(weeks.count) * pitch - 3, height: 7 * pitch - 3)
    .uiLint(.item)
    .overlay(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: max(1, size * 0.18))
        .fill(Color.primary).frame(width: size, height: size)
        .opacity(hoverDay == nil ? 0 : 0.07)
        .offset(x: 15 + floor(max(0, hovered.x - 15) / pitch) * pitch,
                y: floor(max(0, hovered.y) / pitch) * pitch)
        .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      switch phase {
      case .active(let point):
        pointerInside = isEnabled && day(at: point) != nil
        if pointerInside { hovered = point }
      case .ended: pointerInside = false
      }
    }
    .gesture(SpatialTapGesture().onEnded { event in
      if isEnabled, let day = day(at: event.location) { select(day.date) }
    })
    .help(hoverDay.map {
      "\($0.date.formatted(date: .complete, time: .omitted)): \(UsagePresentation.exactTokens($0.tokens)) tokens"
    } ?? "Daily token activity. Select a day for details.")
    .focusable()
    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { event in
      guard isEnabled, let date = selection(after: event.key) else { return .ignored }
      select(date)
      return .handled
    }
    .accessibilityRepresentation {
      HStack(alignment: .top, spacing: 3) {
        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
          VStack(spacing: 3) {
            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
              if let day {
                Button { select(day.date) } label: { Color.clear.frame(width: size, height: size) }
                  .buttonStyle(.plain)
                  .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                  .accessibilityValue("\(UsagePresentation.exactTokens(day.tokens)) tokens")
                  .accessibilityAddTraits(selectedDate == day.date ? .isSelected : [])
              } else {
                Color.clear.frame(width: size, height: size).accessibilityHidden(true)
              }
            }
          }
        }
      }.padding(.leading, 15)
    }
  }
}

private struct ActivityCell: View {
  let day: UsagePresentation.ActivityDay
  let maximumTokens: Int64
  let selected: Bool
  let size: CGFloat
  let select: () -> Void
  private var fill: Color {
    guard day.tokens > 0, maximumTokens > 0 else {
      return AIMTheme.track
    }
    let intensity = 0.24 + 0.70 * sqrt(Double(day.tokens) / Double(maximumTokens))
    return AIMTheme.green.opacity(intensity)
  }

  var body: some View {
    Button(action: select) {
      RoundedRectangle(cornerRadius: max(1, size * 0.18))
        .fill(fill)
        .overlay {
          if selected {
            RoundedRectangle(cornerRadius: max(1, size * 0.18)).stroke(Color.primary, lineWidth: 1)
          }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .uiLint(.item)
    }
    .buttonStyle(.plain)
    .help("\(day.date.formatted(date: .complete, time: .omitted)): \(UsagePresentation.exactTokens(day.tokens)) tokens")
    .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
    .accessibilityValue("\(UsagePresentation.exactTokens(day.tokens)) tokens")
  }
}

private struct AccountUsagePanel: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel

  private var snapshot: CodexAccountUsageSnapshot? {
    model.needsSignIn(account) ? nil : model.usage(for: account.id)
  }
  private var cached: CachedCodexAccountUsage? { model.cachedUsage(for: account.id) }
  private var isRefreshing: Bool { model.usageRefreshAccountID == account.id }
  private var usageFailure: String? {
    model.usageError(for: account.id) ?? cached?.failureMessage
  }

  private var limitBuckets: [(key: String, value: CodexRateLimitBucketSnapshot)] {
    var result: [(String, CodexRateLimitBucketSnapshot)] = []
    var seen = Set<String>()
    if let limits = snapshot?.rateLimits {
      if let bucket = limits.defaultBucket {
        let key = bucket.id ?? "default"
        if UsagePresentation.hasContent(bucket) {
          seen.insert(key)
          result.append((key, bucket))
        }
      }
      for (key, bucket) in limits.buckets.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
        let identity = bucket.id ?? key
        guard seen.insert(identity).inserted else { continue }
        if UsagePresentation.hasContent(bucket) { result.append((key, bucket)) }
      }
    }
    // Model buckets such as Spark from the ChatGPT backend, when the app-server did not list them.
    let titles = Set(result.map { Self.title(of: $0.1, key: $0.0) })
    for bucket in snapshot?.extras?.additionalBuckets ?? [] {
      let key = bucket.id ?? bucket.name ?? "extra"
      guard seen.insert(key).inserted, !titles.contains(Self.title(of: bucket, key: key)) else { continue }
      result.append((key, bucket))
    }
    return result
  }

  static func title(of bucket: CodexRateLimitBucketSnapshot, key: String) -> String {
    CodexBucketNaming.title(id: bucket.id, name: bucket.name, model: bucket.model, fallback: key)
  }

  private var monthlyCredits: CodexMonthlyCredits? { snapshot?.extras?.monthlyCredits }
  private var hasLimits: Bool {
    monthlyCredits != nil || !limitBuckets.isEmpty
  }

  var body: some View {
    AIMSection("Usage", accessory: {
      if !hasLimits {
        EmptyUsageHeader(reason: AccountUsageSummary.reason(for: account, model: model).full,
          isRefreshing: isRefreshing, disabled: model.isBusy,
          refresh: { Task { await model.refreshUsage(accountID: account.id) } },
          copy: { model.copyWarnings([AccountUsageSummary.reason(for: account, model: model).full]) })
      } else {
        usageStatus
      }
    }) {
      if snapshot != nil, hasLimits {
        ForEach(limitBuckets, id: \.key) { item in
          UsageBucket(
            bucket: item.value,
            fallbackName: item.key,
            accountID: account.id,
            refresh: { Task { await model.refreshUsage(accountID: account.id) } }
          )
        }

        if let monthlyCredits {
          MonthlyCreditsRow(accountID: account.id, credits: monthlyCredits) {
            Task { await model.refreshUsage(accountID: account.id) }
          }
        }

        HiddenUsageRowsNote(
          accountID: account.id,
          rowIDs: limitBuckets.flatMap { item in
            ["primary", "secondary"].map { "\(item.key)/\($0)" }
          } + (monthlyCredits == nil ? [] : [MonthlyCreditsRow.rowID]))

        if monthlyCredits == nil, !limitBuckets.contains(where: { UsagePresentation.hasRateLimits($0.value) }) {
          UsageUnavailableRow(text: "Rate limits unavailable")
        }
      } else {
        VStack(alignment: .leading, spacing: AIMTheme.sectionSpacing) {
          HStack {
            Text("Codex").aimText(.section)
            Spacer()
          }
          ForEach(AccountUsageSummary.emptyWindows(for: account, model: model)) { window in
            ProviderWindowMeter(window: window, providerID: account.identity.providerID, now: Date())
          }
        }
      }
    }
    if let snapshot {
      let accountFacts = UsagePresentation.accountFacts(snapshot)
      let summaryFacts = UsagePresentation.summaryFacts(snapshot.usage)
      if !accountFacts.isEmpty || !summaryFacts.isEmpty {
        AIMSection("Usage facts") {
          ForEach(accountFacts) { fact in
            UsageFact(label: fact.label, value: fact.value, help: fact.help)
          }
          ForEach(summaryFacts) { fact in
            UsageFact(label: fact.label, value: fact.value)
          }
        }
      }
    }
    if !model.dailyUsage(for: account.id).isEmpty {
      AIMSection("Daily activity") {
        UsageActivityCalendar(rows: model.dailyUsage(for: account.id), model: model)
      }
    }
  }

  @ViewBuilder private var usageStatus: some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      if let failure = usageFailure {
        Text(failure).aimText(.secondary, tint: AIMTheme.amber).lineLimit(1)
          .help(failure)
        WarningCopyButton(label: "Copy usage error") {
          model.copyWarnings([failure])
        }
      } else if let fetchedAt = snapshot?.fetchedAt {
        Text(cached?.isStale == true ? "Cached" : "Updated")
          .aimText(.secondary)
        Text(fetchedAt.formatted(date: .omitted, time: .shortened))
          .aimText(.secondary).monospacedDigit()
      }
      refreshButton
    }
  }

  private var refreshButton: some View {
    AIMIconButton(
      icon: .refresh,
      label: isRefreshing ? "Refreshing usage" : "Refresh usage",
      disabled: model.usageRefreshAccountID != nil || model.isBusy
    ) {
      Task { await model.refreshUsage(accountID: account.id) }
    }
  }

}

private struct UsageBucket: View {
  let bucket: CodexRateLimitBucketSnapshot
  let fallbackName: String
  let accountID: UUID
  let refresh: () -> Void
  @AppStorage private var hiddenRaw: String

  init(
    bucket: CodexRateLimitBucketSnapshot, fallbackName: String, accountID: UUID,
    refresh: @escaping () -> Void
  ) {
    self.bucket = bucket
    self.fallbackName = fallbackName
    self.accountID = accountID
    self.refresh = refresh
    _hiddenRaw = AppStorage(wrappedValue: "", HiddenUsageRows.key(for: accountID))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AIMTheme.sectionSpacing) {
      HStack(alignment: .firstTextBaseline, spacing: AIMTheme.sectionSpacing) {
        Text(AccountUsagePanel.title(of: bucket, key: fallbackName))
          .aimText(.section).lineLimit(1)
        if let model = bucket.model, !model.isEmpty {
          Text(model).aimText(.secondary, monospaced: true).lineLimit(1)
        }
        Spacer()
        if let plan = CodexPlanNames.display(UsagePresentation.nonempty(bucket.plan)) {
          Text(plan).aimText(.secondary)
        }
      }
      let rows = bucket.windowRows(idPrefix: "\(fallbackName)/")
      if !rows.isEmpty {
        let hidden = HiddenUsageRows.parse(hiddenRaw)
        ForEach(rows.filter { !hidden.contains($0.id) }) { row in
          UsageMeter(window: row.usage)
            .usageRowMenu(accountID: accountID, rowID: row.id, refresh: refresh)
        }
      }
      let credits = UsagePresentation.credits(bucket.credits)
      let spendControl = UsagePresentation.spendControl(bucket.spendControlReached)
      if credits != nil || spendControl != nil {
        VStack(spacing: AIMTheme.rowSpacing) {
          if let credits { UsageFact(label: "Credits", value: credits) }
          if let spendControl { UsageFact(label: "Spend control", value: spendControl) }
        }
      }
    }
  }
}

struct UsageUnavailableRow: View {
  let text: String
  var body: some View {
    ProviderWindowMeter(window: UsageWindow(id: "usage", title: "Usage", usedPercent: nil),
      providerID: .codex, now: Date()).help(text)
  }
}

struct EmptyUsageHeader: View {
  let reason: String
  let isRefreshing: Bool
  let disabled: Bool
  let refresh: () -> Void
  let copy: () -> Void

  var body: some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      Text(reason).aimText(.secondary).lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .trailing).help(reason)
      AIMIconButton(icon: .refresh, label: "Check again", disabled: disabled || isRefreshing, action: refresh)
      AIMIconButton(icon: .copy, label: "Copy reason", action: copy)
    }
    .foregroundStyle(.secondary)
  }
}

/// A missing value keeps the real bar's four-point frame.
struct DottedUsageTrack: View {
  var body: some View {
    Canvas { context, size in
      var path = Path()
      path.move(to: CGPoint(x: 0, y: size.height / 2))
      path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
      context.stroke(path, with: .color(AIMTheme.track),
        style: StrokeStyle(lineWidth: 4, lineCap: .butt, dash: [4, 3]))
    }
    .frame(height: 4)
    .clipShape(Capsule())
    .accessibilityHidden(true)
  }
}

/// A Codex window drawn with the same pace tick, colors, and tooltip as generic providers.
private struct UsageMeter: View {
  let window: UsageWindow

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      ProviderWindowMeter(window: window, providerID: .codex, now: context.date)
    }
  }
}

/// The team or enterprise monthly credit pool from the account's `individual_limit`.
private struct MonthlyCreditsRow: View {
  static let rowID = "monthly-credits"
  let accountID: UUID
  let credits: CodexMonthlyCredits
  let refresh: () -> Void
  @AppStorage private var hiddenRaw: String

  init(accountID: UUID, credits: CodexMonthlyCredits, refresh: @escaping () -> Void) {
    self.accountID = accountID
    self.credits = credits
    self.refresh = refresh
    _hiddenRaw = AppStorage(wrappedValue: "", HiddenUsageRows.key(for: accountID))
  }

  var body: some View {
    if !HiddenUsageRows.parse(hiddenRaw).contains(Self.rowID) {
      UsageMeter(window: credits.window)
        .usageRowMenu(accountID: accountID, rowID: Self.rowID, refresh: refresh)
    }
  }
}

private struct TokenPeriodPicker: View {
  @Binding var selection: CodexTokenPeriod

  var body: some View {
    // Five periods are too many for a segmented control, so they sit in a pop-up menu.
    AIMPopUp(
      options: CodexTokenPeriod.allCases, selection: $selection,
      accessibilityLabel: "Token period", label: \.label)
  }
}

private struct TokenStatistic: View {
  let period: CodexTokenPeriod
  let tokens: Int64
  let price: CodexAPIPrice?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: AIMTheme.rowSpacing) {
      Text(UsagePresentation.formatTokens(tokens))
        .aimText(.body)
        .monospacedDigit()
      Text("tokens").aimText(.secondary)
      if let price {
        Text("·").aimText(.secondary)
        Text("≈\(UsagePresentation.formatCurrency(price.inputEquivalent(for: tokens))) API input rate")
          .aimText(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(period.label)
    .accessibilityValue(detail)
    .help(detail)
  }

  private var detail: String {
    var value = "\(UsagePresentation.exactTokens(tokens)) tokens"
    guard let price else { return value }
    value += ". API equivalents for \(price.model): "
      + "input \(UsagePresentation.formatCurrency(price.inputEquivalent(for: tokens))), "
      + "cached input \(price.cachedInputEquivalent(for: tokens).map(UsagePresentation.formatCurrency) ?? "unavailable"), "
      + "output \(UsagePresentation.formatCurrency(price.outputEquivalent(for: tokens))). "
      + "These are rate comparisons, not billed spend."
    return value
  }
}

struct UsageFact: View {
  let label: String
  let value: String
  var help: String? = nil
  var body: some View {
    LabeledContent {
      Text(value).aimText(.secondary).monospacedDigit()
    } label: {
      Text(label).aimText(.body)
    }
    .help(help ?? "")
  }
}

/// One fact of a grouped form: the label in Body and the value on the trailing side. Paths use
/// the monospaced Secondary style and copy on click.
struct DetailRow: View {
  let label: String, value: String
  var body: some View {
    LabeledContent {
      // Paths use the system monospaced font; other values read in the system font.
      if value.hasPrefix("/") || value.hasPrefix("~/") {
        AIMCopyablePath(path: value)
      } else {
        Text(value).aimText(.secondary).lineLimit(1).truncationMode(.middle)
          .textSelection(.enabled).help(value)
      }
    } label: {
      Text(label).aimText(.body)
    }
  }
}

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
  /// A fixed width, so the button matches the disabled Default button in a table row.
  var width: CGFloat? = nil
  /// "Sign in again" on the focused card; a table row passes the short "Sign in".
  var title = "Sign in again"

  var body: some View {
    Button(title) { Task { await model.beginSignIn(for: account.id) } }
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
  struct EmptyReason {
    let short: String
    let full: String
  }

  @MainActor static func reason(for account: AccountRecord, model: AccountViewModel) -> EmptyReason {
    let state = model.providerUsage[account.id]
    if model.needsSignIn(account) {
      return EmptyReason(short: "Sign in to see usage", full: "Sign in to see usage")
    }
    let failure = account.identity.providerID == .codex
      ? model.usageError(for: account.id) ?? model.cachedUsage(for: account.id)?.failureMessage : state?.error
    if let failure {
      return EmptyReason(short: "Couldn't check", full: "Couldn't check usage: \(failure)")
    }
    if state?.usage?.availability == .noPlan {
      return EmptyReason(short: "No Go plan", full: "No Go subscription on this key")
    }
    if state?.checkedAt != nil {
      return EmptyReason(short: "No usage available", full: "\(account.identity.providerID.guiName) reports no usage")
    }
    return EmptyReason(short: "Not checked yet", full: "Not checked yet")
  }

  @MainActor static func emptyWindows(for account: AccountRecord, model: AccountViewModel) -> [UsageWindow] {
    let cached = model.providerUsage[account.id]?.usage?.windows ?? []
    if !cached.isEmpty {
      return cached.map { UsageWindow(id: $0.id, title: $0.title, usedPercent: nil) }
    }
    if let windows = model.status?.accounts.lazy
      .filter({ $0.identity.providerID == account.identity.providerID })
      .compactMap({ model.providerUsage[$0.id]?.usage?.windows })
      .first(where: { !$0.isEmpty }) {
      return windows.map { UsageWindow(id: $0.id, title: $0.title, usedPercent: nil) }
    }
    return knownEmptyWindows(providerID: account.identity.providerID)
  }

  static func knownEmptyWindows(providerID: ProviderID) -> [UsageWindow] {
    let names: [String]
    switch providerID.rawValue {
    case "opencodego": names = ["5 hours", "Weekly", "Monthly"]
    case "codex", "claude-code": names = ["Session", "Weekly"]
    case "grok-build": names = ["Session", "Weekly"]
    case "droid": names = ["Standard tokens"]
    case "gemini-cli": names = ["Pro models", "Flash models"]
    default: names = ["Usage"]
    }
    return names.map { UsageWindow(id: $0, title: $0, usedPercent: nil) }
  }
  /// The visible usage windows of an account, primary first. Empty when usage is unknown or the
  /// account needs a new sign-in (stale values never sit beside that state).
  @MainActor static func windows(for account: AccountRecord, model: AccountViewModel) -> [UsageWindow] {
    model.needsSignIn(account) ? [] : model.accountWindows[account.id] ?? []
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

// MARK: - Card 1: focused account

struct FocusedAccountCard: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let now: Date
  let hideEmails: Bool
  let showsUsed: Bool
  let delete: () -> Void
  @Environment(\.aimCopyPath) private var copyPath

  private var providerID: ProviderID { account.identity.providerID }
  private var name: String { account.identity.accountLabel }
  private var isDefault: Bool { model.status?.isDefault(account) == true }

  /// The right side keeps this width whatever the account shows, so nothing moves between accounts.
  static let usageWidth: CGFloat = 300

  var body: some View {
    let window = AccountUsageSummary.windows(for: account, model: model).first { $0.usedPercent != nil }
    AIMCard {
      VStack(alignment: .leading, spacing: AIMTheme.cardInset) {
        HStack(alignment: .center, spacing: AIMTheme.cardInset) {
          HStack(spacing: 12) {
            ProviderMark(providerID: providerID, size: 44)
            VStack(alignment: .leading, spacing: 2) {
              Text(name).aimText(.title).lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
              HStack(spacing: AIMTheme.rowSpacing) {
                Text(providerID.guiName).aimText(.secondary)
                incidentBadge
                statusBadge
              }
              .frame(height: 18)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          AIMHairline(vertical: true).frame(height: 44)
          UsageWindowBlock(
            window: window, providerID: providerID, showsUsed: showsUsed, now: now,
            note: AccountUsageSummary.reason(for: account, model: model).short)
            .frame(width: Self.usageWidth)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focused account")
        actionRow
      }
      .padding(AIMTheme.cardInset)
    }
  }

  private var actionRow: some View {
    HStack(spacing: AIMTheme.rowSpacing) {
      HStack(spacing: AIMTheme.rowSpacing) {
        if model.needsSignIn(account) {
          SignInButton(account: account, model: model)
        } else if isDefault {
          Button(AccountActionCopy.usingDefault) {}
            .buttonStyle(AIMPushButtonStyle())
            .disabled(true)
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
        if providerID == .droid, model.providerUsage[account.id]?.needsKeychainAccess == true {
          Button("Allow access") { Task { await model.allowDroidUsageAccess(accountID: account.id) } }
            .buttonStyle(AIMPushButtonStyle())
            .disabled(model.isBusy || model.providerUsage[account.id]?.isRefreshing == true)
            .help("Allow Switch to read Droid's login for usage")
        }
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

/// The accounts table: rows share `AIMColumns.accounts` and the card's 16 inset, with no header row.
/// An indented outline: each provider has a 32 pt header (brand tile, name, count) and its accounts
/// sit 24 pt in, joined to the tile by a guide line with an elbow at each row. Clicking a row
/// focuses it. `onMove` turns on drag-and-drop reordering.
struct AccountsTableCard: View {
  let accounts: [AccountRecord]
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
    AIMCard(title: "Accounts", bottomInset: 0) {
      if loading {
        HStack(spacing: AIMTheme.rowSpacing) {
          ProgressView().controlSize(.small)
          Text("Loading accounts…").aimText(.secondary)
        }
        .aimRow().padding(.bottom, AIMTheme.tableEndInset)
      } else if accounts.isEmpty {
        Text(query.isEmpty ? "No accounts yet." : "No accounts match “\(query)”.")
          .aimText(.secondary).aimRow().padding(.bottom, AIMTheme.tableEndInset)
      } else {
        rows
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

  /// The 32 pt header above a group: a 16 pt brand tile, the provider name, and the count as plain "×2".
  private func groupHeader(_ provider: ProviderID, count: Int) -> some View {
    HStack(spacing: 8) {
      ProviderMark(providerID: provider, size: 16)
      HStack(spacing: 6) {
        Text(provider.guiName).aimText(.secondary, tint: .primary).fontWeight(.semibold).lineLimit(1)
        Text("×\(count)").aimText(.secondary).monospacedDigit().layoutPriority(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, AIMTheme.cardInset)
    .frame(height: AIMTheme.groupHeaderHeight)
    // The first 4 pt of the guide line, under the brand tile; the rows draw the rest.
    .overlay(alignment: .bottomLeading) {
      Rectangle().fill(AIMTheme.guideLine).frame(width: 1, height: 4)
        .padding(.leading, AIMTheme.cardInset + 7.5).allowsHitTesting(false).accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(provider.guiName), \(count) \(count == 1 ? "account" : "accounts")")
    .accessibilityAddTraits(.isHeader)
  }

  /// One flat lazy list (each group's header, then its accounts), so a page switch builds only the
  /// rows in view, not every account. Groups sit 6 pt apart (top padding on a header); separators
  /// and guide pieces are overlays, so a group is exactly its header plus 36 pt for each account.
  /// The last row also carries the card's bottom inset.
  private var rows: some View {
    let groups = self.groups
    return LazyVStack(spacing: 0) {
      ForEach(Array(groups.enumerated()), id: \.element.provider) { groupIndex, group in
        groupHeader(group.provider, count: group.accounts.count)
          .padding(.top, groupIndex > 0 ? AIMTheme.groupGap : 0)
        ForEach(Array(group.accounts.enumerated()), id: \.element.id) { index, account in
          let isLast = groupIndex == groups.count - 1 && index == group.accounts.count - 1
          AccountsTableRow(
            account: account, model: model, selected: account.id == focusedID, now: now,
            hideEmails: hideEmails, showsUsed: showsUsed,
            focus: { focus(account.id) }, delete: { delete(account) },
            onMove: onMove, contextMenu: contextMenu)
            .overlay(alignment: .top) {
              if index > 0 { AIMRowSeparator(indent: AIMTheme.groupIndent).allowsHitTesting(false) }
            }
            .overlay(alignment: .topLeading) {
              AccountsGuide(isLastInGroup: index == group.accounts.count - 1)
            }
            .padding(.bottom, isLast ? AIMTheme.tableEndInset : 0)
        }
      }
    }
  }
}

/// The outline piece of one account row: a 1 pt line from the row's top to its middle (to its
/// bottom unless it is the group's last row), and a 10 pt elbow at the row's center that stops
/// 6.5 pt short of the name. One path, so the crossing is not drawn twice. The header draws the
/// first 4 pt, under the brand tile.
private struct AccountsGuide: View {
  let isLastInGroup: Bool

  var body: some View {
    Canvas { context, _ in
      let x = AIMTheme.cardInset + 7.5
      let row = AIMTheme.rowHeight
      var guide = Path(CGRect(x: x, y: 0, width: 1, height: isLastInGroup ? row / 2 : row))
      guide.addRect(CGRect(x: x, y: row / 2, width: 10, height: 1))
      context.fill(guide, with: .color(AIMTheme.guideLine))
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
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

  /// Why the usage cell has no bar, from the state the model already keeps.
  private var usageReason: String {
    let reason = AccountUsageSummary.reason(for: account, model: model).short
    return reason == "Couldn't check" ? "Couldn't check usage" : reason
  }

  var body: some View {
    let columns = AIMColumns.accounts
    let group = AccountsTableCard.group
    let window = AccountUsageSummary.windows(for: account, model: model).first { $0.usedPercent != nil }
    let isDefault = model.status?.isDefault(account) == true
    let percent = OverviewFormat.percent(window, showsUsed: showsUsed)
    #if AI_MANAGER_PREVIEW
    let previewHover = PreviewArguments.value("hover-account") == account.id.uuidString
    #else
    let previewHover = false
    #endif
    let row = AIMTableRow(
      highlighted: selected, focused: keyboardFocus, previewHovering: previewHover, indent: AIMTheme.groupIndent
    ) {
      // The group header above says the provider; a status dot follows the name only for an incident.
      HStack(spacing: AIMTheme.rowSpacing) {
        Text(name).aimText(.body).lineLimit(1).truncationMode(.middle)
        ProviderStatusDot(entry: model.providerStatus[account.identity.providerID], size: 6)
        if account.autoImported {
          let note = "Added automatically from the \(account.identity.providerID.guiName) login on this Mac."
          Image(systemName: "info.circle")
            .aimText(.secondary)
            .help(note)
            .accessibilityLabel(note)
        }
      }
      .aimColumn(columns[0], group: group)
      // The bar and "83% · 6d 19h"; with no window, the reason fills the cell instead.
      HStack(spacing: AIMTheme.rowSpacing) {
        if let window {
          UsageBar(usedPercent: window.usedPercent, showsUsed: showsUsed,
            providerID: account.identity.providerID).frame(minWidth: 40)
          HStack(spacing: 0) {
            Text(percent).aimText(.body).monospacedDigit().aimRolling(percent).uiLint(.number)
            if let reset = window.resetsAt {
              let text = OverviewFormat.compactReset(reset, now: now, usedPercent: window.usedPercent)
              Text(" · " + (text.hasPrefix("in ") ? String(text.dropFirst(3)) : text))
                .aimText(.body).foregroundStyle(.secondary)
            }
          }
          .lineLimit(1)
          .frame(width: 104, alignment: .trailing)
        } else {
          Text(usageReason).aimText(.secondary).lineLimit(1)
            .help(AccountUsageSummary.reason(for: account, model: model).full)
        }
      }
      .accessibilityElement(children: .combine)
      .aimColumn(columns[1], group: group)
      HStack(spacing: AIMTheme.rowSpacing) {
        switch OverviewFormat.rowAction(for: account, model: model) {
        case .isDefault:
          Button("Default") {}
            .buttonStyle(AIMPushButtonStyle(width: AIMTheme.rowButtonWidth))
            .disabled(true)
            .accessibilityLabel(AccountActionCopy.usingDefault)
            .accessibilityHint("This account is already the default.")
        case .signIn:
          SignInButton(account: account, model: model, prominent: false, width: AIMTheme.rowButtonWidth, title: "Sign in")
        case .switchTo:
          Button("Switch") { Task { await model.switchDefault(to: account.id) } }
            .buttonStyle(AIMPushButtonStyle(width: AIMTheme.rowButtonWidth))
            .disabled(model.isBusy || !account.canSwitchDefault)
        }
        AccountMoreMenu(account: account, model: model, delete: delete)
      }
      .uiLint(.actions)
      .aimColumn(columns[2], group: group)
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

/// One usage window with a fixed reset-line slot. Missing usage has a grey reason capsule.
struct UsageWindowBlock: View {
  let window: UsageWindow?
  let providerID: ProviderID
  let showsUsed: Bool
  let now: Date
  var note: String? = nil
  var spacing: CGFloat = 6
  /// The label of a block with no window.
  static let emptyTitle = "Usage"

  private var value: String {
    guard let window else { return "–" }
    return window.usedPercent.map {
      UsagePercentagePreferences.label(forUsed: Int($0.rounded()), showsUsed: showsUsed)
    } ?? "–"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      HStack(spacing: AIMTheme.rowSpacing) {
        Text(window?.title ?? Self.emptyTitle).aimText(.body).lineLimit(1)
        Spacer(minLength: AIMTheme.rowSpacing)
        if window != nil {
          Text(value).aimText(.body).monospacedDigit().lineLimit(1).aimRolling(value)
            .flipsUsedAndLeft(showsUsed).uiLint(.number)
        } else {
          Text(note ?? "Not checked yet").aimText(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.08), in: Capsule()).lineLimit(1)
        }
      }
      .frame(height: 18)
      if window == nil {
        DottedUsageTrack()
      } else {
        UsageBar(usedPercent: window?.usedPercent, showsUsed: showsUsed, providerID: providerID)
      }
      if let reset = window?.resetsAt {
        ResetTimeText(reset: reset, now: now, usedPercent: window?.usedPercent).lineLimit(1)
      } else {
        // An empty line keeps the reset line's height.
        Text(" ").aimText(.secondary).lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
