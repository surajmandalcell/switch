import AIManagerCore
import Foundation

#if AI_MANAGER_PREVIEW
@MainActor
enum MenuBarPopoverPreviewData {
  static let snapshot = MenuBarSnapshot(
    accounts: [
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "66D91DF8-056C-4DD0-AF97-EAF45D74A8D2")!,
        identity: "ladygaga@gmail.com", detail: "Codex CLI · Personal",
        isVerified: true, isActive: true,
        usage: MenuBarUsageSnapshot(
          usedPercentage: 42, secondaryUsedPercentage: 68,
          resetsAt: Date().addingTimeInterval(2 * 3_600),
          secondaryResetsAt: Date().addingTimeInterval(2 * 86_400),
          fetchedAt: Date().addingTimeInterval(-120),
          tokenPeriodLabel: "since reset", tokens: 412_000_000,
          apiPrice: CodexAPIPrice(
            model: "gpt-5.6-sol", inputPerMillion: 4,
            cachedInputPerMillion: 0.4, outputPerMillion: 20),
          primaryMinutes: 300, secondaryMinutes: 10_080)),
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "15431467-BF10-4BCB-9300-C785336CB1D1")!,
        identity: "bankai39@gmail.com", detail: "Codex CLI · Studio",
        isVerified: true, isActive: false,
        usage: MenuBarUsageSnapshot(
          usedPercentage: 18, secondaryUsedPercentage: 37,
          resetsAt: Date().addingTimeInterval(75 * 60),
          secondaryResetsAt: Date().addingTimeInterval(4 * 86_400),
          fetchedAt: Date().addingTimeInterval(-480),
          tokenPeriodLabel: "since reset", tokens: 128_000_000,
          apiPrice: CodexAPIPrice(
            model: "gpt-5.6-sol", inputPerMillion: 4,
            cachedInputPerMillion: 0.4, outputPerMillion: 20),
          primaryMinutes: 300, secondaryMinutes: 10_080)),
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "DB9AB65A-F894-426D-8A16-86772A8F054D")!,
        identity: "joestar89@gmail.com", detail: "Codex CLI · Personal",
        isVerified: false, isActive: false),
    ])

  /// Four synthetic rows in the states the design shows: two windows, one window, unknown, and
  /// needing sign-in. The live Preview status item and the popover screenshots use this one.
  static var fullSnapshot: MenuBarSnapshot {
    MenuBarSnapshot(accounts: [
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "0E0A2001-7F3A-4C27-9D84-5B1E2A6C0001")!,
        identity: "ada.lovelace@example.test", detail: "Claude Code",
        isVerified: true, isActive: true,
        usage: MenuBarUsageSnapshot(
          usedPercentage: 24, secondaryUsedPercentage: 59,
          resetsAt: Date().addingTimeInterval(3 * 3_600 + 20 * 60),
          secondaryResetsAt: Date().addingTimeInterval(2 * 86_400 + 4 * 3_600),
          fetchedAt: Date().addingTimeInterval(-120),
          primaryMinutes: 300, secondaryMinutes: 10_080),
        providerID: .claudeCode),
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "0E0A2002-7F3A-4C27-9D84-5B1E2A6C0002")!,
        identity: "grace.hopper@example.test", detail: "Codex CLI",
        isVerified: true, isActive: true,
        usage: MenuBarUsageSnapshot(
          usedPercentage: 88,
          resetsAt: Date().addingTimeInterval(5 * 86_400 + 13 * 3_600),
          fetchedAt: Date().addingTimeInterval(-300),
          primaryLabel: "Weekly", primaryMinutes: 10_080),
        providerID: .codex),
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "0E0A2003-7F3A-4C27-9D84-5B1E2A6C0003")!,
        identity: "alan.turing@example.test", detail: "Grok Build",
        isVerified: true, isActive: true, usage: nil, providerID: .grokBuild),
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "0E0A2004-7F3A-4C27-9D84-5B1E2A6C0004")!,
        identity: "katherine.johnson@example.test", detail: "Claude Code",
        isVerified: false, isActive: false, providerID: .claudeCode),
    ])
  }

  static func snapshot(accountCount: Int) -> MenuBarSnapshot {
    let accounts = fullSnapshot.accounts
    return MenuBarSnapshot(accounts: (0..<accountCount).map { index in
      let account = accounts[index % accounts.count]
      return MenuBarAccountSnapshot(
        id: UUID(),
        identity: index == 4 ? "a.very.long.synthetic.account.name.for.truncation@example.test" : account.identity,
        detail: account.detail, isVerified: account.isVerified,
        isActive: index < accounts.count && account.isActive,
        usage: account.usage, providerID: account.providerID)
    })
  }
}
#endif
