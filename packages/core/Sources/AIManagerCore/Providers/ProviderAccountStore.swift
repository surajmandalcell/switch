import CSQLite
import Foundation

/// Account store for every generic `ProviderSpec`. Mirrors `ClaudeCodeProfiles`: its own index,
/// lock, default per provider, and pending sign-ins. `AccountManager.status()` merges it in.
///
/// - Index: `<applicationSupport>/provider-accounts/accounts.json`
/// - Vault: `<vaultRoot>/<provider-id>/<uuid>.json`, a JSON-encoded `ProviderCredential`, mode 0600.
struct ProviderAccountStore {
    private struct Index: Codable {
        var accounts: [AccountRecord] = []
        var defaults: [String: UUID] = [:]
        var pending: [AccountLoginSession] = []
    }

    private enum DefaultRule { case always, ifNone, never }

    private static let maxBackups = 10
    private static let pendingLifetime: TimeInterval = 24 * 3_600
    private static let maxFileBytes = 16 * 1_024 * 1_024

    private let paths: ManagerPaths
    private let fileManager: FileManager
    private let environment: [String: String]
    private let specs: [ProviderSpec]
    private let lock: OperationLock
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(paths: ManagerPaths, fileManager: FileManager = .default,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         specs: [ProviderSpec] = ProviderCatalog.all) throws {
        self.paths = paths
        self.fileManager = fileManager
        self.environment = environment
        self.specs = specs
        self.lock = try OperationLock(
            at: paths.applicationSupport.appending(path: "provider-accounts/accounts.lock"),
            fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.encoder = encoder
        self.decoder = decoder
        try pruneStaleLogins()
    }

    // MARK: Paths

    private var root: URL {
        paths.applicationSupport.appending(path: "provider-accounts", directoryHint: .isDirectory)
    }
    private var indexURL: URL { root.appending(path: "accounts.json") }
    private func vaultURL(_ providerID: ProviderID, _ id: UUID) -> URL {
        paths.vaultRoot.appending(path: providerID.rawValue, directoryHint: .isDirectory)
            .appending(path: "\(id.uuidString).json")
    }
    private func loginRoot(_ id: UUID) -> URL {
        root.appending(path: "logins/\(id.uuidString)", directoryHint: .isDirectory)
    }
    private func loginHome(_ id: UUID) -> URL {
        loginRoot(id).appending(path: "home", directoryHint: .isDirectory)
    }
    private func backupDirectory(_ providerID: ProviderID) -> URL {
        root.appending(path: "backups/\(providerID.rawValue)", directoryHint: .isDirectory)
    }

    func spec(_ providerID: ProviderID) -> ProviderSpec? { specs.first { $0.id == providerID } }

    // MARK: Reads

    func accounts() throws -> [AccountRecord] {
        try lock.withLock { try readIndex().accounts.filter { spec($0.identity.providerID) != nil } }
    }

    func defaults() throws -> [String: UUID] { try lock.withLock { try readIndex().defaults } }

    func pending() throws -> [AccountLoginSession] {
        try pruneStaleLogins()
        return try lock.withLock { try readIndex().pending }
    }

    func contains(_ accountID: UUID) throws -> Bool {
        try accounts().contains { $0.id == accountID }
    }

    func spec(forAccount accountID: UUID) throws -> ProviderSpec {
        try lock.withLock {
            let record = try record(accountID, in: readIndex())
            guard let spec = spec(record.identity.providerID) else { throw AIManagerError.accountNotFound }
            return spec
        }
    }

    /// Identity of the live login in the real user home. Read-only; nil when not signed in.
    func liveIdentity(_ providerID: ProviderID) -> CredentialIdentity? {
        guard let spec = spec(providerID), spec.style == .files,
              let live = try? readLive(spec, home: nil), isComplete(spec, live) else { return nil }
        return identity(spec, live)
    }

    // MARK: Add and import

    func addSecret(_ providerID: ProviderID, fields: [String: String]) throws -> AccountRecord {
        guard let spec = spec(providerID), spec.style == .secret else {
            throw AIManagerError.unsupportedSource("Provider \(providerID.rawValue) does not take typed credentials.")
        }
        var values: [String: String] = [:]
        for field in spec.fields {
            let value = (fields[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                if field.optional { continue }
                throw AIManagerError.operationFailed("Enter the \(field.title) for \(spec.name).")
            }
            values[field.key] = value
        }
        return try saveCredential(spec, ProviderCredential(fields: values),
                                  source: vaultURL(spec.id, UUID()).deletingLastPathComponent(),
                                  rule: .ifNone)
    }

    /// Saves the live login in `home` (default: the real user home). Importing from the real home
    /// makes the account the provider default, because it IS the live login.
    @discardableResult
    func importLive(_ providerID: ProviderID, from home: URL? = nil) throws -> AccountRecord {
        guard let spec = spec(providerID), spec.style == .files else {
            throw AIManagerError.unsupportedSource("Provider \(providerID.rawValue) does not use CLI files.")
        }
        return try lock.withLock {
            let credential = try readLive(spec, home: home)
            if let missing = spec.files.first(where: { !$0.optional && credential.files[$0.id] == nil }) {
                throw AIManagerError.invalidSource(
                    "\(spec.name) is not signed in: \(missing.path) was not found.")
            }
            return try saveCredential(spec, credential, source: home ?? paths.userHome,
                                      rule: home == nil ? .always : .never)
        }
    }

    // MARK: Credentials

    /// The default account of a `files` provider reads the live files while they still identify as
    /// the same login, because the CLI keeps them fresher than the vault.
    func credential(for accountID: UUID) throws -> (credential: ProviderCredential, live: Bool, liveDigest: String?) {
        try lock.withLock {
            let index = try readIndex()
            let record = try record(accountID, in: index)
            guard let spec = spec(record.identity.providerID) else { throw AIManagerError.accountNotFound }
            if spec.style == .files, index.defaults[spec.id.rawValue] == accountID,
               var live = try? readLive(spec, home: nil), isComplete(spec, live),
               identity(spec, live).key == record.identity.userID {
                live.isLive = true
                return (live, true, digest(live))
            }
            return (try readVault(record), false, nil)
        }
    }

    /// Saves a refreshed credential. When it came from the live files, they are rewritten only if
    /// their digest still equals `liveDigest`. Returns whether the live files were updated.
    @discardableResult
    func persist(_ accountID: UUID, _ updated: ProviderCredential, live: Bool, liveDigest: String?) throws -> Bool {
        try lock.withLock {
            var index = try readIndex()
            let position = try position(accountID, in: index)
            guard let spec = spec(index.accounts[position].identity.providerID) else {
                throw AIManagerError.accountNotFound
            }
            let bytes = try encoder.encode(updated)
            try CoreSupport.atomicWrite(bytes, to: index.accounts[position].credentialFile, fileManager: fileManager)
            index.accounts[position].credentialDigest = CoreSupport.digest(bytes)
            if let email = spec.identify?(updated)?.email { index.accounts[position].identity.email = email }
            try writeIndex(index)
            // ponytail: compare-and-swap is not atomic against the CLI; add a file lock if CLIs ever write while Switch refreshes.
            guard live, let liveDigest, spec.style == .files,
                  digest(try readLive(spec, home: nil)) == liveDigest else { return false }
            try writeLive(spec, updated, home: nil)
            return true
        }
    }

    func recordCheck(_ accountID: UUID, _ result: VerificationResult) throws {
        try lock.withLock {
            var index = try readIndex()
            index.accounts[try position(accountID, in: index)].verification = result
            try writeIndex(index)
        }
    }

    // MARK: Switch and delete

    func makeDefault(_ accountID: UUID) throws -> SwitchResult {
        try lock.withLock {
            var index = try readIndex()
            let target = try record(accountID, in: index)
            guard let spec = spec(target.identity.providerID) else { throw AIManagerError.accountNotFound }
            let raw = spec.id.rawValue
            let previous = index.defaults[raw]
            var backup = indexURL
            if spec.style == .files {
                let targetCredential = try readVault(target)
                // (a) Capture the outgoing live login so rotated tokens are never lost.
                let outgoing = try readLive(spec, home: nil)
                if isComplete(spec, outgoing) {
                    let key = identity(spec, outgoing).key
                    if let saved = index.accounts.first(where: {
                        $0.identity.providerID == spec.id && $0.identity.userID == key
                    }) {
                        if digest(try readVault(saved)) != digest(outgoing) {
                            _ = try saveCredential(spec, outgoing, source: paths.userHome, rule: .never)
                        }
                    } else {
                        _ = try saveCredential(spec, outgoing, source: paths.userHome, rule: .never)
                    }
                    index = try readIndex()
                }
                // (b) Back up the live bytes, newest ten per provider.
                backup = try writeBackup(spec.id, outgoing)
                // (c) Write the target's files; restore the previous ones if a later file fails.
                do {
                    try writeLive(spec, targetCredential, home: nil)
                } catch {
                    try? writeLive(spec, outgoing, home: nil)
                    throw error
                }
            }
            // (d) Set the default.
            index.defaults[raw] = accountID
            if let at = index.accounts.firstIndex(where: { $0.id == accountID }) {
                index.accounts[at].lastUsedAt = Date()
            }
            try writeIndex(index)
            return .init(accountID: accountID, backup: backup, previousAccountID: previous)
        }
    }

    func delete(_ accountID: UUID, replacement: UUID? = nil) throws -> AccountDeletionResult {
        try lock.withLock {
            var index = try readIndex()
            let target = try record(accountID, in: index)
            let providerID = target.identity.providerID
            if let replacement {
                guard replacement != accountID, index.accounts.contains(where: {
                    $0.id == replacement && $0.identity.providerID == providerID
                }) else { throw AIManagerError.invalidReplacementAccount }
            }
            index.accounts.removeAll { $0.id == accountID }
            var newDefault: UUID?
            if index.defaults[providerID.rawValue] == accountID {
                // `files` providers keep their live files; the default is only cleared.
                if spec(providerID)?.style == .secret {
                    newDefault = replacement
                        ?? index.accounts.first { $0.identity.providerID == providerID }?.id
                }
                index.defaults[providerID.rawValue] = newDefault
            }
            try writeIndex(index)
            try? fileManager.removeItem(at: target.credentialFile)
            return .init(accountID: accountID, replacementDefaultAccountID: newDefault,
                         removedManagedHome: false, removedCredential: true)
        }
    }

    // MARK: Sign-in

    /// Prepares a private temp home and the command to run. The GUI opens it in Terminal.
    func startLogin(_ providerID: ProviderID) throws -> AccountLoginStart {
        guard let spec = spec(providerID), spec.style == .files,
              let login = spec.login, let command = login.first else {
            throw AIManagerError.unsupportedSource("Provider \(providerID.rawValue) has no sign-in command.")
        }
        guard let executable = resolveExecutable(command) else { throw AIManagerError.cliNotFound }
        try pruneStaleLogins()
        let session = AccountLoginSession(id: UUID(), providerID: providerID, createdAt: Date())
        let home = loginHome(session.id)
        var launchEnvironment = environment
        launchEnvironment["HOME"] = home.path
        try lock.withLock {
            try CoreSupport.privateDirectory(home, fileManager: fileManager)
            for file in spec.files {
                guard let name = file.homeEnv else { continue }
                guard CoreSupport.safeRelativePath(file.path) else { throw AIManagerError.unsafePath(file.path) }
                let parent = (file.path as NSString).deletingLastPathComponent
                let directory = parent.isEmpty ? home : home.appending(path: parent, directoryHint: .isDirectory)
                try CoreSupport.privateDirectory(directory, fileManager: fileManager)
                launchEnvironment[name] = directory.path
            }
            var index = try readIndex()
            index.pending.append(session)
            try writeIndex(index)
        }
        launchEnvironment.merge(spec.loginEnv) { _, new in new }
        return .init(session: session, launchSpec: .init(
            executable: executable, arguments: Array(login.dropFirst()), environment: launchEnvironment))
    }

    func checkLogin(_ id: UUID) throws -> AccountLoginCheck {
        try lock.withLock {
            var index = try readIndex()
            guard let session = index.pending.first(where: { $0.id == id }),
                  let spec = spec(session.providerID) else {
                throw AIManagerError.invalidSource("Sign-in is no longer active.")
            }
            let home = loginHome(id)
            let found = try readLive(spec, home: home)
            guard isComplete(spec, found) else {
                return .init(session: session, state: .waitingForLogin,
                             message: "\(spec.name) sign-in has not produced account access yet.")
            }
            let account = try importLive(spec.id, from: home)
            index = try readIndex()
            index.pending.removeAll { $0.id == id }
            try writeIndex(index)
            try? fileManager.removeItem(at: loginRoot(id))
            return .init(session: session, state: .completed, account: account,
                         message: "\(spec.name) account was saved.")
        }
    }

    func cancelLogin(_ id: UUID) throws {
        try lock.withLock {
            var index = try readIndex()
            guard index.pending.contains(where: { $0.id == id }) else {
                throw AIManagerError.invalidSource("Sign-in is no longer active.")
            }
            index.pending.removeAll { $0.id == id }
            try writeIndex(index)
            try? fileManager.removeItem(at: loginRoot(id))
        }
    }

    private func pruneStaleLogins() throws {
        try lock.withLock {
            var index = try readIndex()
            let cutoff = Date().addingTimeInterval(-Self.pendingLifetime)
            let stale = index.pending.filter { $0.createdAt < cutoff }
            guard !stale.isEmpty else { return }
            index.pending.removeAll { $0.createdAt < cutoff }
            try writeIndex(index)
            for session in stale { try? fileManager.removeItem(at: loginRoot(session.id)) }
        }
    }

    private func resolveExecutable(_ command: String) -> URL? {
        func usable(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && fileManager.isExecutableFile(atPath: url.path)
        }
        if command.contains("/") {
            let url = URL(fileURLWithPath: command)
            return usable(url) ? url : nil
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            paths.userHome.appending(path: ".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin",
            paths.userHome.appending(path: ".npm-global/bin").path,
            paths.userHome.appending(path: ".bun/bin").path,
        ]
        return directories.map { URL(fileURLWithPath: $0).appending(path: command) }.first(where: usable)
    }

    // MARK: Index and vault

    private func position(_ id: UUID, in index: Index) throws -> Int {
        guard let position = index.accounts.firstIndex(where: { $0.id == id }) else {
            throw AIManagerError.accountNotFound
        }
        return position
    }

    private func record(_ id: UUID, in index: Index) throws -> AccountRecord {
        index.accounts[try position(id, in: index)]
    }

    private func readIndex() throws -> Index {
        guard CoreSupport.entryExists(indexURL) else { return Index() }
        let values = try indexURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 4 * 1_048_576 else {
            throw AIManagerError.unsafePath("Provider account index is not a bounded regular file")
        }
        let index = try decoder.decode(Index.self, from: Data(contentsOf: indexURL))
        let ids = index.accounts.map(\.id)
        // Records of a provider that is no longer in the catalog stay in the file but are hidden.
        guard Set(ids).count == ids.count,
              Set(index.pending.map(\.id)).count == index.pending.count,
              Set(ids).isDisjoint(with: index.pending.map(\.id)),
              index.accounts.allSatisfy({ account in
                  !account.identity.providerID.rawValue.contains("/")
                      && CoreSupport.sameLocation(
                          account.credentialFile, vaultURL(account.identity.providerID, account.id))
              }),
              index.defaults.allSatisfy({ raw, id in
                  index.accounts.contains { $0.id == id && $0.identity.providerID.rawValue == raw }
              }) else {
            throw AIManagerError.invalidSource("Provider account index contains invalid account paths or IDs.")
        }
        return index
    }

    private func writeIndex(_ index: Index) throws {
        try CoreSupport.privateDirectory(root, fileManager: fileManager)
        try CoreSupport.atomicWrite(try encoder.encode(index), to: indexURL, fileManager: fileManager)
    }

    private func readVault(_ record: AccountRecord) throws -> ProviderCredential {
        guard let data = try readBounded(record.credentialFile) else {
            throw AIManagerError.invalidSource("The saved credential for this account is missing.")
        }
        return try decoder.decode(ProviderCredential.self, from: data)
    }

    private func saveCredential(_ spec: ProviderSpec, _ credential: ProviderCredential, source: URL,
                                rule: DefaultRule) throws -> AccountRecord {
        try lock.withLock {
            var index = try readIndex()
            let found = identity(spec, credential)
            let existing = index.accounts.firstIndex {
                $0.identity.providerID == spec.id && $0.identity.userID == found.key
            }
            let old = existing.map { index.accounts[$0] }
            let id = old?.id ?? UUID()
            let url = vaultURL(spec.id, id)
            let bytes = try encoder.encode(credential)
            try CoreSupport.atomicWrite(bytes, to: url, fileManager: fileManager)
            let record = AccountRecord(
                id: id,
                identity: .init(providerID: spec.id, email: found.email ?? old?.identity.email,
                                userID: found.key, authMode: spec.style == .files ? .oauth : .apiKey),
                credentialFile: url,
                home: spec.style == .files ? paths.userHome : url.deletingLastPathComponent(),
                source: source,
                importedAt: old?.importedAt ?? Date(),
                verification: .init(state: .verifiedLocally, checkedAt: Date(),
                                    detail: "Saved locally. Usage has not been checked yet."),
                lastUsedAt: old?.lastUsedAt,
                credentialDigest: CoreSupport.digest(bytes))
            if let existing { index.accounts[existing] = record } else { index.accounts.append(record) }
            let raw = spec.id.rawValue
            if rule == .always || (rule == .ifNone && index.defaults[raw] == nil) { index.defaults[raw] = id }
            do {
                try writeIndex(index)
            } catch {
                if old == nil { try? fileManager.removeItem(at: url) }
                throw error
            }
            return record
        }
    }

    // MARK: Identity

    private func identity(_ spec: ProviderSpec, _ credential: ProviderCredential) -> CredentialIdentity {
        if let found = spec.identify?(credential) { return found }
        // Never keep a raw secret in the index: the key is a hash.
        let secure = Set(spec.fields.filter(\.secure).map(\.key))
        let basis = spec.style == .secret
            ? CoreSupport.digest(Data(credential.fields.filter { secure.contains($0.key) }
                .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n").utf8))
            : digest(credential)
        return CredentialIdentity(key: basis)
    }

    private func digest(_ credential: ProviderCredential) -> String {
        var data = Data()
        for (key, value) in credential.files.sorted(by: { $0.key < $1.key }) {
            data.append(Data(key.utf8))
            data.append(0)
            data.append(value)
            data.append(0)
        }
        return CoreSupport.digest(data)
    }

    private func isComplete(_ spec: ProviderSpec, _ credential: ProviderCredential) -> Bool {
        spec.files.allSatisfy { $0.optional || credential.files[$0.id] != nil }
    }

    // MARK: Backups

    private func writeBackup(_ providerID: ProviderID, _ credential: ProviderCredential) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = backupDirectory(providerID)
        let url = directory.appending(path: "\(stamp)-\(UUID().uuidString.prefix(4)).json")
        try CoreSupport.atomicWrite(try encoder.encode(credential), to: url, fileManager: fileManager)
        let names = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted(by: >)
        for name in names.dropFirst(Self.maxBackups) {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
        return url
    }

    // MARK: Live files

    /// `home` is a temp sign-in home that mirrors the user home layout; nil means the real one.
    private func liveURL(_ file: LiveFile, home: URL?) throws -> URL {
        guard CoreSupport.safeRelativePath(file.path) else { throw AIManagerError.unsafePath(file.path) }
        if let home { return home.appending(path: file.path) }
        if let name = file.homeEnv, let value = environment[name], !value.isEmpty {
            let directory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
            if paths.isolationRoot.map({ CoreSupport.isContained(directory, by: $0) }) ?? true {
                return directory.appending(path: (file.path as NSString).lastPathComponent)
            }
        }
        return paths.userHome.appending(path: file.path)
    }

    private func readLive(_ spec: ProviderSpec, home: URL?) throws -> ProviderCredential {
        var files: [String: Data] = [:]
        for file in spec.files {
            let url = try liveURL(file, home: home)
            if let table = file.sqliteTable {
                files[file.id] = try readRows(url, table: table, keys: file.sqliteKeys)
            } else if let data = try readBounded(url) {
                if let key = file.key {
                    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let member = object[key] else { continue }
                    files[file.id] = try Self.json(member)
                } else {
                    files[file.id] = data
                }
            }
        }
        return ProviderCredential(files: files)
    }

    private func writeLive(_ spec: ProviderSpec, _ credential: ProviderCredential, home: URL?) throws {
        for file in spec.files {
            guard let data = credential.files[file.id] else { continue }
            let url = try liveURL(file, home: home)
            if file.sqliteTable != nil {
                try writeRows(url, file: file, data: data)
            } else if let key = file.key {
                var object: [String: Any] = [:]
                var mode = 0o600
                if let existing = try readBounded(url) {
                    if !existing.isEmpty {
                        guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                            throw AIManagerError.operationFailed(
                                "\(file.path) is not a JSON object, so Switch left it unchanged.")
                        }
                        object = parsed
                    }
                    let resolved = url.resolvingSymlinksInPath()
                    mode = ((try? fileManager.attributesOfItem(atPath: resolved.path))?[.posixPermissions]
                        as? NSNumber)?.intValue ?? 0o600
                }
                object[key] = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                try replaceFile(url, with: Self.json(object, pretty: true), mode: mode)
            } else {
                try replaceFile(url, with: data, mode: 0o600)
            }
        }
    }

    private static func json(_ value: Any, pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: value, options: options)
    }

    private func readBounded(_ url: URL) throws -> Data? {
        let resolved = url.resolvingSymlinksInPath()
        guard CoreSupport.entryExists(resolved) else { return nil }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= Self.maxFileBytes else {
            throw AIManagerError.unsafePath("\(url.lastPathComponent) is not a bounded regular file")
        }
        return try Data(contentsOf: resolved)
    }

    /// Temp file in the same directory, then rename. Existing parent directories keep their mode.
    private func replaceFile(_ url: URL, with data: Data, mode: Int) throws {
        let target = url.resolvingSymlinksInPath()
        let directory = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let temporary = directory.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        do {
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
            guard rename(temporary.path, target.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: SQLite rows

    private static let lockedMessage = "The app database is busy. Quit the app, then switch again."

    private func readRows(_ url: URL, table: String, keys: [String]) throws -> Data? {
        let url = url.resolvingSymlinksInPath()
        guard CoreSupport.entryExists(url), Self.isIdentifier(table), !keys.isEmpty else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_500)
        let marks = keys.indices.map { "?\($0 + 1)" }.joined(separator: ",")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM \(table) WHERE key IN (\(marks))", -1,
                                 &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, key) in keys.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), key, -1, transient)
        }
        var rows: [String: String] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                guard let key = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                      sqlite3_column_type(statement, 1) != SQLITE_NULL,
                      let value = sqlite3_column_text(statement, 1) else { continue }
                rows[key] = String(decoding: UnsafeBufferPointer(
                    start: value, count: Int(sqlite3_column_bytes(statement, 1))), as: UTF8.self)
            } else if status == SQLITE_DONE {
                break
            } else if status == SQLITE_BUSY || status == SQLITE_LOCKED {
                throw AIManagerError.operationFailed(Self.lockedMessage)
            } else {
                return nil
            }
        }
        return rows.isEmpty ? nil : try Self.json(rows)
    }

    private func writeRows(_ url: URL, file: LiveFile, data: Data) throws {
        let url = url.resolvingSymlinksInPath()
        guard let table = file.sqliteTable, Self.isIdentifier(table) else {
            throw AIManagerError.unsafePath(file.path)
        }
        guard CoreSupport.entryExists(url) else {
            throw AIManagerError.operationFailed("\(file.path) was not found. Open the app once, then switch again.")
        }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            throw AIManagerError.invalidSource("The saved rows for \(file.path) are unreadable.")
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw AIManagerError.operationFailed("\(file.path) could not be opened for writing.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_500)
        func fail(_ status: Int32) -> AIManagerError {
            status == SQLITE_BUSY || status == SQLITE_LOCKED
                ? .operationFailed(Self.lockedMessage)
                : .operationFailed("\(file.path) could not be updated: \(String(cString: sqlite3_errmsg(db))).")
        }
        let begin = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        guard begin == SQLITE_OK else { throw fail(begin) }
        do {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (key, value) in rows where file.sqliteKeys.contains(key) {
                var changed = false
                for sql in ["UPDATE \(table) SET value = ?2 WHERE key = ?1",
                            "INSERT INTO \(table) (key, value) VALUES (?1, ?2)"] where !changed {
                    var statement: OpaquePointer?
                    let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
                    guard prepared == SQLITE_OK else { throw fail(prepared) }
                    defer { sqlite3_finalize(statement) }
                    sqlite3_bind_text(statement, 1, key, -1, transient)
                    sqlite3_bind_text(statement, 2, value, -1, transient)
                    let stepped = sqlite3_step(statement)
                    guard stepped == SQLITE_DONE else { throw fail(stepped) }
                    changed = sqlite3_changes(db) > 0
                }
            }
            let commit = sqlite3_exec(db, "COMMIT", nil, nil, nil)
            guard commit == SQLITE_OK else { throw fail(commit) }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func isIdentifier(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
