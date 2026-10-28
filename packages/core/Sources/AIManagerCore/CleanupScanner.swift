import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum CleanupTool: String, Codable, CaseIterable, Sendable {
    case codex, claude, grok, droid, gemini, copilot, opencode
}

/// What Maintenance acts on: one tool home that accounts share, one account with its own home,
/// or a tool found on this Mac that has no account.
public struct CleanupSource: Identifiable, Hashable, Sendable {
    public let id: String
    public let tool: CleanupTool
    public let title: String
    public let detail: String
    public let providerID: ProviderID
    public let accountID: UUID?
    public let accountEmail: String?
    public let home: URL
    public let userHome: URL
    /// Account profile folders whose own files (not links to the shared home) join this source's scan.
    public let extraHomes: [URL]

    public init(id: String, tool: CleanupTool, title: String, detail: String, providerID: ProviderID,
                accountID: UUID? = nil, accountEmail: String? = nil, home: URL, userHome: URL, extraHomes: [URL] = []) {
        self.id = id; self.tool = tool; self.title = title; self.detail = detail; self.providerID = providerID
        self.accountID = accountID; self.accountEmail = accountEmail; self.home = home; self.userHome = userHome
        self.extraHomes = extraHomes
    }

    /// An account's own Claude Code profile. Backup lists it; Cleanup folds it into the shared Claude Code source.
    public var isClaudeProfile: Bool { tool == .claude && accountID != nil }

    public var backupService: BackupSource.Service? {
        switch tool {
        case .codex: .codex
        case .claude: .claude
        case .grok: .grok
        case .droid: .droid
        case .gemini: .gemini
        case .copilot: .copilot
        case .opencode: .opencode
        }
    }

    /// Items to back up differ for an account's own Claude home: its shared folders are links.
    public var backupItems: [BackupItem] {
        guard let service = backupService else { return [] }
        if accountID != nil, tool == .claude {
            return [BackupItem("backups"), BackupItem("sessions"), BackupItem(".claude.json", isLogin: true),
                    BackupItem(".credentials.json", isLogin: true)]
        }
        return BackupPresets.items(for: service)
    }
}

public enum CleanupSources {
    /// Shared homes first (Codex CLI, Claude Code with its profiles, Grok Build, Droid), then tools found on this Mac without accounts.
    public static func make(paths: ManagerPaths, accounts: [AccountRecord], fileManager: FileManager = .default) -> [CleanupSource] {
        let user = paths.userHome
        func count(_ id: ProviderID) -> [AccountRecord] { accounts.filter { $0.identity.providerID == id } }
        func plural(_ n: Int) -> String { "\(n) \(n == 1 ? "account" : "accounts")" }
        func exists(_ url: URL) -> Bool { CoreSupport.entryExists(url) }
        var result: [CleanupSource] = []
        func add(_ id: String, _ tool: CleanupTool, _ title: String, _ detail: String, _ provider: ProviderID,
                 home: URL, account: AccountRecord? = nil) {
            result.append(CleanupSource(id: id, tool: tool, title: title, detail: detail, providerID: provider,
                accountID: account?.id, accountEmail: account?.identity.email, home: home, userHome: user))
        }
        let codex = count(.codex)
        if !codex.isEmpty || exists(paths.sharedRoot) {
            add("codex", .codex, "Codex CLI", plural(codex.count), .codex, home: paths.sharedRoot)
        }
        let claude = count(.claudeCode)
        let claudeHome = user.appending(path: ".claude", directoryHint: .isDirectory)
        if !claude.isEmpty || exists(claudeHome) {
            result.append(CleanupSource(id: "claude", tool: .claude, title: "Claude Code", detail: "Shared history · \(plural(claude.count))",
                providerID: .claudeCode, home: claudeHome, userHome: user, extraHomes: claude.map(\.home).filter(exists)))
        }
        // Each profile sits right after the shared entry. Cleanup shows one Claude Code entry (`isClaudeProfile`).
        for account in claude where exists(account.home) {
            add("claude:\(account.id.uuidString)", .claude, "Claude Code", "Own profile", .claudeCode, home: account.home, account: account)
        }
        let grok = count(.grokBuild)
        if !grok.isEmpty || exists(paths.grokHome) {
            add("grok-build", .grok, "Grok Build", plural(grok.count), .grokBuild, home: paths.grokHome)
        }
        let droid = count(.droid)
        if !droid.isEmpty || exists(paths.droidHome) {
            add("droid", .droid, "Droid", plural(droid.count), .droid, home: paths.droidHome)
        }
        let found: [(String, CleanupTool, String, ProviderID, URL)] = [
            ("gemini", .gemini, "Gemini CLI", .geminiCLI, user.appending(path: ".gemini")),
            ("copilot", .copilot, "GitHub Copilot CLI", ProviderID(rawValue: "copilot"), user.appending(path: ".copilot")),
            ("opencode", .opencode, "opencode", ProviderID(rawValue: "opencode"), user.appending(path: ".local/share/opencode")),
        ]
        for (id, tool, title, provider, home) in found where exists(home) {
            add(id, tool, title, "Found on this Mac", provider, home: home)
        }
        return result
    }
}

