import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum BackupSchedule: String, Codable, Sendable { case off, daily, weekly }

public struct BackupSource: Codable, Hashable, Sendable {
    public enum Service: String, Codable, CaseIterable, Sendable { case codex, claude, grok, droid, gemini }
    public var id: String
    public var service: Service
    public var home: URL
    public init(id: String, service: Service, home: URL) {
        self.id = id; self.service = service; self.home = home
    }
}

public struct BackupItem: Codable, Hashable, Sendable {
    public var path: String
    public var isLogin: Bool
    public init(_ path: String, isLogin: Bool = false) { self.path = path; self.isLogin = isLogin }
}

public struct BackupSet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var source: BackupSource
    public var items: [BackupItem]
    public var destination: URL
    public var includeLogins: Bool
    public var promptsOnly: Bool
    public var schedule: BackupSchedule
    public var keep: Int
    /// Extra homes the set copies, by folder name (a Claude Code account's own profile). Their items start with
    /// `BackupSet.profilePrefix/<name>/`, and the snapshot stores their files under that path.
    public var profiles: [String: URL]
    /// Unchecked on the Backup checklist: no schedule, kept so its snapshots stay in History and can be restored.
    public var retired: Bool
    public init(id: UUID = UUID(), name: String, source: BackupSource, items: [BackupItem], destination: URL,
                includeLogins: Bool = false, schedule: BackupSchedule = .off, keep: Int = 10,
                profiles: [String: URL] = [:], retired: Bool = false, promptsOnly: Bool = false) {
        self.id = id; self.name = name; self.source = source; self.items = items; self.destination = destination
        self.includeLogins = includeLogins; self.schedule = schedule; self.keep = keep
        self.profiles = profiles; self.retired = retired
        self.promptsOnly = promptsOnly
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        source = try values.decode(BackupSource.self, forKey: .source)
        items = try values.decode([BackupItem].self, forKey: .items)
        destination = try values.decode(URL.self, forKey: .destination)
        includeLogins = try values.decode(Bool.self, forKey: .includeLogins)
        promptsOnly = try values.decodeIfPresent(Bool.self, forKey: .promptsOnly) ?? false
        schedule = try values.decode(BackupSchedule.self, forKey: .schedule)
        keep = try values.decode(Int.self, forKey: .keep)
        // Sets saved before the checklist have neither field.
        profiles = try values.decodeIfPresent([String: URL].self, forKey: .profiles) ?? [:]
        retired = try values.decodeIfPresent(Bool.self, forKey: .retired) ?? false
    }

    public static let profilePrefix = "_profiles"
    /// The tool this set backs up. An old per-account Claude Code set belongs to Claude Code.
    public var toolKey: String { source.id.hasPrefix("claude:") ? "claude" : source.id }
}

extension BackupSet {
    /// Links in the chosen roots themselves (macOS /var, /tmp, a linked ~/.codex) are the owner's layout; only links below them are refused.
    func resolved() -> BackupSet {
        var copy = self
        copy.source.home = BackupIO.real(source.home)
        copy.destination = BackupIO.real(destination)
        copy.profiles = profiles.mapValues(BackupIO.real)
        return copy
    }
}

public enum BackupPresets {
    // Paths are relative to the selected service or profile home, never the process home.
    public static func items(for service: BackupSource.Service) -> [BackupItem] {
        let paths: [String]
        let logins: [String]
        switch service {
        case .codex:
            paths = ["sessions", "archived_sessions", "config.toml", "AGENTS.md", "prompts", "rules"]
            logins = ["auth.json"]
        case .claude:
            paths = ["projects", "CLAUDE.md", "settings.json", "commands", "agents", "skills",
                     "plugins/installed_plugins.json", "plugins/known_marketplaces.json"]
            logins = [".credentials.json"]
        case .grok:
            paths = ["sessions", "archived_sessions", "config.toml", "AGENTS.md", "prompts", "rules"]
            logins = ["auth.json"]
        case .droid:
            paths = ["sessions", "settings.json", "droids", "commands"]
            logins = ["auth.v2.file", "auth.v2.key", "auth.v2.loginkeychain"]
        case .gemini:
            paths = ["tmp", "settings.json", "GEMINI.md", "commands", "extensions", "skills"]
            logins = ["oauth_creds.json", "google_accounts.json"]
        }
        return paths.map { BackupItem($0) } + logins.map { BackupItem($0, isLogin: true) }
    }

