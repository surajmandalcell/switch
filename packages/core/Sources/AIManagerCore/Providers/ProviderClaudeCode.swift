import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#endif

// Claude Code usage. Claude Code owns the OAuth tokens (macOS Keychain, or `.credentials.json`
// when the Keychain write fails), so Switch never refreshes them and never reads the Keychain:
// it reads the access token from the profile file when that file is there and still valid, and
// otherwise asks the CLI itself through its `/usage` panel.

extension ProviderCatalog {
    static let claudeCode = ProviderSpec(
        id: "claude-code", name: "Claude Code", style: .files, files: [ClaudeUsage.credentialsFile],
        dashboard: "https://claude.ai/settings/usage", statusPage: "https://status.claude.com",
        usage: { credential in
            guard let credentials = credential.json(ClaudeUsage.credentialsFile.id) else {
                throw ProviderError.missingCredential("Sign in to Claude Code first.")
            }
            return try await ClaudeUsage.fetch(credentials: credentials)
        })
}

enum ClaudeUsage {
    static let credentialsFile = LiveFile(".claude/.credentials.json", homeEnv: "CLAUDE_CONFIG_DIR", optional: true)
    private static let endpoint = "https://api.anthropic.com/api/oauth/usage"

    // MARK: Fetch

    /// The access token when it is present and not about to expire; nil otherwise.
    static func liveToken(_ credentials: JSON, now: Date = Date()) -> String? {
        let oauth = credentials["claudeAiOauth"]
        guard let token = oauth["accessToken"].string else { return nil }
        if let expiry = oauth["expiresAt"].date, expiry <= now.addingTimeInterval(30) { return nil }
        return token
    }

    /// Read-only: an expired token is reported, never refreshed (Claude Code owns the refresh token).
    static func fetch(credentials: JSON, executable: URL? = nil) async throws -> ProviderUsage {
        guard let token = liveToken(credentials) else {
            throw ProviderError.unauthorized("Open Claude Code to refresh this sign-in.")
        }
        var headers = HTTP.bearer(token)
        headers["anthropic-beta"] = "oauth-2025-04-20"
        headers["User-Agent"] = "claude-cli/\(await cliVersion(executable: executable)) (external, cli)"
        // The flag asks for rate limit resets; older accounts answer 400 or 403 without it.
        var response = try await HTTP.send(endpoint + "?cedar_ember=1", headers: headers)
        if response.status == 400 || response.status == 403 {
            response = try await HTTP.send(endpoint, headers: headers)
        }
        try HTTP.check(response)
        return map(try response.json(), credentials: credentials)
    }

