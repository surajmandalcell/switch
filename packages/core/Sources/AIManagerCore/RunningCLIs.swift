import Foundation

// Auto switch, "Restart when idle": finds interactive Codex and Claude Code processes, waits
// until their turn ends, stops them, and hands a resume request to a launcher the app injects
// (the app opens a new Terminal window). Nothing here opens a window or touches an account.

public enum CLITool: String, Sendable {
    case codex, claude
}

public struct RunningCLI: Equatable, Sendable {
    public var pid: Int32
    public var tool: CLITool
    /// The full command line seen at discovery; a stop requires it to be unchanged (guards pid reuse).
    public var command: String
    public var sessionID: String
    public var cwd: String
    public var transcript: URL
    /// Claude Code only: the profile folder (`CLAUDE_CONFIG_DIR`, else the default ~/.claude).
    public var configDir: String?
    /// The original options (`--yolo`, `--permission-mode=plan`) to carry over to the reopened run.
    /// Nil when they cannot be carried over safely (an option with a separate value, or a prompt).
    public var flags: [String]?
}

public enum CLITurnState: Equatable, Sendable {
    case working
    /// The turn ended. `cutShort` is true when a usage or rate limit ended it.
    case idle(cutShort: Bool)
}

/// What to open again. The app turns it into a launch on the new default account.
public struct CLIResume: Equatable, Sendable {
    public var tool: CLITool
    public var sessionID: String
    public var cwd: String
    /// The original run's options, carried over so a restrictive run never comes back weaker.
    public var flags: [String]
    /// Set only when a limit cut the last turn short.
    public var prompt: String?

    public init(tool: CLITool, sessionID: String, cwd: String, flags: [String] = [], prompt: String? = nil) {
        self.tool = tool
        self.sessionID = sessionID
        self.cwd = cwd
        self.flags = flags
        self.prompt = prompt
    }

    /// Arguments after the executable. One element each, so nothing needs quoting here; the
    /// launch script quotes every element. The prompt loses leading dashes, so it never parses as a flag.
    public var arguments: [String] {
        let head = flags + (tool == .codex ? ["resume", sessionID] : ["--resume", sessionID])
        let text = prompt.map { String($0.drop { $0 == "-" || $0.isWhitespace }) } ?? ""
        return head + (text.isEmpty ? [] : [text])
    }
}

public enum CLIRestartOutcome: Equatable, Sendable {
    /// Stopped and handed to the launcher, which accepted it.
    case relaunched
    /// Stopped, but the launcher failed.
    case launchFailed
    /// The process ended by itself (the user closed it): nothing to reopen.
    case exited
    /// The deadline passed or the task was cancelled; the process still runs on the old account.
    case leftRunning
    /// The original options cannot be carried over safely; nothing was signaled.
    case unsupportedOptions
}

public struct CLIRestartOptions: Sendable {
    public var pollInterval: TimeInterval = 3
    /// Give up waiting for an idle turn after this long (2 hours).
    public var deadline: TimeInterval = 7200
    /// SIGKILL follows SIGTERM only after this long.
    public var killGrace: TimeInterval = 5
    /// Sent as the resume prompt only when a limit cut the last turn short. Empty sends none.
    public var resumeMessage = AutoSwitch.defaultResumeMessage

    public init(pollInterval: TimeInterval = 3, deadline: TimeInterval = 7200, killGrace: TimeInterval = 5,
                resumeMessage: String = AutoSwitch.defaultResumeMessage) {
        self.pollInterval = pollInterval
        self.deadline = deadline
        self.killGrace = killGrace
        self.resumeMessage = resumeMessage
    }
}

// MARK: - Transcript state

public enum CLITranscript {
    /// Reads the turn state from the end of a transcript. Unknown or unreadable means working,
    /// so a CLI is never stopped on a guess.
    public static func state(_ tool: CLITool, tail: String) -> CLITurnState {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        return tool == .codex ? codexState(lines) : claudeState(lines)
    }

    static func isLimitText(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["usage limit", "usage_limit", "rate limit", "rate_limit", "session limit", "weekly limit",
                "hit your limit"].contains { lower.contains($0) }
    }