public struct CleanupCategory: Identifiable, Sendable {
    public enum Risk: String, Sendable { case safe, caution }
    public let id: String
    public let title: String
    public let detail: String
    public let risk: Risk
    /// Selected when the page opens: only regenerable files, never anything that loses work.
    public let preselected: Bool
    public let byProject: Bool
    /// False for old app versions and the like: they show in every time range.
    public let ageBased: Bool
    public let items: [CleanupItem]
    public var selectable: [CleanupItem] { items.filter { $0.protectedReason == nil } }
    public var protectedItems: [CleanupItem] { items.filter { $0.protectedReason != nil } }
}

public struct CleanupScan: Sendable {
    public let sourceID: String
    public let categories: [CleanupCategory]
    /// Everything the page lists, protected items included. Rewrites are not counted: they shrink files already counted.
    public let totalBytes: Int64

    /// "701 items stay untouched: 650 linked by another app, 51 running now." The reasons come largest first.
    /// Pasted-image rows are left out: they only skip a rewrite, never a chat.
    public var untouchedText: String? {
        let reasons = categories.filter { $0.id != "images" }.flatMap(\.protectedItems).compactMap(\.protectedReason)
        guard !reasons.isEmpty else { return nil }
        let counts = Dictionary(grouping: reasons, by: { $0 }).map { (reason: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.reason) > ($1.count, $0.reason) }
        let named = counts.map { Self.label($0.reason) }
        let parts = counts.count == 1 ? named[0] : zip(counts, named).map { "\($0.count.formatted()) \($1)" }.joined(separator: ", ")
        return "\(reasons.count.formatted()) \(reasons.count == 1 ? "item stays" : "items stay") untouched: \(parts)."
    }

    private static func label(_ reason: String) -> String {
        switch reason {
        case "Another app links this file, so it stays.": "linked by another app"
        case "This item belongs to another user.": "owned by someone else"
        case "In use now.": "running now"
        default: reason.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
    }
}

/// Names that are never listed or removed: sign-in files, settings, keys, registries, live databases.
enum CleanupGuard {
    private static let names: Set<String> = [
        "auth.json", ".credentials.json", "credentials.json", "oauth_creds.json", "google_accounts.json",
        "settings.json", "settings.local.json", "config.toml", "config.json", ".claude.json", "secrets.json",
        "mcp.json", "mcp-config.json", "opencode.json", "session_index.jsonl", "accounts.json", "installation_id",
        "memory", "memories", "agents", "droids", "skills", "commands", "hooks", "hooks.json", "rules", "prompts",
        "agents.md", "claude.md", "gemini.md", "keybindings.json", "context", "installed_plugins.json",
        "known_marketplaces.json", "id_ed25519", "id_ed25519.pub", "host.json", "trusted_folders.toml",
        ".switch-trash", ".ds_store",
    ]
    static func protectedName(_ component: String, last: Bool = true) -> Bool {
        let name = component.lowercased()
        if names.contains(name) || name.hasPrefix("auth.") || name.hasPrefix("mcp-oauth") || name.hasPrefix("mcp-secrets") { return true }
        guard last else { return false }
        // Key and token files, and live databases with their journals.
        return name.contains("keychain") || name.hasSuffix(".key") || name.contains("token")
            || [".sqlite", ".sqlite3", ".db", "-wal", "-shm"].contains { name.hasSuffix($0) }
    }
    static func acceptable(_ path: String) -> Bool {
        guard CoreSupport.safeRelativePath(path), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !parts.enumerated().contains { $0.element.isEmpty || $0.element == "." || protectedName($0.element, last: $0.offset == parts.count - 1) }
    }
}

struct CleanupScanner {
    let source: CleanupSource
    /// Codex titles and last-updated dates from the conversation index, by canonical file path.
    var summaries: [String: ChatThreadSummary] = [:]
    var now = Date()
    private let files = FileManager.default
    /// A file written this recently belongs to a running session.
    static let activeWindow: TimeInterval = 300

    /// Command lines and resolved program paths of running processes, read the first time a check needs them.
    private let processes: LazyList
    /// Paths a running tool holds open, read the first time a check needs them.
    private let openFiles: LazyList

    private final class LazyList {
        private let load: () -> [String]
        private(set) lazy var values: [String] = load()
        init(_ load: @escaping () -> [String]) { self.load = load }
    }

