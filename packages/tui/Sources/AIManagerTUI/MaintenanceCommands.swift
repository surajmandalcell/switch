import Foundation
import AIManagerCore

enum MaintenanceCommands {
    static func run(_ input: CommandLineInput, manager: AccountManager) async throws {
        let arguments = try validate(input)
        if input.command == "backup" {
            try await backup(input, arguments: arguments, manager: manager)
        } else {
            try await cleanup(input, arguments: arguments, manager: manager)
        }
    }

    private static func validate(_ input: CommandLineInput) throws -> [String] {
        let valueOptions: Set<String> = ["--item", "--destination", "--schedule", "--keep", "--older-than", "--sample"]
        let flags: Set<String> = ["--json", "--yes", "--include-logins", "--exclude-logins", "--prompts-only", "--full-content"]
        var arguments: [String] = [], options: [String] = []
        var index = 0
        while index < input.values.count {
            let value = input.values[index]
            if valueOptions.contains(value) {
                guard input.values.indices.contains(index + 1), !input.values[index + 1].isEmpty,
                      !input.values[index + 1].hasPrefix("-") else { throw CLIError.message("Enter a value after \(value).") }
                options.append(value); index += 2
            } else if flags.contains(value) {
                options.append(value); index += 1
            } else if value.hasPrefix("-") {
                throw CLIError.message("Unknown maintenance option '\(value)'.")
            } else {
                arguments.append(value); index += 1
            }
        }
        if arguments.isEmpty { arguments = [input.command == "backup" ? "list" : "sources"] }
        let action = arguments[0]
        var allowed: Set<String> = ["--json"]
        var count = 1
        if input.command == "backup" {
            switch action {
            case "list": break
            case "configure": count = 2; allowed.formUnion(["--yes", "--destination", "--schedule", "--keep", "--include-logins", "--exclude-logins", "--prompts-only", "--full-content"])
            case "retire", "run": count = 2; allowed.insert("--yes")
            case "history": count = 2
            case "restore": count = 3; allowed.formUnion(["--yes", "--destination", "--item", "--include-logins"])
            default: throw CLIError.message("Unknown backup action. Use list, configure, retire, run, history, or restore.")
            }
        } else {
            switch action {
            case "sources": break
            case "samples": allowed.insert("--older-than")
            case "clear-index": allowed.insert("--yes")
            case "remove-samples": allowed.formUnion(["--yes", "--sample"])
            case "scan", "trash-list": count = 2
            case "review": count = 2; allowed.insert("--item")
            case "trash": count = 2; allowed.formUnion(["--yes", "--item"])
            case "restore", "purge": count = 3; allowed.insert("--yes")
            default: throw CLIError.message("Unknown cleanup action. Run ai-manager help.")
            }
        }
        guard arguments.count == count else { throw CLIError.message("Incorrect number of arguments for \(input.command) \(action). Run ai-manager help.") }
        guard options.allSatisfy(allowed.contains) else { throw CLIError.message("An option does not apply to \(input.command) \(action).") }
        for option in Set(options) where option != "--item" && option != "--sample" {
            guard options.filter({ $0 == option }).count == 1 else { throw CLIError.message("Pass \(option) only once.") }
        }
        guard !(options.contains("--include-logins") && options.contains("--exclude-logins")),
              !(options.contains("--prompts-only") && options.contains("--full-content")) else {
            throw CLIError.message("Choose one login setting and one backup mode.")
        }
        return arguments
    }

    private static func report<T: Encodable>(_ value: T, input: CommandLineInput, lines: [String]) async {
        if input.json { await AIManagerCLI.output(value, json: true) }
        else { print(lines.isEmpty ? "No items." : lines.joined(separator: "\n")) }
    }

    private static func cache(_ input: CommandLineInput) throws -> CodexUsageStatisticsCache {
        try CodexUsageStatisticsCache(databaseURL: input.paths.applicationSupport.appending(path: "cache/account-usage.sqlite"),
            activityDatabaseURL: input.paths.applicationSupport.appending(path: "activity/daily.sqlite"))
    }

    private struct Source: Encodable {
        let id: String
        let title: String
        let detail: String
        let home: URL
        init(_ source: CleanupSource) {
            id = source.id; title = source.title; detail = source.detail; home = source.home
        }
    }

    private struct Item: Encodable {
        let id: String
        let item: CleanupItem
        init(_ item: CleanupItem) { id = item.id; self.item = item }
    }

    private struct Category: Encodable {
        let id: String
        let title: String
        let risk: String
        let items: [Item]
        init(_ category: CleanupCategory) {
            id = category.id; title = category.title; risk = category.risk.rawValue
            items = category.items.map(Item.init)
        }
    }

