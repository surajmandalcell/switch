import Foundation
import AIManagerCore

/// The Backup checklist as a client shows it (Mac `MaintenanceStore`): one row per tool and the shared settings.
public struct BackupChecklistValue: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var sourceID: String
        public var title: String
        public var checked: Bool
        /// The checked set; nil when the tool is unchecked.
        public var setID: String?
        public var bytes: Int64
        public var lastBackup: Date?
    }

    public struct Shared: Codable, Equatable, Sendable {
        public var schedule: BackupSchedule
        public var keep: Int
        public var includeLogins: Bool
        public var promptsOnly: Bool
    }

    public var rows: [Row]
    /// The folder the checked tools share.
    public var folder: String?
    /// Nil until a tool is checked.
    public var shared: Shared?
}

/// Progress of `runBackups`: the set being copied, its place in the run, and what it copied so far.
public struct BackupRunProgress: Codable, Equatable, Sendable {
    public var setID: String
    public var index: Int
    public var count: Int
    public var files: Int
    public var bytes: Int64
}

/// Backups (architecture.md 2.9). They run outside the action lane, as on the Mac, where a backup never blocks a
/// switch; the core's backup lock keeps two copies apart.
extension AppEngine {
    public func backupChecklist() async throws -> BackupChecklistValue {
        let backups = BackupEngine(applicationSupport: paths.applicationSupport)
        let sets = try await backups.sets()
        var newest: [String: Date] = [:]
        for set in sets {
            guard let snapshots = try? await backups.status(for: set).snapshots else { continue }
            let date = snapshots.filter { !$0.manifest.safety }.map(\.date).max()
            if let date, date > newest[set.toolKey] ?? .distantPast { newest[set.toolKey] = date }
        }
        let rows = try await checklistSources().map { source in
            let set = sets.first { $0.source.id == source.id && !$0.retired }
            return BackupChecklistValue.Row(sourceID: source.id, title: source.title, checked: set != nil,
                                            setID: set.map { $0.id.uuidString.lowercased() },
                                            bytes: BackupChecklist.size(of: source), lastBackup: newest[source.id])
        }
        let checked = sets.filter { !$0.retired }
        let shared = checked.first.map {
            BackupChecklistValue.Shared(schedule: $0.schedule, keep: $0.keep,
                                        includeLogins: checked.allSatisfy(\.includeLogins),
                                        promptsOnly: checked.allSatisfy(\.promptsOnly))
        }
        return BackupChecklistValue(rows: rows, folder: checked.first?.destination.path, shared: shared)
    }

    /// The Mac `backUpNow`: the given sets (all checked sets when nil) one after another. A cancelled run stops
    /// after the set it was copying; a failed set goes to `notices.error` and the run goes on.
    public func runBackups(_ ids: [UUID]?, progress: (@Sendable (BackupRunProgress) -> Void)? = nil) async throws
        -> ActionResult {
        let backups = BackupEngine(applicationSupport: paths.applicationSupport)
        let sets = try await backups.sets()
        let chosen = try ids.map { ids in
            try ids.map { id in
                guard let set = sets.first(where: { $0.id == id }) else { throw AppEngineError.notFound("No backup set has that ID.") }
                guard !set.retired else {
                    throw AIManagerError.invalidSource("This backup set is retired. Check its tool to back it up again.")
                }
                return set
            }
        } ?? sets.filter { !$0.retired }
        guard !chosen.isEmpty else { throw AIManagerError.invalidSource("Check a tool on the Backup checklist first.") }
        let sources = try await checklistSources()
        var files = 0, tools = 0, fresh: Int64 = 0, failures: [String] = []
        for (index, queued) in chosen.enumerated() {
            let set = sources.first { $0.id == queued.source.id }.map { BackupChecklist.withProfiles(queued, homes: $0.extraHomes) }
                ?? queued
            let setID = set.id.uuidString.lowercased()
            do {
                let snapshot = try await backups.snapshot(set) { value in
                    progress?(BackupRunProgress(setID: setID, index: index, count: chosen.count, files: value.files,
                                                bytes: value.bytes))
                }
                files += snapshot.files; fresh += snapshot.newBytes; tools += 1
            } catch is CancellationError {
                setNotice("Backup cancelled.")
                throw CancellationError()
            } catch {
                failures.append(chosen.count > 1 ? "\(set.name): \(describe(error))" : describe(error))
            }
        }
        if !failures.isEmpty { setError(failures.joined(separator: " ")) }
        guard tools > 0 else { throw AIManagerError.invalidSource(failures.joined(separator: " ")) }
        let notice = "Backed up \(tools > 1 ? "\(tools) tools: " : "")\(files) files. \(Self.size(fresh)) of new data."
        setNotice(notice)
        return .done(notice: notice, error: failures.isEmpty ? nil : failures.joined(separator: " "))
    }