    private static func object(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    /// Codex rollout: `event_msg` lines. A turn runs from task_started to task_complete,
    /// turn_aborted, or an error event with nothing after it but token bookkeeping.
    private static func codexState(_ lines: [Substring]) -> CLITurnState {
        var ended = false
        var cut = false
        var activity = false
        for line in lines.reversed() {
            guard let item = object(line) else { continue }
            let kind = item["type"] as? String
            let payload = item["payload"] as? [String: Any]
            let event = kind == "event_msg" ? payload?["type"] as? String : nil
            switch event {
            case "task_started", "turn_started", "user_message":
                return ended ? .idle(cutShort: cut) : .working
            case "task_complete", "turn_complete", "turn_aborted":
                ended = true
            case "error":
                if !ended && activity { return .working }
                ended = true
                let text = [payload?["message"], payload?["codex_error_info"]]
                    .compactMap { value in value.flatMap { String(describing: $0) } }.joined(separator: " ")
                if isLimitText(text) { cut = true }
            case "token_count":
                break
            default:
                if kind != "token_usage_record", kind != "turn_context", kind != "world_state" { activity = true }
            }
        }
        return ended ? .idle(cutShort: cut) : .working
    }

    /// Claude Code transcript: the last user or assistant line decides. An assistant line ending
    /// the turn, or an API error line, is idle; a user prompt, tool result, or tool call is working.
    private static func claudeState(_ lines: [Substring]) -> CLITurnState {
        for line in lines.reversed() {
            guard let item = object(line), item["isSidechain"] as? Bool != true else { continue }
            let message = item["message"] as? [String: Any]
            switch item["type"] as? String {
            case "assistant":
                if item["isApiErrorMessage"] as? Bool == true {
                    let text = ((message?["content"] as? [[String: Any]]) ?? [])
                        .compactMap { $0["text"] as? String }.joined(separator: " ")
                    return .idle(cutShort: isLimitText((item["error"] as? String ?? "") + " " + text))
                }
                let stop = message?["stop_reason"] as? String
                return ["end_turn", "stop_sequence", "max_tokens"].contains(stop ?? "") ? .idle(cutShort: false) : .working
            case "user":
                let content = message?["content"]
                let text = (content as? String)
                    ?? ((content as? [[String: Any]])?.first?["text"] as? String) ?? ""
                return text.hasPrefix("[Request interrupted by user") ? .idle(cutShort: false) : .working
            default:
                continue
            }
        }
        return .working
    }

    /// The last `bytes` of a file, starting at a line boundary. Nil when unreadable.
    public static func readTail(_ url: URL, bytes: Int = 2_000_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }
}

// MARK: - Discovery and restart

public enum RunningCLIs {
    // MARK: Which processes count

    private static let codexNonInteractive: Set<String> = [
        "exec", "e", "review", "app-server", "mcp-server", "mcp", "login", "logout", "proto", "completion",
        "apply", "cloud", "sandbox", "debug", "features",
    ]
    private static let claudeNonInteractive: Set<String> = [
        "-p", "--print", "--chrome-native-host", "--input-format", "--output-format", "--sdk-url",
        "mcp", "config", "doctor", "update", "install", "auth", "plugin", "setup-token",
    ]

    /// Codex or Claude Code, when the command line is an interactive run of one. Runs that
    /// print and exit (`codex exec`, `claude -p`) and helper commands are not.
    static func interactiveTool(of command: String) -> CLITool? {
        let args = command.split(separator: " ").map(String.init)
        guard let first = args.first else { return nil }
        func base(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }
        var program = first
        var rest = Array(args.dropFirst())
        if base(first) == "node", let script = rest.first {
            program = script
            rest = Array(rest.dropFirst())
        }
        let tool: CLITool
        if base(program) == "codex" {
            tool = .codex
        } else if base(program) == "claude" || program.contains("/claude/versions/") || program.contains("claude-code/") {
            tool = .claude
        } else {
            return nil
        }
        let blocked = tool == .codex ? codexNonInteractive : claudeNonInteractive
        return rest.contains(where: blocked.contains) ? nil : tool
    }

    // MARK: Finding sessions

