import AIManagerCore
import SwiftUI

// The sheet a click on an Overview heatmap day opens: the day's totals, its cost split by account
// and by model, and one row for each session. Everything comes from the stored usage history
// (UsageHistorySnapshot points, UsageHistory.daySessions); nothing new is kept on disk.

/// A tapped heatmap day; the sheet item.
struct OverviewDayPick: Identifiable, Equatable {
  let day: String
  let tokens: Int64
  var id: String { day }
}

struct OverviewDayDetail: Equatable {
  struct Slice: Identifiable, Equatable {
    let id: String
    let label: String
    let color: Color
    /// USD when `byCost`, else tokens.
    let value: Double
  }

  struct Session: Identifiable, Equatable {
    let id: String
    let title: String
    let tool: String
    let start: Date?
    /// The session began on an earlier day, so its start time is not this day's.
    let continued: Bool
    let tokens: Int64
    let cost: Double?
    /// The Conversations id when the transcript still exists.
    let chatID: String?
    /// A Codex session whose transcript is gone: only the statistics remain.
    let removed: Bool
  }

  static let maxSlices = 6

  let day: String
  let tokens: Int64
  let cost: Double?
  /// Nil when the stored statistics hold no per-session data for the day.
  let sessions: [Session]?
  let byAccount: [Slice]
  let byModel: [Slice]
  /// The splits weigh USD; with no priced usage they weigh tokens.
  let byCost: Bool

