import Foundation

struct ClaudeCodeAuthStatus: Sendable {
    let loggedIn: Bool
    let email: String?

    init(loggedIn: Bool, email: String?) {
        self.loggedIn = loggedIn
        self.email = email
    }
}

struct ClaudeCodeProfiles {
    typealias StatusCheck = @Sendable (LaunchSpec) async throws -> ClaudeCodeAuthStatus
    typealias Logout = @Sendable (LaunchSpec) async throws -> Void

    private struct Index: Codable {
        var accounts: [AccountRecord] = []
        var pending: [AccountLoginSession] = []
        var defaultID: UUID?
        var accountOrder: [UUID] = []
    }

    private let paths: ManagerPaths
    private let fileManager: FileManager
    private let loginRunner: AccountLoginRunner
    private let statusCheck: StatusCheck
    private let logout: Logout
    private let lock: OperationLock
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(paths: ManagerPaths, fileManager: FileManager, loginRunner: AccountLoginRunner,
         statusCheck: @escaping StatusCheck = { try await ClaudeCodeProfiles.cliStatus($0) },
         logout: @escaping Logout = { try await ClaudeCodeProfiles.cliLogout($0) }) throws {
        self.paths = paths
        self.fileManager = fileManager
        self.loginRunner = loginRunner
        self.statusCheck = statusCheck
        self.logout = logout
        self.lock = try OperationLock(
            at: paths.applicationSupport.appending(path: "claude-code-profiles/profiles.lock"),
            fileManager: fileManager)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        _ = repairSharedHistory()
    }

    private var root: URL {
        paths.applicationSupport.appending(path: "claude-code-profiles", directoryHint: .isDirectory)
    }
    private var indexURL: URL { root.appending(path: "profiles.json") }
    private func home(_ id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
            .appending(path: "config", directoryHint: .isDirectory)
    }

    func accounts() throws -> [AccountRecord] { try lock.withLock { try readIndex().accounts } }
    func pending() throws -> [AccountLoginSession] { try lock.withLock { try readIndex().pending } }
    func defaultID() throws -> UUID? { try lock.withLock { try readIndex().defaultID } }
    func accountOrder() throws -> [UUID] { try lock.withLock { try readIndex().accountOrder } }

    func reorder(_ ids: [UUID]) throws {
        try lock.withLock {
            var index = try readIndex()
            guard ids.count == Set(ids).count,
                  Set(index.accounts.map(\.id)).isSubset(of: ids) else {
                throw AIManagerError.sourceChanged
            }
            index.accountOrder = ids
            try writeIndex(index)
        }
    }

    func startLogin() throws -> AccountLoginStart {
        guard let executable = executable() else {
            throw AIManagerError.operationFailed("Claude Code CLI was not found.")
        }
        let session = AccountLoginSession(id: UUID(), providerID: .claudeCode, createdAt: Date())
        let config = home(session.id)
        let spec = launchSpec(executable: executable, home: config, arguments: ["auth", "login"])
        try lock.withLock {
            try CoreSupport.privateDirectory(config, fileManager: fileManager)
            linkSharedHistory(session.id)
            var index = try readIndex()
            index.pending.append(session)
            try writeIndex(index)
        }
        do {
            try loginRunner.launch(session.id, spec)
        } catch {
            try? lock.withLock {
                var index = try readIndex()
                index.pending.removeAll { $0.id == session.id }
                try writeIndex(index)
                try fileManager.removeItem(at: config.deletingLastPathComponent())
            }
            throw error
        }
        return .init(session: session, launchSpec: spec)
    }

