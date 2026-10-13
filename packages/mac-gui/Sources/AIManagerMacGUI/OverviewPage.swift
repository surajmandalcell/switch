import AIManagerCore
import SwiftUI

// The Overview page: five cards (focused account, accounts table, current limits, recent
// activity, maintenance) on the shared parts in AIManagerParts.swift.

// MARK: - Recent activity data

/// Today, Yesterday, and the last 30 days of local history for the focused account's tool.
enum OverviewActivity {
  struct Row: Identifiable, Equatable {
    let label: String
    let icon: AIMIcon.Name
    let tokens: Int64
    /// An estimated API-equivalent cost; nil when no price is known.
    let cost: Double?
    let detail: String
    var id: String { label }
  }

  enum Source: Equatable {
    case rows([Row])
    /// One Secondary line: loading, or no local history for this tool.
    case message(String)
  }

  private static let icons: [AIMIcon.Name] = [.chart, .clock, .calendar]

  @MainActor static func source(
    for account: AccountRecord, model: AccountViewModel, now: Date = Date()
  ) -> Source {
    let provider = account.identity.providerID
    switch provider {
    case .claudeCode:
      if let summary = model.claudeActivity {
        return .rows(summary.rows.enumerated().map { index, row in
          Row(label: row.label, icon: icons[min(index, 2)], tokens: Int64(row.tokens),
            cost: row.costUSD, detail: row.detail)
        })
      }
      return .message(model.isClaudeActivityLoading
        ? "Scanning local Claude Code logs…" : "Claude Code activity is not available yet.")
    case .codex:
      let days = model.dailyUsage(for: account.id)
      guard !days.isEmpty else { return .message("No local history for Codex CLI yet.") }
      let periods: [(String, CodexTokenPeriod)] = [
        ("Today", .today), ("Yesterday", .yesterday), ("Last 30 days", .monthly),
      ]
      return .rows(periods.enumerated().map { index, item in
        let tokens = item.1.tokens(in: days, endingAt: now)
        return Row(
          label: item.0, icon: icons[index], tokens: tokens,
          cost: model.apiPrice?.inputEquivalent(for: tokens),
          detail: "\(UsagePresentation.exactTokens(tokens)) tokens. The cost is an input-rate comparison, not billed spend.")
      })
    default:
      return .message("\(provider.guiName) keeps no local history that Switch can read.")
    }
  }
}

// MARK: - Page

struct OverviewPage: View {
  @ObservedObject var model: AccountViewModel
  let query: String
  /// Goes to another page; the "View all limits", "View full history", and "Open Backup" links use it.
  var navigate: (AIManagerPage) -> Void = { page in
    NotificationCenter.default.post(name: AIManagerNavigation.request, object: page)
  }
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
      // Five cards at the full content width: 20-point margins, 12 points between them.
      AIMScrollPage {
          if let account = focused {
            FocusedAccountCard(
              account: account, accounts: accounts, model: model, now: context.date,
              hideEmails: hideEmails, showsUsed: showsUsed,
              focus: { focusedID = $0 },
              delete: { model.requestDeletion(of: account, into: $pendingDeletion) })
            AccountsTableCard(
              accounts: visibleAccounts, total: accounts.count, query: query, model: model,
              focusedID: account.id, now: context.date, hideEmails: hideEmails,
              showsUsed: showsUsed,
              focus: { focusedID = $0 },
              delete: { model.requestDeletion(of: $0, into: $pendingDeletion) })
            CurrentLimitsCard(
              account: account, model: model, now: context.date, showsUsed: showsUsed
            ) { navigate(.accounts) }
            RecentActivityCard(account: account, model: model, now: context.date) {
              navigate(.conversations)
            }
            MaintenanceStatusCard(model: model) { navigate(.maintenance) }
          } else {
            OverviewEmptyCard(model: model)
          }
          if let notice = model.notice {
            AIMPanel { Notice(text: notice, tone: AIMTheme.blue).aimRow() }
          }
      }
    }
    .accountDeletionAlert(model: model, pending: $pendingDeletion)
    // The page remembers its focused account while the app runs.
    .onChange(of: focusedID) { _, id in AIMPlace.overviewFocus = id }
    #if AI_MANAGER_PREVIEW
    .onChange(of: model.selectedAccountID) { _, id in
      if PreviewArguments.value("select") != nil { focusedID = id }
    }
    #endif
    .onAppear {
      focusedID = focusedID ?? AIMPlace.overviewFocus ?? OverviewFocus.defaultAccountID(in: model.status)
      #if AI_MANAGER_PREVIEW
      // Preview screenshots: `--select=claude-code` also focuses that account here.
      if PreviewArguments.value("select") != nil, let id = model.selectedAccountID { focusedID = id }
      #endif
    }
  }
}


// MARK: - Card 4: recent activity

struct RecentActivityCard: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let now: Date
  let viewHistory: () -> Void

  static let group = "activity"

  var body: some View {
    let source = OverviewActivity.source(for: account, model: model, now: now)
    AIMCard(
      title: "Recent activity", note: "(\(account.identity.providerID.guiName))", divider: true,
      bottomInset: AIMTheme.textRowsEndInset,
      accessory: { AIMCardLink(title: "View full history", action: viewHistory) }
    ) {
      switch source {
      case .message(let text):
        Text(text).aimText(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, AIMTheme.cardInset)
          .frame(height: AIMTheme.rowHeight)
      case .rows(let rows):
        VStack(spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 { AIMRowSeparator() }
            ActivityRow(row: row)
          }
        }
      }
    }
  }
}

private struct ActivityRow: View {
  let row: OverviewActivity.Row

  var body: some View {
    let columns = AIMColumns.activity
    let group = RecentActivityCard.group
    AIMTableRow {
      HStack(spacing: 10) {
        AIMIcon(name: row.icon).aimFont(.body).foregroundStyle(.secondary).frame(width: 20)
        Text(row.label).aimText(.body).lineLimit(1)
      }
      .aimColumn(columns[0], group: group)
      HStack(spacing: 4) {
        Text(UsagePresentation.formatTokens(row.tokens))
          .aimText(.body).monospacedDigit().uiLint(.number)
        Text("tokens").aimText(.secondary)
      }
      .aimColumn(columns[1], group: group)
      Text(row.cost.map { "≈ \(Fmt.money($0))" } ?? "No price")
        .aimText(.body).monospacedDigit().lineLimit(1).uiLint(.number)
        .aimColumn(columns[2], group: group)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.label)
    .accessibilityValue("\(UsagePresentation.exactTokens(row.tokens)) tokens, "
      + (row.cost.map { "\(Fmt.money($0)) API-equivalent estimate" } ?? "no price"))
    .help(row.detail)
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
