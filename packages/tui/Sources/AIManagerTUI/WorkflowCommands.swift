import Foundation
import AIManagerCore

enum WorkflowCommands {
    static func run(_ input: CommandLineInput, manager: AccountManager) async throws {
        switch input.command {
        case "conversations": try await conversations(input)
        case "missions": try await missions(input, manager: manager)
        case "claude-shell":
            try validate(input, flags: ["--yes", "--json"], arguments: 0...1)
            let action = input.positional.first ?? "status"
            guard ["status", "enable", "disable"].contains(action) else {
                throw CLIError.message("Choose claude-shell status, enable, or disable.")
            }
            if action != "status" {
                try AIManagerCLI.confirm(input, "\(action.capitalized) the Claude shell integration in your shell startup files?")
                try await manager.setClaudeShellIntegration(action == "enable")
            }
            let enabled = await manager.claudeShellIntegrationInstalled()
            if input.json { await AIManagerCLI.output(["enabled": enabled], json: true) }
            else { print("Claude shell integration: \(enabled ? "enabled" : "disabled")") }
        case "droid-usage-key": try await droidUsageKey(input, manager: manager)
        case "auto-switch": try await autoSwitch(input, manager: manager)
        default: throw CLIError.message("Unknown workflow command.")
        }
    }

    private static func conversations(_ input: CommandLineInput) async throws {
        try validate(input, flags: ["--json"], options: ["--query", "--limit", "--offset", "--role"], arguments: 0...2)
        let action = input.positional.first ?? "list"
        guard ["list", "show", "export"].contains(action) else {
            throw CLIError.message("Choose conversations list, show, or export.")
        }
        guard action == "list" ? input.positional.count <= 1 : input.positional.count == 2 else {
            throw CLIError.message("List takes no conversation ID; show and export each need one ID.")
        }
        if action == "list", input.values.contains("--offset") || input.values.contains("--role") {
            throw CLIError.message("--offset and --role apply to conversation messages. Use conversations show.")
        }
        let limit = try integer(input, "--limit", fallback: 100, range: 1...(action == "show" ? 200 : 1_000))
        let offset = try integer(input, "--offset", fallback: 0, range: 0...Int.max)
        let roles: [String: ChatMessageFilter] = ["all": .all, "prompts": .prompts,
            "responses": .responses, "tools": .tools, "other": .other]
        guard let filter = roles[input.option("--role") ?? "all"] else {
            throw CLIError.message("Role must be all, prompts, responses, tools, or other.")
        }
        let index = ChatHistoryIndex(home: input.paths.sharedRoot,
            cacheFile: input.paths.applicationSupport.appending(path: "cache/chat-history-v1.json"))
        let snapshot = try await index.refresh(query: action == "list" ? input.option("--query") ?? "" : "", limit: limit)
        if action == "list" {
            guard input.positional.count <= 1 else { throw CLIError.message("conversations list takes no thread ID.") }
            if input.json {
                await AIManagerCLI.output(ThreadList(threads: snapshot.threads.map(Thread.init),
                    total: snapshot.totalThreadCount, matching: snapshot.matchingThreadCount,
                    skippedFiles: snapshot.skippedFileCount, unreadableRecords: snapshot.unreadableRecordCount), json: true)
            } else {
                for thread in snapshot.threads {
                    print("\(thread.id)\t\(thread.updatedAt.ISO8601Format())\t\(thread.title)")
                }
                print("\(snapshot.matchingThreadCount) matching conversations; \(snapshot.skippedFileCount) skipped files.")
            }
            return
        }
        guard input.positional.count == 2 else { throw CLIError.message("A conversation ID from conversations list is required.") }
        let id = input.positional[1]
        if action == "show" {
            guard let detail = try await index.detail(for: id, offset: offset, limit: min(limit, 200),
                query: input.option("--query") ?? "", filter: filter) else {
                throw CLIError.message("Conversation not found. Run conversations list.")
            }
            if input.json {
                await AIManagerCLI.output(ThreadDetail(thread: Thread(detail.thread), messages: detail.messages.map(Message.init),
                    matching: detail.matchingMessageCount, nextOffset: detail.nextOffset), json: true)
            } else {
                print(ChatTranscriptExport.text(for: detail.messages))
                if let next = detail.nextOffset { print("More messages: use --offset \(next).") }
            }
        } else {
            guard !input.json, !input.values.contains("--offset"), !input.values.contains("--limit") else {
                throw CLIError.message("conversations export writes the full text to stdout; use show for JSON or pages.")
            }
            var next = 0
            repeat {
                guard let detail = try await index.detail(for: id, offset: next, limit: 200,
                    query: input.option("--query") ?? "", filter: filter) else {
                    throw CLIError.message("Conversation not found. Run conversations list.")
                }
                print(ChatTranscriptExport.text(for: detail.messages))
                guard let offset = detail.nextOffset else { break }
                next = offset
            } while true
        }
    }