    public static func isLogin(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            let name = component.lowercased()
            return ["auth.json", ".credentials.json", "oauth_creds.json", "google_accounts.json", ".claude.json"].contains(name)
                || name.hasPrefix("auth.v2.") || name.hasSuffix(".key") || name.contains("keychain")
                || name.contains("token") || name == "credentials" || name == "credentials.json"
        }
    }
}

public struct BackupManifest: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case file, directory, symlink }
        public var path: String
        public var kind: Kind
        public var size: Int64
        public var mtime: Double
        public var mode: UInt32
        public var inode: UInt64
        public var device: UInt64
        public var sha256: String
        public var linkTarget: String?
    }
    public var setID: UUID
    public var date: Date
    public var source: BackupSource
    public var entries: [Entry]
    public var files: Int
    public var bytes: Int64
    public var newBytes: Int64
    public var skipped: [String]
    public var safety: Bool
    public var promptsOnly: Bool? = nil
}

public struct BackupSnapshot: Identifiable, Sendable {
    public var id: String { folder.lastPathComponent }
    public var folder: URL
    public var manifest: BackupManifest
    public var date: Date { manifest.date }
    public var files: Int { manifest.files }
    public var totalBytes: Int64 { manifest.bytes }
    public var newBytes: Int64 { manifest.newBytes }
    public var state: String { manifest.skipped.isEmpty ? "Complete" : "Complete with skipped items" }
}

public struct BackupProgress: Sendable { public var files: Int; public var bytes: Int64 }
public struct BackupStatus: Sendable {
    public enum State: Equatable, Sendable { case ready, waiting(String) }
    public var snapshots: [BackupSnapshot]
    public var state: State
    public var nextDue: Date?
    public var lastError: String?
}
public struct BackupRestoreResult: Sendable {
    public var restored: Int
    public var extraFiles: [String]
    public var safetySnapshot: BackupSnapshot?
}
public enum BackupError: Error, LocalizedError, Sendable {
    case waiting(String), unsafe(String), busy, changed(String)
    public var errorDescription: String? {
        switch self {
        case .waiting(let volume): return "Waiting for \(volume). Connect the destination and try again."
        case .unsafe(let reason): return "Unsafe backup path: \(reason)"
        case .busy: return "Another backup operation is running."
        case .changed(let path): return "File changed or vanished: \(path)"
        }
    }
}

