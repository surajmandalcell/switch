import XCTest
@testable import AIManagerCore

final class AutoSwitchDecisionTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    private func order(_ a: Double?, _ b: Double?, _ c: Double?) -> [AutoSwitch.Candidate] {
        [.init(id: self.a, leftPercent: a), .init(id: self.b, leftPercent: b), .init(id: self.c, leftPercent: c)]
    }

    func testStaysAboveThresholdAndWithoutUsage() {
        XCTAssertEqual(AutoSwitch.decide(order: order(40, 90, 90), defaultID: a, threshold: 1), .stay)
        XCTAssertEqual(AutoSwitch.decide(order: order(nil, 90, 90), defaultID: a, threshold: 1), .stay)
        XCTAssertEqual(AutoSwitch.decide(order: order(0, 90, 90), defaultID: UUID(), threshold: 1), .stay)
    }

    func testSwitchesToFirstAccountInOrderAboveThreshold() {
        XCTAssertEqual(AutoSwitch.decide(order: order(1, 50, 90), defaultID: a, threshold: 1), .switchTo(b))
        // The order is a priority list: an earlier account that recovered wins over a later one.
        XCTAssertEqual(AutoSwitch.decide(order: order(80, 50, 0), defaultID: c, threshold: 1), .switchTo(a))
    }

    func testSkipsSignedOutAndAtThresholdAccounts() {
        XCTAssertEqual(AutoSwitch.decide(order: order(0, nil, 30), defaultID: a, threshold: 5), .switchTo(c))
        XCTAssertEqual(AutoSwitch.decide(order: order(0, 5, 30), defaultID: a, threshold: 5), .switchTo(c))
        XCTAssertEqual(AutoSwitch.decide(order: order(0, 5.5, 30), defaultID: a, threshold: 5), .switchTo(b))
    }

    func testNoneLeftWhenEveryOtherAccountIsAtThresholdOrSignedOut() {
        XCTAssertEqual(AutoSwitch.decide(order: order(1, nil, 1), defaultID: a, threshold: 1), .noneLeft)
        XCTAssertEqual(AutoSwitch.decide(order: [.init(id: a, leftPercent: 0)], defaultID: a, threshold: 1), .noneLeft)
    }

    func testNoSwitchBackAndForth() {
        // a ran out and b took over. b is fine, so nothing happens, even though a is still empty.
        XCTAssertEqual(AutoSwitch.decide(order: order(0, 60, 70), defaultID: b, threshold: 1), .stay)
        // When b runs out too, a is skipped until it recovers above the threshold.
        XCTAssertEqual(AutoSwitch.decide(order: order(0, 1, 70), defaultID: b, threshold: 1), .switchTo(c))
        XCTAssertEqual(AutoSwitch.decide(order: order(0, 1, 1), defaultID: b, threshold: 1), .noneLeft)
        XCTAssertEqual(AutoSwitch.decide(order: order(25, 1, 1), defaultID: b, threshold: 1), .switchTo(a))
    }

    func testPercentLeftIsTheLowerOfSessionAndWeekly() {
        let windows = [
            UsageWindow(id: "session", title: "Session", usedPercent: 40),
            UsageWindow(id: "weekly", title: "Weekly", usedPercent: 97),
            UsageWindow(id: "opus", title: "Opus", usedPercent: 100),
        ]
        XCTAssertEqual(AutoSwitch.leftPercent(of: windows), 3)
        XCTAssertEqual(AutoSwitch.leftPercent(of: [UsageWindow(id: "monthly", title: "Monthly", usedPercent: 130)]), 0)
        let past = Date(timeIntervalSince1970: 1000)
        let reset = [UsageWindow(id: "session", title: "Session", usedPercent: 100, resetsAt: past),
                     UsageWindow(id: "weekly", title: "Weekly", usedPercent: 50, resetsAt: past.addingTimeInterval(9999))]
        XCTAssertEqual(AutoSwitch.leftPercent(of: reset, now: past.addingTimeInterval(10)), 50)
        XCTAssertNil(AutoSwitch.leftPercent(of: []))
        XCTAssertNil(AutoSwitch.leftPercent(of: [UsageWindow(id: "session", title: "Session", usedPercent: nil)]))
    }
}

final class CLITranscriptTests: XCTestCase {
    private func lines(_ items: [String]) -> String { items.joined(separator: "\n") + "\n" }
    private func codex(_ type: String, _ extra: String = "") -> String {
        #"{"type":"event_msg","payload":{"type":"\#(type)"\#(extra)}}"#
    }
    private let tokens = #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#
    private let limit = #","message":"You've hit your usage limit. Try again later.","codex_error_info":"usage_limit_exceeded""#