    private static func missions(_ input: CommandLineInput, manager: AccountManager) async throws {
        try validate(input, flags: ["--yes", "--json"], options: ["--account"], arguments: 0...2)
        let action = input.positional.first ?? "list"
        guard ["list", "owner", "plan", "resume", "start"].contains(action) else {
            throw CLIError.message("Choose missions list, owner, plan, resume, or start.")
        }
        guard !input.values.contains("--account") || action == "owner" else {
            throw CLIError.message("--account is supported only by missions owner.")
        }
        let missions = try await manager.droidMissions()
        if action == "list" {
            guard input.positional.count <= 1 else { throw CLIError.message("missions list takes no mission ID.") }
            if input.json { await AIManagerCLI.output(missions.map(Mission.init), json: true) }
            else {
                for mission in missions {
                    print("\(mission.id)\t\(mission.completed)/\(mission.total) done\t\(mission.owner?.uuidString ?? "unknown owner")\t\(mission.title)")
                }
            }
            return
        }
        guard input.positional.count == 2, let mission = missions.first(where: { $0.id == input.positional[1] }) else {
            throw CLIError.message("A known mission ID from missions list is required.")
        }
        if action == "owner" {
            guard let id = try input.optionalAccountID("--account") else { throw CLIError.message("--account <Droid account UUID> is required.") }
            try AIManagerCLI.confirm(input, "Record the selected Droid account as this mission's owner?")
            try await manager.setDroidMissionOwner(folder: mission.id, accountID: id)
            if input.json { await AIManagerCLI.output(["owner": id.uuidString], json: true) }
            else { print("Mission owner saved: \(id.uuidString)") }
            return
        }
        if action == "plan" {
            try AIManagerCLI.confirm(input, "Write a continuation plan without changing the original mission?")
            let plan = try await manager.writeDroidMissionPlan(folder: mission.id)
            if input.json { await AIManagerCLI.output(["path": plan.path], json: true) }
            else { print(plan.path) }
            return
        }
        guard !input.json else { throw CLIError.message("Mission resume and start run Droid in this terminal; omit --json.") }
        let status = try await manager.status()
        guard let accountID = action == "resume" ? mission.owner : status.defaultAccountID(for: .droid) else {
            throw CLIError.message(action == "resume" ? "Set this mission's owner before resuming it." : "Choose a default Droid account first.")
        }
        var isDirectory: ObjCBool = false
        guard !mission.workingDirectory.isEmpty,
              FileManager.default.fileExists(atPath: mission.workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError.message("The mission working folder is missing.")
        }
        if let root = input.paths.isolationRoot {
            let directory = URL(fileURLWithPath: mission.workingDirectory).resolvingSymlinksInPath().pathComponents
            let allowed = root.resolvingSymlinksInPath().pathComponents
            guard directory.starts(with: allowed) else { throw CLIError.message("The mission working folder is outside the isolated home.") }
        }
        try AIManagerCLI.confirm(input, action == "resume"
            ? "Resume this mission on its saved owner account?"
            : "Start a new mission from the remaining features? This can use your provider allowance.")
        if status.defaultAccountID(for: .droid) != accountID {
            let result = try await AIManagerCLI.switchAccount(accountID, input: input, manager: manager)
            await AIManagerCLI.output(result, json: false)
        }
        let arguments: [String]
        if action == "resume" { arguments = ["--resume", mission.id] }
        else {
            let plan = try await manager.writeDroidMissionPlan(folder: mission.id)
            arguments = ["exec", "--mission", "-f", plan.path, "--auto", "high"]
        }
        let spec = try await manager.launchSpec(accountID: accountID, arguments: arguments,
            workingDirectory: URL(fileURLWithPath: mission.workingDirectory, isDirectory: true))
        let code = try await manager.run(spec)
        if code != 0 { throw CLIError.exit(code, "Droid exited with status \(code).") }
    }