    /// `processes` and `openFiles` stand in for the live process list in tests.
    init(source: CleanupSource, summaries: [ChatThreadSummary] = [], now: Date = Date(),
         processes: [String]? = nil, openFiles: [String]? = nil) {
        self.source = CleanupSource(id: source.id, tool: source.tool, title: source.title, detail: source.detail,
            providerID: source.providerID, accountID: source.accountID, accountEmail: source.accountEmail,
            home: CoreSupport.canonical(source.home), userHome: CoreSupport.canonical(source.userHome),
            extraHomes: source.extraHomes.map(CoreSupport.canonical))
        self.summaries = Dictionary(summaries.map { (CoreSupport.canonical($0.source).path, $0) }, uniquingKeysWith: { first, _ in first })
        self.now = now
        let tool = source.tool
        self.processes = LazyList { processes ?? RunningProcesses.snapshot() }
        self.openFiles = LazyList { openFiles ?? ToolWriterProbe.openFiles(tool: tool) }
    }

    /// A running process starts from, or has an argument inside, this path.
    private func inUse(_ path: String) -> Bool {
        processes.values.contains { line in
            line == path || line.hasPrefix(path + "/") || line.contains(path + "/") || line.contains(path + " ") || line.hasSuffix(path)
        }
    }

    static func modified(_ info: stat) -> Double {
        #if canImport(Darwin)
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        #else
        return Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1e9
        #endif
    }