    /// Restores a snapshot (all of it, or `items` with their descendants) in place, after a safety snapshot, or into
    /// `destination`. Login files come back only with `includeLogins`, as the CLI asks.
    public func restoreBackup(setID: UUID, snapshotID: String, items: [String], destination: URL?,
                              includeLogins: Bool, progress: (@Sendable (BackupRunProgress) -> Void)? = nil)
        async throws -> ActionResult {
        let manager = try requireManager()
        let backups = BackupEngine(applicationSupport: paths.applicationSupport)
        guard var set = try await backups.sets().first(where: { $0.id == setID }) else {
            throw AppEngineError.notFound("No backup set has that ID.")
        }
        let status = try await backups.status(for: set)
        if case .waiting(let volume) = status.state { throw BackupError.waiting(volume) }
        guard let snapshot = status.snapshots.first(where: { $0.id == snapshotID }) else {
            throw AppEngineError.notFound("No snapshot of this set has that ID.")
        }
        let selected = snapshot.manifest.entries.filter { entry in
            items.isEmpty || items.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
        }
        guard !selected.isEmpty, items.allSatisfy({ path in selected.contains { $0.path == path || $0.path.hasPrefix(path + "/") } }) else {
            throw AIManagerError.invalidSource("Select paths listed in the snapshot manifest.")
        }
        if selected.contains(where: { BackupPresets.isLogin($0.path) }), !includeLogins {
            throw AIManagerError.invalidSource("This selection includes login files. Review it and allow login files to restore them.")
        }
        set.includeLogins = includeLogins
        do {
            let id = setID.uuidString.lowercased()
            let result = try await manager.restoreBackup(snapshot, set: set, items: items.isEmpty ? nil : items,
                                                         to: destination) { value in
                progress?(BackupRunProgress(setID: id, index: 0, count: 1, files: value.files, bytes: value.bytes))
            }
            let notice = "Restored \(result.restored) files" + (destination.map { " to \($0.lastPathComponent)" } ?? "") + "."
            setNotice(notice)
            return .done(notice: notice)
        } catch {
            setError(describe(error))
            throw error
        }
    }

    // MARK: Checklist changes (BackupChecklist rules, shared with the Mac app and the CLI)

    /// The CLI `backup configure` and the Mac folder pick: every checked tool moves to `destination`, then
    /// `sourceID` is checked there. Shared values left out keep the checked sets' current ones.
    public func configureBackup(sourceID: String, destination: URL, schedule: BackupSchedule?, keep: Int?,
                                includeLogins: Bool?, promptsOnly: Bool?) async throws -> BackupChecklistValue {
        let source = try await backupSource(sourceID)
        if let keep, keep <= 0 { throw AIManagerError.invalidSource("Keep at least one snapshot.") }
        return try await changeSets { sets in
            var shared = BackupChecklist.derivedShared(sets.filter { !$0.retired }) ?? SharedBackupSettings()
            shared.schedule = schedule ?? shared.schedule
            shared.keep = keep ?? shared.keep
            shared.includeLogins = includeLogins ?? shared.includeLogins
            shared.promptsOnly = promptsOnly ?? shared.promptsOnly
            let moved = BackupChecklist.move(sets, to: destination)
            return BackupChecklist.share(shared, to: BackupChecklist.check(moved, source: source, destination: destination,
                                                                          shared: shared))
        }
    }

    /// The Mac checklist toggle. Checking needs the shared folder (a checked tool's); unchecking retires the set,
    /// and its snapshots stay in History.
    public func setBackupChecked(sourceID: String, checked: Bool) async throws -> BackupChecklistValue {
        let source = try await backupSource(sourceID)
        return try await changeSets { sets in
            guard checked else { return BackupChecklist.retire(sets, tool: source.id) }
            let active = sets.filter { !$0.retired }
            guard let folder = active.first?.destination else {
                throw AIManagerError.invalidSource("Choose a backup folder first.")
            }
            if active.contains(where: { $0.source.id == source.id }) { return sets }
            return BackupChecklist.check(sets, source: source, destination: folder,
                                         shared: BackupChecklist.derivedShared(active) ?? SharedBackupSettings())
        }
    }

    /// The CLI `backup retire`: stops backups for a tool. Existing snapshots stay available.
    public func retireBackup(tool: String) async throws -> BackupChecklistValue {
        try await changeSets { sets in
            guard sets.contains(where: { $0.toolKey == tool && !$0.retired }) else {
                throw AppEngineError.notFound("No checked tool has that ID.")
            }
            return BackupChecklist.retire(sets, tool: tool)
        }
    }

    /// The Mac shared settings: one change for every checked tool at once.
    public func setBackupShared(schedule: BackupSchedule?, keep: Int?, includeLogins: Bool?, promptsOnly: Bool?)
        async throws -> BackupChecklistValue {
        if let keep, keep <= 0 { throw AIManagerError.invalidSource("Keep at least one snapshot.") }
        return try await changeSets { sets in
            guard var shared = BackupChecklist.derivedShared(sets.filter { !$0.retired }) else {
                throw AIManagerError.invalidSource("Check a tool on the Backup checklist first.")
            }
            shared.schedule = schedule ?? shared.schedule
            shared.keep = keep ?? shared.keep
            shared.includeLogins = includeLogins ?? shared.includeLogins
            shared.promptsOnly = promptsOnly ?? shared.promptsOnly
            return BackupChecklist.share(shared, to: sets)
        }
    }

    /// Saves the sets `change` returns (fail closed: nothing changes when the save fails) and returns the checklist.
    private func changeSets(_ change: ([BackupSet]) throws -> [BackupSet]) async throws -> BackupChecklistValue {
        let backups = BackupEngine(applicationSupport: paths.applicationSupport)
        do {
            try await backups.saveSets(try change(try await backups.sets()))
        } catch {
            setError(describe(error))
            throw error
        }
        return try await backupChecklist()
    }

    private func backupSource(_ id: String) async throws -> CleanupSource {
        guard let source = try await checklistSources().first(where: { $0.id == id }) else {
            throw AppEngineError.notFound("No backup source has that ID.")
        }
        return source
    }

    /// The tools on the Backup checklist, each once (a Claude Code profile is part of the Claude Code row).
    private func checklistSources() async throws -> [CleanupSource] {
        if status == nil { await reloadAccounts() }
        return CleanupSources.make(paths: paths, accounts: status?.accounts ?? [])
            .filter { !$0.isClaudeProfile && $0.backupService != nil }
    }

    /// The Mac `MaintenanceStore.size`.
    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
