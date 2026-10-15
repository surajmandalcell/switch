import AIManagerCore
import SwiftUI

// The Overview page: a usage dashboard. A period control and a grouping control drive a totals
// card and four charts (OverviewCharts.swift), then the Maintenance card. Account switching lives
// on Accounts. The history loads off the main actor (AccountViewModel.loadUsageHistory).

// MARK: - Colors

/// A brand color for each service, and one stable palette for models and projects.
enum OverviewPalette {
  private static let ramp: [Color] = [
    0x5B8DEF, 0xF0883E, 0x3FB68B, 0xB26BE0, 0xE5638B, 0xD9B43A,
    0x2FB5C7, 0x7A6BE0, 0x9BCB4A, 0xE0705A, 0x5CA0D3, 0xC98A5E,
  ].map { Color(hex: $0) }
  static let other = Color(nsColor: .tertiaryLabelColor)

  /// FNV-1a: the same key gets the same color on every launch (`hashValue` changes per launch).
  static func hash(_ key: String) -> UInt32 {
    key.utf8.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 }
  }

  static func hashed(_ key: String) -> Color { ramp[Int(hash(key) % UInt32(ramp.count))] }

  /// The key's hashed ramp slot, or the next free one when a larger series on screen already has it,
  /// so no two series of one chart share a color. `taken` collects the slots in use.
  static func color(_ key: String, taken: inout Set<Int>) -> Color {
    var slot = Int(hash(key) % UInt32(ramp.count))
    while taken.contains(slot), taken.count < ramp.count { slot = (slot + 1) % ramp.count }
    taken.insert(slot)
    return ramp[slot]
  }

  /// The service's brand color; its next accounts get lighter and darker steps of it.
  static func account(service: String, rank: Int) -> Color {
    guard UsageBarColor.table[service] != nil,
          let brand = UsageBarColor.color(usedPercent: 0, providerID: ProviderID(rawValue: service)) else { return hashed(service) }
    guard rank > 0, let base = NSColor(brand).usingColorSpace(.sRGB) else { return brand }
    let steps: [CGFloat] = [0, 0.38, -0.3, 0.62, -0.5]
    let step = steps[rank % steps.count]
    return Color(nsColor: base.blended(withFraction: abs(step), of: step > 0 ? .white : .black) ?? base)
  }
}

// MARK: - Data

struct OverviewSeries: Identifiable, Equatable {
  let id: String
  let label: String
  let color: Color
  let tokens: Int64
  /// Tokens per day, aligned with `OverviewDataset.days`.
  let daily: [Int64]
  /// The tool behind an account group (nil for models, projects, and Other); its brand tile
  /// tells two accounts with one label apart.
  var service: String?
}

/// The brand tile of an account group's tool, small enough to sit on the text line.
struct OverviewServiceTile: View {
  static let size: CGFloat = 13
  let service: String?
  /// Keep the tile's space on a row without one ("Other"), so the labels of a list stay aligned.
  var reserve = false

  var body: some View {
    if let service {
      ProviderMark(providerID: ProviderID(rawValue: service), size: Self.size)
    } else if reserve {
      Color.clear.frame(width: Self.size, height: Self.size)
    }
  }
}

/// Everything the cards draw: the chosen period and grouping, and the year behind the heatmap.
struct OverviewDataset: Equatable {
  static let maxSeries = 6

  let period: UsagePeriod
  let grouping: UsageGrouping
  let days: [String]
  let series: [OverviewSeries]
  let totals: UsageTotals
  let yearDays: [String]
  let yearTotals: [Int64]
  /// Token cuts between the four non-empty heat levels.
  let heatCuts: [Int64]

  var yearTokens: Int64 { yearTotals.reduce(0, +) }
  /// The weekday column of the first heatmap day.
  var yearOffset: Int { yearDays.first.map(OverviewDay.weekday) ?? 0 }
  /// A new run of every draw-in starts when this changes, not when numbers refresh.
  var drawKey: Int {
    var hasher = Hasher()
    hasher.combine(period)
    hasher.combine(grouping)
    return hasher.finalize()
  }

  func heatLevel(_ tokens: Int64) -> Int {
    tokens <= 0 ? 0 : 1 + heatCuts.filter { tokens > $0 }.count
  }

  static func heatColor(_ level: Int) -> Color {
    level == 0 ? Color.primary.opacity(0.065) : AIMTheme.blue.opacity([0.26, 0.5, 0.76, 1][min(level, 4) - 1])
  }