    func testCodexWorkingWhileTheTurnRuns() {
        let tail = lines([codex("task_started"), #"{"type":"response_item","payload":{"type":"function_call"}}"#, tokens])
        XCTAssertEqual(CLITranscript.state(.codex, tail: tail), .working)
        XCTAssertEqual(CLITranscript.state(.codex, tail: ""), .working)
        XCTAssertEqual(CLITranscript.state(.codex, tail: "not json\n"), .working)
    }

    func testCodexIdleAfterTurnEnd() {
        let done = lines([codex("task_started"), codex("agent_message"), codex("task_complete"), tokens])
        XCTAssertEqual(CLITranscript.state(.codex, tail: done), .idle(cutShort: false))
        let aborted = lines([codex("task_started"), codex("turn_aborted")])
        XCTAssertEqual(CLITranscript.state(.codex, tail: aborted), .idle(cutShort: false))
        // A new turn after a finished one is working again.
        let next = lines([codex("task_complete"), codex("task_started"), codex("user_message")])
        XCTAssertEqual(CLITranscript.state(.codex, tail: next), .working)
    }

    func testCodexCutShortByUsageLimit() {
        let cut = lines([codex("task_started"), codex("error", limit), tokens])
        XCTAssertEqual(CLITranscript.state(.codex, tail: cut), .idle(cutShort: true))
        let cutThenComplete = lines([codex("task_started"), codex("error", limit), codex("task_complete")])
        XCTAssertEqual(CLITranscript.state(.codex, tail: cutThenComplete), .idle(cutShort: true))
        let other = lines([codex("task_started"), codex("error", #","message":"stream disconnected""#)])
        XCTAssertEqual(CLITranscript.state(.codex, tail: other), .idle(cutShort: false))
        // An old limit error does not mark a later finished turn.
        let old = lines([codex("task_started"), codex("error", limit), codex("task_started"), codex("task_complete")])
        XCTAssertEqual(CLITranscript.state(.codex, tail: old), .idle(cutShort: false))
        // An error that the turn continued past is not a turn end.
        let retried = lines([codex("task_started"), codex("error", limit), codex("agent_message")])
        XCTAssertEqual(CLITranscript.state(.codex, tail: retried), .working)
    }

    private func claude(_ role: String, stop: String? = nil, extra: String = "", text: String = "ok") -> String {
        let stopJSON = stop.map { #""stop_reason":"\#($0)","# } ?? #""stop_reason":null,"#
        return #"{"type":"\#(role)",\#(extra)"message":{"role":"\#(role)",\#(stopJSON)"content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    func testClaudeIdleOnEndTurn() {
        let tail = lines([claude("user"), claude("assistant", stop: "tool_use"), claude("user"), claude("assistant", stop: "end_turn"),
                          #"{"type":"system","subtype":"turn_duration"}"#, #"{"type":"last-prompt"}"#])
        XCTAssertEqual(CLITranscript.state(.claude, tail: tail), .idle(cutShort: false))
    }

    func testClaudeWorkingMidTurn() {
        XCTAssertEqual(CLITranscript.state(.claude, tail: lines([claude("assistant", stop: "end_turn"), claude("user")])), .working)
        XCTAssertEqual(CLITranscript.state(.claude, tail: lines([claude("assistant", stop: "tool_use")])), .working)
        XCTAssertEqual(CLITranscript.state(.claude, tail: lines([claude("assistant")])), .working)
        // Subagent lines are ignored.
        let sidechain = lines([claude("assistant", stop: "end_turn"), claude("user", extra: #""isSidechain":true,"#)])
        XCTAssertEqual(CLITranscript.state(.claude, tail: sidechain), .idle(cutShort: false))
        XCTAssertEqual(CLITranscript.state(.claude, tail: ""), .working)
    }

    func testClaudeCutShortByLimitError() {
        let error = claude("assistant", stop: "stop_sequence",
                           extra: #""isApiErrorMessage":true,"error":"rate_limit","#,
                           text: "You've hit your session limit · resets 7:10am")
        XCTAssertEqual(CLITranscript.state(.claude, tail: lines([claude("user"), error])), .idle(cutShort: true))
        let other = claude("assistant", stop: "stop_sequence", extra: #""isApiErrorMessage":true,"error":"server_error","#,
                           text: "API Error: 500")
        XCTAssertEqual(CLITranscript.state(.claude, tail: lines([claude("user"), other])), .idle(cutShort: false))
        let interrupted = claude("user", text: "[Request interrupted by user]")
        XCTAssertEqual(CLITranscript.state(.claude, tail: lines([claude("assistant", stop: "tool_use"), interrupted])),
                       .idle(cutShort: false))
    }

    func testTailStartsAtALineBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try (String(repeating: "x", count: 50) + "\n" + codex("task_complete") + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(CLITranscript.readTail(url, bytes: 80), codex("task_complete") + "\n")
    }
}

final class CLIResumeCommandTests: XCTestCase {
    func testResumeArgumentsKeepEachValueWhole() {
        let id = "01a0b8fc-33d4-7ba2-95a5-d1a0cbabd226"
        XCTAssertEqual(CLIResume(tool: .codex, sessionID: id, cwd: "/w", prompt: nil).arguments, ["resume", id])
        XCTAssertEqual(CLIResume(tool: .claude, sessionID: id, cwd: "/w", prompt: nil).arguments, ["--resume", id])
        // A prompt with quotes, a dollar sign, a newline, and a flag-like start stays one argument.
        let prompt = "--force it's $(rm -rf /) \"x\"\nline two"
        XCTAssertEqual(CLIResume(tool: .codex, sessionID: id, cwd: "/w", prompt: prompt).arguments, ["resume", id, prompt])
        XCTAssertEqual(CLIResume(tool: .claude, sessionID: id, cwd: "/w", prompt: prompt).arguments, ["--resume", id, prompt])
    }

    func testOnlyInteractiveRunsAreCandidates() {
        let cases: [(String, CLITool?)] = [
            ("codex --no-daemon --yolo resume 01a0b8fc-33d4-7ba2-95a5-d1a0cbabd226", .codex),
            ("/Users/x/.codex/packages/standalone/releases/0.160.1/bin/codex", .codex),
            ("node /opt/homebrew/bin/codex", .codex),
            ("codex exec --skip-git-repo-check -m gpt-6.1-sol -C /w", nil),
            ("codex review", nil),
            ("timeout 3600 codex exec -s read-only", nil),
            ("/Users/x/.codex/packages/standalone/releases/0.160.1/bin/codex-code-mode-host", nil),
            ("claude --dangerously-skip-permissions --resume 8bd5d842", .claude),
            ("/Users/x/.local/share/claude/versions/2.1.299 --allowed-tools x", .claude),
            ("claude -p hello", nil),
            ("claude --print --output-format json", nil),
            ("/Users/x/.local/bin/claude --chrome-native-host", nil),
            ("/bin/zsh -c claude", nil),
        ]
        for (command, tool) in cases {
            XCTAssertEqual(RunningCLIs.interactiveTool(of: command), tool, command)
        }
    }

    func testClaudeSessionComesFromItsProfileFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-cfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/x/My Project.v2"
        XCTAssertEqual(RunningCLIs.encodedProjectName(cwd), "-Users-x-My-Project-v2")
        let project = root.appending(path: "projects/\(RunningCLIs.encodedProjectName(cwd))")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
        try "{}\n".write(to: project.appending(path: "abc.jsonl"), atomically: true, encoding: .utf8)
        try #"{"pid":4242,"sessionId":"abc","cwd":"\#(cwd)","kind":"interactive"}"#
            .write(to: root.appending(path: "sessions/4242.json"), atomically: true, encoding: .utf8)
        try #"{"pid":4243,"sessionId":"abc","cwd":"\#(cwd)","kind":"headless"}"#
            .write(to: root.appending(path: "sessions/4243.json"), atomically: true, encoding: .utf8)
        let cli = try XCTUnwrap(RunningCLIs.claudeSession(pid: 4242, command: "claude", configDir: root.path))
        XCTAssertEqual(cli.sessionID, "abc")
        XCTAssertEqual(cli.cwd, cwd)
        XCTAssertEqual(cli.transcript.lastPathComponent, "abc.jsonl")
        XCTAssertNil(RunningCLIs.claudeSession(pid: 4243, command: "claude", configDir: root.path))
        XCTAssertNil(RunningCLIs.claudeSession(pid: 1, command: "claude", configDir: root.path))
    }
}

private actor ResumeLog {
    private(set) var resumes: [CLIResume] = []
    func add(_ resume: CLIResume) { resumes.append(resume) }
}

/// Starts its own child process only. It signals nothing else and opens no Terminal window.
final class RunningCLIProcessTests: XCTestCase {
    private var root: URL!
    private var child: Process?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "running-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "bin/codex"), withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
    }

    override func tearDown() {
        if let child, child.isRunning { child.terminate() }
        try? FileManager.default.removeItem(at: root)
    }

    private let sessionID = "01a0b8fc-33d4-7ba2-95a5-d1a0cbabd226"

    /// A rollout with a running turn, held open by a `codex` child that sleeps.
    private func startFakeCodex(originator: String = "codex-tui") throws -> (cli: RunningCLI, rollout: URL) {
        let folder = root.appending(path: "sessions/2026/10/15")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rollout = folder.appending(path: "rollout-2026-10-15T00-00-00-\(sessionID).jsonl")
        let meta = #"{"type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"\#(root.path)","originator":"\#(originator)"}}"#
        try (meta + "\n" + #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n")
            .write(to: rollout, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"exec 3<"$1"; exec "$2" 600"#, "sh", rollout.path, root.appending(path: "bin/codex").path]
        // No inherited pipes: a child that outlives a killed test run must not hold the runner's output open.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        child = process
        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(5)
        while RunningCLIs.commandLine(pid: pid)?.hasSuffix("/bin/codex 600") != true {
            XCTAssertLessThan(Date(), deadline, "the fake codex never started")
            if Date() >= deadline { throw CocoaError(.fileReadUnknown) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let found = RunningCLIs.find(claudeDefaultConfig: root, requireTTY: false).filter { $0.pid == pid }
        return (try XCTUnwrap(found.first), rollout)
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func runScenario(end: [String]) async throws -> (CLIRestartOutcome, CLIResume?, pid: Int32) {
        let (cli, rollout) = try startFakeCodex()
        XCTAssertEqual(cli.tool, .codex)
        XCTAssertEqual(cli.sessionID, sessionID)
        XCTAssertEqual(cli.cwd, root.path)
        XCTAssertEqual(cli.transcript.resolvingSymlinksInPath().path, rollout.resolvingSymlinksInPath().path)

        let log = ResumeLog()
        let options = CLIRestartOptions(pollInterval: 0.1, deadline: 30, killGrace: 2, resumeMessage: "Continue please.")
        let task = Task { await RunningCLIs.restart(cli, options: options) { await log.add($0); return true } }
        // Mid-turn: the child must keep running.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNotNil(RunningCLIs.commandLine(pid: cli.pid), "stopped in the middle of a turn")
        let early = await log.resumes
        XCTAssertTrue(early.isEmpty)
        try append(end, to: rollout)
        let outcome = await task.value
        let resumes = await log.resumes
        XCTAssertNil(RunningCLIs.commandLine(pid: cli.pid), "the old process is still alive")
        return (outcome, resumes.first, cli.pid)
    }

    func testIdleTurnStopsTheChildAndResumesWithoutAPrompt() async throws {
        let (outcome, resume, _) = try await runScenario(end: [#"{"type":"event_msg","payload":{"type":"task_complete"}}"#])
        XCTAssertEqual(outcome, .relaunched)
        XCTAssertEqual(resume, CLIResume(tool: .codex, sessionID: sessionID, cwd: root.path, prompt: nil))
    }

    func testLimitCutPassesTheResumeMessage() async throws {
        let (outcome, resume, _) = try await runScenario(end: [
            #"{"type":"event_msg","payload":{"type":"error","message":"You've hit your usage limit.","codex_error_info":"usage_limit_exceeded"}}"#,
        ])
        XCTAssertEqual(outcome, .relaunched)
        XCTAssertEqual(resume?.prompt, "Continue please.")
        XCTAssertEqual(resume?.arguments, ["resume", sessionID, "Continue please."])
    }

    func testExecRolloutIsSkipped() throws {
        let folder = root.appending(path: "sessions/2026/10/15")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rollout = folder.appending(path: "rollout-2026-10-15T00-00-00-\(sessionID).jsonl")
        try (#"{"type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"/w","originator":"codex_exec"}}"# + "\n")
            .write(to: rollout, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"exec 3<"$1"; exec "$2" 600"#, "sh", rollout.path, root.appending(path: "bin/codex").path]
        // No inherited pipes: a child that outlives a killed test run must not hold the runner's output open.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        child = process
        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(5)
        while RunningCLIs.commandLine(pid: pid)?.hasSuffix("/bin/codex 600") != true, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(RunningCLIs.find(claudeDefaultConfig: root, requireTTY: false).filter { $0.pid == pid }.isEmpty)
        // A real run always has a terminal; the fake one has none, so the default filter skips it too.
        XCTAssertTrue(RunningCLIs.find(claudeDefaultConfig: root).filter { $0.pid == pid }.isEmpty)
    }

    func testDeadlineLeavesTheChildRunning() async throws {
        let (cli, _) = try startFakeCodex()
        let options = CLIRestartOptions(pollInterval: 0.1, deadline: 0.6, killGrace: 1)
        let outcome = await RunningCLIs.restart(cli, options: options) { _ in XCTFail("launched"); return true }
        XCTAssertEqual(outcome, .leftRunning)
        XCTAssertNotNil(RunningCLIs.commandLine(pid: cli.pid))
    }
}