    func scan() throws -> CleanupScan {
        var result: [CleanupCategory] = []
        func add(_ id: String, _ title: String, _ detail: String, risk: CleanupCategory.Risk = .safe,
                 preselected: Bool = false, byProject: Bool = false, ageBased: Bool = true, _ items: [CleanupItem]) {
            guard !items.isEmpty else { return }
            result.append(CleanupCategory(id: id, title: title, detail: detail, risk: risk, preselected: preselected,
                byProject: byProject, ageBased: ageBased, items: items.sorted { $0.updatedAt > $1.updatedAt }))
        }
        let logs = "Run logs the tool rewrites. Nothing user-facing is lost."
        let caches = "Downloads and scratch files the tool fetches again."
        let oldVersions = "Older copies of the tool. The current version stays."
        let imagesTitle = "Pasted images in old conversations"
        let imagesDetail = "Removes pasted screenshots from old chats. The text stays and chats still open."
        switch source.tool {
        case .codex:
            let sessions = try codexSessions()
            add("conversations", "Conversations", "Saved chats you can resume, by project. Dates are the last activity.",
                risk: .caution, byProject: true, sessions.filter { !$0.agent && !$0.item.isArchivedPath }.map(\.item))
            add("archived", "Archived conversations", "Chats you archived in Codex.", risk: .caution, byProject: true,
                sessions.filter { !$0.agent && $0.item.isArchivedPath }.map(\.item))
            add("agents", "Review and agent sessions",
                "Short sessions Codex starts for auto-reviews and sub-agents. They are not chats you can open.",
                risk: .caution, byProject: true, sessions.filter(\.agent).map(\.item))
            add("images", imagesTitle, imagesDetail, risk: .caution, byProject: true, imageRewrites(sessions.map(\.item)))
            add("generated-images", "Generated images", "Pictures Codex made for you, by age. Removing them deletes the saved copies.",
                risk: .caution, preselected: true, try children(["generated_images"]))
            add("logs", "Logs and temp files", logs, preselected: true, try children(["log", ".tmp"]))
            add("caches", "Caches", caches, preselected: true,
                try children(["cache", "shell_snapshots"]) + whole(["Library/Caches/com.openai.codex", "Library/Caches/Codex"], root: 1))
            add("versions", "Old app versions", oldVersions, preselected: true, ageBased: false,
                try oldReleases("packages/standalone/releases", current: "packages/standalone/current", label: "Standalone")
                + oldReleases("packages/app-server-daemon/releases", current: "packages/app-server-daemon/current", label: "App server"))
            add("worktrees", "Git worktrees", "Working copies made by the Codex app. They may hold changes you have not merged.",
                risk: .caution, try children(["worktrees"]))
            add("history", "Prompt history", "The prompts you typed. Removing it clears the up-arrow history.",
                risk: .caution, whole(["history.jsonl"]))
        case .claude:
            let chats = try claudeProjects()
            add("conversations", "Conversations", "Saved chats you can resume, by project. Dates are the last activity.",
                risk: .caution, byProject: true, chats)
            add("images", imagesTitle, imagesDetail, risk: .caution, byProject: true, imageRewrites(chats))
            add("logs", "Logs and debug files", logs, preselected: true,
                try children(["debug", "telemetry", "logs", "statsig", "todos"])
                + children(profileDirectories(["debug", "telemetry", "logs", "statsig", "todos"]), root: 1))
            add("caches", "Caches", caches, preselected: true,
                try children(["cache", "paste-cache", "image-cache", "session-env", "shell-snapshots"])
                + children(profileDirectories(["cache", "paste-cache", "image-cache", "session-env", "shell-snapshots"]), root: 1)
                + whole(["Library/Caches/claude-cli-nodejs", "Library/Caches/com.anthropic.claudefordesktop"], root: 1))
            add("backups", "Old config backups", "Copies of the settings file. The five newest stay.", preselected: true,
                try children(["backups"], keepNewest: 5) + children(profileDirectories(["backups"]), root: 1, keepNewest: 5))
            add("file-history", "File history", "Copies of files from before each edit. Removing them turns off rewind for old chats.",
                risk: .caution, try children(["file-history"]))
            add("versions", "Old app versions", oldVersions, preselected: true, ageBased: false,
                try oldReleases(".local/share/claude/versions", current: ".local/bin/claude", label: "Claude Code", root: 1)
                + oldReleases("Library/Application Support/Claude/claude-code", current: nil, label: "Claude app", root: 1))
            add("claude-vm", "Claude app VM", "Runs Claude Code inside the Claude app. The app downloads it again when needed.",
                ageBased: false, try claudeVM())
            add("history", "Prompt history", "The prompts you typed. Removing it clears the up-arrow history.",
                risk: .caution, whole(["history.jsonl"]))
        case .grok:
            add("conversations", "Conversations", "Saved chats you can resume, by project. Dates are the last update.",
                risk: .caution, byProject: true, try folderSessions("sessions", encoded: true))
            add("logs", "Logs", logs, preselected: true, try children(["logs"]))
            add("caches", "Caches", caches, preselected: true, try children(["marketplace-cache", "upload_queue"]))
            add("versions", "Old app versions", "Older Grok builds and unfinished downloads. The one you run stays.",
                risk: .caution, try versions("downloads", launcher: "bin/grok", extraLaunchers: ["bin/agent"]))
        case .droid:
            add("conversations", "Conversations", "Saved chats you can resume, by project. Dates are the last update.",
                risk: .caution, byProject: true, try droidSessions())
            add("logs", "Logs", logs, preselected: true, try children(["logs"]))
            add("caches", "Caches and temp files", caches, preselected: true, try children(["cache", "temp"]))
        case .gemini:
            add("conversations", "Conversations", "Saved chats you can resume, by project. Dates are the last update.",
                risk: .caution, byProject: true, try geminiChats())
            add("logs", "Logs", logs, preselected: true, try children(["antigravity-cli/log", "antigravity-cli/annotations"]))
            add("caches", "Caches", caches, preselected: true, try children(["antigravity-cli/cache", "tmp/bin"]))
        case .copilot:
            add("conversations", "Sessions", "Saved Copilot sessions. Sessions synced to GitHub stay there.",
                risk: .caution, try folderSessions("session-state", encoded: false))
            add("logs", "Logs", logs, preselected: true, try children(["logs"]))
            add("caches", "Caches", caches, preselected: true,
                try children(["plugin-data"]) + whole(["Library/Caches/copilot"], root: 1))
        case .opencode:
            add("conversations", "Conversations", "Saved OpenCode chats, by project. Dates are the last update.",
                risk: .caution, byProject: true, try openCodeSessions())
            add("logs", "Logs", logs, preselected: true, try children(["log"]))
            add("caches", "Caches and tool output", caches, preselected: true,
                try children(["tool-output"]) + (try children([".cache/opencode"], root: 1)))
            add("snapshots", "Undo snapshots", "Copies used to undo edits. Removing them loses undo for old sessions.",
                risk: .caution, try children(["snapshot"]))
        }
        let total = result.filter { $0.id != "images" }.flatMap(\.items).reduce(Int64(0)) { $0 + $1.bytes }
        return CleanupScan(sourceID: source.id, categories: result, totalBytes: total)
    }

    // MARK: Item building