/// All file work runs at utility priority. Cancellation propagates into each tree walk.
public actor BackupEngine {
    public static let markerName = ".switch-backup"
    public static let manifestName = "manifest.json"
    private let applicationSupport: URL
    private var busy = false
    private var errors: [UUID: String] = [:]
    public init(applicationSupport: URL) { self.applicationSupport = BackupIO.real(applicationSupport) }

    public func sets() throws -> [BackupSet] {
        let url = applicationSupport.appending(path: "backup-sets.json")
        guard CoreSupport.entryExists(url) else { return [] }
        try BackupIO.noLinks(url, leafMayBeLink: false)
        return try JSONDecoder().decode([BackupSet].self, from: Data(contentsOf: url))
    }

    public func saveSets(_ sets: [BackupSet]) throws {
        for set in sets { try BackupIO.validate(set) }
        try BackupIO.noLinks(applicationSupport, leafMayBeLink: false)
        let lock = try OperationLock(at: applicationSupport.appending(path: "backup-sets.lock"), fileManager: .default)
        try lock.withLock {
            try CoreSupport.atomicWrite(JSONEncoder().encode(sets), to: applicationSupport.appending(path: "backup-sets.json"), fileManager: .default)
        }
    }

    public func status(for set: BackupSet, now: Date = Date()) async throws -> BackupStatus {
        let set = set.resolved()
        let lastError = errors[set.id]
        return try await work {
            try BackupIO.validate(set)
            if let volume = BackupIO.missingDestination(set.destination) {
                return BackupStatus(snapshots: [], state: .waiting(volume), nextDue: nil, lastError: lastError)
            }
            let snapshots = try BackupIO.list(set)
            let interval: TimeInterval? = set.schedule == .off ? nil : (set.schedule == .daily ? 86_400 : 604_800)
            let nextDue = interval.map { snapshots.first(where: { !$0.manifest.safety })?.date.addingTimeInterval($0) ?? now }
            return BackupStatus(snapshots: snapshots, state: .ready, nextDue: nextDue, lastError: lastError)
        }
    }

    public func snapshot(_ set: BackupSet, progress: (@Sendable (BackupProgress) -> Void)? = nil) async throws -> BackupSnapshot {
        let set = set.resolved()
        return try await mutate(set) { try BackupIO.withLock(set) {
            let snapshot = try BackupIO.snapshot(set, safety: false, progress: progress)
            try BackupIO.prune(set)
            return snapshot
        } }
    }

    public func prune(_ set: BackupSet) async throws {
        let set = set.resolved()
        try await mutate(set) { try BackupIO.withLock(set) { try BackupIO.prune(set) } }
    }

    /// A nil destination means restore in place. Selected paths include their descendants.
    public func restore(_ snapshot: BackupSnapshot, set: BackupSet, items: [String]? = nil, to destination: URL? = nil,
                        progress: (@Sendable (BackupProgress) -> Void)? = nil) async throws -> BackupRestoreResult {
        let set = set.resolved()
        var resolvedSnapshot = snapshot
        resolvedSnapshot.folder = BackupIO.real(snapshot.folder)
        let snapshot = resolvedSnapshot
        let destination = destination.map(BackupIO.real)
        return try await mutate(set) { try BackupIO.withLock(set) {
            try BackupIO.restore(snapshot, set: set, items: items, destination: destination, progress: progress)
        } }
    }

    private func mutate<T: Sendable>(_ set: BackupSet, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        guard !busy else { throw BackupError.busy }
        busy = true
        defer { busy = false }
        do { let result = try await work(body); errors[set.id] = nil; return result }
        catch { errors[set.id] = error.localizedDescription; throw error }
    }

    private func work<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try body() }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