    private struct Scan: Encodable {
        let source: String
        let bytes: Int64
        let categories: [Category]
        init(_ scan: CleanupScan) {
            source = scan.sourceID; bytes = scan.totalBytes; categories = scan.categories.map(Category.init)
        }
    }

    private struct Reviewed: Encodable {
        let count: Int
        let bytes: Int64
        let items: [Item]
        init(_ plan: ConversationCleanupPlan) {
            count = plan.items.count; bytes = plan.bytes; items = plan.items.map(Item.init)
        }
    }

    private struct Snapshot: Encodable {
        let id: String
        let folder: URL
        let manifest: BackupManifest
        init(_ snapshot: BackupSnapshot) {
            id = snapshot.id; folder = snapshot.folder; manifest = snapshot.manifest
        }
    }

    private struct Restored: Encodable {
        let restored: Int
        let extraFiles: [String]
        let safetySnapshot: Snapshot?
        init(_ result: BackupRestoreResult) {
            restored = result.restored; extraFiles = result.extraFiles
            safetySnapshot = result.safetySnapshot.map(Snapshot.init)
        }
    }

    private struct Sample: Encodable {
        let id: Int64
        let account: UUID
        let date: Date
        let bytes: Int64
        init(_ sample: CleanupUsageSample) {
            id = sample.id; account = sample.accountID; date = sample.fetchedAt; bytes = sample.bytes
        }
    }

    private static func sources(_ input: CommandLineInput, manager: AccountManager) async throws -> [CleanupSource] {
        let status = try await manager.status()
        return CleanupSources.make(paths: input.paths, accounts: status.accounts).filter { !$0.isClaudeProfile }
    }

    private static func source(_ id: String?, input: CommandLineInput, manager: AccountManager) async throws -> CleanupSource {
        guard let id, let source = try await sources(input, manager: manager).first(where: { $0.id == id }) else {
            throw CLIError.message("Unknown source. Run ai-manager cleanup sources.")
        }
        return source
    }