    private func openCodeSessions() throws -> [CleanupItem] {
        try OpenCodeStore.sessions(home: source.home).compactMap { session in
            if !session.database {
                guard let built = try item(0, session.path, title: session.title, project: session.project,
                    date: session.updatedAt, companions: session.companions) else { return nil }
                return now.timeIntervalSince(session.updatedAt) < Self.activeWindow ? built.protecting("In use now.") : built
            }
            let database = source.home.appending(path: "opencode.db")
            var info = stat()
            guard lstat(database.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            let reason: String? = info.st_uid != getuid() ? "This item belongs to another user."
                : info.st_nlink != 1 ? "Another app links this file, so it stays."
                : now.timeIntervalSince(session.updatedAt) < Self.activeWindow ? "In use now." : nil
            return CleanupItem(root: 0, path: "opencode.db", companions: [], title: session.title,
                project: session.project, updatedAt: session.updatedAt, bytes: session.bytes, isDirectory: false,
                protectedReason: reason, inode: UInt64(info.st_ino), device: UInt64(info.st_dev),
                modifiedAt: Self.modified(info), rewrite: nil, databaseSessionID: session.id, databaseFingerprint: session.fingerprint)
        }
    }

    private func root(_ index: Int) -> URL { index == 0 ? source.home : source.userHome }

    private struct Walk { var bytes: Int64 = 0; var newest: Double = 0; var count = 0 }

    private func walk(_ url: URL, _ info: stat, into total: inout Walk) throws {
        try Task.checkCancellation()
        total.count += 1
        guard total.count <= 2_000_000 else { throw AIManagerError.operationFailed("A folder is too large to scan.") }
        total.newest = max(total.newest, Self.modified(info))
        if info.st_mode & S_IFMT == S_IFREG { total.bytes += Int64(info.st_size) }
        guard info.st_mode & S_IFMT == S_IFDIR else { return }
        for name in (try? files.contentsOfDirectory(atPath: url.path)) ?? [] {
            let child = url.appending(path: name)
            var childInfo = stat()
            if lstat(child.path, &childInfo) == 0 { try walk(child, childInfo, into: &total) }
        }
    }

    /// nil when the path is missing, a link, or protected by name.
    func item(_ rootIndex: Int, _ path: String, title: String? = nil, project: String? = nil, date: Date? = nil,
              companions: [String] = []) throws -> CleanupItem? {
        guard CleanupGuard.acceptable(path) else { return nil }
        let url = root(rootIndex).appending(path: path)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else { return nil }
        var total = Walk()
        try walk(url, info, into: &total)
        var kept: [String] = []
        for extra in companions where CleanupGuard.acceptable(extra) {
            var extraInfo = stat()
            let extraURL = root(rootIndex).appending(path: extra)
            guard lstat(extraURL.path, &extraInfo) == 0, [S_IFREG, S_IFDIR].contains(extraInfo.st_mode & S_IFMT) else { continue }
            var extraTotal = Walk()
            try walk(extraURL, extraInfo, into: &extraTotal)
            total.bytes += extraTotal.bytes
            total.newest = max(total.newest, extraTotal.newest)
            kept.append(extra)
        }
        let newest = Date(timeIntervalSince1970: total.newest)
        let reason: String? = info.st_uid != getuid() ? "This item belongs to another user."
            : (kind == S_IFREG && info.st_nlink != 1) ? "Another app links this file, so it stays."
            : now.timeIntervalSince(newest) < Self.activeWindow ? "In use now."
            : nil
        return CleanupItem(root: rootIndex, path: path, companions: kept,
            title: title ?? (path as NSString).lastPathComponent, project: project, updatedAt: date ?? newest,
            bytes: total.bytes, isDirectory: kind == S_IFDIR, protectedReason: reason,
            inode: UInt64(info.st_ino), device: UInt64(info.st_dev), modifiedAt: Self.modified(info), rewrite: nil)
    }

    // MARK: Old versions, the Claude app VM, and pasted images

    /// A running process uses this item, or nil. The item stays listed, protected, so the page can count it.
    private func guardRunning(_ built: CleanupItem?, at url: URL) -> CleanupItem? {
        guard let built else { return nil }
        return inUse(CoreSupport.canonical(url).path) ? built.protecting("A running app uses this version.") : built
    }

    /// Every build in `directory` except the one `current` resolves to (or, with no `current`, the highest version number).
    /// A build a running process uses is listed as protected. With no build to keep found, nothing is listed.
    func oldReleases(_ directory: String, current: String?, label: String, root rootIndex: Int = 0) throws -> [CleanupItem] {
        let base = root(rootIndex).appending(path: directory)
        let builds = try names(directory, root: rootIndex)
        var keep: String?
        if let current {
            if let target = realpath(root(rootIndex).appending(path: current).path, nil) {
                keep = CoreSupport.canonical(URL(fileURLWithPath: String(cString: target))).path; free(target)
            }
        } else {
            keep = builds.max { $0.compare($1, options: .numeric) == .orderedAscending }
                .map { CoreSupport.canonical(base.appending(path: $0)).path }
        }
        guard let keep, builds.contains(where: { CoreSupport.canonical(base.appending(path: $0)).path == keep }) else { return [] }
        return try builds.compactMap { name -> CleanupItem? in
            let url = base.appending(path: name)
            guard CoreSupport.canonical(url).path != keep else { return nil }
            return guardRunning(try item(rootIndex, directory + "/" + name, title: "\(label) \(name)"), at: url)
        }
    }

    /// Claude's virtual machine for running Claude Code inside the desktop app. Protected while the app runs.
    private func claudeVM() throws -> [CleanupItem] {
        let path = "Library/Application Support/Claude/claude-code-vm"
        guard let built = try item(1, path, title: "Claude app VM") else { return [] }
        let running = processes.values.contains { $0.contains("/Claude.app/Contents/MacOS/") }
        return [running ? built.protecting("The Claude app is running.") : built]
    }

    /// Folders of the account profiles inside the user home, as paths the scan can list (`root` 1).
    private func profileDirectories(_ names: [String]) -> [String] {
        source.extraHomes.flatMap { home -> [String] in
            let prefix = source.userHome.path + "/"
            guard home.path.hasPrefix(prefix) else { return [] }
            let relative = String(home.path.dropFirst(prefix.count))
            return names.map { relative + "/" + $0 }
        }
    }

    /// One row for each transcript that holds pasted pictures; its size is what the rewrite saves.
    /// Open or recently written transcripts are listed as protected.
    private func imageRewrites(_ transcripts: [CleanupItem]) -> [CleanupItem] {
        transcripts.compactMap { chat in
            guard chat.protectedReason == nil, !chat.isDirectory, chat.path.hasSuffix(".jsonl") else { return nil }
            let url = root(chat.root).appending(path: chat.path)
            let saved = ImageStripper.savings(of: url)
            guard saved > 0 else { return nil }
            let reason: String? = openFiles.values.contains(CoreSupport.canonical(url).path) ? "A running app has this chat open."
                : now.timeIntervalSince1970 - chat.modifiedAt < ConversationCleanup.rewriteQuietPeriod ? "Changed in the last hour." : nil
            return CleanupItem(root: chat.root, path: chat.path, companions: [], title: chat.title, project: chat.project,
                updatedAt: chat.updatedAt, bytes: saved, isDirectory: false, protectedReason: reason, inode: chat.inode,
                device: chat.device, modifiedAt: chat.modifiedAt, rewrite: true)
        }
    }

    private func names(_ directory: String, root rootIndex: Int) throws -> [String] {
        guard CleanupGuard.acceptable(directory) || directory.isEmpty else { return [] }
        let url = root(rootIndex).appending(path: directory)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return [] }
        return try files.contentsOfDirectory(atPath: url.path).sorted()
    }