    /// Interactive Codex and Claude Code processes of this user with a known session.
    /// `requireTTY` is false only in tests: a real interactive CLI always has a terminal.
    /// `claudeConfigFilter` receives each Claude Code profile folder and keeps the ones on the old account.
    public static func find(
        claudeDefaultConfig: URL, requireTTY: Bool = true,
        claudeConfigFilter: (String) -> Bool = { _ in true }
    ) -> [RunningCLI] {
        var found: [RunningCLI] = []
        for row in run("/bin/ps", ["-axww", "-o", "pid=,tty=,command="]).split(separator: "\n") {
            let parts = row.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), pid != getpid() else { continue }
            if requireTTY, parts[1] == "??" { continue }
            let command = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard let tool = interactiveTool(of: command) else { continue }
            let args = procArgs(pid: pid)
            switch tool {
            case .codex:
                guard var cli = codexSession(pid: pid, command: command) else { continue }
                cli.flags = args.flatMap { flags(tool: .codex, argv: $0.argv, sessionID: cli.sessionID) }
                found.append(cli)
            case .claude:
                let dir = args.flatMap { claudeConfigDir(env: $0.env) } ?? claudeDefaultConfig.path
                guard claudeConfigFilter(dir), var cli = claudeSession(pid: pid, command: command, configDir: dir)
                else { continue }
                cli.flags = args.flatMap { flags(tool: .claude, argv: $0.argv, sessionID: cli.sessionID) }
                found.append(cli)
            }
        }
        return found
    }

