import Foundation
import XCTest
@testable import AIManagerCore

final class ClaudeSharedHistoryTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fileManager = FileManager.default
    private var userHome: URL { root.appending(path: "user") }
    private var shared: URL { userHome.appending(path: ".claude") }

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(path: "ClaudeSharedHistoryTests-\(UUID().uuidString)")
        paths = .init(
            applicationSupport: root.appending(path: "support"),
            credentialStore: root.appending(path: "user/.switch/codex"),
            defaultHome: root.appending(path: "user/.codex"),
            sharedRoot: root.appending(path: "user/.codex"),
            orcaAccountsRoot: root.appending(path: "orca"),
            claudeExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            isolationRoot: root)
        try fileManager.createDirectory(at: userHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    private func makeProfiles(status: @escaping ClaudeCodeProfiles.StatusCheck = { _ in .init(loggedIn: true, email: "a@example.test") })
        throws -> ClaudeCodeProfiles {
        try ClaudeCodeProfiles(paths: paths, fileManager: fileManager,
                               loginRunner: .init(launch: { _, _ in }), statusCheck: status, logout: { _ in })
    }

    private func config(_ id: UUID) -> URL {
        paths.applicationSupport.appending(path: "claude-code-profiles/\(id.uuidString)/config")
    }

    private func write(_ text: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func isLink(_ url: URL, to target: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == target.path
    }

    // MARK: Shared history

    func testNewProfileLinksSharedItemsAndSeedsConfigWithoutAccount() throws {
        try write(#"{"mcpServers":{"x":{}},"theme":"dark","hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"me@example.test"}}"#,
                  to: userHome.appending(path: ".claude.json"))
        let profiles = try makeProfiles()
        let id = try profiles.startLogin().session.id
        let dir = config(id)

        for item in ClaudeCodeProfiles.sharedItems {
            XCTAssertTrue(isLink(dir.appending(path: item), to: shared.appending(path: item)), item)
        }
        for item in [".claude.json", ".credentials.json", "policy-limits.json", "remote-settings.json"] {
            XCTAssertFalse(ClaudeCodeProfiles.sharedItems.contains(item))
            XCTAssertNil(try? fileManager.destinationOfSymbolicLink(atPath: dir.appending(path: item).path), item)
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: shared.appending(path: "projects").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let seeded = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: ".claude.json"))) as? [String: Any]
        XCTAssertNil(seeded?["oauthAccount"])
        XCTAssertEqual(seeded?["theme"] as? String, "dark")
        XCTAssertNotNil(seeded?["mcpServers"])
        XCTAssertEqual(seeded?["hasCompletedOnboarding"] as? Bool, true)
    }

    func testMigrationMergesWithoutLosingDataAndBacksUp() throws {
        let profiles = try makeProfiles()
        let id = try profiles.startLogin().session.id
        let dir = config(id)
        let short = id.uuidString.prefix(8).lowercased()
        try write("{\"a\":1}\n{\"shared\":1}\n", to: shared.appending(path: "history.jsonl"))
        try write("shared settings", to: shared.appending(path: "settings.json"))
        try write("shared", to: shared.appending(path: "projects/p1/shared.jsonl"))
        for item in ["projects", "history.jsonl", "settings.json"] {
            try fileManager.removeItem(at: dir.appending(path: item))
        }
        try write("mine", to: dir.appending(path: "projects/p1/mine.jsonl"))
        try write("only mine", to: dir.appending(path: "projects/p2/only.jsonl"))
        try write("{\"a\":1}\n{\"mine\":1}", to: dir.appending(path: "history.jsonl"))
        try write("profile settings", to: dir.appending(path: "settings.json"))

        let problems = profiles.linkSharedHistory(id)
        XCTAssertEqual(problems, [])
        for item in ["projects", "history.jsonl", "settings.json"] {
            XCTAssertTrue(isLink(dir.appending(path: item), to: shared.appending(path: item)), item)
        }
        XCTAssertEqual(try text(shared.appending(path: "projects/p1/shared.jsonl")), "shared")
        XCTAssertEqual(try text(shared.appending(path: "projects/p1.from-\(short)/mine.jsonl")), "mine")
        XCTAssertEqual(try text(shared.appending(path: "projects/p2/only.jsonl")), "only mine")
        XCTAssertEqual(try text(shared.appending(path: "history.jsonl")), "{\"a\":1}\n{\"shared\":1}\n{\"mine\":1}\n")
        XCTAssertEqual(try text(shared.appending(path: "settings.json")), "shared settings")

        let backups = paths.applicationSupport.appending(path: "claude-code-profiles/backups/\(id.uuidString)")
        let stamp = try XCTUnwrap(fileManager.contentsOfDirectory(atPath: backups.path).first)
        let backup = backups.appending(path: stamp)
        XCTAssertEqual(try text(backup.appending(path: "settings.json")), "profile settings")
        XCTAssertEqual(try text(backup.appending(path: "projects/p1/mine.jsonl")), "mine")
        XCTAssertEqual(try text(backup.appending(path: "history.jsonl")), "{\"a\":1}\n{\"mine\":1}")

        XCTAssertEqual(profiles.linkSharedHistory(id), []) // a second run changes nothing
        XCTAssertEqual(try text(shared.appending(path: "history.jsonl")), "{\"a\":1}\n{\"shared\":1}\n{\"mine\":1}\n")
    }

    func testMissingSharedTargetReceivesTheProfileItem() throws {
        let profiles = try makeProfiles()
        let id = try profiles.startLogin().session.id
        let dir = config(id)
        try fileManager.removeItem(at: dir.appending(path: "CLAUDE.md"))
        try fileManager.removeItem(at: shared.appending(path: "projects"))
        try fileManager.removeItem(at: dir.appending(path: "projects"))
        try write("notes", to: dir.appending(path: "CLAUDE.md"))
        try write("kept", to: dir.appending(path: "projects/p/a.jsonl"))
        XCTAssertEqual(profiles.linkSharedHistory(id), [])
        XCTAssertEqual(try text(shared.appending(path: "CLAUDE.md")), "notes")
        XCTAssertEqual(try text(shared.appending(path: "projects/p/a.jsonl")), "kept")
    }

    func testRepairReplacesWrongOrMissingLinks() throws {
        let profiles = try makeProfiles()
        let id = try profiles.startLogin().session.id
        let dir = config(id)
        try fileManager.removeItem(at: dir.appending(path: "skills"))
        try fileManager.createSymbolicLink(atPath: dir.appending(path: "skills").path,
                                           withDestinationPath: root.appending(path: "elsewhere").path)
        try fileManager.removeItem(at: dir.appending(path: "agents"))
        XCTAssertEqual(profiles.repairSharedHistory(), [:])
        XCTAssertTrue(isLink(dir.appending(path: "skills"), to: shared.appending(path: "skills")))
        XCTAssertTrue(isLink(dir.appending(path: "agents"), to: shared.appending(path: "agents")))
    }

    func testFailedMigrationLeavesProfileItemInPlace() throws {
        let profiles = try makeProfiles()
        let id = try profiles.startLogin().session.id
        let dir = config(id)
        // The shared item is a file where the profile has a folder: nothing may be merged or removed.
        try fileManager.removeItem(at: shared.appending(path: "plans"))
        try write("file", to: shared.appending(path: "plans"))
        try fileManager.removeItem(at: dir.appending(path: "plans"))
        try write("keep me", to: dir.appending(path: "plans/x.md"))
        let problems = profiles.linkSharedHistory(id)
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(try text(dir.appending(path: "plans/x.md")), "keep me")
    }

    // MARK: Quick switch

    func testMakeDefaultWritesActiveFile() async throws {
        let profiles = try makeProfiles(status: { spec in
            let config = try XCTUnwrap(spec.environment["CLAUDE_CONFIG_DIR"])
            let id = URL(fileURLWithPath: config).deletingLastPathComponent().lastPathComponent
            return .init(loggedIn: true, email: "\(id)@example.test")
        })
        let first = try await profiles.checkLogin(try profiles.startLogin().session.id).account
        let second = try await profiles.checkLogin(try profiles.startLogin().session.id).account
        let active = paths.vaultRoot.appending(path: "claude/active")
        XCTAssertEqual(try text(active), try XCTUnwrap(first).home.path)
        _ = try profiles.makeDefault(try XCTUnwrap(second).id)
        XCTAssertEqual(try text(active), try XCTUnwrap(second).home.path)
        let mode = try fileManager.attributesOfItem(atPath: active.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testShellIntegrationInstallsOnceAndRemovesExactBlock() throws {
        let profiles = try makeProfiles()
        let zshrc = userHome.appending(path: ".zshrc")
        let bashrc = userHome.appending(path: ".bashrc")
        let original = "export A=1\nalias x=y"
        try write(original, to: zshrc)
        XCTAssertFalse(profiles.shellIntegrationInstalled())

        try profiles.installShellIntegration()
        try profiles.installShellIntegration()
        XCTAssertTrue(profiles.shellIntegrationInstalled())
        let installed = try text(zshrc)
        XCTAssertEqual(installed.components(separatedBy: "# >>> switch claude >>>").count, 2)
        XCTAssertEqual(try text(URL(fileURLWithPath: zshrc.path + ".switch-backup")), original)
        XCTAssertFalse(fileManager.fileExists(atPath: bashrc.path))

        try profiles.removeShellIntegration()
        try profiles.removeShellIntegration()
        XCTAssertFalse(profiles.shellIntegrationInstalled())
        XCTAssertEqual(try text(zshrc).trimmingCharacters(in: .whitespacesAndNewlines), original)
    }

    func testShellFunctionUsesActiveDirectoryOnlyWhenItExists() throws {
        let profiles = try makeProfiles()
        try profiles.installShellIntegration()
        let bin = root.appending(path: "bin")
        try write("#!/bin/sh\necho \"dir=${CLAUDE_CONFIG_DIR:-none} args=$*\"\n", to: bin.appending(path: "claude"))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "claude").path)
        let account = root.appending(path: "account dir")
        try fileManager.createDirectory(at: account, withIntermediateDirectories: true)

        func run() throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", ". '\(profiles.shellScript.path)'; claude one two"]
            process.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let active = paths.vaultRoot.appending(path: "claude/active")
        try profiles.writeActive(nil)
        XCTAssertEqual(try run(), "dir=none args=one two")
        try Data(account.path.utf8).write(to: active)
        XCTAssertEqual(try run(), "dir=\(account.path) args=one two")
        try Data(root.appending(path: "gone").path.utf8).write(to: active)
        XCTAssertEqual(try run(), "dir=none args=one two")
    }

    // MARK: Usage API mapper

    func testUsageMapperReadsWindowsScopedLimitsExtraUsageAndGrants() throws {
        let now = try XCTUnwrap(Fmt.iso("2026-10-10T00:00:00Z"))
        let json = try JSON(data: Data("""
        {"five_hour":{"utilization":10,"resets_at":"2099-01-01T00:00:00.000Z"},
         "seven_day":{"utilization":20,"resets_at":"2099-01-08T00:00:00.000Z"},
         "seven_day_sonnet":{"utilization":5,"resets_at":"2099-01-08T00:00:00.000Z"},
         "seven_day_opus":null,
         "limits":[{"kind":"weekly_scoped","group":"weekly","percent":7,"resets_at":"2099-01-08T00:00:00.000Z","is_active":false,
                    "scope":{"model":{"display_name":"Fable","id":null},"surface":null}},
                   {"kind":"weekly_scoped","group":"weekly","percent":9,"scope":{"model":{"display_name":"All models"}}}],
         "extra_usage":{"is_enabled":true,"used_credits":500,"monthly_limit":1000,"utilization":50,"currency":"USD"},
         "cedar_ember":{"eligible":true,"grants":[
           {"id":"a","resets_left":1,"ends_at":"2026-10-22T16:00:00+00:00"},
           {"id":"b","resets_left":2,"ends_at":null},
           {"id":"old","resets_left":3,"ends_at":"2026-09-01T00:00:00+00:00"}]}}
        """.utf8))
        let credentials = try JSON(data: Data(#"{"claudeAiOauth":{"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#.utf8))
        let usage = ClaudeUsage.map(json, credentials: credentials, now: now)

        XCTAssertEqual(usage.windows.map(\.title), ["Session", "Weekly", "Fable weekly", "Sonnet weekly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [10, 20, 7, 5])
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[1].windowMinutes, 10080)
        XCTAssertNotNil(usage.windows[0].resetsAt)
        XCTAssertEqual(usage.cost, UsageCost(used: 5, limit: 10, currency: "USD", period: "Monthly"))
        XCTAssertEqual(usage.sections.first?.rows.first, UsageRow("Available", "3"))
        XCTAssertEqual(usage.plan, "Max 20x")

        let ineligible = ClaudeUsage.map(try JSON(data: Data(#"{"cedar_ember":{"eligible":false}}"#.utf8)), credentials: nil)
        XCTAssertEqual(ineligible.sections.first?.rows.first, UsageRow("Available", "0"))
        XCTAssertNil(ClaudeUsage.map(try JSON(data: Data("{}".utf8)), credentials: nil).cost)
    }

    func testLiveTokenRequiresAnUnexpiredAccessToken() throws {
        let fresh = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let stale = Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000
        func creds(_ expires: Double) throws -> JSON {
            try JSON(data: Data(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":\#(Int(expires))}}"#.utf8))
        }
        XCTAssertEqual(ClaudeUsage.liveToken(try creds(fresh)), "t")
        XCTAssertNil(ClaudeUsage.liveToken(try creds(stale)))
        XCTAssertNil(ClaudeUsage.liveToken(try JSON(data: Data("{}".utf8))))
    }

    // MARK: Usage panel parser (fixtures from CodexBar's tests)

    func testPanelParserReadsSessionWeeklyAndModelRows() throws {
        let now = try XCTUnwrap(Fmt.iso("2025-11-20T12:00:00Z"))
        let usage = try ClaudeUsage.parseUsageText("""
        Settings: Status   Config   Usage (tab to cycle)

        Current session
        1% used  (Resets 5am (Europe/Vienna))
        Current week (all models)
        1% used  (Resets Dec 2 at 12am (Europe/Vienna))
        Current week (Sonnet only)
        4% used (Resets Dec 2 at 12am (Europe/Vienna))

        Account: user@example.com
        """, now: now)
        XCTAssertEqual(usage.windows.map(\.title), ["Session", "Weekly", "Sonnet weekly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [1, 1, 4])
        XCTAssertEqual(usage.windows.map(\.windowMinutes), [300, 10080, 10080])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Vienna"))
        let weekly = try XCTUnwrap(usage.windows[1].resetsAt)
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: weekly)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2025, 12, 2, 0])
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(usage.windows[0].resetsAt)), 5)
    }

    func testPanelParserHandlesAnsiLeftPercentAndGarbledDuplicates() throws {
        let usage = try ClaudeUsage.parseUsageText("""
        \u{1B}[2J\u{1B}[HSettings:  Status   Config   Usage  (tab to cycle)

         Current session
         \u{1B}[38;5;245m▌\u{1B}[0m                                                  0% used
         Resets 1:10pm (Asia/Seoul)

         Current week (all models)
         █████████████████████████████████▌                66% used
         Resets Jul 24 at 2pm (Asia/Seoul)

         Current week (all modls)
         █████████████████████████████████▌                67% used
         Resets Jul 24 at 1:59pm (Asia/Seoul)

         Current week (Fable)
         ████████████████████████████████████              29% left
         Resets Jul 24 at 2pm (Asia/Seoul)
        """)
        XCTAssertEqual(usage.windows.map(\.title), ["Session", "Weekly", "Fable weekly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [0, 66, 71])
    }

    func testPanelParserReportsLoadingAndEmptyText() {
        XCTAssertThrowsError(try ClaudeUsage.parseUsageText("Loading usage data..."))
        XCTAssertThrowsError(try ClaudeUsage.parseUsageText("hello"))
    }

    func testResetDateForms() throws {
        let now = try XCTUnwrap(Fmt.iso("2025-11-20T12:00:00Z"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let at = try XCTUnwrap(ClaudeUsage.resetDate("Resets 9:30pm (UTC)", now: now))
        XCTAssertEqual(utc.dateComponents([.day, .hour, .minute], from: at).hour, 21)
        XCTAssertGreaterThan(at, now)
        let dated = try XCTUnwrap(ClaudeUsage.resetDate("Resets Nov 3, 2026 at 1:30pm (UTC)", now: now))
        XCTAssertEqual(utc.dateComponents([.year, .month, .day, .hour, .minute], from: dated).year, 2026)
        XCTAssertNil(ClaudeUsage.resetDate("soon", now: now))
    }

    // MARK: Terminal probe

    private func fakeClaude(_ body: String) throws -> URL {
        let url = root.appending(path: "fake-claude-\(UUID().uuidString)")
        try write("#!/bin/sh\n\(body)\n", to: url)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testProbeTypesUsageParsesPanelAndPassesSafeFlags() async throws {
        let log = root.appending(path: "invocation.txt")
        let panel = root.appending(path: "panel.txt")
        try write("""
        Settings: Status   Config   Usage (tab to cycle)
        Current session
        12% used  (Resets 5am (UTC))
        Current week (all models)
        30% used  (Resets Dec 2 at 12am (UTC))
        """, to: panel)
        let claude = try fakeClaude("""
        echo "dir=$CLAUDE_CONFIG_DIR key=${ANTHROPIC_API_KEY:-none} args=$*" > '\(log.path)'
        printf 'Welcome\\n> '
        read line
        echo "typed=$line" >> '\(log.path)'
        cat '\(panel.path)'
        exec sleep 60
        """)
        let configDir = root.appending(path: "cfg")
        let cwd = root.appending(path: "probe-cwd")
        let usage = try await ClaudeUsageProbe.run(
            configDir: configDir, executable: claude,
            environment: ["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "secret"],
            workingDirectory: cwd, timeout: 20)
        XCTAssertEqual(usage.windows.map(\.usedPercent), [12, 30])
        let record = try text(log)
        XCTAssertTrue(record.contains("dir=\(configDir.path) key=none"))
        XCTAssertTrue(record.contains("--allowed-tools  --strict-mcp-config --settings"))
        XCTAssertTrue(record.contains("disableAllHooks"))
        XCTAssertTrue(record.contains("typed=/usage"))
    }

    func testProbeTimesOutAndKillsTheChild() async throws {
        let pidFile = root.appending(path: "pid.txt")
        let claude = try fakeClaude("echo $$ > '\(pidFile.path)'\nexec sleep 60")
        let started = Date()
        do {
            _ = try await ClaudeUsageProbe.run(configDir: root.appending(path: "cfg"), executable: claude,
                                               environment: ["PATH": "/usr/bin:/bin"],
                                               workingDirectory: root.appending(path: "probe-cwd"), timeout: 3)
            XCTFail("expected a timeout")
        } catch let error as ProviderError {
            guard case .unavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let pid = try XCTUnwrap(Int32(try text(pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        usleep(300_000)
        XCTAssertNotEqual(kill(pid, 0), 0, "child still running")
    }

    func testProfileUsageProbesOnceInsideTheRateLimitWindow() async throws {
        let counter = root.appending(path: "runs.txt")
        let panel = root.appending(path: "panel.txt")
        try write("Current session\n7% used (Resets 5am (UTC))\n", to: panel)
        paths.claudeExecutable = try fakeClaude("""
        echo run >> '\(counter.path)'
        printf '> '
        read line
        cat '\(panel.path)'
        exec sleep 60
        """)
        let profiles = try makeProfiles()
        let login = try await profiles.checkLogin(try profiles.startLogin().session.id)
        let account = try XCTUnwrap(login.account)
        try write(#"{"oauthAccount":{"emailAddress":"owner@example.test","organizationName":"Org"}}"#,
                  to: config(account.id).appending(path: ".claude.json"))
        // An expired token must not be used or refreshed.
        try write(#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"keep","expiresAt":1000}}"#,
                  to: config(account.id).appending(path: ".credentials.json"))

        let first = try await profiles.usage(accountID: account.id)
        let second = try await profiles.usage(accountID: account.id)
        XCTAssertEqual(first.windows.first?.usedPercent, 7)
        XCTAssertEqual(first.email, "owner@example.test")
        XCTAssertEqual(first.organization, "Org")
        XCTAssertEqual(second, first)
        XCTAssertEqual(try text(counter).split(separator: "\n").count, 1)
        XCTAssertTrue(try text(config(account.id).appending(path: ".credentials.json")).contains("keep"))
    }
}