    private static func droidUsageKey(_ input: CommandLineInput, manager: AccountManager) async throws {
        try validate(input, flags: ["--json", "--yes", "--stdin", "--remove"], arguments: 1...1)
        let id = try input.requiredAccountID()
        let status = try await manager.status()
        guard status.accounts.contains(where: { $0.id == id && $0.identity.providerID == .droid }) else { throw AIManagerError.accountNotFound }
        guard !(input.values.contains("--stdin") && input.values.contains("--remove")) else {
            throw CLIError.message("Choose --stdin or --remove, not both.")
        }
        if input.values.contains("--stdin") || input.values.contains("--remove") {
            try AIManagerCLI.confirm(input, "Update this Droid account's optional usage API key?")
            var key = ""
            if input.values.contains("--stdin") {
                var data = Data()
                while let chunk = try FileHandle.standardInput.read(upToCount: min(4_096, 16_385 - data.count)), !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= 16_384 else {
                        throw CLIError.message("Standard input must contain an API key of at most 16 KB.")
                    }
                }
                guard let value = String(data: data, encoding: .utf8),
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError.message("Standard input must contain a nonempty UTF-8 API key of at most 16 KB.")
                }
                key = value
            }
            try await manager.setDroidUsageAPIKey(accountID: id, apiKey: key)
        }
        let saved = await manager.hasDroidUsageAPIKey(accountID: id)
        if input.json { await AIManagerCLI.output(["saved": saved], json: true) }
        else { print("Droid usage API key: \(saved ? "saved" : "not saved")") }
    }

    private static func autoSwitch(_ input: CommandLineInput, manager: AccountManager) async throws {
        try validate(input, flags: ["--json", "--yes"], options: ["--provider", "--min-remaining"], arguments: 0...0)
        guard let value = input.option("--provider"),
              let provider = AccountManager.providerCatalog.first(where: { $0.id.rawValue == value })?.id else {
            throw CLIError.message("--provider <id> is required. Run providers for IDs.")
        }
        guard let threshold = Double(input.option("--min-remaining") ?? "1"), threshold.isFinite, (0...100).contains(threshold) else {
            throw CLIError.message("--min-remaining must be a number from 0 to 100.")
        }
        let status = try await manager.status()
        guard let current = status.defaultAccountID(for: provider) else { throw CLIError.message("This provider has no default account.") }
        let accounts = status.accounts.filter { $0.identity.providerID == provider }
        let cache = try? CodexUsageStatisticsCache(
            databaseURL: input.paths.applicationSupport.appending(path: "cache/account-usage.sqlite"),
            activityDatabaseURL: input.paths.applicationSupport.appending(path: "activity/daily.sqlite"))
        var candidates: [AutoSwitch.Candidate] = []
        var failures: [String: String] = [:]
        for account in accounts {
            do {
                let usage = try await LimitsCommands.withTimeout(60) {
                    try await LimitsCommands.fetchUsage(account, manager: manager, cache: cache, force: true)
                }
                candidates.append(.init(id: account.id, leftPercent: AutoSwitch.leftPercent(of: usage.windows)))
            } catch {
                candidates.append(.init(id: account.id, leftPercent: nil))
                failures[account.id.uuidString] = LimitFormat.message(error)
            }
        }
        guard candidates.first(where: { $0.id == current })?.leftPercent != nil else {
            throw CLIError.message("The default account's remaining usage is unknown. No account was switched.")
        }
        let decision: String
        var switched: SwitchResult?
        switch AutoSwitch.decide(order: candidates, defaultID: current, threshold: threshold) {
        case .stay: decision = "stay"
        case .noneLeft: decision = "none-left"
        case .switchTo(let id):
            switched = try await AIManagerCLI.switchAccount(id, input: input, manager: manager)
            decision = "switched"
        }
        if input.json { await AIManagerCLI.output(AutoResult(decision: decision, result: switched, failures: failures), json: true) }
        else {
            print("Auto switch: \(decision)")
            if let switched { await AIManagerCLI.output(switched, json: false) }
            for (id, reason) in failures.sorted(by: { $0.key < $1.key }) { print("Usage unavailable for \(id): \(reason)") }
        }
        if decision == "none-left" { throw CLIError.exit(1, "No saved account has enough known usage remaining.") }
    }

    private static func integer(_ input: CommandLineInput, _ name: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = input.option(name) else { return fallback }
        guard let number = Int(value), range.contains(number) else { throw CLIError.message("\(name) must be between \(range.lowerBound) and \(range.upperBound).") }
        return number
    }

    static func validate(_ input: CommandLineInput, flags: Set<String>, options: Set<String> = [], arguments: ClosedRange<Int>) throws {
        var index = 0
        var seenOptions: Set<String> = []
        while index < input.values.count {
            let value = input.values[index]
            if options.contains(value) {
                guard seenOptions.insert(value).inserted else { throw CLIError.message("Pass \(value) only once.") }
                index += 1
                guard index < input.values.count, !input.values[index].hasPrefix("--") else { throw CLIError.message("\(value) needs a value.") }
            } else if value.hasPrefix("-"), !flags.contains(value) {
                throw CLIError.message("Unknown option '\(value)'. Run help.")
            }
            index += 1
        }
        guard arguments.contains(input.positional.count) else { throw CLIError.message("Unexpected arguments. Run help for this command's syntax.") }
    }

    private struct Thread: Encodable {
        let id: String, title: String, preview: String, source: String
        let updatedAt: Date
        let messages: Int
        init(_ value: ChatThreadSummary) {
            id = value.id; title = value.title; preview = value.preview
            source = value.appSource.rawValue; updatedAt = value.updatedAt; messages = value.messageCount
        }
    }
    private struct ThreadList: Encodable {
        let threads: [Thread]
        let total: Int, matching: Int, skippedFiles: Int, unreadableRecords: Int
    }
    private struct Message: Encodable {
        let id: String, role: String, text: String
        let timestamp: Date?
        let model: String?
        init(_ value: ChatMessage) {
            id = value.id; role = value.role.rawValue; text = value.text; timestamp = value.timestamp; model = value.model
        }
    }
    private struct ThreadDetail: Encodable {
        let thread: Thread
        let messages: [Message]
        let matching: Int
        let nextOffset: Int?
    }
    private struct Mission: Encodable {
        let id: String, title: String, state: String, workingDirectory: String
        let completed: Int, total: Int, left: Int
        let owner: UUID?
        init(_ value: DroidMission) {
            id = value.id; title = value.title; state = value.state; workingDirectory = value.workingDirectory
            completed = value.completed; total = value.total; left = value.left; owner = value.owner
        }
    }
    private struct AutoResult: Encodable {
        let decision: String
        let result: SwitchResult?
        let failures: [String: String]
    }
}