    private static func cleanup(_ input: CommandLineInput, arguments: [String], manager: AccountManager) async throws {
        let action = arguments.first ?? "sources"
        if action == "sources" {
            let sources = try await Self.sources(input, manager: manager)
            await report(sources.map(Source.init), input: input, lines: sources.map { "\($0.id)\t\($0.title)\t\($0.detail)\t\($0.home.path)" })
            return
        }
        if action == "samples" || action == "remove-samples" {
            let cache = try Self.cache(input)
            var samples = try await cache.cleanupSamples()
            if let value = input.option("--older-than") {
                guard let date = ISO8601DateFormatter().date(from: value) else { throw CLIError.message("Enter --older-than as an ISO8601 date and time.") }
                samples = samples.filter { $0.fetchedAt < date }
            }
            if action == "remove-samples" {
                let ids = input.optionValues("--sample")
                guard !ids.isEmpty, ids.count == Set(ids).count else { throw CLIError.message("Select unique --sample IDs from cleanup samples.") }
                let chosen = ids.compactMap { id in samples.first { String($0.id) == id } }
                guard chosen.count == ids.count else { throw AIManagerError.sourceChanged }
                try AIManagerCLI.confirm(input, "Remove \(chosen.count) cached usage samples? Activity totals stay.")
                try await cache.removeCleanupSamples(chosen)
                await report(["removed": chosen.count], input: input, lines: ["Removed \(chosen.count) cached usage samples. Activity totals stay."])
            } else {
                await report(samples.map(Sample.init), input: input, lines: samples.map { "\($0.id)\t\($0.accountID.uuidString)\t\($0.fetchedAt.ISO8601Format())\t\($0.bytes) bytes" })
            }
            return
        }
        if action == "clear-index" {
            try AIManagerCLI.confirm(input, "Clear the conversation index cache? Chats and activity totals stay.")
            try await ChatHistoryIndex(home: input.paths.sharedRoot,
                cacheFile: input.paths.applicationSupport.appending(path: "cache/chat-history-v1.json")).clearCache()
            await report(["cleared": "conversation-index"], input: input, lines: ["Conversation index cache cleared. Chats and activity totals stay."])
            return
        }
        let source = try await Self.source(arguments.dropFirst().first, input: input, manager: manager)
        switch action {
        case "scan":
            let scan = try AccountManager.scanCleanup(source)
            let lines = ["\(source.title): \(scan.totalBytes) bytes"] + scan.categories.flatMap { category in
                ["\(category.title) (\(category.risk.rawValue))"] + category.items.map {
                    "\($0.id)\t\($0.bytes) bytes\t\($0.updatedAt.ISO8601Format())\t\($0.title)\t\($0.protectedReason ?? "Available")"
                }
            }
            await report(Scan(scan), input: input, lines: lines)
        case "review", "trash":
            let ids = input.optionValues("--item")
            guard !ids.isEmpty, ids.count == Set(ids).count else {
                throw CLIError.message("Select unique --item IDs from cleanup scan. No files were changed.")
            }
            let available = try AccountManager.scanCleanup(source).categories.flatMap(\.items)
            let items = ids.compactMap { id in available.first { $0.id == id } }
            guard items.count == ids.count else { throw AIManagerError.sourceChanged }
            let plan = try await manager.reviewCleanup(source, items)
            if action == "review" {
                await report(Reviewed(plan), input: input, lines: ["Reviewed \(plan.items.count) items, \(plan.bytes) bytes."] + plan.items.map { $0.id + "\t" + $0.title })
                return
            }
            try AIManagerCLI.confirm(input, "Move \(plan.items.count) items (\(plan.bytes) bytes) into recoverable trash? This frees no space until purge.")
            let index = ChatHistoryIndex(home: input.paths.sharedRoot,
                cacheFile: input.paths.applicationSupport.appending(path: "cache/chat-history-v1.json"))
            let cache = try Self.cache(input)
            await index.attachActivityCache(cache)
            let batch = try await manager.moveToCleanupTrash(source, plan) { urls in
                try await index.preserveActivity(for: urls)
            }
            await report(batch, input: input, lines: ["Trash batch: \(batch.id.uuidString)", "Moved \(batch.items.count) items, \(batch.bytes) bytes. No space is freed until purge."])
        case "trash-list":
            let batches = try await manager.cleanupTrash(source)
            await report(batches, input: input, lines: batches.map { "\($0.id.uuidString)\t\($0.createdAt.ISO8601Format())\t\($0.items.count) items\t\($0.bytes) bytes" })
        case "restore", "purge":
            guard arguments.count == 3, let id = UUID(uuidString: arguments[2]) else {
                throw CLIError.message("Enter a batch UUID from cleanup trash-list.")
            }
            guard try await manager.cleanupTrash(source).contains(where: { $0.id == id }) else {
                throw CLIError.message("That trash batch does not exist for this source.")
            }
            if action == "restore" {
                try AIManagerCLI.confirm(input, "Restore trash batch \(id.uuidString)? Existing changed files stay protected.")
                try await manager.restoreCleanupTrash(source, id)
            } else {
                try AIManagerCLI.confirm(input, "Permanently delete trash batch \(id.uuidString)? This cannot be undone.")
                try await manager.permanentlyRemoveCleanupTrash(source, id)
            }
            await report(["batch": id.uuidString, "action": action], input: input, lines: ["\(action == "restore" ? "Restored" : "Permanently removed") trash batch \(id.uuidString)."])
        default:
            throw CLIError.message("Unknown cleanup action. Use sources, scan, review, trash, trash-list, restore, or purge.")
        }
    }

