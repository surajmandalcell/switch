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
            if index.defaultID == nil { index.defaultID = id }
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
            if current.defaultID == id { current.defaultID = replacement }
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

    private func launchSpec(executable: URL, home: URL, arguments: [String]) -> LaunchSpec {
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_AWS_API_KEY",
                    "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
                    "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                    "CLAUDE_CODE_USE_ANTHROPIC_AWS"] {
            environment.removeValue(forKey: key)
        }
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
