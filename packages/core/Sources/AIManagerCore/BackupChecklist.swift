import Foundation

/// The Backup settings every checked tool shares. The Mac app keeps a copy under `key` in its preferences.
public struct SharedBackupSettings: Codable, Equatable, Sendable {
    public var schedule: BackupSchedule = .off
    public var keep = 10
    public var includeLogins = false
    public var promptsOnly: Bool? = nil
    public static let key = "backupShared"

    public init(schedule: BackupSchedule = .off, keep: Int = 10, includeLogins: Bool = false, promptsOnly: Bool? = nil) {
        self.schedule = schedule
        self.keep = keep
        self.includeLogins = includeLogins
        self.promptsOnly = promptsOnly
    }
}

/// The Backup checklist's rules, as pure functions over the saved sets. The store saves what they return.
/// A tool is checked while it has an active (not retired) set. Unchecking or moving the shared folder
/// retires a set instead of deleting it, so its snapshots stay in History and can be restored.
public enum BackupChecklist {
    /// What an account's own Claude Code profile adds: the files that are real there (its shared folders are links).
    static let profileFiles: [BackupItem] = [
        BackupItem("backups"), BackupItem("sessions"), BackupItem(".claude.json", isLogin: true),
        BackupItem(".credentials.json", isLogin: true),
    ]

    /// The set contents for one tool. Claude Code covers the shared ~/.claude items and every profile folder.
    public static func contents(for source: CleanupSource) -> (items: [BackupItem], profiles: [String: URL]) {
        let set = BackupSet(
            name: source.title, source: BackupSource(id: source.id, service: source.backupService ?? .claude, home: source.home),
            items: source.backupItems, destination: source.home)
        let synced = withProfiles(set, homes: source.extraHomes)
        return (synced.items, synced.profiles)
    }