    func whole(_ paths: [String], root rootIndex: Int = 0) -> [CleanupItem] {
        paths.compactMap { try? item(rootIndex, $0, title: ($0 as NSString).lastPathComponent) }
    }

    /// Each direct child of the listed folders. `keepNewest` leaves the newest few in place.
    func children(_ directories: [String], root rootIndex: Int = 0, keepNewest: Int = 0) throws -> [CleanupItem] {
        var result: [CleanupItem] = []
        for directory in directories {
            var found: [CleanupItem] = []
            for name in try names(directory, root: rootIndex) {
                if let built = try item(rootIndex, directory + "/" + name) { found.append(built) }
            }
            result += found.sorted { $0.updatedAt > $1.updatedAt }.dropFirst(keepNewest)
        }
        return result
    }

    /// Old builds. The build a launcher link points at and the newest other build stay.
    func versions(_ directory: String, launcher: String, extraLaunchers: [String] = [], root rootIndex: Int = 0) throws -> [CleanupItem] {
        var keep = Set<String>()
        for link in [launcher] + extraLaunchers {
            let url = root(rootIndex).appending(path: link)
            if let target = realpath(url.path, nil) {
                keep.insert(CoreSupport.canonical(URL(fileURLWithPath: String(cString: target))).path); free(target)
            }
        }
        let base = root(rootIndex).appending(path: directory)
        let all = try names(directory, root: rootIndex).compactMap { try item(rootIndex, directory + "/" + $0) }
        let live = all.filter { keep.contains(CoreSupport.canonical(base.appending(path: ($0.path as NSString).lastPathComponent)).path) }
        // No launcher target found: keep everything rather than guess.
        guard !live.isEmpty else { return [] }
        let others = all.filter { candidate in !live.contains { $0.path == candidate.path } }
            .sorted { $0.updatedAt > $1.updatedAt }
        let newestWhole = others.first { !$0.title.hasSuffix(".tmp") }
        return others.filter { $0.path != newestWhole?.path }
    }

    // MARK: Conversations

    private struct Session { var item: CleanupItem; var agent: Bool }