    func checkLogin(_ id: UUID) async throws -> AccountLoginCheck {
        let session = try lock.withLock {
            guard let session = try readIndex().pending.first(where: { $0.id == id }) else {
                throw AIManagerError.invalidSource("Claude Code sign-in is no longer active.")
            }
            return session
        }
        guard let executable = executable() else {
            throw AIManagerError.operationFailed("Claude Code CLI was not found.")
        }
        let status = try await statusCheck(launchSpec(executable: executable, home: home(id),
                                                       arguments: ["auth", "status"]))
        guard status.loggedIn, let email = status.email, !email.isEmpty else {
            return .init(session: session, state: .waitingForLogin,
                         message: "Claude Code sign-in has not produced an account identity yet.")
        }
        let account = try lock.withLock {
            var index = try readIndex()
            guard index.pending.contains(where: { $0.id == id }) else {
                throw AIManagerError.sourceChanged
            }
            let identity = AccountIdentity(providerID: .claudeCode, email: email,
                                           userID: email, accountID: id.uuidString,
                                           authMode: .oauth)
            let account = AccountRecord(id: id, identity: identity, credentialFile: home(id),
                                        home: home(id), source: home(id), importedAt: Date(),
                                        verification: .init(state: .verifiedLocally, checkedAt: Date(),
                                                            detail: "Claude Code reports this profile is signed in."),
                                        credentialDigest: "")
            index.accounts.append(account)
            index.pending.removeAll { $0.id == id }
            if index.defaultID == nil {
                index.defaultID = id
                try? writeActive(id)
            }
            try writeIndex(index)
            return account
        }
        _ = loginRunner.cancel(id)
        return .init(session: session, state: .completed, account: account,
                     message: "Claude Code profile was saved.")
    }

    func cancelLogin(_ id: UUID) async throws {
        guard try pending().contains(where: { $0.id == id }) else {
            throw AIManagerError.invalidSource("Claude Code sign-in is no longer active.")
        }
        _ = loginRunner.cancel(id)
        if let executable = executable() {
            let status = try await statusCheck(launchSpec(executable: executable, home: home(id),
                                                           arguments: ["auth", "status"]))
            if status.loggedIn {
                try await logout(launchSpec(executable: executable, home: home(id),
                                            arguments: ["auth", "logout"]))
            }
        }
        try lock.withLock {
            var index = try readIndex()
            index.pending.removeAll { $0.id == id }
            try writeIndex(index)
            try fileManager.removeItem(at: home(id).deletingLastPathComponent())
        }
    }

    func makeDefault(_ id: UUID) throws -> SwitchResult {
        try lock.withLock {
            var index = try readIndex()
            guard index.accounts.contains(where: { $0.id == id }) else { throw AIManagerError.accountNotFound }
            let previous = index.defaultID
            let backup = root.appending(path: "backups/\(UUID().uuidString).json")
            try CoreSupport.privateDirectory(backup.deletingLastPathComponent(), fileManager: fileManager)
            try CoreSupport.atomicWrite(try encoder.encode(index), to: backup, fileManager: fileManager)
            linkSharedHistory(id)
            try writeActive(id)
            index.defaultID = id
            try writeIndex(index)
            return .init(accountID: id, backup: backup, previousAccountID: previous)
        }
    }

    func launchSpec(_ id: UUID, arguments: [String], workingDirectory: URL?) throws -> LaunchSpec {
        let index = try lock.withLock { try readIndex() }
        guard index.accounts.contains(where: { $0.id == id }) else { throw AIManagerError.accountNotFound }
        guard index.defaultID == id else {
            throw AIManagerError.operationFailed("Use this Claude Code profile before opening it.")
        }
        guard let executable = executable() else {
            throw AIManagerError.operationFailed("Claude Code CLI was not found.")
        }
        try? lock.withLock { linkSharedHistory(id) }
        var spec = launchSpec(executable: executable, home: home(id), arguments: arguments)
        spec.workingDirectory = workingDirectory
        return spec
    }

