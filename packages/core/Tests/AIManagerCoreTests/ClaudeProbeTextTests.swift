import Foundation
import XCTest
@testable import AIManagerCore

/// Text captured from Claude Code 2.1.296 on macOS (identity removed).
final class ClaudeProbeTextTests: XCTestCase {
    func testTrustPromptPreselectsNo() {
        let prompt = """
        Quick safety check: Is this a project you created or one you trust?
        \u{1B}[1m❯ No, exit\u{1B}[0m
          Yes, I trust this folder
        Enter to confirm · Esc to cancel
        """
        XCTAssertTrue(ClaudeUsage.trustSelectionIsNo(prompt))
        let moved = prompt + "\n  No, exit\n❯ Yes, I trust this folder\n"
        XCTAssertFalse(ClaudeUsage.trustSelectionIsNo(moved))
    }

    func testUsagePanelWithJoinedWords() throws {
        let panel = """
        Current session
        \u{1B}[2C███████████████████████\u{1B}[27C46%used
        Resets 5:30pm (Asia/Calcutta)
        Current week (all models)
        ██████████████████████████████████\u{1B}[16C68%used
        Resets Oct 11 at 1:30am (Asia/Calcutta)
        Current week (Fable)
        \u{1B}[51C0% used
        Resets Oct 11 at 1:30am (Asia/Calcutta)
        What's contributing to your limits usage?
        """
        XCTAssertTrue(ClaudeUsage.panelIsComplete(panel))
        let now = ISO8601DateFormatter().date(from: "2026-10-10T07:40:00Z")!
        let usage = try ClaudeUsage.parseUsageText(panel, now: now)
        XCTAssertEqual(usage.windows.map(\.title), ["Session", "Weekly", "Fable weekly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [46, 68, 0])
        XCTAssertEqual(usage.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z"))
        XCTAssertEqual(usage.windows[1].resetsAt, ISO8601DateFormatter().date(from: "2026-10-10T20:00:00Z"))
    }
}