    /// The first line of a Codex transcript names the working folder and what started the session.
    private func firstLine(_ url: URL, limit: Int = 1_048_576) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while data.count < limit, let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            if let end = data.firstIndex(of: 10) { return data.prefix(upTo: end) }
        }
        return nil
    }

    private func codexSessions() throws -> [Session] {
        var result: [Session] = []
        for name in ["sessions", "archived_sessions"] {
            let rootURL = source.home.appending(path: name)
            var info = stat()
            guard lstat(rootURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            guard let iterator = files.enumerator(at: rootURL, includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { continue }
            var visited = 0
            for case let url as URL in iterator {
                try Task.checkCancellation()
                visited += 1
                guard visited <= 500_000 else { throw AIManagerError.operationFailed("The conversation inventory is too large.") }
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    iterator.skipDescendants(); continue
                }
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                let path = name + "/" + String(url.standardizedFileURL.path.dropFirst(rootURL.standardizedFileURL.path.count + 1))
                var meta: [String: Any] = [:]
                if let line = firstLine(url), let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let payload = object["payload"] as? [String: Any] { meta = payload }
                let known = summaries[CoreSupport.canonical(url).path]
                let project = known?.workingDirectory ?? (meta["cwd"] as? String) ?? "Unknown project"
                let agent = (meta["source"] as? [String: Any])?["subagent"] != nil
                // The date is the file's last write, the chat's last activity; the index may date a chat by when it was refreshed.
                guard let built = try item(0, path, title: known?.title ?? Self.firstPrompt(in: url) ?? url.deletingPathExtension().lastPathComponent,
                    project: project) else { continue }
                result.append(Session(item: built, agent: agent))
            }
        }
        return result
    }

    /// Claude Code: `projects/<folder>/<session>.jsonl` with an optional `<session>/` folder beside it.
    private func claudeProjects() throws -> [CleanupItem] {
        var result: [CleanupItem] = []
        for folder in try names("projects", root: 0) {
            let directory = "projects/" + folder
            var cwd: String?
            for name in try names(directory, root: 0) where name.hasSuffix(".jsonl") {
                let stem = String(name.dropLast(6))
                if cwd == nil { cwd = workingDirectory(in: source.home.appending(path: directory + "/" + name)) }
                if let built = try item(0, directory + "/" + name, title: Self.firstPrompt(in: source.home.appending(path: directory + "/" + name)) ?? stem,
                    project: cwd ?? Self.decodeProjectFolder(folder), companions: [directory + "/" + stem]) { result.append(built) }
            }
        }
        return result
    }

    /// The first real user prompt of a transcript, on one line. Codex, Claude Code, and Droid keep it in the first lines.
    /// nil when the file has none, so the caller falls back to the session id.
    static func firstPrompt(in url: URL, limit: Int = 262_144) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        for line in data.split(separator: 10, omittingEmptySubsequences: true).prefix(400) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["isMeta"] as? Bool != true,
                  let text = userText(object) else { continue }
            // Tool wrappers and injected context start with "<" or a file banner. They are not what the person typed.
            guard let title = oneLine(text), !title.hasPrefix("<"), !title.hasPrefix("# AGENTS.md") else { continue }
            return title
        }
        return nil
    }

    private static func userText(_ object: [String: Any]) -> String? {
        if let payload = object["payload"] as? [String: Any], payload["type"] as? String == "user_message",
           let message = payload["message"] as? String { return message }
        for level in [object, object["message"] as? [String: Any], object["payload"] as? [String: Any]] {
            guard let level, level["role"] as? String == "user" else { continue }
            if let text = level["content"] as? String { return text }
            if let parts = level["content"] as? [[String: Any]] {
                let texts = parts.compactMap { $0["text"] as? String }
                if !texts.isEmpty { return texts.joined(separator: "\n") }
            }
        }
        return nil
    }

    private func workingDirectory(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 131_072) else { return nil }
        for line in data.split(separator: 10).prefix(400) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let cwd = object["cwd"] as? String ?? (object["payload"] as? [String: Any])?["cwd"] as? String { return cwd }
        }
        return nil
    }

    /// Claude and Droid name a project folder after its path with "-" for "/". This is lossy for names with dashes.
    static func decodeProjectFolder(_ name: String) -> String {
        name.hasPrefix("-") ? name.replacingOccurrences(of: "-", with: "/") : name
    }

    /// Grok and Copilot: one folder per project (percent-encoded path) holding one folder per session,
    /// or, for Copilot, one folder per session.
    private func folderSessions(_ directory: String, encoded: Bool) throws -> [CleanupItem] {
        var result: [CleanupItem] = []
        for name in try names(directory, root: 0) {
            let path = directory + "/" + name
            if encoded {
                var info = stat()
                guard lstat(source.home.appending(path: path).path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                let project = name.removingPercentEncoding ?? name
                // The project folder also holds the prompt history file; that is not a conversation.
                for session in try names(path, root: 0) where session != "prompt_history.jsonl" {
                    let folder = source.home.appending(path: path + "/" + session)
                    if let built = try item(0, path + "/" + session, title: Self.grokTitle(folder) ?? session, project: project) {
                        result.append(built)
                    }
                }
            } else if let built = try item(0, path, title: Self.copilotTitle(source.home.appending(path: path)) ?? name) {
                result.append(built)
            }
        }
        return result
    }

    private static func oneLine(_ text: String) -> String? {
        let first = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let collapsed = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 80 ? String(collapsed.prefix(79)) + "…" : collapsed
    }

    /// Grok keeps a generated title in the session's `summary.json`.
    static func grokTitle(_ folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appending(path: "summary.json"), options: .mappedIfSafe),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ((object["generated_title"] as? String) ?? (object["session_summary"] as? String)).flatMap(oneLine)
    }

    /// Copilot names a session in `workspace.yaml`. The value can be a block scalar, so read the first text line after `name:`.
    static func copilotTitle(_ folder: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: folder.appending(path: "workspace.yaml")) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard let at = lines.firstIndex(where: { $0.hasPrefix("name:") }) else { return nil }
        var value = lines[at].dropFirst(5).trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value.hasPrefix("|") || value.hasPrefix(">") {
            value = lines.dropFirst(at + 1).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
        }
        return oneLine(value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
    }

    /// Droid: `sessions/<folder>/<id>.jsonl` with `<id>.json` and `.bak` files beside it.
    private func droidSessions() throws -> [CleanupItem] {
        var result: [CleanupItem] = []
        for folder in try names("sessions", root: 0) {
            let directory = "sessions/" + folder
            let all = try names(directory, root: 0)
            for name in all where name.hasSuffix(".jsonl") {
                let stem = String(name.dropLast(6))
                let beside = all.filter { $0 != name && $0.hasPrefix(stem + ".") }.map { directory + "/" + $0 }
                if let built = try item(0, directory + "/" + name, title: Self.firstPrompt(in: source.home.appending(path: directory + "/" + name)) ?? stem,
                    project: workingDirectory(in: source.home.appending(path: directory + "/" + name)) ?? Self.decodeProjectFolder(folder), companions: beside) { result.append(built) }
            }
        }
        return result
    }

    private func geminiChats() throws -> [CleanupItem] {
        var result: [CleanupItem] = []
        for project in try names("tmp", root: 0) {
            let chats = "tmp/" + project + "/chats"
            for name in try names(chats, root: 0) {
                if let built = try item(0, chats + "/" + name, title: name, project: project) { result.append(built) }
            }
        }
        return result
    }
}