private enum BackupIO {
    static let fm = FileManager.default
    static func validate(_ set: BackupSet) throws {
        guard !set.name.isEmpty, set.name != ".", set.name != "..", !set.name.contains("/"),
              set.keep > 0, set.items.allSatisfy({ safePath($0.path) }),
              set.source.home.isFileURL, set.destination.isFileURL else { throw BackupError.unsafe("invalid backup set") }
        guard set.profiles.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("/") && $0.key != "." && $0.key != ".." && $0.value.isFileURL })
        else { throw BackupError.unsafe("invalid profile folder") }
        for home in [set.source.home] + Array(set.profiles.values) {
            guard !CoreSupport.isContained(set.destination, by: home),
                  !CoreSupport.isContained(home, by: set.destination.appending(path: "Switch Backups")) else {
                throw BackupError.unsafe("source and backup destination overlap")
            }
        }
    }
    /// One folder to copy from: the set's own home (empty prefix) or a profile home (its files sit under `prefix` in a snapshot).
    typealias Root = (prefix: String, home: URL, items: [BackupItem])
    static func roots(_ set: BackupSet) -> [Root] {
        let own = set.items.filter { !$0.path.hasPrefix(BackupSet.profilePrefix + "/") }
        var result: [Root] = [("", set.source.home, own)]
        for name in set.profiles.keys.sorted() {
            let prefix = BackupSet.profilePrefix + "/" + name
            let items = set.items.filter { $0.path.hasPrefix(prefix + "/") }
                .map { BackupItem(String($0.path.dropFirst(prefix.count + 1)), isLogin: $0.isLogin) }
            result.append((prefix, set.profiles[name]!, items))
        }
        return result
    }
    /// Where a stored path lives on disk, or nil when it belongs to a profile this set no longer knows.
    static func location(_ set: BackupSet, _ path: String) -> URL? {
        let marker = BackupSet.profilePrefix + "/"
        guard path == BackupSet.profilePrefix || path.hasPrefix(marker) else { return set.source.home.appending(path: path) }
        let parts = path.dropFirst(marker.count).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let home = set.profiles[parts[0]] else { return nil }
        return home.appending(path: parts[1])
    }
    /// A chosen group such as "_profiles" stands for the items below it, so a safety copy covers them.
    static func expand(_ paths: [String], in set: BackupSet) -> [String] {
        paths.flatMap { path -> [String] in
            let below = set.items.map(\.path).filter { $0.hasPrefix(path + "/") && path.hasPrefix(BackupSet.profilePrefix) }
            return below.isEmpty ? [path] : below
        }
    }
    static func safePath(_ path: String) -> Bool {
        CoreSupport.safeRelativePath(path) && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." })
    }
    // Check every ancestor, including broken links. Traversal never crosses a link.
    // realpath on the longest existing prefix; the missing tail is appended unchanged.
    static func real(_ url: URL) -> URL {
        var existing = url.path
        var tail: [String] = []
        while existing != "/" {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                return tail.reduce(URL(fileURLWithPath: String(cString: resolved))) { $0.appending(path: $1) }
            }
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return url
    }
    // Not standardizedFileURL: it would strip /private and hide the /var link.
    static func noLinks(_ url: URL, leafMayBeLink: Bool) throws {
        var cursor = URL(fileURLWithPath: url.path)
        if leafMayBeLink { cursor.deleteLastPathComponent() }
        while cursor.path != "/" {
            var info = stat()
            if lstat(cursor.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { throw BackupError.unsafe("symbolic link ancestor") }
            cursor.deleteLastPathComponent()
        }
    }
    static func metadata(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw BackupError.changed(url.lastPathComponent) }
        return info
    }
    static func modified(_ info: stat) -> Double {
        #if canImport(Darwin)
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        #else
        return Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1e9
        #endif
    }
    static func unchanged(_ a: stat, _ b: stat) -> Bool {
        #if canImport(Darwin)
        let sameChange = a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        #else
        let sameChange = a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec
        #endif
        return a.st_ino == b.st_ino && a.st_dev == b.st_dev && a.st_size == b.st_size
            && a.st_mode == b.st_mode && modified(a) == modified(b) && sameChange
    }
    static func missingDestination(_ destination: URL) -> String? {
        let parts = destination.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            let volume = URL(fileURLWithPath: "/Volumes/\(parts[2])")
            if !fm.fileExists(atPath: volume.path) { return parts[2] }
        }
        return fm.fileExists(atPath: destination.path) ? nil : destination.lastPathComponent
    }
    static func root(_ set: BackupSet) -> URL { set.destination.appending(path: "Switch Backups").appending(path: set.name) }
    static func prepare(_ set: BackupSet) throws {
        try validate(set)
        if let volume = missingDestination(set.destination) { throw BackupError.waiting(volume) }
        try noLinks(set.destination, leafMayBeLink: false)
        let base = root(set)
        try noLinks(base, leafMayBeLink: false)
        try CoreSupport.privateDirectory(base, fileManager: fm)
        try CoreSupport.privateDirectory(base.deletingLastPathComponent(), fileManager: fm)
        let marker = base.appending(path: BackupEngine.markerName)
        if CoreSupport.entryExists(marker) {
            guard try owns(base, setID: set.id) else { throw BackupError.unsafe("backup name belongs to another set") }
        } else {
            guard try fm.contentsOfDirectory(atPath: base.path).isEmpty else { throw BackupError.unsafe("unmarked backup folder") }
            try CoreSupport.atomicWrite(Data(set.id.uuidString.utf8), to: marker, fileManager: fm)
        }
    }
    static func withLock<T>(_ set: BackupSet, _ body: () throws -> T) throws -> T {
        try prepare(set)
        let lock = try OperationLock(at: root(set).appending(path: ".lock"), fileManager: fm)
        return try lock.withLock(body)
    }
    static func owns(_ folder: URL, setID: UUID) throws -> Bool {
        try noLinks(folder, leafMayBeLink: false)
        let marker = folder.appending(path: BackupEngine.markerName)
        guard CoreSupport.entryExists(marker) else { return false }
        try noLinks(marker, leafMayBeLink: false)
        return try Data(contentsOf: marker) == Data(setID.uuidString.utf8)
    }
    static func load(_ folder: URL, setID: UUID) throws -> BackupSnapshot? {
        guard try owns(folder, setID: setID) else { return nil }
        let url = folder.appending(path: BackupEngine.manifestName)
        guard CoreSupport.entryExists(url) else { return nil }
        try noLinks(url, leafMayBeLink: false)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: url))
        guard manifest.setID == setID, manifest.entries.allSatisfy({ safePath($0.path) }),
              Set(manifest.entries.map(\.path)).count == manifest.entries.count else { throw BackupError.unsafe("invalid manifest") }
        return BackupSnapshot(folder: folder, manifest: manifest)
    }
    static func list(_ set: BackupSet) throws -> [BackupSnapshot] {
        try validate(set)
        let base = root(set)
        guard CoreSupport.entryExists(base) else { return [] }
        guard try owns(base, setID: set.id) else { throw BackupError.unsafe("unmarked backup set") }
        return try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { try load($0, setID: set.id) }.sorted { $0.date > $1.date }
    }
    static func cleanup(_ set: BackupSet) throws {
        for folder in try fm.contentsOfDirectory(at: root(set), includingPropertiesForKeys: nil)
        where folder.lastPathComponent.hasPrefix(".in-progress-") {
            if try owns(folder, setID: set.id) { try fm.removeItem(at: folder) }
        }
    }
    static func selected(_ path: String, items: [String]) -> Bool {
        items.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    static func walk(_ home: URL, items: [BackupItem], includeLogins: Bool,
                     visit: (String, URL, stat) throws -> Void, skipped: (String) -> Void) throws {
        try noLinks(home, leafMayBeLink: false)
        var seen = Set<String>()
        func descend(_ path: String) throws {
            try Task.checkCancellation()
            guard seen.insert(path).inserted, includeLogins || !BackupPresets.isLogin(path) else { return }
            let url = home.appending(path: path)
            do {
                try noLinks(url, leafMayBeLink: true)
                let info = try metadata(url)
                try visit(path, url, info)
                if info.st_mode & S_IFMT == S_IFDIR {
                    try noLinks(url, leafMayBeLink: false)
                    for child in try fm.contentsOfDirectory(atPath: url.path).sorted() { try descend(path + "/" + child) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { skipped(path) }
        }
        // A preset item the tool never created (no archived_sessions yet) is not an error.
        for item in items where includeLogins || !item.isLogin {
            if CoreSupport.entryExists(home.appending(path: item.path)) { try descend(item.path) }
        }
    }
    static func snapshot(_ set: BackupSet, safety: Bool, progress: (@Sendable (BackupProgress) -> Void)?) throws -> BackupSnapshot {
        try noLinks(set.source.home, leafMayBeLink: false)
        try cleanup(set)
        let previous = try list(set).first
        let old = Dictionary(uniqueKeysWithValues: (previous?.manifest.entries ?? []).map { ($0.path, $0) })
        let date = Date()
        let name = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString
        let staging = root(set).appending(path: ".in-progress-" + name)
        try CoreSupport.privateDirectory(staging, fileManager: fm)
        try CoreSupport.atomicWrite(Data(set.id.uuidString.utf8), to: staging.appending(path: BackupEngine.markerName), fileManager: fm)
        var manifest = BackupManifest(setID: set.id, date: date, source: set.source, entries: [], files: 0,
                                      bytes: 0, newBytes: 0, skipped: [], safety: safety)
        var prefix = ""
        let visit: (String, URL, stat) throws -> Void = { relative, source, _ in
            let path = prefix.isEmpty ? relative : prefix + "/" + relative
            let target = staging.appending(path: "files/" + path)
            try CoreSupport.privateDirectory(target.deletingLastPathComponent(), fileManager: fm)
            var entry: BackupManifest.Entry?
            var copied = false
            for attempt in 0...1 {
                try Task.checkCancellation()
                do {
                    if CoreSupport.entryExists(target) { try fm.removeItem(at: target) }
                    try noLinks(source, leafMayBeLink: true)
                    let before = try metadata(source)
                    let kind = before.st_mode & S_IFMT
                    var hash = ""
                    var link: String?
                    copied = false
                    if kind == S_IFDIR {
                        try CoreSupport.privateDirectory(target, fileManager: fm)
                    } else if kind == S_IFLNK {
                        link = try fm.destinationOfSymbolicLink(atPath: source.path)
                        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link!)
                        hash = CoreSupport.digest(Data(link!.utf8))
                    } else if kind == S_IFREG {
                        // Safety copies must preserve current bytes even when a tool restores the old modified time.
                        if !safety, let prior = old[path], let previous, previous.manifest.source == set.source,
                           prior.kind == .file, prior.size == before.st_size, prior.mtime == modified(before),
                           prior.mode == UInt32(before.st_mode & 0o7777), prior.inode == before.st_ino, prior.device == before.st_dev {
                            let priorFile = previous.folder.appending(path: "files/" + path)
                            try noLinks(priorFile, leafMayBeLink: false)
                            let stored = try metadata(priorFile)
                            guard stored.st_mode & S_IFMT == S_IFREG, stored.st_size == prior.size,
                                  UInt32(stored.st_mode & 0o7777) == prior.mode else { throw BackupError.changed(path) }
                            try fm.linkItem(at: priorFile, to: target)
                            hash = prior.sha256
                        } else {
                            try fm.copyItem(at: source, to: target)
                            try noLinks(target, leafMayBeLink: false)
                            guard try metadata(target).st_mode & S_IFMT == S_IFREG else { throw BackupError.changed(path) }
                            try fm.setAttributes([.posixPermissions: NSNumber(value: before.st_mode & 0o7777)], ofItemAtPath: target.path)
                            hash = try CoreSupport.digest(file: target)
                            copied = true
                        }
                    } else { return } // sockets, devices and pipes carry no data to back up
                    try noLinks(source, leafMayBeLink: true)
                    guard unchanged(before, try metadata(source)) else { throw BackupError.changed(path) }
                    entry = BackupManifest.Entry(path: path, kind: kind == S_IFDIR ? .directory : (kind == S_IFLNK ? .symlink : .file),
                                                 size: kind == S_IFDIR ? 0 : Int64(before.st_size), mtime: modified(before),
                                                 mode: UInt32(before.st_mode & 0o7777), inode: UInt64(before.st_ino), device: UInt64(before.st_dev),
                                                 sha256: hash, linkTarget: link)
                    break
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if attempt == 1 {
                        if CoreSupport.entryExists(target) { try fm.removeItem(at: target) }
                        manifest.skipped.append(path)
                    }
                }
            }
            if let entry {
                manifest.entries.append(entry)
                if entry.kind != .directory {
                    manifest.files += 1; manifest.bytes += entry.size
                    if copied { manifest.newBytes += entry.size }
                    progress?(BackupProgress(files: manifest.files, bytes: manifest.bytes))
                }
            }
        }
        if set.promptsOnly {
            manifest.promptsOnly = true
            var index = "# Prompt index\n\n"
            func store(_ path: String, _ text: String) throws {
                let data = Data(text.utf8)
                let target = staging.appending(path: "files/" + path)
                let hash = CoreSupport.digest(data)
                try CoreSupport.privateDirectory(target.deletingLastPathComponent(), fileManager: fm)
                if let prior = old[path], prior.kind == .file, prior.sha256 == hash, let previous {
                    let file = previous.folder.appending(path: "files/" + path)
                    try noLinks(file, leafMayBeLink: false)
                    guard try metadata(file).st_mode & S_IFMT == S_IFREG,
                          try CoreSupport.digest(file: file) == hash else { throw BackupError.changed(path) }
                    try fm.linkItem(at: file, to: target)
                } else {
                    try CoreSupport.atomicWrite(data, to: target, fileManager: fm)
                    manifest.newBytes += Int64(data.count)
                }
                let info = try metadata(target)
                manifest.entries.append(.init(path: path, kind: .file, size: Int64(data.count), mtime: modified(info),
                    mode: UInt32(info.st_mode & 0o7777), inode: UInt64(info.st_ino), device: UInt64(info.st_dev), sha256: hash))
                manifest.files += 1; manifest.bytes += Int64(data.count)
                progress?(BackupProgress(files: manifest.files, bytes: manifest.bytes))
            }
            for root in roots(set) {
                let items = root.items.filter { PromptBackup.isConversationRoot($0.path, service: set.source.service) }
                try walk(root.home, items: items, includeLogins: false, visit: { path, source, info in
                    guard info.st_mode & S_IFMT == S_IFREG,
                          PromptBackup.isTranscript(path, service: set.source.service) else { return }
                    try noLinks(source, leafMayBeLink: false)
                    let document = try PromptBackup.read(source, path: path, service: set.source.service)
                    try noLinks(source, leafMayBeLink: false)
                    guard unchanged(info, try metadata(source)) else { throw BackupError.changed(path) }
                    guard let document else { return }
                    let identity = root.prefix + "/" + path
                    let file = "prompts/" + PromptBackup.folder(document.project) + "/" + PromptBackup.folder(document.title)
                        + "-" + CoreSupport.digest(Data(identity.utf8)) + ".md"
                    try store(file, document.markdown)
                    index += "- [\(PromptBackup.inline(document.title))](\(file.dropFirst(8))) · \(PromptBackup.inline(document.project))\n"
                }, skipped: { manifest.skipped.append(root.prefix + "/" + $0) })
            }
            try store("prompts/index.md", index)
        } else {
            for root in roots(set) {
                prefix = root.prefix
                try walk(root.home, items: root.items, includeLogins: set.includeLogins, visit: visit,
                         skipped: { manifest.skipped.append(prefix.isEmpty ? $0 : prefix + "/" + $0) })
            }
        }
        try Task.checkCancellation()
        try CoreSupport.atomicWrite(JSONEncoder().encode(manifest), to: staging.appending(path: BackupEngine.manifestName), fileManager: fm)
        let published = root(set).appending(path: name)
        try fm.moveItem(at: staging, to: published)
        return BackupSnapshot(folder: published, manifest: manifest)
    }
    static func prune(_ set: BackupSet) throws {
        for snapshot in try list(set).dropFirst(set.keep) {
            try Task.checkCancellation()
            guard try owns(snapshot.folder, setID: set.id), try load(snapshot.folder, setID: set.id) != nil else { continue }
            try fm.removeItem(at: snapshot.folder)
        }
    }
    static func restore(_ snapshot: BackupSnapshot, set: BackupSet, items: [String]?, destination: URL?,
                        progress: (@Sendable (BackupProgress) -> Void)?) throws -> BackupRestoreResult {
        guard snapshot.folder.deletingLastPathComponent().standardizedFileURL.path == root(set).standardizedFileURL.path,
              !snapshot.folder.lastPathComponent.hasPrefix("."), let stored = try load(snapshot.folder, setID: set.id) else {
            throw BackupError.unsafe("snapshot does not belong to this set")
        }
        if stored.manifest.promptsOnly == true, destination == nil {
            throw BackupError.unsafe("prompt backups must be restored into a folder")
        }
        let paths = items ?? (stored.manifest.promptsOnly == true ? ["prompts"] : set.items.filter { set.includeLogins || !$0.isLogin }.map(\.path))
        guard paths.allSatisfy(safePath) else { throw BackupError.unsafe("invalid restore selection") }
        // Into a folder, a profile's files keep their stored path. In place, they go back to their profile home (or are skipped when it is gone).
        func place(_ path: String) -> URL? { destination.map { $0.appending(path: path) } ?? location(set, path) }
        let entries = stored.manifest.entries.filter {
            selected($0.path, items: paths) && (set.includeLogins || !BackupPresets.isLogin($0.path)) && place($0.path) != nil
        }
        let homes = destination.map { [$0] } ?? [set.source.home] + set.profiles.keys.sorted().map { set.profiles[$0]! }
        for targetHome in homes {
            try noLinks(targetHome, leafMayBeLink: false)
            guard !CoreSupport.isContained(targetHome, by: root(set)), !CoreSupport.isContained(root(set), by: targetHome) else {
                throw BackupError.unsafe("restore destination overlaps backups")
            }
            if let volume = missingDestination(targetHome), targetHome.path.hasPrefix("/Volumes/") { throw BackupError.waiting(volume) }
        }
        // Verify the complete selection before changing any current file.
        for entry in entries {
            let source = stored.folder.appending(path: "files/" + entry.path)
            try noLinks(source, leafMayBeLink: entry.kind == .symlink)
            let info = try metadata(source)
            let kind = info.st_mode & S_IFMT
            guard (entry.kind == .file && kind == S_IFREG) || (entry.kind == .directory && kind == S_IFDIR)
                    || (entry.kind == .symlink && kind == S_IFLNK) else { throw BackupError.unsafe("snapshot entry type changed") }
            if entry.kind == .file, try CoreSupport.digest(file: source) != entry.sha256 { throw BackupError.unsafe("snapshot checksum mismatch") }
            if entry.kind == .symlink, try fm.destinationOfSymbolicLink(atPath: source.path) != entry.linkTarget { throw BackupError.unsafe("snapshot link changed") }
            try noLinks(place(entry.path)!, leafMayBeLink: true)
        }
        var safety: BackupSnapshot?
        var extras: [String] = []
        if destination == nil {
            var safetySet = set
            safetySet.promptsOnly = false
            safetySet.items = expand(paths, in: set).map { BackupItem($0) }
            safety = try self.snapshot(safetySet, safety: true, progress: nil)
            guard safety!.manifest.skipped.allSatisfy({ location(set, $0).map { !CoreSupport.entryExists($0) } ?? true }) else {
                throw BackupError.unsafe("safety snapshot could not preserve current files")
            }
            let restoredPaths = Set(entries.map(\.path))
            for root in roots(set) {
                try walk(root.home, items: root.items, includeLogins: set.includeLogins, visit: { relative, _, info in
                    let path = root.prefix.isEmpty ? relative : root.prefix + "/" + relative
                    if info.st_mode & S_IFMT != S_IFDIR && !restoredPaths.contains(path) { extras.append(path) }
                }, skipped: { _ in })
            }
        }
        for targetHome in homes { try CoreSupport.privateDirectory(targetHome, fileManager: fm) }
        var count = 0
        var bytes: Int64 = 0
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let target = place(entry.path)!
            try noLinks(target, leafMayBeLink: true)
            if entry.kind == .directory {
                try noLinks(target, leafMayBeLink: false)
                try CoreSupport.privateDirectory(target, fileManager: fm)
                continue
            }
            try CoreSupport.privateDirectory(target.deletingLastPathComponent(), fileManager: fm)
            if CoreSupport.entryExists(target), try metadata(target).st_mode & S_IFMT == S_IFDIR {
                throw BackupError.unsafe("restoring a file would remove a current directory")
            }
            let temporary = target.deletingLastPathComponent().appending(path: ".switch-restore-" + UUID().uuidString)
            defer { if CoreSupport.entryExists(temporary) { try? fm.removeItem(at: temporary) } }
            if entry.kind == .symlink {
                try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: entry.linkTarget!)
            } else {
                try fm.copyItem(at: stored.folder.appending(path: "files/" + entry.path), to: temporary)
                try fm.setAttributes([.posixPermissions: NSNumber(value: entry.mode)], ofItemAtPath: temporary.path)
                guard try CoreSupport.digest(file: temporary) == entry.sha256 else { throw BackupError.unsafe("restore checksum mismatch") }
            }
            try noLinks(target, leafMayBeLink: true)
            guard rename(temporary.path, target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            count += 1; bytes += entry.size
            progress?(BackupProgress(files: count, bytes: bytes))
        }
        return BackupRestoreResult(restored: count, extraFiles: extras.sorted(), safetySnapshot: safety)
    }
}