    private static func backup(_ input: CommandLineInput, arguments: [String], manager: AccountManager) async throws {
        let action = arguments.first ?? "list"
        let engine = BackupEngine(applicationSupport: input.paths.applicationSupport)
        var sets = try await engine.sets()
        switch action {
        case "list":
            await report(sets, input: input, lines: setLines(sets))
        case "configure":
            let source = try await Self.source(arguments.dropFirst().first, input: input, manager: manager)
            guard source.backupService != nil else { throw CLIError.message("This source does not support backups.") }
            guard let path = input.option("--destination"), !path.isEmpty else {
                throw CLIError.message("Enter --destination with an existing backup folder.")
            }
            let destination = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
            let scheduleValue = input.option("--schedule") ?? sets.first(where: { !$0.retired })?.schedule.rawValue ?? "off"
            guard let schedule = BackupSchedule(rawValue: scheduleValue) else {
                throw CLIError.message("Schedule must be off, daily, or weekly.")
            }
            let keepValue = input.option("--keep") ?? String(sets.first(where: { !$0.retired })?.keep ?? 10)
            guard let keep = Int(keepValue), keep > 0 else { throw CLIError.message("Retention must be a positive integer.") }
            let active = sets.filter { !$0.retired }
            let includeLogins = input.values.contains("--include-logins") ? true
                : input.values.contains("--exclude-logins") ? false : !active.isEmpty && active.allSatisfy(\.includeLogins)
            let promptsOnly = input.values.contains("--prompts-only") ? true
                : input.values.contains("--full-content") ? false : !active.isEmpty && active.allSatisfy(\.promptsOnly)
            let shared = SharedBackupSettings(schedule: schedule, keep: keep, includeLogins: includeLogins, promptsOnly: promptsOnly)
            sets = BackupChecklist.move(sets, to: destination)
            sets = BackupChecklist.share(shared, to: BackupChecklist.check(sets, source: source, destination: destination, shared: shared))
            try AIManagerCLI.confirm(input, "Save the backup checklist and shared folder, schedule, and retention? Existing snapshots stay available.")
            try await engine.saveSets(sets)
            await report(sets, input: input, lines: setLines(sets))
        case "retire":
            guard let id = arguments.dropFirst().first, sets.contains(where: { $0.toolKey == id && !$0.retired }) else {
                throw CLIError.message("Enter an active source ID from backup list.")
            }
            try AIManagerCLI.confirm(input, "Stop backups for \(id)? Existing snapshots stay available.")
            sets = BackupChecklist.retire(sets, tool: id)
            try await engine.saveSets(sets)
            await report(sets, input: input, lines: setLines(sets))
        case "run", "history", "restore":
            guard arguments.count >= 2, let id = UUID(uuidString: arguments[1]), let saved = sets.first(where: { $0.id == id }) else {
                throw CLIError.message("Enter a set UUID from backup list.")
            }
            var set = saved
            if action == "run" {
                guard !set.retired else { throw CLIError.message("This backup set is retired. Configure its source to enable backups.") }
                if let source = try await sources(input, manager: manager).first(where: { $0.id == set.source.id }) {
                    set = BackupChecklist.withProfiles(set, homes: source.extraHomes)
                }
                try AIManagerCLI.confirm(input, "Create a backup and prune only Switch snapshots beyond retention \(set.keep)?")
                let snapshot = try await engine.snapshot(set)
                await report(Snapshot(snapshot), input: input, lines: snapshotLines(snapshot))
                return
            }
            let status = try await engine.status(for: set)
            if case .waiting(let volume) = status.state { throw BackupError.waiting(volume) }
            if action == "history" {
                await report(status.snapshots.map(Snapshot.init), input: input, lines: status.snapshots.flatMap(snapshotLines))
                return
            }
            guard arguments.count == 3, let snapshot = status.snapshots.first(where: { $0.id == arguments[2] }) else {
                throw CLIError.message("Enter a snapshot ID from backup history.")
            }
            let destination = input.option("--destination").map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
            let items = input.optionValues("--item")
            let selected = snapshot.manifest.entries.filter { entry in
                items.isEmpty || items.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
            }
            guard !selected.isEmpty, items.allSatisfy({ path in selected.contains { $0.path == path || $0.path.hasPrefix(path + "/") } }) else {
                throw CLIError.message("Select paths listed in the snapshot manifest.")
            }
            if selected.contains(where: { BackupPresets.isLogin($0.path) }), !input.values.contains("--include-logins") {
                throw CLIError.message("This selection includes login files. Review it and pass --include-logins to restore them.")
            }
            set.includeLogins = input.values.contains("--include-logins")
            try AIManagerCLI.confirm(input, "Restore \(selected.count) files to \(destination?.path ?? set.source.home.path)? In-place restore first saves a safety snapshot.")
            let result = try await manager.restoreBackup(snapshot, set: set, items: items.isEmpty ? nil : items, to: destination)
            var lines = ["Restored \(result.restored) files. \(result.extraFiles.count) extra files stayed."]
            if let safety = result.safetySnapshot { lines.append("Safety snapshot: \(safety.id) at \(safety.folder.path)") }
            await report(Restored(result), input: input, lines: lines)
        default:
            throw CLIError.message("Unknown backup action. Use list, configure, retire, run, history, or restore.")
        }
    }

    private static func setLines(_ sets: [BackupSet]) -> [String] {
        sets.map { "\($0.id.uuidString)\t\($0.source.id)\t\($0.retired ? "Retired" : "Active")\t\($0.schedule.rawValue)\tKeep \($0.keep)\t\($0.promptsOnly ? "Prompts" : "Full")\t\($0.destination.path)" }
    }

    private static func snapshotLines(_ snapshot: BackupSnapshot) -> [String] {
        ["\(snapshot.id)\t\(snapshot.date.ISO8601Format())\t\(snapshot.files) files\t\(snapshot.totalBytes) bytes\t\(snapshot.state)", "Folder: \(snapshot.folder.path)"]
    }

}