    func check(_ id: UUID) async -> AccountCheckResult {
        guard let account = try? accounts().first(where: { $0.id == id }) else {
            return .init(verification: .init(state: .needsSignIn, checkedAt: Date(),
                                             detail: "Claude Code profile was not found."))
        }
        guard let executable = executable() else {
            return .init(verification: .init(state: .needsSignIn, checkedAt: Date(),
                                             detail: "Claude Code CLI was not found."))
        }
        let result: VerificationResult
        do {
            let status = try await statusCheck(launchSpec(executable: executable, home: home(id),
                                                           arguments: ["auth", "status"]))
            let matches = status.loggedIn && status.email == account.identity.email
            result = .init(state: matches ? .verifiedLocally : .needsSignIn,
                           checkedAt: Date(),
                           detail: matches ? "Claude Code reports this profile is signed in."
                               : "Sign in to this Claude Code profile again; its saved identity does not match.")
        } catch {
            result = .init(state: .needsSignIn, checkedAt: Date(),
                           detail: "Claude Code could not check this profile.")
        }
        try? lock.withLock {
            var index = try readIndex()
            if let position = index.accounts.firstIndex(where: { $0.id == id }) {
                index.accounts[position].verification = result
                try writeIndex(index)
            }
        }
        return .init(verification: result)
    }

    func delete(_ id: UUID, replacement: UUID?) async throws -> AccountDeletionResult {
        let index = try lock.withLock { try readIndex() }
        guard index.accounts.contains(where: { $0.id == id }) else { throw AIManagerError.accountNotFound }
        if index.defaultID == id {
            guard let replacement, replacement != id,
                  index.accounts.contains(where: { $0.id == replacement }) else {
                throw AIManagerError.defaultAccountReplacementRequired
            }
        }
        guard let executable = executable() else {
            throw AIManagerError.operationFailed("Claude Code CLI was not found.")
        }
        try await logout(launchSpec(executable: executable, home: home(id),
                                    arguments: ["auth", "logout"]))
        return try lock.withLock {
            var current = try readIndex()
            guard current.accounts.contains(where: { $0.id == id }) else { throw AIManagerError.sourceChanged }
            current.accounts.removeAll { $0.id == id }
            current.accountOrder.removeAll { $0 == id }
            if current.defaultID == id {
                current.defaultID = replacement
                try? writeActive(replacement)
            }
            try writeIndex(current)
            try fileManager.removeItem(at: home(id).deletingLastPathComponent())
            return .init(accountID: id, replacementDefaultAccountID: replacement,
                         removedManagedHome: true, removedCredential: true)
        }
    }

    private func readIndex() throws -> Index {
        guard CoreSupport.entryExists(indexURL) else { return Index() }
        let values = try indexURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1_048_576 else {
            throw AIManagerError.unsafePath("Claude Code profile index is not a bounded regular file")
        }
        let index = try decoder.decode(Index.self, from: Data(contentsOf: indexURL))
        guard Set(index.accounts.map(\.id)).count == index.accounts.count,
              Set(index.pending.map(\.id)).count == index.pending.count,
              Set(index.accounts.map(\.id)).isDisjoint(with: index.pending.map(\.id)),
              index.accountOrder.count == Set(index.accountOrder).count,
              index.accounts.allSatisfy({ account in
                  account.identity.providerID == .claudeCode
                      && CoreSupport.sameLocation(account.home, home(account.id))
                      && CoreSupport.sameLocation(account.credentialFile, home(account.id))
              }),
              index.defaultID == nil || index.accounts.contains(where: { $0.id == index.defaultID }) else {
            throw AIManagerError.invalidSource("Claude Code profile index contains invalid account paths or IDs.")
        }
        return index
    }

    private func writeIndex(_ index: Index) throws {
        try CoreSupport.privateDirectory(root, fileManager: fileManager)
        try CoreSupport.atomicWrite(try encoder.encode(index), to: indexURL, fileManager: fileManager)
    }