  /// A zero-token day has no sheet.
  static func make(
    day: String, tokens: Int64, input: OverviewDayInput, accounts: [AccountRecord], hideEmails: Bool
  ) -> OverviewDayDetail? {
    guard tokens > 0 else { return nil }
    let points = input.points.filter { $0.day == day }
    let costs = points.compactMap(\.costUSD)
    let cost = costs.isEmpty ? nil : costs.reduce(0, +)
    let byCost = (cost ?? 0) > 0
    let named = Dictionary(accounts.map { ($0.id.uuidString.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    // A transcript with no account of its own belongs to the only saved account of its tool.
    var sole: [String: String] = [:]
    for (service, group) in Dictionary(grouping: accounts, by: { $0.identity.providerID.rawValue }) where group.count == 1 {
      sole[service] = group[0].id.uuidString.lowercased()
    }

    struct Sum { var service = ""; var account = Int64(0); var transcript = Int64(0); var cost = 0.0 }
    var accountSums: [String: Sum] = [:]
    var modelSums: [String: Sum] = [:]
    for point in points {
      let key = point.accountID ?? sole[point.service] ?? "service:" + point.service
      var sum = accountSums[key] ?? Sum()
      sum.service = point.service
      let isTranscript = point.model != nil || point.project != nil
      if isTranscript { sum.transcript += point.tokens } else { sum.account += point.tokens }
      sum.cost += point.costUSD ?? 0
      accountSums[key] = sum
      if isTranscript {
        var model = modelSums[point.model ?? "unknown"] ?? Sum()
        model.service = point.service
        model.transcript += point.tokens
        model.cost += point.costUSD ?? 0
        modelSums[point.model ?? "unknown"] = model
      }
    }

    var ranks: [String: Int] = [:]
    let accountRows = accountSums.map { key, sum in (key, sum, byCost ? sum.cost : Double(max(sum.account, sum.transcript))) }
      .filter { $0.2 > 0 }.sorted { ($1.2, $0.0) < ($0.2, $1.0) }
    let accountSlices = slices(accountRows.map { key, sum, value in
      let rank = ranks[sum.service, default: 0]
      ranks[sum.service] = rank + 1
      let label: String
      if let record = named[key] {
        let text = record.identity.accountLabel
        label = hideEmails ? EmailPrivacy.mask(text) : text
      } else if key.hasPrefix("service:") {
        label = providerName(sum.service)
      } else if let shared = sharedName(key) {
        label = shared
      } else {
        label = "Removed account"
      }
      return Slice(id: key, label: label, color: OverviewPalette.account(service: sum.service, rank: rank), value: value)
    })

    var taken = Set<Int>()
    let modelRows = modelSums.map { key, sum in (key, byCost ? sum.cost : Double(sum.transcript)) }
      .filter { $0.1 > 0 }.sorted { ($1.1, $0.0) < ($0.1, $1.0) }
    let modelSlices = slices(modelRows.map { key, value in
      Slice(id: key, label: key == "unknown" ? "Unknown model" : key, color: OverviewPalette.color(key, taken: &taken), value: value)
    })

    var rows: [Session]?
    if let sessions = input.sessions, !sessions.isEmpty {
      let epoch = OverviewDay.epoch(day)
      rows = sessions.map { session in
        let thread = session.threadID.flatMap { input.threads[$0] }
        let isCodex = session.threadID != nil
        let title = thread.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? projectLabel(session.project)
        let continued = session.start.map { Int(($0.timeIntervalSince1970 / 86_400).rounded(.down)) != epoch } ?? true
        return Session(
          id: session.id, title: title, tool: toolName(session.service), start: session.start, continued: continued,
          tokens: session.tokens, cost: session.costUSD, chatID: thread?.id, removed: isCodex && thread == nil)
      }
    }
    return OverviewDayDetail(
      day: day, tokens: tokens, cost: cost, sessions: rows, byAccount: accountSlices, byModel: modelSlices, byCost: byCost)
  }

  /// The largest slices, then one "Other" for the rest.
  private static func slices(_ all: [Slice]) -> [Slice] {
    guard all.count > maxSlices else { return all }
    let rest = all.dropFirst(maxSlices)
    return Array(all.prefix(maxSlices)) + [Slice(id: "other", label: "Other", color: OverviewPalette.other, value: rest.reduce(0) { $0 + $1.value })]
  }

  static func providerName(_ service: String) -> String {
    ProviderID(rawValue: service).guiName
  }

  /// "Claude Code (shared)" for a `shared:<service>` group of history points, else nil.
  static func sharedName(_ key: String) -> String? {
    UsageHistory.sharedService(key).map { providerName($0) + " (shared)" }
  }

  static func toolName(_ service: String) -> String {
    switch service {
    case ProviderID.codex.rawValue: "Codex CLI"
    case ProviderID.claudeCode.rawValue: "Claude Code"
    default: providerName(service)
    }
  }

  static func projectLabel(_ project: String) -> String {
    let name = URL(fileURLWithPath: project).lastPathComponent
    return project.hasPrefix("/") && !name.isEmpty ? name : project
  }
}

// MARK: - Sheet

struct OverviewDaySheet: View {
  private enum Split: Hashable { case account, model }

  let pick: OverviewDayPick
  let load: (String) async -> OverviewDayInput
  let accounts: [AccountRecord]
  let hideEmails: Bool
  /// Opens the Conversations page on a thread; the sheet closes first.
  let openChat: (String) -> Void
  let close: () -> Void
  /// Loaded by the sheet; a render check passes it ready.
  @State var detail: OverviewDayDetail?
  @State private var split = Split.account

  static let size = CGSize(width: 560, height: 680)

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: AIMTheme.sectionSpacing) {
        Text(OverviewDay.title(pick.day)).aimText(.section)
        totals
        if let detail {
          splitSection(detail)
          sessionsSection(detail)
        } else {
          Spacer(minLength: 0)
        }
      }
      .padding(AIMTheme.pageMargin)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      AIMHairline()
      HStack {
        Spacer()
        AIMButton(title: "Done", tone: .primary, action: close).keyboardShortcut(.defaultAction)
      }
      .padding(AIMTheme.cardInset)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .focusEffectDisabled(!AIMFocus.showsSystemRings)
    .onExitCommand(perform: close)
    .task {
      let input = await load(pick.day)
      guard !Task.isCancelled else { return }
      detail = OverviewDayDetail.make(
        day: pick.day, tokens: pick.tokens, input: input, accounts: accounts, hideEmails: hideEmails)
    }
  }

  // MARK: Totals

  private var totals: some View {
    HStack(alignment: .top, spacing: AIMTheme.cardGap) {
      total("Tokens", UsagePresentation.formatTokens(pick.tokens))
      total("Estimated cost", detail.map { $0.cost.map(UsagePresentation.formatCurrency) ?? "–" })
      total("Sessions", detail.map { $0.sessions.map { "\($0.count)" } ?? "–" })
    }
  }

  private func total(_ label: String, _ value: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).aimText(.secondary).lineLimit(1)
      Text(value ?? " ").aimText(.title).monospacedDigit().lineLimit(1).aimRolling(value)
    }
    .accessibilityElement(children: .combine)
    .aimTile()
  }

  // MARK: Cost split

  @ViewBuilder private func splitSection(_ detail: OverviewDayDetail) -> some View {
    let both = !detail.byAccount.isEmpty && !detail.byModel.isEmpty
    let shown = both ? split : (detail.byAccount.isEmpty ? .model : .account)
    let slices = shown == .account ? detail.byAccount : detail.byModel
    VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
      HStack {
        Text(detail.byCost ? "Cost split" : "Token split").aimText(.body)
        Spacer()
        if both {
          AIMSegmentedPicker(
            options: [Split.account, .model], selection: $split, accessibilityLabel: "Split by"
          ) { $0 == .account ? "Account" : "Model" }
        }
      }
      if slices.isEmpty {
        Text("No split is available for this day.").aimText(.secondary)
      } else {
        let sum = slices.reduce(0) { $0 + $1.value }
        OverviewDayBar(slices: slices, total: sum)
        VStack(spacing: 0) {
          ForEach(slices) { slice in
            HStack(spacing: 8) {
              Circle().fill(slice.color).frame(width: 8, height: 8)
              Text(slice.label).aimText(.body).lineLimit(1).truncationMode(.middle)
              Spacer(minLength: 12)
              Text(Self.percent(slice.value, of: sum)).aimText(.body).monospacedDigit()
              Text(detail.byCost ? UsagePresentation.formatCurrency(slice.value) : UsagePresentation.formatTokens(Int64(slice.value)))
                .aimText(.secondary).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            .frame(height: 22)
          }
        }
      }
    }
    .id(shown)
    .aimAppear()
  }

  private static func percent(_ value: Double, of total: Double) -> String {
    let share = value / max(total, 1) * 100
    return share < 1 ? "<1%" : "\(Int(share.rounded()))%"
  }

  // MARK: Sessions

  @ViewBuilder private func sessionsSection(_ detail: OverviewDayDetail) -> some View {
    VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
      Text("Sessions").aimText(.body)
      if let sessions = detail.sessions {
        AIMScrollView {
          VStack(spacing: 0) {
            ForEach(sessions) { session in
              OverviewDaySessionRow(session: session) {
                if let id = session.chatID { openChat(id) }
              }
            }
          }
        }
        .frame(maxHeight: .infinity)
      } else {
        // No transcripts on this Mac for the day (removed, or used on another computer).
        Text("No sessions on this Mac for this day. The totals come from the account's usage report.")
          .aimText(.secondary).multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxHeight: .infinity, alignment: .topLeading)
  }
}