    /// Codex keeps its rollout open; `lsof` names it, and the first line holds the session id and cwd.
    private static func codexSession(pid: Int32, command: String) -> RunningCLI? {
        let rollout = run("/usr/sbin/lsof", ["-nP", "-p", String(pid), "-Fn"]).split(separator: "\n")
            .map { String($0.dropFirst()) }
            .first { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                return path.contains("/sessions/") && name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
            }
        guard let rollout else { return nil }
        let url = URL(fileURLWithPath: rollout)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1_000_000),
              let line = String(decoding: head, as: UTF8.self).split(separator: "\n").first,
              let meta = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              meta["type"] as? String == "session_meta",
              let payload = meta["payload"] as? [String: Any],
              let id = payload["id"] as? String, UUID(uuidString: id) != nil,
              let cwd = payload["cwd"] as? String, cwd.hasPrefix("/"),
              payload["originator"] as? String != "codex_exec" else { return nil }
        return RunningCLI(pid: pid, tool: .codex, command: command, sessionID: id, cwd: cwd,
                          transcript: url, configDir: nil)
    }

    /// Claude Code writes `<profile>/sessions/<pid>.json` (session id, cwd, kind) for each run.
    static func claudeSession(pid: Int32, command: String, configDir: String) -> RunningCLI? {
        let config = URL(fileURLWithPath: configDir)
        guard let data = try? Data(contentsOf: config.appending(path: "sessions/\(pid).json")),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              info["kind"] as? String == "interactive",
              let id = info["sessionId"] as? String, UUID(uuidString: id) != nil,
              let cwd = info["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
        let projects = config.appending(path: "projects", directoryHint: .isDirectory)
        var transcript = projects.appending(path: encodedProjectName(cwd)).appending(path: "\(id).jsonl")
        if !FileManager.default.fileExists(atPath: transcript.path) {
            let match = (try? FileManager.default.contentsOfDirectory(atPath: projects.path))?
                .map { projects.appending(path: $0).appending(path: "\(id).jsonl") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let match else { return nil }
            transcript = match
        }
        return RunningCLI(pid: pid, tool: .claude, command: command, sessionID: id, cwd: cwd,
                          transcript: transcript, configDir: configDir)
    }

    /// Claude Code names a project folder after its cwd with every other character as a dash.
    static func encodedProjectName(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        })
    }

    /// `CLAUDE_CONFIG_DIR` from the process environment entries only (never argv); nil when unset.
    /// No other environment value is kept.
    static func claudeConfigDir(env: [String]) -> String? {
        let prefix = "CLAUDE_CONFIG_DIR="
        guard let entry = env.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(entry.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    // MARK: Exact argv and environment

    /// The options to carry over to the reopened run, or nil when they cannot be carried over safely.
    /// `argv` starts with the program (`node <script>` counts as the program). The resume pieces are
    /// removed; every other element must be a flag (start with "-"), so a value or a prompt fails closed.
    static func flags(tool: CLITool, argv: [String], sessionID: String) -> [String]? {
        guard let first = argv.first else { return nil }
        let skip = URL(fileURLWithPath: first).lastPathComponent == "node" ? 2 : 1
        let resumeWords: Set<String> = tool == .codex
            ? ["resume", "--last", "--all", "--include-non-interactive"]
            : ["--resume", "-r", "--continue", "-c", "--fork-session"]
        let idAfter: Set<String> = tool == .codex ? ["resume"] : ["--resume", "-r"]
        let rest = Array(argv.dropFirst(skip))
        var kept: [String] = []
        for (index, arg) in rest.enumerated() {
            if resumeWords.contains(arg) { continue }
            if arg == sessionID, index > 0, idAfter.contains(rest[index - 1]) { continue }
            kept.append(arg)
        }
        return kept.allSatisfy { $0.hasPrefix("-") && $0 != "--" } ? kept : nil
    }

    /// Splits a `KERN_PROCARGS2` buffer: Int32 argc, exec path, NUL padding, argc argv strings, then
    /// environment strings up to an empty one. Nil when the buffer is cut short.
    static func parseProcArgs(_ bytes: [UInt8]) -> (argv: [String], env: [String])? {
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.prefix(4).enumerated().reduce(Int32(0)) { $0 | Int32($1.element) << (8 * Int32($1.offset)) }
        guard argc >= 0 else { return nil }
        var index = 4
        func string() -> String? {
            guard let end = bytes[index...].firstIndex(of: 0) else { return nil }
            defer { index = end + 1 }
            return String(decoding: bytes[index..<end], as: UTF8.self)
        }
        guard string() != nil else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var argv: [String] = []
        for _ in 0..<argc {
            guard let arg = string() else { return nil }
            argv.append(arg)
        }
        var env: [String] = []
        while index < bytes.count, let entry = string(), !entry.isEmpty { env.append(entry) }
        return (argv, env)
    }

    /// The exact argv and environment of a process of this user; nil when unreadable.
    static func procArgs(pid: Int32) -> (argv: [String], env: [String])? {
        var limit: Int32 = 0
        var limitSize = MemoryLayout<Int32>.size
        var maxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&maxMib, 2, &limit, &limitSize, nil, 0) == 0, limit > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(limit))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer[..<size]))
    }

    // MARK: Waiting, stopping, reopening

    /// Waits until the CLI's turn ends, stops it, and calls `launch`. Never stops a CLI that is
    /// mid-turn: the state is read twice in a row, and again right before the signal.
    public static func restart(
        _ cli: RunningCLI, options: CLIRestartOptions = CLIRestartOptions(),
        launch: (CLIResume) async -> Bool
    ) async -> CLIRestartOutcome {
        guard let flags = cli.flags else { return .unsupportedOptions }
        let end = Date().addingTimeInterval(options.deadline)
        var idleReads = 0
        while Date() < end, !Task.isCancelled {
            guard commandLine(pid: cli.pid) == cli.command else { return .exited }
            if case .idle = turnState(of: cli) { idleReads += 1 } else { idleReads = 0 }
            if idleReads >= 2, case .idle(let cut) = turnState(of: cli) {
                guard stop(cli, grace: options.killGrace) else { return .leftRunning }
                let message = options.resumeMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                let prompt = cut && !message.isEmpty ? message : nil
                let resume = CLIResume(tool: cli.tool, sessionID: cli.sessionID, cwd: cli.cwd, flags: flags, prompt: prompt)
                return await launch(resume) ? .relaunched : .launchFailed
            }
            try? await Task.sleep(for: .seconds(options.pollInterval))
        }
        return .leftRunning
    }

    static func turnState(of cli: RunningCLI) -> CLITurnState {
        CLITranscript.readTail(cli.transcript).map { CLITranscript.state(cli.tool, tail: $0) } ?? .working
    }

    /// SIGTERM, then SIGKILL after `grace` seconds if still alive. Signals only the exact process
    /// found at discovery. False when it could not be stopped or is no longer that process.
    static func stop(_ cli: RunningCLI, grace: TimeInterval) -> Bool {
        guard commandLine(pid: cli.pid) == cli.command else { return false }
        kill(cli.pid, SIGTERM)
        let end = Date().addingTimeInterval(grace)
        while Date() < end {
            if commandLine(pid: cli.pid) == nil { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard commandLine(pid: cli.pid) == cli.command else { return true }
        kill(cli.pid, SIGKILL)
        Thread.sleep(forTimeInterval: 0.3)
        return commandLine(pid: cli.pid) == nil
    }

    /// The command line of a live process; nil when it is gone or a zombie.
    static func commandLine(pid: Int32) -> String? {
        let text = run("/bin/ps", ["-ww", "-p", String(pid), "-o", "stat=,command="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = text.firstIndex(of: " "), !text[..<space].hasPrefix("Z") else { return nil }
        return String(text[text.index(after: space)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        // End of output means the command exited. No waitUntilExit: its run loop can stall under load.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