    private func executable() -> URL? {
        var candidates = [paths.claudeExecutable].compactMap { $0 }
        if paths.isolationRoot == nil {
            candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                .map { URL(fileURLWithPath: String($0)).appending(path: "claude") }
            candidates += [
                fileManager.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude"),
                URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                URL(fileURLWithPath: "/usr/local/bin/claude"),
            ]
        }
        return candidates.map { $0.resolvingSymlinksInPath().standardizedFileURL }.first { candidate in
            let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
                && fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    static let strippedEnvironmentKeys = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_AWS_API_KEY", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_ANTHROPIC_AWS",
    ]

    private func launchSpec(executable: URL, home: URL, arguments: [String]) -> LaunchSpec {
        var environment = ProcessInfo.processInfo.environment
        for key in Self.strippedEnvironmentKeys { environment.removeValue(forKey: key) }
        environment["CLAUDE_CONFIG_DIR"] = home.path
        if let isolationRoot = paths.isolationRoot { environment["HOME"] = isolationRoot.path }
        return .init(executable: executable, arguments: arguments, environment: environment)
    }

    static func cliStatus(_ spec: LaunchSpec) async throws -> ClaudeCodeAuthStatus {
        let data = try await run(spec, captureOutput: true)
        guard !data.isEmpty else { return .init(loggedIn: false, email: nil) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return .init(loggedIn: object?["loggedIn"] as? Bool == true,
                     email: object?["email"] as? String)
    }

    static func cliLogout(_ spec: LaunchSpec) async throws {
        _ = try await run(spec, captureOutput: false)
    }

    private static func run(_ spec: LaunchSpec, captureOutput: Bool) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = spec.executable
                process.arguments = spec.arguments
                process.environment = spec.environment
                let output = Pipe()
                process.standardOutput = captureOutput ? output : FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let deadline = Date().addingTimeInterval(10)
                    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                        throw AIManagerError.operationFailed("Claude Code timed out.")
                    }
                    guard process.terminationStatus == 0 || captureOutput else {
                        throw AIManagerError.operationFailed("Claude Code sign-out failed.")
                    }
                    continuation.resume(returning: captureOutput ? output.fileHandleForReading.readDataToEndOfFile() : Data())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Shared history

extension ClaudeCodeProfiles {
    /// Items every profile shares with the canonical `~/.claude`. Never `.claude.json`,
    /// `.credentials.json`, `policy-limits.json` or `remote-settings.json`: those are per account.
    static let sharedItems = [
        "projects", "history.jsonl", "settings.json", "CLAUDE.md", "keybindings.json", "commands",
        "agents", "skills", "plugins", "output-styles", "agent-memory", "plans", "tasks",
        "file-history", "todos", "ide",
    ]
    private static let sharedFiles: Set<String> = ["history.jsonl", "settings.json", "CLAUDE.md", "keybindings.json"]

    var sharedHome: URL { paths.userHome.appending(path: ".claude", directoryHint: .isDirectory) }

    /// Links one profile's shared items to the canonical home. Returns a line per item that could
    /// not be linked; a failed item is left exactly as it was.
    @discardableResult
    func linkSharedHistory(_ id: UUID) -> [String] {
        var problems: [String] = []
        let config = home(id)
        do {
            if !CoreSupport.entryExists(sharedHome) {
                try fileManager.createDirectory(at: sharedHome, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            }
            try CoreSupport.privateDirectory(config, fileManager: fileManager)
        } catch {
            return ["shared home: \(error.localizedDescription)"]
        }
        let stamp = ISO8601DateFormatter.backupStamp()
        for item in Self.sharedItems {
            do { try link(item, id: id, config: config, stamp: stamp) } catch {
                problems.append("\(item): \(error.localizedDescription)")
            }
        }
        do { try seedConfig(config) } catch { problems.append(".claude.json: \(error.localizedDescription)") }
        return problems
    }

    /// Repairs every saved and pending profile; keyed by profile with only the ones that had problems.
    @discardableResult
    func repairSharedHistory() -> [UUID: [String]] {
        (try? lock.withLock {
            let index = try readIndex()
            var report: [UUID: [String]] = [:]
            for id in index.accounts.map(\.id) + index.pending.map(\.id) {
                let problems = linkSharedHistory(id)
                if !problems.isEmpty { report[id] = problems }
            }
            return report
        }) ?? [:]
    }

    private func link(_ item: String, id: UUID, config: URL, stamp: String) throws {
        let target = sharedHome.appending(path: item)
        let local = config.appending(path: item)
        let isFile = Self.sharedFiles.contains(item)
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: local.path) {
            if destination == target.path { return }
            try fileManager.removeItem(at: local) // a wrong link holds no data
        } else if CoreSupport.entryExists(local) {
            try migrate(item, id: id, local: local, target: target, isFile: isFile, stamp: stamp)
        }
        if !isFile, !CoreSupport.entryExists(target) {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        try fileManager.createSymbolicLink(atPath: local.path, withDestinationPath: target.path)
    }

    /// Backs the real item up, merges it into the shared home without overwriting, then removes it.
    private func migrate(_ item: String, id: UUID, local: URL, target: URL, isFile: Bool,
                         stamp: String) throws {
        let backup = root.appending(path: "backups/\(id.uuidString)/\(stamp)/\(item)")
        try CoreSupport.privateDirectory(backup.deletingLastPathComponent(), fileManager: fileManager)
        try fileManager.copyItem(at: local, to: backup)
        guard CoreSupport.entryExists(target) else {
            try fileManager.moveItem(at: local, to: target)
            return
        }
        if isFile {
            if item == "history.jsonl" { try Self.appendNewLines(from: local, to: target) }
            try fileManager.removeItem(at: local)
            return
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue,
              try local.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AIManagerError.unsafePath("\(item) is not a folder in both places")
        }
        let short = id.uuidString.prefix(8).lowercased()
        for name in try fileManager.contentsOfDirectory(atPath: local.path) {
            var destination = target.appending(path: name)
            var attempt = 0
            while CoreSupport.entryExists(destination) {
                destination = target.appending(path: "\(name).from-\(short)" + (attempt == 0 ? "" : "-\(attempt)"))
                attempt += 1
            }
            try fileManager.moveItem(at: local.appending(path: name), to: destination)
        }
        try fileManager.removeItem(at: local)
    }

    private static func appendNewLines(from source: URL, to target: URL) throws {
        let existing = try Data(contentsOf: target)
        var seen = Set(String(decoding: existing, as: UTF8.self).split(separator: "\n").map(String.init))
        var fresh: [String] = []
        for line in String(decoding: try Data(contentsOf: source), as: UTF8.self).split(separator: "\n")
        where seen.insert(String(line)).inserted {
            fresh.append(String(line))
        }
        guard !fresh.isEmpty else { return }
        var addition = Data()
        if let last = existing.last, last != 0x0A { addition.append(0x0A) }
        addition.append(Data((fresh.joined(separator: "\n") + "\n").utf8))
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: addition)
    }

    /// New profiles start from the shared `~/.claude.json` minus the signed-in account.
    private func seedConfig(_ config: URL) throws {
        let url = config.appending(path: ".claude.json")
        guard !CoreSupport.entryExists(url),
              let data = try? Data(contentsOf: paths.userHome.appending(path: ".claude.json")),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        object.removeValue(forKey: "oauthAccount")
        try CoreSupport.atomicWrite(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                                    to: url, fileManager: fileManager)
    }

    // MARK: Quick switch for plain `claude`

    private var activeFile: URL { paths.vaultRoot.appending(path: "claude/active") }
    var shellScript: URL { paths.vaultRoot.appending(path: "claude/claude.sh") }
    private static let beginMarker = "# >>> switch claude >>>"
    private static let endMarker = "# <<< switch claude <<<"

    /// Names the config dir that plain `claude` should use; empty when there is no default.
    func writeActive(_ id: UUID?) throws {
        try CoreSupport.atomicWrite(Data((id.map { home($0).path } ?? "").utf8), to: activeFile,
                                    fileManager: fileManager)
    }

    private var shellRCFiles: [URL] {
        let zshrc = paths.userHome.appending(path: ".zshrc")
        let bashrc = paths.userHome.appending(path: ".bashrc")
        return CoreSupport.entryExists(bashrc) ? [zshrc, bashrc] : [zshrc]
    }

    private func rcText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func shellIntegrationInstalled() -> Bool {
        CoreSupport.entryExists(shellScript)
            && shellRCFiles.contains { rcText($0).contains(Self.beginMarker) }
    }

    func installShellIntegration() throws {
        func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        claude() {
          if [ -d "$(cat \(quoted(activeFile.path)) 2>/dev/null)" ]; then
            CLAUDE_CONFIG_DIR="$(cat \(quoted(activeFile.path)))" command claude "$@"
          else
            command claude "$@"
          fi
        }

        """
        try CoreSupport.atomicWrite(Data(script.utf8), to: shellScript, fileManager: fileManager)
        let block = "\(Self.beginMarker)\n[ -r \(quoted(shellScript.path)) ] && . \(quoted(shellScript.path))\n\(Self.endMarker)\n"
        for rc in shellRCFiles {
            let existing = rcText(rc)
            guard !existing.contains(Self.beginMarker) else { continue }
            let backup = URL(fileURLWithPath: rc.path + ".switch-backup")
            if CoreSupport.entryExists(rc), !CoreSupport.entryExists(backup) {
                try fileManager.copyItem(at: rc, to: backup)
            }
            let addition = Data(((existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + block).utf8)
            if CoreSupport.entryExists(rc) {
                let handle = try FileHandle(forWritingTo: rc)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: addition)
            } else {
                try addition.write(to: rc)
            }
        }
    }

    func removeShellIntegration() throws {
        for rc in shellRCFiles {
            var lines = rcText(rc).components(separatedBy: "\n")
            guard let begin = lines.firstIndex(of: Self.beginMarker),
                  let end = lines[begin...].firstIndex(of: Self.endMarker) else { continue }
            lines.removeSubrange(begin...end)
            try Data(lines.joined(separator: "\n").utf8).write(to: rc)
        }
        if CoreSupport.entryExists(shellScript) { try fileManager.removeItem(at: shellScript) }
    }
}

private extension ISO8601DateFormatter {
    static func backupStamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}

// MARK: - Usage

private final class ClaudeUsageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: (at: Date, result: Result<ProviderUsage, Error>)] = [:]

    func value(_ id: UUID, within interval: TimeInterval) -> Result<ProviderUsage, Error>? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id], Date().timeIntervalSince(entry.at) < interval else { return nil }
        return entry.result
    }

    func store(_ id: UUID, _ result: Result<ProviderUsage, Error>) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = (Date(), result)
    }
}

extension ClaudeCodeProfiles {
    /// One check of a profile at most this often; the usage endpoint rate limits hard and the
    /// terminal probe takes seconds.
    static let usageInterval: TimeInterval = 10 * 60
    private static let usageCache = ClaudeUsageCache()

    /// Usage of one profile without ever refreshing its token: Claude Code owns the refresh token.
    func usage(accountID: UUID) async throws -> ProviderUsage {
        guard try accounts().contains(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }
        if let cached = Self.usageCache.value(accountID, within: Self.usageInterval) { return try cached.get() }
        let result: Result<ProviderUsage, Error>
        do { result = .success(try await fetchUsage(accountID)) } catch is CancellationError {
            throw CancellationError()
        } catch { result = .failure(error) }
        Self.usageCache.store(accountID, result)
        return try result.get()
    }

    private func fetchUsage(_ id: UUID) async throws -> ProviderUsage {
        let config = home(id)
        let cli = executable()
        var usage: ProviderUsage
        if let data = Self.boundedRead(config.appending(path: ".credentials.json")),
           let credentials = try? JSON(data: data), ClaudeUsage.liveToken(credentials) != nil {
            usage = try await ClaudeUsage.fetch(credentials: credentials, executable: cli)
        } else {
            guard let cli else { throw AIManagerError.operationFailed("Claude Code CLI was not found.") }
            try? lock.withLock { linkSharedHistory(id) }
            usage = try await ClaudeUsageProbe.run(
                configDir: config, executable: cli,
                environment: launchSpec(executable: cli, home: config, arguments: []).environment)
        }
        if let data = Self.boundedRead(config.appending(path: ".claude.json")),
           let identity = try? JSON(data: data) {
            let account = identity["oauthAccount"]
            usage.email = usage.email ?? account["emailAddress"].string
            usage.organization = usage.organization ?? account["organizationName"].string
        }
        return usage
    }

    private static func boundedRead(_ url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32_000_000 else { return nil }
        return try? Data(contentsOf: url)
    }
}
