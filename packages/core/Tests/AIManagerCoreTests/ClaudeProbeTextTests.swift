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
        XCTAssertEqual(usage.windows.map(\.title), ["Session", "Weekly", "Weekly Fable"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [46, 68, 0])
        XCTAssertEqual(usage.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z"))
        XCTAssertEqual(usage.windows[1].resetsAt, ISO8601DateFormatter().date(from: "2026-10-10T20:00:00Z"))
    }

    // MARK: Screen replay

    private let now = ISO8601DateFormatter().date(from: "2026-10-10T08:40:00Z")!

    /// A real Claude Code 2.1.296 transcript: every row is cursor addressed, and the skill list that
    /// scrolls past before the panel opens used to garble or drop the Session row.
    func testRealTranscriptShowsEveryLimit() throws {
        let rendered = ClaudeTerminalScreen.render(String(decoding: ClaudeUsagePanelFixture.bytes, as: UTF8.self))
        XCTAssertTrue(rendered.contains("  Current session\n"))
        XCTAssertTrue(ClaudeUsage.isComplete(rendered: rendered))
        let usage = try ClaudeUsage.parse(rendered: rendered, now: now)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "weekly-fable"])
        XCTAssertEqual(usage.windows.map(\.title), ["Session", "Weekly", "Weekly Fable"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [90, 73, 0])
        XCTAssertEqual(usage.windows.map(\.windowMinutes), [300, 10080, 10080])
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(usage.windows.map(\.resetsAt), [iso.date(from: "2026-10-10T12:00:00Z"),
                                                       iso.date(from: "2026-10-10T20:00:00Z"),
                                                       iso.date(from: "2026-10-10T20:00:00Z")])
        XCTAssertEqual(usage.plan, "Max")
        XCTAssertEqual(usage.sections, [UsageSection("Usage credits", [UsageRow("Status", "Off")])])
    }

    func testReplayIsTheSameWhateverTheReadSizes() {
        let bytes = ClaudeUsagePanelFixture.bytes
        var whole = ClaudeTerminalScreen()
        whole.feed(bytes)
        for size in [1, 7, 4096] {
            var parts = ClaudeTerminalScreen()
            for start in stride(from: 0, to: bytes.count, by: size) {
                parts.feed(bytes[start..<min(start + size, bytes.count)])
            }
            XCTAssertEqual(parts.text, whole.text, "read size \(size)")
        }
    }

    func testReplayFollowsCursorMovesErasesAndScrolling() {
        var screen = ClaudeTerminalScreen(columns: 20, rows: 4)
        // Rows drawn bottom first, a row redrawn after an erase, then a column move and a vertical move.
        screen.feed(Data("\u{1B}[3;1Hthree\u{1B}[1;1Hone old\u{1B}[2K\u{1B}[1;1Hone\u{1B}[2;5Htwo".utf8))
        XCTAssertEqual(screen.text, "one\n    two\nthree")
        screen.feed(Data("\u{1B}[3dX\u{1B}[8G\u{1B}[1AY\u{1B}[3C\u{1B}[2DZ\u{1B}[1;1H\u{1B}[0J".utf8))
        XCTAssertEqual(screen.text, "")
        // Line feeds past the last row scroll the top row away; colors change nothing.
        screen.feed(Data("\u{1B}[1;1H\u{1B}[31ma\r\nb\r\nc\r\nd\r\ne".utf8))
        XCTAssertEqual(screen.text, "b\nc\nd\ne")
    }

    func testReplayKeepsTheMainScreenWhileTheAlternateScreenIsShown() {
        var screen = ClaudeTerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("shell\u{1B}[?1049h\u{1B}[2J\u{1B}[Hpanel".utf8))
        XCTAssertEqual(screen.text, "panel")
        screen.feed(Data("\u{1B}[?1049l".utf8))
        XCTAssertEqual(screen.text, "shell")
    }

    func testReplayKeepsWideGlyphsAndSplitCharacters() {
        var screen = ClaudeTerminalScreen(columns: 20, rows: 2)
        let bytes = Array("█▌ 日本 ok".utf8)
        screen.feed(Data(bytes[0..<4])) // ends inside the second character
        screen.feed(Data(bytes[4...]))
        XCTAssertEqual(screen.text, "█▌ 日本 ok")
    }

    // MARK: Panel content

    func testPanelNeedsBothSessionAndWeeklyBeforeItIsComplete() {
        let weeklyOnly = "Current week (all models)\n██  73% used\nResets Oct 11 at 1:30am (UTC)"
        XCTAssertFalse(ClaudeUsage.panelIsComplete(weeklyOnly))
        XCTAssertTrue(ClaudeUsage.panelIsComplete("Current session\n 9% used\nResets 5pm (UTC)\n" + weeklyOnly))
        XCTAssertTrue(ClaudeUsage.panelIsComplete("Failed to load usage data"))
    }

    func testUsageCreditsStateAndAmountsAreKept() throws {
        let on = try ClaudeUsage.parseUsageText("""
        Current session
        9% used
        Current week (all models)
        10% used
        Usage credits
        Usage credits are on · $12.50 of $50.00 spent · /usage-credits to manage
        Esc to cancel
        """, now: now)
        XCTAssertEqual(on.sections, [UsageSection("Usage credits", [UsageRow("Status", "On"),
                                                                    UsageRow("Amount", "$12.50 of $50.00 spent")])])
    }

    func testPlanComesFromAuthStatusAndTierText() async throws {
        XCTAssertEqual(ClaudeUsage.planName(type: "max", tier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(ClaudeUsage.planName(type: "pro", tier: nil), "Pro")
        XCTAssertNil(ClaudeUsage.planName(type: nil, tier: "default_claude_max_5x"))
        let script = FileManager.default.temporaryDirectory.appending(path: "claude-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: script) }
        try """
        #!/bin/sh
        echo '{"loggedIn":true,"email":"user@example.com","orgName":"Org","subscriptionType":"max"}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let status = try await ClaudeCodeProfiles.cliStatus(
            .init(executable: script, arguments: ["auth", "status"], environment: [:]))
        XCTAssertEqual(status.subscriptionType, "max")
        XCTAssertEqual(status.organization, "Org")
        XCTAssertEqual(status.email, "user@example.com")
    }

    // MARK: Probe

    func testSilentClaudeReportsThePermissionHintWithoutRetrying() async throws {
#if !os(macOS)
        throw XCTSkip("The Claude Code usage probe needs a macOS pseudo terminal.")
#endif
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-silent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = root.appending(path: "runs.txt")
        let claude = root.appending(path: "claude")
        // Like a child blocked on a privacy prompt: it starts and prints nothing.
        try "#!/bin/sh\necho run >> '\(runs.path)'\nexec sleep 60\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        do {
            _ = try await ClaudeUsageProbe.run(configDir: root.appending(path: "cfg"), executable: claude,
                                               environment: ["PATH": "/usr/bin:/bin"],
                                               workingDirectory: root.appending(path: "cwd"), timeout: 2)
            XCTFail("A silent start must fail")
        } catch {
            XCTAssertEqual(error as? ProviderError, ClaudeUsageProbe.silentStart)
        }
        XCTAssertEqual(try String(contentsOf: runs, encoding: .utf8), "run\n", "no second attempt")
    }

    func testProbeRunsAgainWhenTheFirstPanelHasNoSessionRow() async throws {
#if !os(macOS)
        throw XCTSkip("The Claude Code usage probe needs a macOS pseudo terminal.")
#endif
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = root.appending(path: "runs.txt")
        let claude = root.appending(path: "claude")
        let script = """
        #!/bin/sh
        echo run >> '\(runs.path)'
        printf 'Welcome\\n> '
        read line
        if [ "$(wc -l < '\(runs.path)')" -lt 2 ]; then
          printf 'Current week (all models)\\n30%% used  (Resets Dec 2 at 12am (UTC))\\n'
        else
          printf 'Current session\\n12%% used  (Resets 5am (UTC))\\nCurrent week (all models)\\n30%% used  (Resets Dec 2 at 12am (UTC))\\n'
        fi
        exec sleep 60
        """
        try script.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let usage = try await ClaudeUsageProbe.run(configDir: root.appending(path: "cfg"), executable: claude,
                                                   environment: ["PATH": "/usr/bin:/bin"],
                                                   workingDirectory: root.appending(path: "cwd"), timeout: 6)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [12, 30])
        XCTAssertEqual(try String(contentsOf: runs, encoding: .utf8).split(separator: "\n").count, 2)
    }
}