private extension CleanupItem {
    var isArchivedPath: Bool { path.hasPrefix("archived_sessions/") }
}

/// Is a running tool holding files open inside a home? Reads process names and open paths only.
enum ToolWriterProbe {
    static func processNames(_ tool: CleanupTool) -> [String] {
        switch tool {
        case .codex: ["codex"]
        case .claude: ["claude"]
        case .grok: ["grok"]
        case .droid: ["droid"]
        case .gemini: ["gemini", "agy"]
        case .copilot: ["copilot"]
        case .opencode: ["opencode"]
        }
    }

    static func check(tool: CleanupTool, home: URL) -> WriterState {
        let (open, unknown) = openPaths(tool: tool)
        if open.contains(where: { CoreSupport.isContained($0, by: home) }) { return .active }
        return unknown ? .unknown : .inactive
    }

    /// Real paths every running process of the tool holds open. Empty when none runs or the list cannot be read.
    static func openFiles(tool: CleanupTool) -> [String] { openPaths(tool: tool).paths.map(\.path) }

    /// The files the tool's processes hold open; `unknown` when a process list or a process could not be read.
    private static func openPaths(tool: CleanupTool) -> (paths: [URL], unknown: Bool) {
        var unknown = false
        var paths: [URL] = []
        for name in processNames(tool) {
            guard let (status, data) = run("/usr/bin/pgrep", ["-x", name]) else { unknown = true; continue }
            if status == 1 { continue }
            guard status == 0, let text = String(data: data, encoding: .utf8) else { unknown = true; continue }
            for pid in text.split(whereSeparator: \.isWhitespace).compactMap({ Int32($0) }) {
                guard let (code, listing) = run("/usr/sbin/lsof", ["-n", "-P", "-a", "-p", String(pid), "-F0n"]), code == 0 else {
                    // The process ended between the two calls, or lsof cannot read it.
                    if kill(pid, 0) == 0 || errno != ESRCH { unknown = true }
                    continue
                }
                paths += listing.split(separator: 0).compactMap { field -> URL? in
                    guard field.first == 110, let path = String(data: field.dropFirst(), encoding: .utf8), path.hasPrefix("/") else { return nil }
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return (paths, unknown)
    }

    fileprivate static func run(_ executable: String, _ arguments: [String]) -> (Int32, Data)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

/// What is running now: each program's real path (links resolved) and each full command line.
enum RunningProcesses {
    static func snapshot() -> [String] {
        var lines: [String] = []
        if let (status, data) = ToolWriterProbe.run("/bin/ps", ["-axww", "-o", "comm="]), status == 0 {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let path = String(line)
                lines.append(path)
                if let real = realpath(path, nil) { lines.append(String(cString: real)); free(real) }
            }
        }
        if let (status, data) = ToolWriterProbe.run("/bin/ps", ["-axww", "-o", "args="]), status == 0 {
            lines += String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        return lines
    }
}