    private final class Cached: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var version: String? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }
    private static let cached = Cached()

    /// `claude --version`, asked once per run; 2.1.0 when it cannot be read.
    static func cliVersion(executable: URL?) async -> String {
        if let known = cached.version { return known }
        let found: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable ?? URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = executable == nil ? ["claude", "--version"] : ["--version"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return continuation.resume(returning: nil) }
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning {
                    process.terminate()
                    return continuation.resume(returning: nil)
                }
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression)
                    .map { String(text[$0]) })
            }
        }
        if let found { cached.version = found }
        return found ?? "2.1.0"
    }

    // MARK: Usage API mapper

    static func map(_ json: JSON, credentials: JSON?, now: Date = Date()) -> ProviderUsage {
        var windows: [UsageWindow] = []
        func add(_ id: String, _ title: String, used: Double?, reset: JSON, minutes: Int) {
            guard let used else { return }
            windows.append(.init(id: id, title: title, usedPercent: used, resetsAt: reset.date, windowMinutes: minutes))
        }
        add("session", "Session", used: json["five_hour"]["utilization"].double,
            reset: json["five_hour"]["resets_at"], minutes: 300)
        add("weekly", "Weekly", used: json["seven_day"]["utilization"].double,
            reset: json["seven_day"]["resets_at"], minutes: 10080)

        var seen = Set<String>()
        for limit in json["limits"].array where limit["kind"].string == "weekly_scoped"
            && (limit["group"].string ?? "weekly") == "weekly" {
            guard let name = limit.at("scope.model.display_name").string,
                  !name.lowercased().contains("all models"), seen.insert(name.lowercased()).inserted else { continue }
            add("weekly-\(slug(name))", "\(name) weekly", used: limit["percent"].double,
                reset: limit["resets_at"], minutes: 10080)
        }
        // Older top-level model limits, when no scoped limit already covers that model.
        for (key, name) in [("seven_day_sonnet", "Sonnet"), ("seven_day_opus", "Opus")]
        where seen.insert(name.lowercased()).inserted {
            add("weekly-\(slug(name))", "\(name) weekly", used: json[key]["utilization"].double,
                reset: json[key]["resets_at"], minutes: 10080)
        }

        var cost: UsageCost?
        let extra = json["extra_usage"]
        if extra["is_enabled"].bool == true {
            // Credits are cents.
            cost = UsageCost(used: extra["used_credits"].double.map { $0 / 100 },
                             limit: extra["monthly_limit"].double.flatMap { $0 > 0 ? $0 / 100 : nil },
                             currency: extra["currency"].string ?? "USD", period: "Monthly")
        }

        var sections: [UsageSection] = []
        let resets = json["cedar_ember"]
        if resets.exists {
            var rows = [UsageRow("Available", "0")]
            if resets["eligible"].bool == true {
                let open = resets["grants"].array.filter { ($0["ends_at"].date ?? .distantFuture) > now }
                    .filter { ($0["resets_left"].double ?? 0) >= 1 }
                let count = open.reduce(0) { $0 + Int($1["resets_left"].double ?? 0) }
                rows = [UsageRow("Available", "\(count)")]
                if let next = open.compactMap({ $0["ends_at"].date }).min() {
                    let day = DateFormatter()
                    day.locale = Locale(identifier: "en_US_POSIX")
                    day.dateFormat = "MMM d"
                    rows.append(UsageRow("Next expires", day.string(from: next)))
                }
            }
            sections = [UsageSection("Rate limit resets", rows)]
        }
        if let enabled = extra["is_enabled"].bool {
            sections.append(UsageSection("Usage credits", [UsageRow("Status", enabled ? "On" : "Off")]))
        }
        return ProviderUsage(windows: windows, cost: cost, sections: sections, plan: plan(credentials))
    }

    /// "Max 20x" from the credentials `subscriptionType` and `rateLimitTier`.
    static func plan(_ credentials: JSON?) -> String? {
        let oauth = (credentials ?? JSON(nil))["claudeAiOauth"]
        return planName(type: oauth["subscriptionType"].string, tier: oauth["rateLimitTier"].string)
    }

    /// "Max 5x" from "max" and a tier such as "default_claude_max_5x".
    static func planName(type: String?, tier: String?) -> String? {
        guard let type, !type.isEmpty else { return nil }
        var plan = type.prefix(1).uppercased() + type.dropFirst()
        if let tier, let multiplier = tier.range(of: #"\d+x"#, options: .regularExpression) {
            plan += " " + tier[multiplier]
        }
        return plan
    }

    private static func slug(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }

    // MARK: `/usage` panel text

    /// Lower-case letters and digits only, so spacing lost to terminal redraws never breaks a match.
    static func squash(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    /// True when the latest `❯` selection marker in a trust prompt points at a "No" option.
    static func trustSelectionIsNo(_ text: String) -> Bool {
        let plain = ClaudeTerminalScreen.render(text)
        guard let marker = plain.range(of: "❯", options: .backwards) else { return false }
        let line = plain[marker.upperBound...].prefix { $0 != "\n" }
        return line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("no")
    }

    /// True once the panel shows both a Current session and a Current week value, or says why it has none.
    static func panelIsComplete(_ text: String) -> Bool { isComplete(rendered: ClaudeTerminalScreen.render(text)) }

    static func isComplete(rendered: String) -> Bool {
        let ids = Set(windows(rendered: rendered, now: Date()).map(\.id))
        if ids.contains("session") && ids.contains("weekly") { return true }
        let flat = squash(rendered)
        return flat.contains("failedtoloadusagedata")
            || (flat.contains("currentlyusingyoursubscription") && flat.contains("claudecodeusage"))
    }

    private struct Label {
        let key: String
        let title: String
        let minutes: Int
        var exact = true
    }

    private static let weekLabel = try! NSRegularExpression(pattern: #"current\s*week\s*\(([^)]+)\)"#,
                                                          options: [.caseInsensitive])

    private static func label(_ line: String) -> Label? {
        let flat = squash(line)
        if flat.hasPrefix("currentsession") { return .init(key: "session", title: "Session", minutes: 300) }
        guard flat.hasPrefix("currentweek") else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        if let match = weekLabel.firstMatch(in: line, range: range), let part = Range(match.range(at: 1), in: line) {
            let model = line[part].trimmingCharacters(in: .whitespaces)
            // "all models", also when a redraw dropped a letter.
            if squash(model).hasPrefix("all") {
                return .init(key: "weekly", title: "Weekly", minutes: 10080, exact: squash(model) == "allmodels")
            }
            let name = model.replacingOccurrences(of: #"(?i)\s+only$"#, with: "", options: .regularExpression)
            return .init(key: "weekly-\(slug(name))", title: "\(name) weekly", minutes: 10080)
        }
        return .init(key: "weekly", title: "Weekly", minutes: 10080)
    }

    /// Percent used on a line: "12% used" is 12, "88% left" is 12.
    private static func percentUsed(_ line: String) -> Double? {
        let lower = line.lowercased()
        // A status line such as "Opus | 0% context" is not a quota row.
        if line.contains("|"), ["opus", "sonnet", "haiku", "default"].contains(where: lower.contains) { return nil }
        guard let range = line.range(of: #"[0-9]{1,3}(?:\.[0-9]+)?\p{Zs}*%"#, options: .regularExpression),
              let value = Double(line[range].dropLast().trimmingCharacters(in: .whitespaces)) else { return nil }
        if ["used", "spent", "consumed"].contains(where: lower.contains) { return min(max(value, 0), 100) }
        if ["left", "remaining", "available"].contains(where: lower.contains) { return min(max(100 - value, 0), 100) }
        return nil
    }

    private static func resetText(_ line: String) -> String? {
        guard let range = line.range(of: #"(?i)\bresets?\b|\bResets?(?=[A-Z0-9])"#, options: .regularExpression)
        else { return nil }
        // The panel wraps the text in its own parentheses: "(Resets 5am (Europe/Vienna))".
        var text = String(line[range.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " )\t"))
        if text.filter({ $0 == "(" }).count > text.filter({ $0 == ")" }).count { text += ")" }
        return text
    }

    /// Parses the text of Claude Code's `/usage` panel (ported from CodexBar's ClaudeStatusProbe).
    static func parseUsageText(_ raw: String, now: Date = Date()) throws -> ProviderUsage {
        try parse(rendered: ClaudeTerminalScreen.render(raw), now: now)
    }

    /// The quota windows on a rendered panel: Session first, then Weekly, then each model row.
    static func windows(rendered: String, now: Date) -> [UsageWindow] {
        let lines = rendered.components(separatedBy: "\n")
        let starts = lines.indices.filter { label(lines[$0]) != nil }
        var order: [String] = []
        var rows: [String: UsageWindow] = [:]
        var exactKeys = Set<String>()
        for (position, start) in starts.enumerated() {
            guard let info = label(lines[start]) else { continue }
            let end = min(position + 1 < starts.count ? starts[position + 1] : lines.count, start + 14)
            var used: Double?
            var reset: String?
            for line in lines[start..<end] {
                if used != nil, line.allSatisfy(\.isWhitespace) { break } // a blank line ends the row
                used = used ?? percentUsed(line)
                reset = reset ?? resetText(line)
            }
            // The panel redraws; the last complete copy of a row wins.
            guard let used else { continue }
            if rows[info.key] == nil { order.append(info.key) }
            if !info.exact, exactKeys.contains(info.key) { continue } // a garbled copy never beats a clean one
            if info.exact { exactKeys.insert(info.key) }
            rows[info.key] = .init(id: info.key, title: info.title, usedPercent: used,
                                   resetsAt: reset.flatMap { resetDate($0, now: now) }, windowMinutes: info.minutes)
        }
        return (["session", "weekly"] + order).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .compactMap { rows[$0] }
    }

    static func parse(rendered: String, now: Date) throws -> ProviderUsage {
        let windows = windows(rendered: rendered, now: now)
        guard !windows.isEmpty else {
            let flat = squash(rendered)
            if flat.contains("failedtoloadusagedata") || flat.contains("loadingusage") {
                throw ProviderError.unavailable("Claude Code could not load usage data.")
            }
            if flat.contains("currentlyusingyoursubscription") {
                throw ProviderError.unsupported("Claude Code shows no usage limits for this account.")
            }
            throw ProviderError.parse("Claude Code did not show a usage panel.")
        }
        // The header names the plan: "Opus 5.5 with xhigh effort · Claude Max".
        let plan = rendered.range(of: #"·\s*Claude (Max|Pro|Team|Enterprise)\b"#, options: .regularExpression)
            .map { String(rendered[$0].split(separator: " ").last ?? "") }
        return ProviderUsage(windows: windows, sections: [usageCredits(rendered: rendered)].compactMap { $0 },
                             plan: plan, fetchedAt: now)
    }

    /// The panel's last block: "Usage credits" and a line such as "Usage credits are off · /usage-credits to turn
    /// them on". Any other text on that line (amounts, limits) is kept as it is shown.
    static func usageCredits(rendered: String) -> UsageSection? {
        let lines = rendered.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let heading = lines.lastIndex(where: { $0.lowercased() == "usage credits" }),
              let line = lines[(heading + 1)...].first(where: { !$0.isEmpty }),
              !line.lowercased().hasPrefix("esc ") else { return nil }
        let parts = line.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("/usage-credits") }
        let off = line.range(of: #"(?i)\b(are|is) off\b|\bdisabled\b"#, options: .regularExpression) != nil
        var rows = [UsageRow("Status", off ? "Off" : "On")]
        // "Usage credits are on" only repeats the state; any other text is detail the panel gave.
        for part in parts where part.range(of: #"(?i)^usage credits (are|is) (on|off)$"#, options: .regularExpression) == nil {
            rows.append(UsageRow(part.contains(where: \.isNumber) ? "Amount" : "Detail", part))
        }
        return UsageSection("Usage credits", rows)
    }

    /// Reset texts such as "Resets 5am (Europe/Vienna)", "Resets Dec 2 at 12am", "Resets 9:30pm".
    static func resetDate(_ raw: String, now: Date = Date()) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (pattern, template) in [(#"(?i)^resets?:?\s*"#, ""), (#"(?i)\bat\b"#, " "),
                                    (#"(?i)\b([A-Za-z]{3})(\d)"#, "$1 $2"), (#",(\d)"#, ", $1"),
                                    (#"(?i)(\d)at(?=\d)"#, "$1 ")] {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        var zone = TimeZone.current
        if let part = text.range(of: #"\([^)]+\)"#, options: .regularExpression) {
            zone = TimeZone(identifier: text[part].trimmingCharacters(in: CharacterSet(charactersIn: "() "))) ?? zone
            text.removeSubrange(part)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        // A leap year default keeps Feb 29 parseable.
        formatter.defaultDate = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))
        func parse(_ prefixes: [String]) -> Date? {
            for prefix in prefixes {
                for time in ["h:mma", "h:mm a", "ha", "h a", "HH:mm"] {
                    formatter.dateFormat = prefix + time
                    if let date = formatter.date(from: text) { return date }
                }
            }
            return nil
        }
        if let date = parse(["MMM d, yyyy, ", "MMM d, yyyy ", "MMM d yyyy "]) { return date }
        // Yearless forms resolve to the next time that matches, allowing a reset that just passed.
        let earliest = now.addingTimeInterval(-12 * 3600)
        if let date = parse(["MMM d, ", "MMM d "]) {
            return calendar.nextDate(after: earliest, matching: calendar.dateComponents(
                [.month, .day, .hour, .minute], from: date), matchingPolicy: .nextTime)
        }
        guard let date = parse([""]) else { return nil }
        return calendar.nextDate(after: now, matching: calendar.dateComponents([.hour, .minute], from: date),
                                 matchingPolicy: .nextTime)
    }
}

// MARK: - Terminal probe

enum ClaudeUsageProbe {
    /// Opens Claude Code in a pseudo terminal for one config dir, types `/usage`, and parses the panel.
    /// Runs without tools, hooks or MCP servers, in a private empty folder, and always kills the child.
    /// An attempt that ends without a Session row is repeated once; the second result is kept as is.
    static func run(configDir: URL, executable: URL, environment: [String: String]? = nil,
                    workingDirectory: URL? = nil, timeout: TimeInterval = 25) async throws -> ProviderUsage {
        var first: ProviderUsage?
        do {
            let usage = try await attempt(configDir: configDir, executable: executable, environment: environment,
                                          workingDirectory: workingDirectory, timeout: timeout)
            if usage.windows.contains(where: { $0.id == "session" }) { return usage }
            first = usage
        } catch let error as ProviderError {
            guard case .unavailable = error else { throw error }
        }
        do {
            return try await attempt(configDir: configDir, executable: executable, environment: environment,
                                     workingDirectory: workingDirectory, timeout: timeout)
        } catch {
            if let first { return first }
            throw error
        }
    }

    private static func attempt(configDir: URL, executable: URL, environment: [String: String]?,
                                workingDirectory: URL?, timeout: TimeInterval) async throws -> ProviderUsage {
#if canImport(Darwin)
        let fileManager = FileManager.default
        let directory = workingDirectory
            ?? fileManager.temporaryDirectory.appending(path: "switch-claude-probe", directoryHint: .isDirectory)
        try CoreSupport.privateDirectory(directory, fileManager: fileManager)
        var env = environment ?? ProcessInfo.processInfo.environment
        for key in ClaudeCodeProfiles.strippedEnvironmentKeys { env.removeValue(forKey: key) }
        env["CLAUDE_CONFIG_DIR"] = configDir.path
        env["TERM"] = "xterm-256color"
        env["NO_COLOR"] = "1"

        var primary: Int32 = -1
        var secondary: Int32 = -1
        var size = winsize(ws_row: UInt16(ClaudeTerminalScreen.defaultRows), ws_col: UInt16(ClaudeTerminalScreen.defaultColumns),
                           ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &size) == 0 else {
            throw ProviderError.unavailable("Claude Code could not be started.")
        }
        _ = fcntl(primary, F_SETFL, O_NONBLOCK)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--allowed-tools", "", "--strict-mcp-config", "--settings",
                             #"{"remoteControlAtStartup":false,"disableAllHooks":true}"#]
        process.environment = env
        process.currentDirectoryURL = directory
        let terminal = FileHandle(fileDescriptor: secondary, closeOnDealloc: false)
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        do { try process.run() } catch {
            close(primary)
            close(secondary)
            throw ProviderError.unavailable("Claude Code could not be started.")
        }
        close(secondary)
        defer {
            if process.isRunning {
                process.terminate()
                let end = Date().addingTimeInterval(1)
                while process.isRunning && Date() < end { usleep(50_000) }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    let last = Date().addingTimeInterval(1)
                    while process.isRunning && Date() < last { usleep(50_000) }
                }
            }
            close(primary)
            removeArtifacts(configDir: configDir, directory: directory)
        }

        func send(_ text: String) { _ = text.withCString { Darwin.write(primary, $0, strlen($0)) } }
        func drain() -> Data {
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 16384)
            while true {
                let count = Darwin.read(primary, &chunk, chunk.count)
                guard count > 0 else { return data }
                data.append(contentsOf: chunk[0..<count])
            }
        }

        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        // Every byte goes through a virtual screen; the panel is read from the rendered rows, never the stream.
        var screen = ClaudeTerminalScreen()
        var text = ""
        var flat = ""
        var received = 0
        var complete = false
        var lastOutput = start
        var lastEnter = start
        var lastTrust = Date.distantPast
        var trustKeys = 0
        var commandSent = false
        var enters = 0
        var completeSince: Date?
        func take(_ chunk: Data) {
            screen.feed(chunk)
            text = screen.text
            flat = ClaudeUsage.squash(text)
            complete = commandSent && ClaudeUsage.isComplete(rendered: text)
        }
        while Date() < deadline {
            try Task.checkCancellation()
            let chunk = drain()
            if !chunk.isEmpty {
                received += chunk.count
                guard received < 8_000_000 else { throw ProviderError.unavailable("Claude Code printed too much.") }
                lastOutput = Date()
                take(chunk)
                // Terminal UIs ask where the cursor is and wait for the answer.
                if chunk.range(of: Data([0x1B, 0x5B, 0x36, 0x6E])) != nil { send("\u{1B}[1;1R") }
            }
            let now = Date()
            // Our private folder is new to Claude Code: accept its trust question. Current versions
            // preselect "No, exit", so move the selection to the Yes option before confirming.
            let asksTrust = ["doyoutrust", "trustthisfolder", "trustthefiles", "quicksafetycheck"].contains(where: flat.contains)
            if asksTrust {
                if trustKeys < 4, now.timeIntervalSince(lastTrust) >= 1, now.timeIntervalSince(lastOutput) >= 0.3 {
                    if ClaudeUsage.trustSelectionIsNo(text) {
                        send("\u{1B}[B")
                    } else {
                        send("\r")
                        // Start fresh so the answered prompt no longer reads as pending.
                        screen = ClaudeTerminalScreen()
                        text = ""
                        flat = ""
                        received = 0
                        lastOutput = now
                    }
                    trustKeys += 1
                    lastTrust = now
                }
            } else if !commandSent,
                      (received > 0 && now.timeIntervalSince(lastOutput) >= 1.5) || now.timeIntervalSince(start) >= 8 {
                // Type the command, then confirm it separately: a burst ending in Return reads as a
                // paste and does not submit.
                send("/usage")
                commandSent = true
                lastEnter = now
            } else if commandSent {
                // One Return after the command settles, then at most two retries while no panel shows.
                let wait: TimeInterval = enters == 0 ? 0.8 : 4
                if enters < 3, now.timeIntervalSince(lastEnter) >= wait,
                   enters == 0 || !(flat.contains("currentsession") || flat.contains("loadingusage")) {
                    send("\r")
                    enters += 1
                    lastEnter = now
                }
                // Stop once both rows show and the screen has been still for a second (model rows
                // arrive last); a panel that keeps changing is cut off after 5 seconds.
                if complete { completeSince = completeSince ?? now } else { completeSince = nil }
                if let completeSince, now.timeIntervalSince(lastOutput) >= 1 || now.timeIntervalSince(completeSince) >= 5 { break }
            }
            if !process.isRunning {
                let rest = drain()
                if !rest.isEmpty { take(rest) }
                break
            }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        guard commandSent else { throw ProviderError.unavailable("Claude Code did not become ready in time.") }
        do {
            return try ClaudeUsage.parse(rendered: text, now: Date())
        } catch {
            if !complete, process.isRunning { throw ProviderError.unavailable("Claude Code did not show usage in time.") }
            throw error
        }
#else
        throw ProviderError.unsupported("The Claude Code usage probe needs macOS.")
#endif
    }

    /// Claude Code stores a probe session under `projects/<folder path with dashes>`; with shared
    /// history that would land in the user's real history, so drop the probe's own folder.
    private static func removeArtifacts(configDir: URL, directory: URL) {
        for path in Set([directory.path, directory.resolvingSymlinksInPath().path]) {
            let name = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            try? FileManager.default.removeItem(at: configDir.appending(path: "projects/\(name)"))
        }
    }
}