    /// Sets `set.profiles` to `homes` and keeps one group of profile items for each. Other items stay as they are.
    public static func withProfiles(_ set: BackupSet, homes: [URL]) -> BackupSet {
        var next = set
        next.profiles = Dictionary(homes.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        next.items = set.items.filter { item in
            !item.path.hasPrefix(BackupSet.profilePrefix + "/")
                || next.profiles.keys.contains { item.path.hasPrefix("\(BackupSet.profilePrefix)/\($0)/") }
        }
        for name in next.profiles.keys.sorted() {
            for file in profileFiles {
                let path = "\(BackupSet.profilePrefix)/\(name)/\(file.path)"
                if !next.items.contains(where: { $0.path == path }) { next.items.append(BackupItem(path, isLogin: file.isLogin)) }
            }
        }
        return next
    }

    /// Folds each Claude Code "Own profile" set into the Claude Code set, then moves every active set to one shared
    /// folder: the folder of the set used most recently (`lastUsed` holds each set's newest snapshot date).
    /// The old sets stay, retired, so their snapshots remain restorable. Running it again changes nothing.
    public static func migrate(_ sets: [BackupSet], lastUsed: [UUID: Date]) -> (sets: [BackupSet], folder: URL?) {
        var result = sets
        var newest: BackupSet?
        for set in sets where !set.retired {
            if newest == nil || (lastUsed[set.id] ?? .distantPast) > (lastUsed[newest!.id] ?? .distantPast) { newest = set }
        }
        for index in result.indices where result[index].source.id.hasPrefix("claude:") && !result[index].retired {
            if let claude = result.firstIndex(where: { $0.source.id == "claude" && !$0.retired }) {
                var homes = Array(result[claude].profiles.values)
                if !homes.contains(result[index].source.home) { homes.append(result[index].source.home) }
                result[claude] = withProfiles(result[claude], homes: homes)
            }
            result[index].retired = true
            result[index].schedule = .off
        }
        guard let folder = newest?.destination else { return (result, nil) }
        return (move(result, to: folder), folder)
    }

    /// Every active set backs up into `folder`. A set elsewhere is retired (its snapshots stay where they are) and
    /// continues as a set in `folder`: an earlier retired set there when one exists, else a new one.
    public static func move(_ sets: [BackupSet], to folder: URL) -> [BackupSet] {
        var result = sets
        for index in sets.indices where !sets[index].retired && !sameFolder(sets[index].destination, folder) {
            let old = sets[index]
            result[index].retired = true
            result[index].schedule = .off
            var next = old
            next.destination = folder
            if let back = result.firstIndex(where: { $0.retired && $0.source.id == old.source.id && sameFolder($0.destination, folder) }) {
                next.id = result[back].id
                next.name = result[back].name
                result[back] = next
            } else {
                next.id = UUID()
                result.append(next)
            }
        }
        return result
    }

    /// Unchecks a tool: stops its schedule. Snapshots and source files are never touched.
    public static func retire(_ sets: [BackupSet], tool: String) -> [BackupSet] {
        sets.map { set in
            guard set.toolKey == tool, !set.retired else { return set }
            var next = set
            next.retired = true
            next.schedule = .off
            return next
        }
    }

    /// Checks a tool: its active set gets the tool's current contents; else a set that was unchecked in the same
    /// folder comes back, so its snapshots stay in one history; else a new set. The set gets the shared settings.
    /// A source without a backup service changes nothing.
    public static func check(_ sets: [BackupSet], source: CleanupSource, destination: URL,
                             shared: SharedBackupSettings) -> [BackupSet] {
        guard let service = source.backupService else { return sets }
        let contents = contents(for: source)
        var next = sets
        if let index = next.firstIndex(where: { !$0.retired && $0.source.id == source.id })
            ?? next.firstIndex(where: { $0.retired && $0.source.id == source.id && sameFolder($0.destination, destination) }) {
            next[index].retired = false
            next[index].items = contents.items
            next[index].profiles = contents.profiles
            next[index].source.home = source.home
        } else {
            next.append(BackupSet(
                name: setName(source), source: BackupSource(id: source.id, service: service, home: source.home),
                items: contents.items, destination: destination, profiles: contents.profiles))
        }
        let index = next.firstIndex { $0.source.id == source.id && !$0.retired }!
        next[index] = share(shared, to: [next[index]])[0]
        return next
    }

    /// A shared setting applies to every checked tool at once; retired sets keep theirs.
    public static func share(_ settings: SharedBackupSettings, to sets: [BackupSet]) -> [BackupSet] {
        sets.map { set in
            guard !set.retired else { return set }
            var copy = set
            copy.schedule = settings.schedule
            copy.keep = settings.keep
            copy.includeLogins = settings.includeLogins
            copy.promptsOnly = settings.promptsOnly == true
            return copy
        }
    }

    /// The shared values of the checked sets: schedule and count of the first, login files On only if every set
    /// has them, so one shared toggle never reads Off while a set still copies login files.
    public static func derivedShared(_ checked: [BackupSet]) -> SharedBackupSettings? {
        guard let first = checked.first else { return nil }
        return SharedBackupSettings(schedule: first.schedule, keep: first.keep,
                                    includeLogins: checked.allSatisfy(\.includeLogins),
                                    promptsOnly: checked.allSatisfy(\.promptsOnly))
    }

    /// A tool's set name; an account's own profile adds the account's id prefix.
    public static func setName(_ source: CleanupSource) -> String {
        source.accountID.map { "\(source.title) \($0.uuidString.prefix(8))" } ?? source.title
    }

    public static func sameFolder(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.path == second.standardizedFileURL.path
    }

    /// Bytes the files of a tool's checklist row take, login files left out. Reads only; run it off the main thread.
    public static func size(of source: CleanupSource) -> Int64 {
        let set = contents(for: source)
        var total: Int64 = 0
        func add(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        for item in set.items where !item.isLogin {
            let url = location(of: item.path, home: source.home, profiles: set.profiles)
            guard let url, CoreSupport.entryExists(url) else { continue }
            add(url)
            if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
                for case let file as URL in walker { add(file) }
            }
        }
        return total
    }

    private static func location(of path: String, home: URL, profiles: [String: URL]) -> URL? {
        let marker = BackupSet.profilePrefix + "/"
        guard path.hasPrefix(marker) else { return home.appending(path: path) }
        let parts = path.dropFirst(marker.count).split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? profiles[parts[0]]?.appending(path: parts[1]) : nil
    }
}