  static func make(
    summary: UsageSummary, year: UsageSummary, accounts: [AccountRecord], hideEmails: Bool
  ) -> OverviewDataset {
    let named = Dictionary(accounts.map { ($0.id.uuidString.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    let live = summary.groups.filter { $0.tokens > 0 }
    var ranks: [String: Int] = [:]
    var taken = Set<Int>()
    var series: [OverviewSeries] = live.prefix(maxSeries).map { group in
      let service = group.services.first ?? ""
      let rank = ranks[service, default: 0]
      ranks[service] = rank + 1
      switch summary.grouping {
      case .account:
        let shared = OverviewDayDetail.sharedName(group.key)
        let label = shared ?? named[group.key]?.identity.accountLabel ?? "Removed account"
        return OverviewSeries(
          id: group.key, label: hideEmails && shared == nil ? EmailPrivacy.mask(label) : label,
          color: OverviewPalette.account(service: service, rank: rank), tokens: group.tokens, daily: group.daily,
          service: service.isEmpty ? nil : service)
      case .model, .project:
        return OverviewSeries(
          id: group.key, label: group.label, color: OverviewPalette.color(group.key, taken: &taken),
          tokens: group.tokens, daily: group.daily)
      }
    }
    let rest = live.dropFirst(maxSeries)
    if !rest.isEmpty {
      let daily = summary.days.indices.map { index in rest.reduce(Int64(0)) { $0 + $1.daily[index] } }
      series.append(OverviewSeries(
        id: "other", label: "Other", color: OverviewPalette.other,
        tokens: rest.reduce(0) { $0 + $1.tokens }, daily: daily))
    }
    let active = year.dailyTotals.filter { $0 > 0 }.sorted()
    let cuts = [0.25, 0.5, 0.75].map { active.isEmpty ? Int64(0) : active[min(Int(Double(active.count) * $0), active.count - 1)] }
    return OverviewDataset(
      period: summary.period, grouping: summary.grouping, days: summary.days, series: series,
      totals: summary.totals, yearDays: year.days, yearTotals: year.dailyTotals, heatCuts: cuts)
  }

  // MARK: VoiceOver summaries

  private var periodName: String { "Last \(days.count) days" }
  private var noun: String {
    switch grouping {
    case .account: "account"
    case .model: "model"
    case .project: "project"
    }
  }

  private func tokenText(_ tokens: Int64) -> String { "\(UsagePresentation.formatTokens(tokens)) tokens" }

  var streamSummary: String {
    let busiest = totals.busiestDay.map { ", most on \(OverviewDay.short($0))" } ?? ""
    return "\(periodName), \(tokenText(totals.tokens)) by \(noun)\(busiest)"
  }

  var heatmapSummary: String {
    let top = yearTotals.enumerated().max { ($0.element, $1.offset) < ($1.element, $0.offset) }
    let busiest = top.flatMap { $0.element > 0 ? ", most on \(OverviewDay.short(yearDays[$0.offset]))" : nil } ?? ""
    return "Last 12 months, \(tokenText(yearTokens))\(busiest)"
  }

  var ridgeSummary: String {
    "Daily usage by \(noun). " + series.prefix(3).map { "\($0.label), \(tokenText($0.tokens))" }.joined(separator: ". ")
  }

  var waffleSummary: String {
    let cells = OverviewWaffle.cells(series.map(\.tokens))
    return "Share of tokens by \(noun). "
      + zip(series, cells).map { "\($0.label), \(OverviewWaffle.percent($1).dropLast()) percent" }.joined(separator: ". ")
  }

  /// The explanation under an empty chart.
  var emptyText: String {
    if grouping == .account, series.isEmpty, totals.tokens > 0 {
      return "By account needs history that belongs to one account. Claude Code profiles that share history show under Models and Projects."
    }
    return "No usage in the \(periodName.lowercased()). Use Codex, Claude Code, or Grok Build and it shows here."
  }
}

/// The last dataset, so a page switch draws the charts in its first frame.
@MainActor enum OverviewCache {
  static var last: OverviewDataset?
}

// MARK: - Page

struct OverviewPage: View {
  private static let periodKey = "overviewPeriod"
  private static let groupingKey = "overviewGrouping"

  @ObservedObject var model: AccountViewModel
  /// Goes to another page; the Maintenance card's "Open Backup" uses it.
  let navigate: (AIManagerPage) -> Void
  @State private var period: UsagePeriod
  @State private var grouping: UsageGrouping
  @State private var dataset: OverviewDataset?
  @State private var daySheet: OverviewDayPick?
  @AppStorage(EmailPrivacy.key) private var hideEmails = false

  init(
    model: AccountViewModel,
    navigate: @escaping (AIManagerPage) -> Void = { page in
      NotificationCenter.default.post(name: AIManagerNavigation.request, object: page)
    }
  ) {
    self.model = model
    self.navigate = navigate
    let defaults = UserDefaults.standard
    var period = defaults.string(forKey: Self.periodKey).flatMap(UsagePeriod.init(rawValue:)) ?? .week
    var grouping = defaults.string(forKey: Self.groupingKey).flatMap(UsageGrouping.init(rawValue:)) ?? .account
    #if AI_MANAGER_PREVIEW
    // Preview screenshots: `--overview-period=month --overview-group=model`.
    period = PreviewArguments.value("overview-period").flatMap(UsagePeriod.init(rawValue:)) ?? period
    grouping = PreviewArguments.value("overview-group").flatMap(UsageGrouping.init(rawValue:)) ?? grouping
    #endif
    _period = State(initialValue: period == .year ? .week : period)
    _grouping = State(initialValue: grouping)
    _dataset = State(initialValue: OverviewCache.last)
  }

  private var accounts: [AccountRecord] { model.status?.accounts ?? [] }

  private struct LoadKey: Equatable {
    var period: UsagePeriod
    var grouping: UsageGrouping
    var snapshot: Int
    var accounts: [UUID]
    var hideEmails: Bool
  }

  var body: some View {
    AIMScrollPage {
      if accounts.isEmpty {
        OverviewEmptyCard(model: model)
      } else {
        totalsCard
        chartCard("Tokens per day", height: 200 + OverviewDateAxis.height + 4, hasData: { !$0.series.isEmpty }, footer: true) {
          OverviewStreamChart(dataset: $0)
        }
        chartCard("Activity", note: "(last 12 months, all accounts)", height: nil, hasData: { $0.yearTokens > 0 },
          empty: "No activity in the last 12 months.") { OverviewHeatmap(dataset: $0, onSelect: openDay) }
        chartCard("Trends", height: 300, hasData: { !$0.series.isEmpty }) { OverviewRidgeline(dataset: $0) }
        chartCard("Share of tokens", height: nil, waffle: true, hasData: { !$0.series.isEmpty }) {
          OverviewWaffleChart(dataset: $0)
        }
        RecentBackupsCard(model: model) { navigate(.maintenance) }
      }
    }
    // Keyed on hasLoaded: a cold launch shows this page before the accounts load, and the load
    // guard refuses until then; an unkeyed task would not run again until a page change.
    .task(id: model.hasLoaded) { await model.loadUsageHistory() }
    .task(id: LoadKey(
      period: period, grouping: grouping, snapshot: model.usageHistoryVersion,
      accounts: accounts.map(\.id), hideEmails: hideEmails)
    ) { await rebuild() }
    .onChange(of: period) { _, value in UserDefaults.standard.set(value.rawValue, forKey: Self.periodKey) }
    .onChange(of: grouping) { _, value in UserDefaults.standard.set(value.rawValue, forKey: Self.groupingKey) }
    .sheet(item: $daySheet) { pick in
      OverviewDaySheet(
        pick: pick, load: { await model.loadUsageDay($0) }, accounts: accounts, hideEmails: hideEmails,
        openChat: { id in
          daySheet = nil
          Task {
            await model.selectChat(id)
            navigate(.conversations)
          }
        },
        close: { daySheet = nil })
        .tint(AIMTheme.passiveIcon)
    }
  }

  /// A click on a heatmap day with usage opens its sheet; a day without tokens opens nothing.
  private func openDay(_ day: String) {
    guard let dataset, let index = dataset.yearDays.firstIndex(of: day), dataset.yearTotals[index] > 0 else { return }
    daySheet = OverviewDayPick(day: day, tokens: dataset.yearTotals[index])
  }

  /// Summarizes the snapshot off the main actor. The old charts stay in place until it ends.
  private func rebuild() async {
    guard let snapshot = model.usageHistory else { return }
    let (period, grouping, accounts, hideEmails) = (period, grouping, accounts, hideEmails)
    let (summary, year) = await Task.detached(priority: .userInitiated) {
      (snapshot.summary(period: period, grouping: grouping), snapshot.summary(period: .year, grouping: .model))
    }.value
    guard !Task.isCancelled else { return }
    let built = OverviewDataset.make(summary: summary, year: year, accounts: accounts, hideEmails: hideEmails)
    dataset = built
    OverviewCache.last = built
  }

  // MARK: Cards

  private var periodNote: String { period == .week ? "(last 7 days)" : "(last 30 days)" }

  private var totalsCard: some View {
    AIMCard(
      title: "Usage", note: periodNote, well: true, bottomInset: 0,
      accessory: {
        HStack(spacing: AIMTheme.rowSpacing) {
          AIMSegmentedPicker(
            options: [UsagePeriod.week, .month], selection: $period, accessibilityLabel: "Period"
          ) { $0 == .week ? "Week" : "Month" }
          AIMSegmentedPicker(
            options: UsageGrouping.allCases, selection: $grouping, accessibilityLabel: "Group by"
          ) {
            switch $0 {
            case .account: "Accounts"
            case .model: "Models"
            case .project: "Projects"
            }
          }
        }
      }
    ) {
      let totals = dataset?.totals
      HStack(alignment: .top, spacing: AIMTheme.tileGap) {
        StatTile(label: "Tokens", value: totals.map { UsagePresentation.formatTokens($0.tokens) },
          detail: "In the last \(period.days) days")
        StatTile(label: "Estimated cost", value: totals?.costUSD.map(UsagePresentation.formatCurrency),
          detail: "API-rate estimate, not billed")
        StatTile(label: "Active accounts", value: totals.map { "\($0.activeAccounts)" },
          detail: "Of \(accounts.count) saved")
        StatTile(label: "Busiest day", value: totals?.busiestDay.map(OverviewDay.short),
          detail: totals.map { $0.busiestDay == nil ? "No usage yet" : "\(UsagePresentation.formatTokens($0.busiestDayTokens)) tokens" })
      }
      .uiLint(.stack)
    }
  }

  /// A chart card: a title row, a divider, then the chart in a slot of fixed height, so loading
  /// and an empty group never move the cards.
  private func chartCard<Chart: View>(
    _ title: String, note: String? = nil, height: CGFloat?, waffle: Bool = false,
    hasData: @escaping (OverviewDataset) -> Bool,
    empty: String? = nil, footer: Bool = false, @ViewBuilder chart: @escaping (OverviewDataset) -> Chart
  ) -> some View {
    let groupNote = "(by \(grouping == .account ? "account" : grouping == .model ? "model" : "project"))"
    return AIMCard(title: title, note: note ?? groupNote, divider: true, bottomInset: 0) {
      VStack(alignment: .leading, spacing: 10) {
        OverviewSlot(dataset: dataset, height: height, waffle: waffle, hasData: hasData, empty: empty, chart: chart)
        if footer { OverviewLegend(series: dataset?.series ?? []) }
      }
      // Canvas charts hold no text, so the block itself marks the card's content edge for the inset check.
      .uiLint(.item)
      .padding(.horizontal, AIMTheme.cardInset)
      // The title text sits 14 pt below the top edge; the content ends 14 pt above the bottom.
      .padding(.vertical, 14)
    }
  }
}

/// A chart's frame: the chart when it has data, a quiet block while loading, or the reason there
/// is nothing to draw. All three keep the same size. A nil height sizes the chart itself.
private struct OverviewSlot<Chart: View>: View {
  let dataset: OverviewDataset?
  let height: CGFloat?
  var waffle = false
  let hasData: (OverviewDataset) -> Bool
  let empty: String?
  let chart: (OverviewDataset) -> Chart

  var body: some View {
    Group {
      if let dataset, hasData(dataset) {
        chart(dataset)
      } else {
        placeholder
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: height)
  }

  @ViewBuilder private var placeholder: some View {
    let block = ZStack {
      RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous).fill(AIMTheme.tileFill)
      if let dataset {
        Text(empty ?? dataset.emptyText).aimText(.secondary).multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }
    }
    .accessibilityElement(children: .combine)
    if waffle {
      // The waffle sizes itself from its width: the same split, with nothing in it, keeps the height.
      OverviewWaffleSplit { Color.clear; Color.clear }.background(block)
    } else if height == nil {
      // The heatmap sizes itself from its width: keep its grid shape and legend row while empty.
      VStack(spacing: OverviewHeatmap.legendSpacing) {
        block.aspectRatio(OverviewHeatmap.aspect, contentMode: .fit)
        Color.clear.frame(height: OverviewHeatmap.legendHeight)
      }
    } else {
      block
    }
  }
}

private struct StatTile: View {
  let label: String
  let value: String?
  let detail: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).aimText(.secondary).lineLimit(1)
      Text(value ?? "–").aimText(.title).monospacedDigit().lineLimit(1)
        .aimRolling(value).uiLint(.number)
      Text(detail ?? " ").aimText(.secondary).lineLimit(1)
    }
    .accessibilityElement(children: .combine)
    .aimTile()
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