/// The stacked bar: one segment for each slice, in its color, with a small gap between them.
private struct OverviewDayBar: View {
  let slices: [OverviewDayDetail.Slice]
  let total: Double

  var body: some View {
    GeometryReader { proxy in
      let gap: CGFloat = 2
      let free = max(proxy.size.width - gap * CGFloat(slices.count - 1), 1)
      HStack(spacing: gap) {
        ForEach(slices) { slice in
          Rectangle().fill(slice.color).frame(width: max(free * slice.value / max(total, 1), 2))
        }
      }
    }
    .frame(height: 10)
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    .accessibilityHidden(true)
  }
}

/// A session row: title, tool and start time, tokens and cost. A row whose transcript exists opens
/// it; a removed one is dimmed and does nothing.
private struct OverviewDaySessionRow: View {
  let session: OverviewDayDetail.Session
  let open: () -> Void
  @State private var hovered = false

  private var detail: String {
    var parts = [session.tool]
    if let start = session.start {
      parts.append(session.continued ? "Continued" : start.formatted(date: .omitted, time: .shortened))
    }
    if session.removed { parts.append("Transcript removed") }
    return parts.joined(separator: " · ")
  }

  private var content: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        Text(session.title).aimText(.body).lineLimit(1).truncationMode(.middle)
        Text(detail).aimText(.secondary).lineLimit(1)
      }
      Spacer(minLength: 12)
      VStack(alignment: .trailing, spacing: 1) {
        Text(UsagePresentation.formatTokens(session.tokens)).aimText(.body).monospacedDigit()
        Text(session.cost.map(UsagePresentation.formatCurrency) ?? "–").aimText(.secondary).monospacedDigit()
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background(
      hovered && session.chatID != nil ? AIMTheme.tileFill : Color.clear,
      in: RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous))
    .contentShape(Rectangle())
    .opacity(session.removed ? 0.5 : 1)
    .onHover { hovered = $0 }
    .animation(AIMMotion.fade(AIMMotion.hover), value: hovered)
  }

  var body: some View {
    if session.chatID != nil {
      Button(action: open) { content }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the conversation")
    } else {
      content
        .accessibilityElement(children: .combine)
    }
  }
}
