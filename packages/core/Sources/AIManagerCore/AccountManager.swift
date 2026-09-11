import CryptoKit
import Darwin
import Foundation

public enum WriterState: Sendable { case inactive, active, unknown }
public enum FaultPoint: Sendable, Equatable { case duringHistoryCopy, afterTemporaryCopy, afterHomePublication, afterDefaultCredentialPublication, afterRegistryCommit }

public actor AccountManager {
    public typealias WriterCheck = @Sendable (URL) async -> WriterState
    public typealias CapacityCheck = @Sendable (URL) -> Int64?

    private struct Registry: Codable {
        var accounts: [AccountRecord] = []
        var defaultAccountID: UUID?
    }

    private let paths: ManagerPaths
    private let fileManager: FileManager
    private let writerCheck: WriterCheck
    private let faultInjector: @Sendable (FaultPoint) throws -> Void
    private let verificationTimeout: TimeInterval
    private let capacityCheck: CapacityCheck
    private let lock: OperationLock
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: ManagerPaths = .standard(), fileManager: FileManager = .default, writerCheck: WriterCheck? = nil, capacityCheck: CapacityCheck? = nil, verificationTimeout: TimeInterval = 10, faultInjector: @escaping @Sendable (FaultPoint) throws -> Void = { _ in }) throws {
        self.paths = paths
        self.fileManager = fileManager
        self.writerCheck = writerCheck ?? { home in await AccountManager.systemWriterCheck(home: home) }
        self.faultInjector = faultInjector
        self.verificationTimeout = verificationTimeout
        self.capacityCheck = capacityCheck ?? { AccountManager.systemCapacity(at: $0) }
        self.lock = try OperationLock(at: paths.applicationSupport.appending(path: "manager.lock"), fileManager: fileManager)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func status() throws -> ManagerStatus {
        let registry = try loadRegistry()
        return .init(
            accounts: registry.accounts,
            defaultAccountID: registry.defaultAccountID,
            sharedRoot: paths.sharedRoot,
            pendingRecovery: try pendingOperations(),
            linkedSettingsDivergences: try inspectLinkedSettings(accounts: registry.accounts)
        )
    }

    public func discover(explicit: URL? = nil) async -> [DiscoveredSource] {
        var candidates = [paths.defaultHome, paths.defaultHome.deletingLastPathComponent().appending(path: ".codex2")]
        if let homes = try? fileManager.contentsOfDirectory(at: paths.orcaAccountsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            candidates += homes.map { $0.appending(path: "home", directoryHint: .isDirectory) }
        }
        if let explicit { candidates.append(CoreSupport.home(for: explicit)) }

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let canonical = CoreSupport.canonical(candidate)
            guard seen.insert(canonical.path).inserted,
                  fileManager.fileExists(atPath: candidate.path) || candidate == CoreSupport.home(for: explicit ?? candidate) && explicit != nil else { return nil }
            return inspectSource(candidate)
        }
    }

    public func planImport(source selected: URL, mode: ImportMode) async throws -> ImportPlan {
        try ensureNoRecovery()
        let source = CoreSupport.home(for: selected)
        let inspection = AuthInspection.inspect(home: selected, fileManager: fileManager)
        guard inspection.support == .supportedChatGPT else {
            throw AIManagerError.unsupportedSource(inspection.error ?? inspection.support.rawValue)
        }
        guard let identity = inspection.identity, identity.isResolved else { throw AIManagerError.unresolvedIdentity }
        let id = UUID()
        let destination = paths.applicationSupport.appending(path: "accounts/\(id.uuidString)/home", directoryHint: .isDirectory)
        guard !CoreSupport.isContained(source, by: paths.applicationSupport), !CoreSupport.isContained(destination, by: source) else {
            throw AIManagerError.unsafePath("source and managed destination overlap")
        }
        let manifest = try buildManifest(source: source, mode: mode)
        var conflicts = try mode == .full ? settingConflicts(source: source) : []
        let registry = try loadRegistry()
        if let existing = registry.accounts.first(where: { sameIdentity($0.identity, identity) }), existing.credentialDigest != inspection.digest {
            conflicts.append(.init(relativePath: "auth.json", importedDigest: inspection.digest, sharedDigest: existing.credentialDigest, affectsAllAccounts: false))
        }
        var warnings = manifest.filter { !$0.selected }.map { "Excluded \($0.relativePath): \($0.disposition)" }
        if try sourceMayBeChanging(source) { warnings.append("The source appears active. Close Codex before a full import.") }
        var requiredBytes = manifest.filter(\.selected).reduce(Int64(0)) { partial, entry in
            let (sum, overflow) = partial.addingReportingOverflow(entry.byteCount)
            return overflow ? Int64.max : sum
        }
        let databaseBackupBytes = manifest.filter { $0.selected && $0.category == .database && !$0.relativePath.hasSuffix("-wal") && !$0.relativePath.hasSuffix("-shm") }
            .reduce(Int64(0)) { partial, entry in
                let (sum, overflow) = partial.addingReportingOverflow(entry.byteCount)
                return overflow ? Int64.max : sum
            }
        requiredBytes = requiredBytes.addingReportingOverflow(databaseBackupBytes).overflow ? Int64.max : requiredBytes + databaseBackupBytes
        if let available = capacityCheck(paths.applicationSupport), available < requiredBytes {
            throw AIManagerError.operationFailed("The destination needs \(requiredBytes) bytes but only \(available) bytes are available.")
        }
        return .init(
            id: id,
            source: source,
            destination: destination,
            backup: paths.applicationSupport.appending(path: "backups/\(id.uuidString)", directoryHint: .isDirectory),
            mode: mode,
            identity: identity,
            sourceAuthDigest: inspection.digest,
            reviewedDataDigest: try reviewedDataDigest(source: source, mode: mode, authDigest: inspection.digest),
            manifest: manifest,
            conflicts: conflicts,
            warnings: warnings,
            requiredBytes: requiredBytes
        )
    }

    public func importAccount(plan: ImportPlan, decisions: [String: ConflictChoice] = [:]) async throws -> ImportResult {
        try ensureNoRecovery()
        let missing = plan.conflicts.map(\.relativePath).filter { decisions[$0] == nil }
        guard missing.isEmpty else { throw AIManagerError.missingConflictDecisions(missing) }
        for conflict in plan.conflicts where conflict.externalTarget != nil && decisions[conflict.relativePath] == .useImported {
            guard conflict.externalTargetBytes != nil, conflict.importedDigest != "external-link-requires-review" else {
                throw AIManagerError.invalidSource("Review the linked target for \(conflict.relativePath) before importing it.")
            }
            let bytes = try portableLogicalSize(plan.source.appending(path: conflict.relativePath))
            if let available = capacityCheck(paths.applicationSupport), available < bytes { throw AIManagerError.operationFailed("The reviewed linked data needs \(bytes) bytes but only \(available) bytes are available.") }
        }
        let current = AuthInspection.inspect(home: plan.source, fileManager: fileManager)
        guard current.digest == plan.sourceAuthDigest else { throw AIManagerError.sourceChanged }
        guard try reviewedDataDigest(source: plan.source, mode: plan.mode, authDigest: current.digest) == plan.reviewedDataDigest else { throw AIManagerError.sourceChanged }
        if plan.mode == .full {
            var checked = Set<String>()
            for location in [plan.source, paths.sharedRoot] where checked.insert(CoreSupport.canonical(location).path).inserted {
                switch await writerCheck(location) {
                case .active: throw AIManagerError.activeCodexProcesses
                case .unknown: throw AIManagerError.writerStateUnknown
                case .inactive: break
                }
            }
        }

        return try lock.withLock {
            try performImport(plan: plan, auth: current.data, decisions: decisions)
        }
    }

    public func reviewExternalSetting(plan: ImportPlan, relativePath: String) throws -> ImportPlan {
        guard CoreSupport.settings.contains(relativePath),
              let index = plan.conflicts.firstIndex(where: { $0.relativePath == relativePath && $0.externalTarget != nil }) else {
            throw AIManagerError.invalidSource("No reviewed external setting exists at \(relativePath).")
        }
        let source = plan.source.appending(path: relativePath)
        let currentTarget = try firstExternalLink(source, sourceRoot: plan.source)
        guard currentTarget == plan.conflicts[index].externalTarget else { throw AIManagerError.sourceChanged }
        var reviewed = plan
        reviewed.conflicts[index].externalTargetBytes = try portableLogicalSize(source)
        reviewed.conflicts[index].importedDigest = try treeDigest(source)
        return reviewed
    }

    public func switchDefault(to accountID: UUID) async throws -> SwitchResult {
        try ensureNoRecovery()
        switch await writerCheck(paths.defaultHome) {
        case .active: throw AIManagerError.activeCodexProcesses
        case .unknown: throw AIManagerError.writerStateUnknown
        case .inactive: break
        }
        return try lock.withLock { try performSwitch(to: accountID) }
    }

    public func launchSpec(accountID: UUID, arguments: [String] = [], workingDirectory: URL? = nil) throws -> LaunchSpec {
        let registry = try loadRegistry()
        guard let account = registry.accounts.first(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }
        guard try inspectLinkedSettings(accounts: [account]).isEmpty else {
            throw AIManagerError.operationFailed("Shared settings links changed. Review and repair them before launching this account.")
        }
        guard let executable = resolveExecutable() else { throw AIManagerError.cliNotFound }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        environment["CODEX_HOME"] = account.home.path
        if let isolationRoot = paths.isolationRoot { environment["HOME"] = isolationRoot.path }
        return .init(
            executable: executable,
            arguments: ["-c", "cli_auth_credentials_store=\"file\""] + arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }

    public func repairLinkedSetting(accountID: UUID, relativePath: String, reviewedFingerprint: String) async throws -> LinkedSettingRepairResult {
        try ensureNoRecovery()
        guard CoreSupport.settings.contains(relativePath) else { throw AIManagerError.unsafePath(relativePath) }
        let registry = try loadRegistry()
        guard let account = registry.accounts.first(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }
        switch await writerCheck(account.home) {
        case .active: throw AIManagerError.activeCodexProcesses
        case .unknown: throw AIManagerError.writerStateUnknown
        case .inactive: break
        }
        return try lock.withLock {
            guard let issue = try inspectLinkedSettings(accounts: [account]).first(where: { $0.relativePath == relativePath }) else {
                throw AIManagerError.operationFailed("The reviewed settings link is no longer divergent.")
            }
            guard issue.localFingerprint == reviewedFingerprint else { throw AIManagerError.sourceChanged }
            guard CoreSupport.entryExists(issue.intendedTarget) else {
                throw AIManagerError.operationFailed("The shared settings target is missing and cannot be linked.")
            }

            let operationID = UUID()
            let backupRoot = issue.backupRoot.appending(path: operationID.uuidString, directoryHint: .isDirectory)
            let backup = backupRoot.appending(path: accountID.uuidString).appending(path: relativePath)
            try CoreSupport.privateDirectory(backup.deletingLastPathComponent(), fileManager: fileManager)
            if CoreSupport.entryExists(issue.localPath) { try fileManager.copyItem(at: issue.localPath, to: backup) }

            let temporary = issue.localPath.deletingLastPathComponent().appending(path: ".\(issue.localPath.lastPathComponent).\(operationID.uuidString).link")
            if CoreSupport.entryExists(temporary) { try fileManager.removeItem(at: temporary) }
            try fileManager.createSymbolicLink(at: temporary, withDestinationURL: issue.intendedTarget)
            guard try linkedSettingFingerprint(issue.localPath) == reviewedFingerprint else {
                try? fileManager.removeItem(at: temporary)
                throw AIManagerError.sourceChanged
            }
            let expectedDigest = try treeDigest(temporary)
            let previousDigest = CoreSupport.entryExists(issue.localPath) ? try? treeDigest(issue.localPath) : nil
            var operation = RecoveryOperation(
                id: operationID,
                kind: "settings-link-repair",
                phase: .prepared,
                source: issue.localPath,
                destination: issue.localPath,
                backup: backupRoot,
                expectedDigest: expectedDigest,
                touchedItems: [.init(destination: issue.localPath, backup: CoreSupport.entryExists(backup) ? backup : nil, expectedDigest: expectedDigest, previousDigest: previousDigest, temporary: temporary)],
                registryAccountID: accountID
            )
            try saveOperation(operation)
            guard try linkedSettingFingerprint(issue.localPath) == reviewedFingerprint else {
                try? fileManager.removeItem(at: temporary)
                try finishOperation(&operation)
                throw AIManagerError.sourceChanged
            }
            if CoreSupport.entryExists(issue.localPath) {
                let values = try issue.localPath.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true {
                    try fileManager.removeItem(at: issue.localPath)
                }
            }
            let renamed = temporary.path.withCString { temporaryPath in
                issue.localPath.path.withCString { destinationPath in rename(temporaryPath, destinationPath) }
            }
            guard renamed == 0 else {
                throw AIManagerError.operationFailed("The repaired settings link could not be published (errno \(errno)).")
            }
            try faultInjector(.afterHomePublication)
            guard link(issue.localPath, pointsTo: issue.intendedTarget) else {
                throw AIManagerError.operationFailed("The repaired settings link could not be verified.")
            }
            operation.phase = .published
            try saveOperation(operation)
            try finishOperation(&operation)
            return .init(accountID: accountID, relativePath: relativePath, backup: backupRoot)
        }
    }

    @discardableResult
    public func run(_ spec: LaunchSpec) async throws -> Int32 {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.workingDirectory
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    public func verifyLocal(accountID: UUID) async -> VerificationResult {
        var verificationHome: URL?
        do {
            let base = try launchSpec(accountID: accountID, arguments: ["login", "status"])
            let isolated = paths.applicationSupport.appending(path: "verification/\(UUID().uuidString)", directoryHint: .isDirectory)
            verificationHome = isolated
            try CoreSupport.privateDirectory(isolated, fileManager: fileManager)
            let registry = try loadRegistry()
            guard let account = registry.accounts.first(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }
            try copyPortable(account.home.appending(path: "auth.json"), to: isolated.appending(path: "auth.json"))
            var spec = base
            spec.environment["CODEX_HOME"] = isolated.path
            let process = Process()
            process.executableURL = spec.executable
            process.arguments = spec.arguments
            process.environment = spec.environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(verificationTimeout)
            while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < terminationDeadline { try await Task.sleep(for: .milliseconds(25)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? fileManager.removeItem(at: isolated)
            verificationHome = nil
            let result = process.terminationStatus == 0
                ? VerificationResult(state: .verifiedLocally, checkedAt: Date(), detail: "Codex found file-based credentials. No online request was made.")
                : VerificationResult(state: .needsSignIn, checkedAt: Date(), detail: "Codex did not accept the local credential. Use Codex sign-in for this profile.")
            try recordVerification(result, accountID: accountID)
            return result
        } catch {
            if let verificationHome { try? fileManager.removeItem(at: verificationHome) }
            let result = VerificationResult(state: .needsSignIn, checkedAt: Date(), detail: "Local verification failed without making a model request.")
            try? recordVerification(result, accountID: accountID)
            return result
        }
    }

    public func recover() async throws -> [RecoveryResult] {
        try lock.withLock { try pendingOperations().map { try recoverOperation($0) } }
    }
}

final class JSONLReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var offset = 0
    private var reachedEnd = false
    private let maximumRecordBytes: Int

    init(url: URL, maximumRecordBytes: Int = 64 * 1_024 * 1_024) throws {
        self.maximumRecordBytes = maximumRecordBytes
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    func next() throws -> Data? {
        while true {
            if offset < buffer.count, let newline = buffer[offset...].firstIndex(of: 0x0A) {
                guard newline - offset <= maximumRecordBytes else {
                    throw AIManagerError.invalidSource("A JSONL record exceeds the validation limit.")
                }
                let record = Data(buffer[offset..<newline])
                offset = newline + 1
                compactIfNeeded()
                if record.isEmpty { continue }
                return record
            }
            if reachedEnd {
                guard offset < buffer.count else { return nil }
                guard buffer.count - offset <= maximumRecordBytes else {
                    throw AIManagerError.invalidSource("A JSONL record exceeds the validation limit.")
                }
                let record = Data(buffer[offset...])
                offset = buffer.count
                return record.isEmpty ? nil : record
            }
            guard buffer.count - offset <= maximumRecordBytes else {
                throw AIManagerError.invalidSource("A JSONL record exceeds the validation limit.")
            }
            if let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { buffer.append(chunk) }
            else { reachedEnd = true }
        }
    }

    private func compactIfNeeded() {
        if offset >= 1_048_576 {
            buffer.removeSubrange(0..<offset)
            offset = 0
        }
    }
}

extension AccountManager {
    public static func systemCapacity(at destination: URL) -> Int64? {
        var candidate = destination
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 { candidate.deleteLastPathComponent() }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage, capacity > 0 else { return nil }
        return capacity
    }

    public static func systemWriterCheck(home: URL) async -> WriterState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "codex"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            // pgrep establishes only that a Codex process exists somewhere on the
            // machine; it cannot attribute that process to this home.
            return process.terminationStatus == 0 ? .unknown : (process.terminationStatus == 1 ? .inactive : .unknown)
        } catch {
            return .unknown
        }
    }

    private var registryURL: URL { paths.applicationSupport.appending(path: "accounts.json") }
    private var transactionsURL: URL { paths.applicationSupport.appending(path: "transactions", directoryHint: .isDirectory) }

    private func operationItemsURL(_ id: UUID) -> URL {
        transactionsURL.appending(path: "\(id.uuidString).items", directoryHint: .isDirectory)
    }

    private func loadRegistry() throws -> Registry {
        guard fileManager.fileExists(atPath: registryURL.path) else { return Registry() }
        return try decoder.decode(Registry.self, from: Data(contentsOf: registryURL))
    }

    private func saveRegistry(_ registry: Registry) throws {
        try CoreSupport.atomicWrite(try encoder.encode(registry), to: registryURL, fileManager: fileManager)
    }

    private func recordVerification(_ result: VerificationResult, accountID: UUID) throws {
        var registry = try loadRegistry()
        guard let index = registry.accounts.firstIndex(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }
        registry.accounts[index].verification = result
        try saveRegistry(registry)
    }

    private func pendingOperations() throws -> [RecoveryOperation] {
        guard fileManager.fileExists(atPath: transactionsURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: transactionsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .map {
                var operation = try decoder.decode(RecoveryOperation.self, from: Data(contentsOf: $0))
                let itemRoot = operationItemsURL(operation.id)
                if fileManager.fileExists(atPath: itemRoot.path) {
                    let items = try fileManager.contentsOfDirectory(at: itemRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        .filter { $0.pathExtension == "json" }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                        .map { try decoder.decode(RecoveryItem.self, from: Data(contentsOf: $0)) }
                    operation.touchedItems = (operation.touchedItems ?? []) + items
                }
                return operation
            }
            .filter { ![.completed, .rolledBack].contains($0.phase) }
    }

    private func ensureNoRecovery() throws {
        if try !pendingOperations().isEmpty { throw AIManagerError.recoveryRequired }
    }

    private func saveOperation(_ operation: RecoveryOperation) throws {
        if let items = operation.touchedItems, let last = items.last {
            let itemRoot = operationItemsURL(operation.id)
            try CoreSupport.privateDirectory(itemRoot, fileManager: fileManager)
            let name = String(format: "%09d.json", items.count - 1)
            try CoreSupport.atomicWrite(try encoder.encode(last), to: itemRoot.appending(path: name), fileManager: fileManager)
        }
        var header = operation
        header.touchedItems = nil
        try CoreSupport.atomicWrite(try encoder.encode(header), to: transactionsURL.appending(path: "\(operation.id.uuidString).json"), fileManager: fileManager)
    }

    private func finishOperation(_ operation: inout RecoveryOperation) throws {
        operation.phase = .completed
        try saveOperation(operation)
        try? fileManager.removeItem(at: operationItemsURL(operation.id))
    }

    private func inspectSource(_ selected: URL) -> DiscoveredSource {
        let home = CoreSupport.home(for: selected)
        let inspection = AuthInspection.inspect(home: selected, fileManager: fileManager)
        let settings = CoreSupport.settings.filter { CoreSupport.entryExists(home.appending(path: $0)) }
        let history = HistorySummary(
            activeTranscripts: transcriptCount(in: home.appending(path: "sessions")),
            archivedTranscripts: transcriptCount(in: home.appending(path: "archived_sessions")),
            hasIndexes: ["history.jsonl", "session_index.jsonl"].contains { fileManager.fileExists(atPath: home.appending(path: $0).path) }
        )
        return .init(
            id: CoreSupport.canonical(home).path,
            path: home,
            identity: inspection.identity,
            support: inspection.support,
            settings: settings,
            history: history,
            inspectionError: inspection.error
        )
    }

    private func transcriptCount(in root: URL) -> Int {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "jsonl" { count += 1 }
            if count >= 1_000_000 { break }
        }
        return count
    }

    private func buildManifest(source: URL, mode: ImportMode) throws -> [ManifestEntry] {
        var result: [ManifestEntry] = []
        var count = 0
        let topLevel = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [])
        for url in topLevel.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let relative = url.lastPathComponent
            let category = classify(relative)
            let categorySelected = category == .credential || (mode == .full && [.setting, .transcript, .database].contains(category))
            if categorySelected {
                try appendManifest(url: url, relative: relative, source: source, category: category, count: &count, result: &result)
            } else {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                let disposition = category == .historyIndex
                    ? "Codex rebuilds this local projection from shared transcripts"
                    : "excluded top-level \(category.rawValue) data; descendants were not inspected"
                result.append(.init(relativePath: relative, category: category, byteCount: Int64(values.fileSize ?? 0), selected: false, disposition: disposition))
            }
        }
        if !result.contains(where: { $0.relativePath == "auth.json" }) { throw AIManagerError.invalidSource("auth.json is missing") }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func appendManifest(url: URL, relative: String, source: URL, category: DataCategory, count: inout Int, result: inout [ManifestEntry]) throws {
        count += 1
        guard count <= 500_000 else { throw AIManagerError.invalidSource("Selected data exceeds the 500,000-entry inspection limit.") }
        guard CoreSupport.safeRelativePath(relative) else { throw AIManagerError.unsafePath(relative) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            guard let target = lexicalLinkTarget(url) else { throw AIManagerError.unsafePath("unreadable symbolic link \(relative)") }
            let external = !CoreSupport.isContained(target, by: source)
            result.append(.init(relativePath: relative, category: category, byteCount: Int64(values.fileSize ?? 0), selected: !external, disposition: external ? "external symbolic-link target requires explicit review" : "copy target content"))
            return
        }
        if values.isDirectory == true {
            let children = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [])
            if children.isEmpty { result.append(.init(relativePath: relative, category: category, byteCount: 0, selected: true, disposition: "import empty directory")) }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try appendManifest(url: child, relative: "\(relative)/\(child.lastPathComponent)", source: source, category: category, count: &count, result: &result)
            }
            return
        }
        guard values.isRegularFile == true else { throw AIManagerError.unsafePath("special file \(relative)") }
        let isSQLiteSidecar = category == .database && (relative.hasSuffix("-wal") || relative.hasSuffix("-shm"))
        result.append(.init(relativePath: relative, category: category, byteCount: Int64(values.fileSize ?? 0), selected: !isSQLiteSidecar, disposition: isSQLiteSidecar ? "included by the SQLite snapshot" : "import"))
    }

    private func classify(_ relativePath: String) -> DataCategory {
        let first = relativePath.split(separator: "/").first.map(String.init) ?? relativePath
        if first == "auth.json" { return .credential }
        if CoreSupport.settings.contains(first) { return .setting }
        if CoreSupport.historyDirectories.contains(first) { return .transcript }
        if CoreSupport.historyIndexes.contains(first) { return .historyIndex }
        if first.hasPrefix("goals") || first.hasPrefix("memories") { return .durableAuxiliary }
        if first.hasPrefix("logs_") || first.hasPrefix("queue_") || ["locks", "tmp", "queue", "runtime", "shell_snapshots"].contains(first) || first.hasSuffix(".sock") || first.hasSuffix(".pid") { return .runtime }
        if first.hasPrefix("state_") && (first.hasSuffix(".sqlite") || first.contains(".sqlite-")) || first.hasPrefix("thread_history_") && first.hasSuffix(".sqlite") { return .database }
        if ["packages", "logs", "cache", "models"].contains(first) { return .installation }
        if first.hasPrefix(".orca") { return .hostOwned }
        return .unknown
    }

    private func settingConflicts(source: URL) throws -> [SettingConflict] {
        var result: [SettingConflict] = []
        for relative in CoreSupport.settings {
            let imported = source.appending(path: relative)
            let shared = paths.sharedRoot.appending(path: relative)
            if let externalTarget = try firstExternalLink(imported, sourceRoot: source) {
                result.append(.init(relativePath: relative, importedDigest: "external-link-requires-review", sharedDigest: CoreSupport.entryExists(shared) ? "existing-shared-content" : "missing", externalTarget: externalTarget))
                continue
            }
            guard CoreSupport.entryExists(imported), CoreSupport.entryExists(shared) else { continue }
            try collectSettingConflicts(imported: imported, shared: shared, relative: relative, result: &result)
        }
        return result
    }

    private func collectSettingConflicts(imported: URL, shared: URL, relative: String, result: inout [SettingConflict]) throws {
        let importedValues = try imported.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let sharedValues = try shared.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if importedValues.isDirectory == true, importedValues.isSymbolicLink != true,
           sharedValues.isDirectory == true, sharedValues.isSymbolicLink != true {
            for child in try fileManager.contentsOfDirectory(at: imported, includingPropertiesForKeys: nil, options: []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let sharedChild = shared.appending(path: child.lastPathComponent)
                guard CoreSupport.entryExists(sharedChild) else { continue }
                try collectSettingConflicts(imported: child, shared: sharedChild, relative: "\(relative)/\(child.lastPathComponent)", result: &result)
            }
            return
        }
        let importedDigest = try treeDigest(imported)
        let sharedDigest = try treeDigest(shared)
        if importedDigest != sharedDigest {
            result.append(.init(relativePath: relative, importedDigest: importedDigest, sharedDigest: sharedDigest))
        }
    }

    private func sourceMayBeChanging(_ source: URL) throws -> Bool {
        let lockNames = [".codex.lock", "codex.lock", "app-server.lock"]
        return lockNames.contains { fileManager.fileExists(atPath: source.appending(path: $0).path) }
    }

    private func reviewedDataDigest(source: URL, mode: ImportMode, authDigest: String) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data(authDigest.utf8))
        guard mode == .full else { return hasher.finalize().map { String(format: "%02x", $0) }.joined() }
        for name in CoreSupport.settings {
            let entry = source.appending(path: name)
            if CoreSupport.entryExists(entry) { try updateSourceDigest(entry, relative: name, hasher: &hasher, depth: 0) }
        }
        hasher.update(data: Data(try transcriptFingerprint(source).utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func updateSourceDigest(_ url: URL, relative: String, hasher: inout SHA256, depth: Int) throws {
        guard depth < 64 else { throw AIManagerError.unsafePath("source tree depth exceeds 64") }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        hasher.update(data: Data(relative.utf8))
        if values.isSymbolicLink == true {
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { throw AIManagerError.unsafePath("broken symbolic link \(relative)") }
            hasher.update(data: Data(target.utf8))
        } else if values.isDirectory == true {
            for child in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try updateSourceDigest(child, relative: "\(relative)/\(child.lastPathComponent)", hasher: &hasher, depth: depth + 1)
            }
        } else if values.isRegularFile == true {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                var ended = false
                try autoreleasepool {
                    guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                    hasher.update(data: data)
                }
                if ended { break }
            }
        } else {
            throw AIManagerError.unsafePath("special file in reviewed settings")
        }
    }

    private func performImport(plan: ImportPlan, auth: Data, decisions: [String: ConflictChoice]) throws -> ImportResult {
        var registry = try loadRegistry()
        let matching = registry.accounts.firstIndex { sameIdentity($0.identity, plan.identity) }
        let keepExistingCredential = matching != nil && registry.accounts[matching!].credentialDigest != plan.sourceAuthDigest && decisions["auth.json"] == .keepShared
        if let matching, registry.accounts[matching].credentialDigest != plan.sourceAuthDigest,
           decisions["auth.json"] != .useImported, !keepExistingCredential { throw AIManagerError.credentialConflict }
        let destination = matching.map { registry.accounts[$0].home } ?? plan.destination
        let staging = paths.applicationSupport.appending(path: "staging/\(plan.id.uuidString)/home", directoryHint: .isDirectory)
        var operation = RecoveryOperation(id: plan.id, kind: "import", phase: .prepared, source: plan.source, destination: destination, backup: plan.backup, touchedItems: [], registryAccountID: matching.map { registry.accounts[$0].id } ?? plan.id, registryCredentialDigest: keepExistingCredential ? registry.accounts[matching!].credentialDigest : plan.sourceAuthDigest, previousAccount: matching.map { registry.accounts[$0] })
        try saveOperation(operation)
        try CoreSupport.privateDirectory(plan.backup, fileManager: fileManager)
        _ = try fileManager.contentsOfDirectory(atPath: plan.backup.path)

        if fileManager.fileExists(atPath: destination.path) {
            let saved = plan.backup.appending(path: "account-home", directoryHint: .isDirectory)
            try fileManager.copyItem(at: destination, to: saved)
        }
        operation.phase = .backedUp
        try saveOperation(operation)

        if fileManager.fileExists(atPath: staging.deletingLastPathComponent().path) {
            try fileManager.removeItem(at: staging.deletingLastPathComponent())
        }
        if matching != nil, fileManager.fileExists(atPath: destination.path) {
            try CoreSupport.privateDirectory(staging.deletingLastPathComponent(), fileManager: fileManager)
            try fileManager.copyItem(at: destination, to: staging)
        } else {
            try CoreSupport.privateDirectory(staging, fileManager: fileManager)
        }
        let selectedAuth = keepExistingCredential ? try Data(contentsOf: destination.appending(path: "auth.json")) : auth
        try CoreSupport.atomicWrite(selectedAuth, to: staging.appending(path: "auth.json"), fileManager: fileManager)

        for entry in CoreSupport.settings + CoreSupport.sharedHistoryEntries {
            let target = paths.sharedRoot.appending(path: entry)
            if !fileManager.fileExists(atPath: target.path), CoreSupport.historyDirectories.contains(entry) {
                try CoreSupport.privateDirectory(target, fileManager: fileManager)
            }
            if fileManager.fileExists(atPath: target.path) {
                let link = staging.appending(path: entry)
                if !CoreSupport.entryExists(link) { try fileManager.createSymbolicLink(at: link, withDestinationURL: target) }
            }
        }
        operation.phase = .staged
        try saveOperation(operation)

        var importedFiles = 1
        var importedChats = 0
        let reviewedExternal = plan.conflicts.filter { $0.externalTargetBytes != nil && decisions[$0.relativePath] == .useImported }.map(\.relativePath)
        var unresolved = plan.mode == .full ? plan.manifest.filter { entry in
            !entry.selected && !reviewedExternal.contains { entry.relativePath == $0 || entry.relativePath.hasPrefix($0 + "/") }
        }.map { "\($0.relativePath): \($0.disposition)" } : []
        if plan.mode == .full {
            for setting in CoreSupport.settings where CoreSupport.entryExists(plan.source.appending(path: setting)) {
                let source = plan.source.appending(path: setting)
                let destination = paths.sharedRoot.appending(path: setting)
                let externalConflict = plan.conflicts.first { $0.relativePath == setting && $0.externalTarget != nil }
                if externalConflict != nil, decisions[setting] == .keepShared {
                    if !CoreSupport.entryExists(destination) { unresolved.append("\(setting): kept shared choice, but the shared entry is missing") }
                    continue
                }
                let linkedDigest: String?
                if externalConflict != nil {
                    linkedDigest = try treeDigest(source)
                    try copyPortable(source, to: operation.backup.appending(path: "linked-source/\(setting)"))
                } else { linkedDigest = nil }
                importedFiles += try mergeSetting(
                    source: source,
                    destination: destination,
                    relative: setting,
                    rootChoice: externalConflict.flatMap { _ in decisions[setting] },
                    decisions: decisions,
                    operation: &operation
                )
                if let linkedDigest, try treeDigest(source) != linkedDigest { throw AIManagerError.sourceChanged }
                if !CoreSupport.entryExists(staging.appending(path: setting)) {
                    try fileManager.createSymbolicLink(at: staging.appending(path: setting), withDestinationURL: destination)
                }
            }
            try faultInjector(.duringHistoryCopy)
            let merge = try mergeHistory(from: plan.source, operation: &operation)
            guard try reviewedDataDigest(source: plan.source, mode: plan.mode, authDigest: plan.sourceAuthDigest) == plan.reviewedDataDigest else { throw AIManagerError.sourceChanged }
            importedChats = merge.imported
            importedFiles += merge.imported
            unresolved += merge.unresolved
            let databases = plan.manifest.filter { $0.category == .database && $0.selected && !$0.relativePath.contains("-wal") && !$0.relativePath.contains("-shm") }
            var databaseOutputs: [String: URL] = [:]
            for database in databases {
                let source = plan.source.appending(path: database.relativePath)
                let output = staging.appending(path: URL(fileURLWithPath: database.relativePath).lastPathComponent)
                do {
                    try SQLiteSupport.snapshot(source: source, destination: output)
                    try copyPortable(output, to: operation.backup.appending(path: "databases/\(database.relativePath)"))
                    databaseOutputs[database.relativePath] = output
                } catch {
                    if CoreSupport.entryExists(output) { try? fileManager.removeItem(at: output) }
                    unresolved.append("\(database.relativePath): database snapshot failed (\(error.localizedDescription))")
                }
            }
            let projectionDatabase = databaseOutputs
                .filter { $0.key.hasPrefix("thread_history_") && $0.key.hasSuffix(".sqlite") }
                .sorted { $0.key < $1.key }
                .first?.value
            for database in databases {
                guard let output = databaseOutputs[database.relativePath] else { continue }
                do {
                    let summary = try SQLiteSupport.rebaseRecognizedRolloutPaths(
                        database: output,
                        sourceHome: plan.source,
                        destinationHome: destination,
                        transcriptDestinations: merge.destinations,
                        projectionDatabase: projectionDatabase
                    )
                    if summary.excludedThreadCount > 0 {
                        unresolved.append("\(database.relativePath): excluded \(summary.excludedThreadCount) index rows without a retained transcript or complete projection")
                    }
                    if summary.retainedDatabaseOnlyThreadCount > 0 {
                        unresolved.append("\(database.relativePath): preserved \(summary.retainedDatabaseOnlyThreadCount) paginated threads from database projection only")
                    }
                    importedFiles += 1
                } catch {
                    if CoreSupport.entryExists(output) { try? fileManager.removeItem(at: output) }
                    unresolved.append("\(database.relativePath): unsupported or busy database (\(error.localizedDescription))")
                }
            }
        }

        operation.expectedDigest = try treeDigest(staging)
        operation.previousDigest = fileManager.fileExists(atPath: destination.path) ? try treeDigest(destination) : nil
        try saveOperation(operation)
        try CoreSupport.privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        try faultInjector(.afterHomePublication)
        operation.phase = .published
        try saveOperation(operation)

        let verification = VerificationResult(state: .imported, checkedAt: Date(), detail: "Credential format and private destination were verified offline.")
        let account = AccountRecord(
            id: matching.map { registry.accounts[$0].id } ?? plan.id,
            identity: plan.identity,
            home: destination,
            source: plan.source,
            importedAt: matching.map { registry.accounts[$0].importedAt } ?? Date(),
            verification: verification,
            credentialDigest: keepExistingCredential ? registry.accounts[matching!].credentialDigest : plan.sourceAuthDigest
        )
        if let matching { registry.accounts[matching] = account } else { registry.accounts.append(account) }
        try saveRegistry(registry)
        try faultInjector(.afterRegistryCommit)
        operation.phase = .registryCommitted
        try saveOperation(operation)
        try finishOperation(&operation)
        return .init(account: account, backup: plan.backup, importedFiles: importedFiles, importedChats: importedChats, unresolved: unresolved, verification: verification)
    }

    private func performSwitch(to accountID: UUID) throws -> SwitchResult {
        var registry = try loadRegistry()
        guard registry.accounts.contains(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }

        let defaultAuth = paths.defaultHome.appending(path: "auth.json")
        if (try? defaultAuth.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw AIManagerError.unsafePath("default auth.json is a symbolic link")
        }
        let outgoingInspection = AuthInspection.inspect(home: paths.defaultHome, fileManager: fileManager)
        var registeredOutgoingIndex: Int?
        var registeredOutgoingInspection: AuthInspection?
        if outgoingInspection.support == .supportedChatGPT, let identity = outgoingInspection.identity, identity.isResolved {
            if let currentID = registry.defaultAccountID,
               let index = registry.accounts.firstIndex(where: { $0.id == currentID }) {
                guard sameIdentity(registry.accounts[index].identity, identity) else { throw AIManagerError.credentialConflict }
                registeredOutgoingIndex = index
            } else {
                registeredOutgoingIndex = registry.accounts.firstIndex(where: { sameIdentity($0.identity, identity) })
            }
            if let index = registeredOutgoingIndex {
                let managed = AuthInspection.inspect(home: registry.accounts[index].home, fileManager: fileManager)
                guard managed.support == .supportedChatGPT, let managedIdentity = managed.identity,
                      sameIdentity(registry.accounts[index].identity, managedIdentity) else { throw AIManagerError.credentialConflict }
                let baseline = registry.accounts[index].credentialDigest
                let defaultChanged = outgoingInspection.digest != baseline
                let managedChanged = managed.digest != baseline
                if defaultChanged, managedChanged, outgoingInspection.digest != managed.digest {
                    throw AIManagerError.credentialConflict
                }
                registeredOutgoingInspection = managed
            }
        }
        let id = UUID()
        let backup = paths.applicationSupport.appending(path: "backups/\(id.uuidString)", directoryHint: .isDirectory)
        let originallySelected = registry.accounts.first(where: { $0.id == accountID })!
        var operation = RecoveryOperation(id: id, kind: "switch", phase: .prepared, source: originallySelected.home.appending(path: "auth.json"), destination: defaultAuth, backup: backup, touchedItems: [], previousDigest: outgoingInspection.digest.isEmpty ? nil : outgoingInspection.digest, registryAccountID: accountID, previousDefaultAccountID: registry.defaultAccountID ?? registeredOutgoingIndex.map { registry.accounts[$0].id })
        try saveOperation(operation)
        try CoreSupport.privateDirectory(backup, fileManager: fileManager)
        if fileManager.fileExists(atPath: defaultAuth.path) {
            let saved = backup.appending(path: "auth.json")
            try copyPortable(defaultAuth, to: saved)
        }
        operation.phase = .backedUp
        try saveOperation(operation)
        if let outgoingIndex = registeredOutgoingIndex, let managed = registeredOutgoingInspection {
            let baseline = registry.accounts[outgoingIndex].credentialDigest
            let defaultChanged = outgoingInspection.digest != baseline
            let managedChanged = managed.digest != baseline
            if defaultChanged, !managedChanged {
                operation.previousAccount = registry.accounts[outgoingIndex]
                try replaceRecoverably(source: defaultAuth, destination: registry.accounts[outgoingIndex].home.appending(path: "auth.json"), operation: &operation, backupName: "outgoing-managed-auth.json")
                registry.accounts[outgoingIndex].credentialDigest = outgoingInspection.digest
            } else if managedChanged {
                registry.accounts[outgoingIndex].credentialDigest = managed.digest
            }
            registry.defaultAccountID = registry.accounts[outgoingIndex].id
            try saveRegistry(registry)
            try saveOperation(operation)
        } else if outgoingInspection.support == .supportedChatGPT, let identity = outgoingInspection.identity, identity.isResolved {
                let outgoingID = UUID()
                let outgoingHome = paths.applicationSupport.appending(path: "accounts/\(outgoingID.uuidString)/home")
                try createManagedHome(auth: outgoingInspection.data, at: outgoingHome)
                registry.accounts.append(.init(id: outgoingID, identity: identity, home: outgoingHome, source: paths.defaultHome, importedAt: Date(), verification: .init(state: .imported, checkedAt: Date(), detail: "Captured before changing the default account."), credentialDigest: outgoingInspection.digest))
                registry.defaultAccountID = outgoingID
                operation.previousDefaultAccountID = outgoingID
            try saveRegistry(registry)
            try saveOperation(operation)
        }

        guard let incomingIndex = registry.accounts.firstIndex(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }
        let incoming = registry.accounts[incomingIndex]
        let incomingInspection = AuthInspection.inspect(home: incoming.home, fileManager: fileManager)
        guard incomingInspection.support == .supportedChatGPT, let incomingIdentity = incomingInspection.identity,
              sameIdentity(incoming.identity, incomingIdentity) else { throw AIManagerError.credentialConflict }
        if registry.defaultAccountID == accountID, outgoingInspection.digest == incomingInspection.digest {
            try finishOperation(&operation)
            return .init(accountID: accountID, backup: backup, previousAccountID: accountID)
        }
        let recheck = AuthInspection.inspect(home: paths.defaultHome, fileManager: fileManager)
        guard recheck.digest == outgoingInspection.digest else { throw AIManagerError.sourceChanged }
        operation.expectedDigest = incomingInspection.digest
        try saveOperation(operation)
        try CoreSupport.atomicWrite(incomingInspection.data, to: defaultAuth, fileManager: fileManager)
        try faultInjector(.afterDefaultCredentialPublication)
        operation.phase = .published
        try saveOperation(operation)
        guard AuthInspection.inspect(home: paths.defaultHome, fileManager: fileManager).digest == incomingInspection.digest else {
            throw AIManagerError.operationFailed("The committed default credential did not verify.")
        }
        let previous = registry.defaultAccountID
        registry.defaultAccountID = accountID
        registry.accounts[incomingIndex].lastUsedAt = Date()
        try saveRegistry(registry)
        try faultInjector(.afterRegistryCommit)
        operation.phase = .registryCommitted
        try saveOperation(operation)
        try finishOperation(&operation)
        return .init(accountID: accountID, backup: backup, previousAccountID: previous)
    }

    private func createManagedHome(auth: Data, at home: URL) throws {
        try CoreSupport.privateDirectory(home, fileManager: fileManager)
        try CoreSupport.atomicWrite(auth, to: home.appending(path: "auth.json"), fileManager: fileManager)
        for entry in CoreSupport.settings + CoreSupport.sharedHistoryEntries {
            let target = paths.sharedRoot.appending(path: entry)
            guard fileManager.fileExists(atPath: target.path) else { continue }
            try fileManager.createSymbolicLink(at: home.appending(path: entry), withDestinationURL: target)
        }
    }

    private func sameIdentity(_ lhs: AccountIdentity, _ rhs: AccountIdentity) -> Bool {
        guard lhs.authMode == rhs.authMode else { return false }
        if let left = lhs.accountID, let right = rhs.accountID { return left == right && lhs.workspaceID == rhs.workspaceID }
        return lhs.email != nil && lhs.email == rhs.email && lhs.workspaceID != nil && lhs.workspaceID == rhs.workspaceID
    }

    private func resolveExecutable() -> URL? {
        if let explicit = paths.codexExecutable, fileManager.isExecutableFile(atPath: explicit.path) { return explicit }
        if paths.isolationRoot != nil { return nil }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appending(path: "codex")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func lexicalLinkTarget(_ link: URL) -> URL? {
        guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL }
        return link.deletingLastPathComponent().appending(path: raw).standardizedFileURL
    }

    private func link(_ link: URL, pointsTo intendedTarget: URL) -> Bool {
        guard let target = lexicalLinkTarget(link) else { return false }
        return CoreSupport.canonical(target).pathComponents == CoreSupport.canonical(intendedTarget).pathComponents
    }

    private func inspectLinkedSettings(accounts: [AccountRecord]) throws -> [LinkedSettingsDivergence] {
        var result: [LinkedSettingsDivergence] = []
        let backupRoot = paths.applicationSupport.appending(path: "backups/settings-link-repair", directoryHint: .isDirectory)
        for account in accounts {
            for relativePath in CoreSupport.settings {
                let intendedTarget = paths.sharedRoot.appending(path: relativePath).standardizedFileURL
                guard CoreSupport.entryExists(intendedTarget) else { continue }
                let localPath = account.home.appending(path: relativePath)
                if link(localPath, pointsTo: intendedTarget) { continue }
                result.append(.init(
                    accountID: account.id,
                    relativePath: relativePath,
                    localPath: localPath,
                    intendedTarget: intendedTarget,
                    localFingerprint: try linkedSettingFingerprint(localPath),
                    backupRoot: backupRoot
                ))
            }
        }
        return result
    }

    private func linkedSettingFingerprint(_ url: URL) throws -> String {
        var hasher = SHA256()
        guard CoreSupport.entryExists(url) else {
            hasher.update(data: Data("missing".utf8))
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
                throw AIManagerError.unsafePath("unreadable settings link \(url.lastPathComponent)")
            }
            hasher.update(data: Data("link:\(raw)".utf8))
        } else {
            try updateSourceDigest(url, relative: url.lastPathComponent, hasher: &hasher, depth: 0)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func containsExternalLink(_ root: URL, sourceRoot: URL) throws -> Bool {
        try firstExternalLink(root, sourceRoot: sourceRoot) != nil
    }

    private func firstExternalLink(_ root: URL, sourceRoot: URL) throws -> URL? {
        guard CoreSupport.entryExists(root) else { return nil }
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if rootValues.isSymbolicLink == true {
            guard let target = lexicalLinkTarget(root) else { throw AIManagerError.unsafePath("broken symbolic link") }
            return CoreSupport.isContained(target, by: sourceRoot) ? nil : target
        }
        guard rootValues.isDirectory == true,
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return nil }
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            guard count <= 500_000 else { throw AIManagerError.invalidSource("A settings tree exceeds the inspection limit.") }
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                enumerator.skipDescendants()
                guard let target = lexicalLinkTarget(url) else { throw AIManagerError.unsafePath("broken symbolic link") }
                if !CoreSupport.isContained(target, by: sourceRoot) { return target }
            }
        }
        return nil
    }

    private func treeDigest(_ root: URL) throws -> String {
        var hasher = SHA256()
        var visited = Set<String>()
        try updateDigest(root, relative: "", hasher: &hasher, visited: &visited, depth: 0)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func updateDigest(_ url: URL, relative: String, hasher: inout SHA256, visited: inout Set<String>, depth: Int) throws {
        guard depth < 64 else { throw AIManagerError.unsafePath("symbolic-link depth exceeds 64") }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        if values.isSymbolicLink == true {
            guard let target = lexicalLinkTarget(url) else { throw AIManagerError.unsafePath("broken symbolic link") }
            let key = CoreSupport.canonical(target).path
            guard visited.insert(key).inserted else { throw AIManagerError.unsafePath("symbolic-link cycle") }
            try updateDigest(target, relative: relative, hasher: &hasher, visited: &visited, depth: depth + 1)
            visited.remove(key)
            return
        }
        hasher.update(data: Data(relative.utf8))
        if values.isDirectory == true {
            let children = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let childRelative = relative.isEmpty ? child.lastPathComponent : "\(relative)/\(child.lastPathComponent)"
                try updateDigest(child, relative: childRelative, hasher: &hasher, visited: &visited, depth: depth + 1)
            }
        } else if values.isRegularFile == true {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                var ended = false
                try autoreleasepool {
                    guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                    hasher.update(data: data)
                }
                if ended { break }
            }
        } else {
            throw AIManagerError.unsafePath("special file in selected data")
        }
    }

    private func copyPortable(_ source: URL, to destination: URL, visited: Set<String> = [], depth: Int = 0) throws {
        guard depth < 64 else { throw AIManagerError.unsafePath("symbolic-link depth exceeds 64") }
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        if values.isSymbolicLink == true {
            guard let target = lexicalLinkTarget(source) else { throw AIManagerError.unsafePath("broken symbolic link") }
            let key = CoreSupport.canonical(target).path
            guard !visited.contains(key) else { throw AIManagerError.unsafePath("symbolic-link cycle") }
            var next = visited
            next.insert(key)
            try copyPortable(target, to: destination, visited: next, depth: depth + 1)
        } else if values.isDirectory == true {
            try CoreSupport.privateDirectory(destination, fileManager: fileManager)
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: []) {
                try copyPortable(child, to: destination.appending(path: child.lastPathComponent), visited: visited, depth: depth + 1)
            }
        } else if values.isRegularFile == true {
            try CoreSupport.privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
            try fileManager.copyItem(at: source, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } else {
            throw AIManagerError.unsafePath("special file cannot be copied")
        }
    }

    private func portableLogicalSize(_ root: URL) throws -> Int64 {
        var count = 0
        var visited = Set<String>()
        return try portableLogicalSize(root, count: &count, visited: &visited, depth: 0)
    }

    private func portableLogicalSize(_ url: URL, count: inout Int, visited: inout Set<String>, depth: Int) throws -> Int64 {
        guard depth < 64 else { throw AIManagerError.unsafePath("symbolic-link depth exceeds 64") }
        count += 1
        guard count <= 500_000 else { throw AIManagerError.invalidSource("Linked data exceeds the 500,000-entry review limit.") }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            guard let target = lexicalLinkTarget(url) else { throw AIManagerError.unsafePath("broken symbolic link") }
            let key = CoreSupport.canonical(target).path
            guard visited.insert(key).inserted else { throw AIManagerError.unsafePath("symbolic-link cycle") }
            defer { visited.remove(key) }
            return try portableLogicalSize(target, count: &count, visited: &visited, depth: depth + 1)
        }
        if values.isDirectory == true {
            return try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []).reduce(Int64(0)) { total, child in
                let size = try portableLogicalSize(child, count: &count, visited: &visited, depth: depth + 1)
                let (sum, overflow) = total.addingReportingOverflow(size)
                guard !overflow else { throw AIManagerError.invalidSource("Linked data size overflowed.") }
                return sum
            }
        }
        guard values.isRegularFile == true else { throw AIManagerError.unsafePath("special file in linked data") }
        return Int64(values.fileSize ?? 0)
    }

    private func replaceRecoverably(source: URL, destination: URL, operation: inout RecoveryOperation, backupName: String) throws {
        let backup = operation.backup.appending(path: backupName)
        let hadDestination = CoreSupport.entryExists(destination)
        if hadDestination {
            try CoreSupport.privateDirectory(backup.deletingLastPathComponent(), fileManager: fileManager)
            try copyPortable(destination, to: backup)
        }
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(operation.id.uuidString).stage")
        if fileManager.fileExists(atPath: temporary.path) { try fileManager.removeItem(at: temporary) }
        let previous = hadDestination ? try treeDigest(destination) : nil
        if operation.touchedItems == nil { operation.touchedItems = [] }
        operation.touchedItems!.append(.init(destination: destination, backup: hadDestination ? backup : nil, expectedDigest: "", previousDigest: previous, temporary: temporary))
        try saveOperation(operation)
        try copyPortable(source, to: temporary)
        try faultInjector(.afterTemporaryCopy)
        let expected = try treeDigest(temporary)
        operation.touchedItems![operation.touchedItems!.count - 1].expectedDigest = expected
        try saveOperation(operation)
        try CoreSupport.privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        if hadDestination { _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: []) }
        else { try fileManager.moveItem(at: temporary, to: destination) }
    }

    private func mergeSetting(
        source: URL,
        destination: URL,
        relative: String,
        rootChoice: ConflictChoice?,
        decisions: [String: ConflictChoice],
        operation: inout RecoveryOperation
    ) throws -> Int {
        guard CoreSupport.entryExists(destination) else {
            try replaceRecoverably(source: source, destination: destination, operation: &operation, backupName: "shared-created/\(relative)")
            return 1
        }
        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let destinationValues = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true,
           destinationValues.isDirectory == true, destinationValues.isSymbolicLink != true {
            var imported = 0
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                imported += try mergeSetting(
                    source: child,
                    destination: destination.appending(path: child.lastPathComponent),
                    relative: "\(relative)/\(child.lastPathComponent)",
                    rootChoice: rootChoice,
                    decisions: decisions,
                    operation: &operation
                )
            }
            return imported
        }
        guard try treeDigest(source) != treeDigest(destination) else { return 0 }
        switch decisions[relative] ?? rootChoice {
        case .keepShared: return 0
        case .useImported:
            try replaceRecoverably(source: source, destination: destination, operation: &operation, backupName: "shared/\(relative)")
            return 1
        case nil:
            throw AIManagerError.missingConflictDecisions([relative])
        }
    }

    private func transcriptFingerprint(_ source: URL) throws -> String {
        var hasher = SHA256()
        for name in CoreSupport.historyDirectories {
            let root = source.appending(path: name)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            if try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { continue }
            while let url = enumerator.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                hasher.update(data: Data(url.path.dropFirst(source.path.count).utf8))
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while true {
                    var ended = false
                    try autoreleasepool {
                        guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                        hasher.update(data: data)
                    }
                    if ended { break }
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct TranscriptInfo {
        var url: URL
        var identity: String
        var recordCount: Int
        var contentDigest: String
        var archived: Bool
    }

    private func transcriptInfo(_ url: URL, archived: Bool) throws -> TranscriptInfo? {
        let reader = try JSONLReader(url: url)
        var hasher = SHA256()
        var count = 0
        var identity: String?
        while true {
            var ended = false
            var discoveredIdentity: String?
            try autoreleasepool {
                guard let record = try reader.next() else { ended = true; return }
                if identity == nil, count < 20 {
                    guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any] else { throw AIManagerError.invalidSource("Malformed JSONL transcript metadata in \(url.lastPathComponent)") }
                    if let payload = object["payload"] as? [String: Any], let id = payload["id"] as? String { discoveredIdentity = id }
                    else { discoveredIdentity = object["id"] as? String }
                }
                hasher.update(data: record)
                hasher.update(data: Data([0x0A]))
                count += 1
            }
            if ended { break }
            if let discoveredIdentity { identity = discoveredIdentity }
        }
        guard count > 0 else { return nil }
        guard let identity, !identity.isEmpty else { return nil }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .init(url: url, identity: identity, recordCount: count, contentDigest: digest, archived: archived)
    }

    private func transcriptFiles(_ root: URL, archived: Bool) throws -> [TranscriptInfo] {
        guard fileManager.fileExists(atPath: root.path),
              (try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [] }
        var result: [TranscriptInfo] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true, url.pathExtension == "jsonl", let info = try transcriptInfo(url, archived: archived) { result.append(info) }
        }
        return result
    }

    private func mergeHistory(from sourceHome: URL, operation: inout RecoveryOperation) throws -> (imported: Int, unresolved: [String], destinations: [String: String]) {
        var existing: [String: TranscriptInfo] = [:]
        for (name, archived) in [("sessions", false), ("archived_sessions", true)] {
            for info in try transcriptFiles(paths.sharedRoot.appending(path: name), archived: archived) { existing[info.identity] = info }
        }
        var imported = 0
        var unresolved: [String] = []
        for (name, archived) in [("sessions", false), ("archived_sessions", true)] {
            let sourceRoot = sourceHome.appending(path: name)
            for incoming in try transcriptFiles(sourceRoot, archived: archived) {
                if try file(incoming.url, contains: Data(sourceHome.path.utf8)) {
                    unresolved.append("\(incoming.identity): transcript retains a source path needed for resume context")
                }
                if let current = existing[incoming.identity] {
                    if current.archived != incoming.archived {
                        try preserveConflict(incoming.url, identity: incoming.identity, operation: operation)
                        unresolved.append("\(incoming.identity): active/archive classification conflict")
                    } else if current.recordCount == incoming.recordCount, current.contentDigest == incoming.contentDigest {
                        continue
                    } else if incoming.recordCount > current.recordCount, try transcript(current.url, isPrefixOf: incoming.url, recordCount: current.recordCount) {
                        try replaceRecoverably(source: incoming.url, destination: current.url, operation: &operation, backupName: "history/\(incoming.identity).jsonl")
                        existing[incoming.identity] = .init(url: current.url, identity: incoming.identity, recordCount: incoming.recordCount, contentDigest: incoming.contentDigest, archived: incoming.archived)
                        imported += 1
                    } else if current.recordCount > incoming.recordCount, try transcript(incoming.url, isPrefixOf: current.url, recordCount: incoming.recordCount) {
                        continue
                    } else {
                        try preserveConflict(incoming.url, identity: incoming.identity, operation: operation)
                        unresolved.append("\(incoming.identity): divergent transcript preserved in backup")
                    }
                } else {
                    let sourceComponents = sourceRoot.standardizedFileURL.pathComponents
                    let incomingComponents = incoming.url.standardizedFileURL.pathComponents
                    let relative = incomingComponents.dropFirst(sourceComponents.count).joined(separator: "/")
                    guard CoreSupport.safeRelativePath(relative) else { throw AIManagerError.unsafePath(relative) }
                    let destination = paths.sharedRoot.appending(path: name).appending(path: relative)
                    if fileManager.fileExists(atPath: destination.path) {
                        try preserveConflict(incoming.url, identity: incoming.identity, operation: operation)
                        unresolved.append("\(incoming.identity): filename collision with a different transcript identity")
                    } else {
                        try replaceRecoverably(source: incoming.url, destination: destination, operation: &operation, backupName: "history-created/\(incoming.identity).jsonl")
                        existing[incoming.identity] = .init(url: destination, identity: incoming.identity, recordCount: incoming.recordCount, contentDigest: incoming.contentDigest, archived: archived)
                        imported += 1
                    }
                }
            }
            let auxiliary = try mergeAuxiliaryHistoryFiles(sourceRoot: sourceRoot, destinationRoot: paths.sharedRoot.appending(path: name), operation: &operation)
            imported += auxiliary.imported
            unresolved += auxiliary.unresolved
        }
        let sharedComponents = paths.sharedRoot.standardizedFileURL.pathComponents
        var destinations: [String: String] = [:]
        for (identity, info) in existing {
            let components = info.url.standardizedFileURL.pathComponents
            guard components.count > sharedComponents.count,
                  Array(components.prefix(sharedComponents.count)) == sharedComponents else { continue }
            let relative = components.dropFirst(sharedComponents.count).joined(separator: "/")
            if CoreSupport.safeRelativePath(relative), relative.hasPrefix("sessions/") || relative.hasPrefix("archived_sessions/") {
                destinations[identity] = relative
            }
        }
        return (imported, unresolved, destinations)
    }

    private func transcript(_ prefix: URL, isPrefixOf complete: URL, recordCount: Int) throws -> Bool {
        let prefixReader = try JSONLReader(url: prefix)
        let completeReader = try JSONLReader(url: complete)
        for _ in 0..<recordCount {
            let equal = try autoreleasepool {
                guard let left = try prefixReader.next(), let right = try completeReader.next() else { return false }
                return left == right
            }
            guard equal else { return false }
        }
        return try prefixReader.next() == nil
    }

    private func file(_ url: URL, contains needle: Data) throws -> Bool {
        guard !needle.isEmpty else { return true }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var overlap = Data()
        while true {
            var ended = false
            var found = false
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { ended = true; return }
                var window = overlap
                window.append(chunk)
                found = window.range(of: needle) != nil
                overlap = Data(window.suffix(max(0, needle.count - 1)))
            }
            if found { return true }
            if ended { break }
        }
        return false
    }

    private func mergeAuxiliaryHistoryFiles(sourceRoot: URL, destinationRoot: URL, operation: inout RecoveryOperation) throws -> (imported: Int, unresolved: [String]) {
        guard fileManager.fileExists(atPath: sourceRoot.path),
              (try sourceRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let enumerator = fileManager.enumerator(at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return (0, []) }
        var imported = 0
        var unresolved: [String] = []
        while let source = enumerator.nextObject() as? URL {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, source.pathExtension != "jsonl" else { continue }
            let base = sourceRoot.standardizedFileURL.pathComponents
            let components = source.standardizedFileURL.pathComponents
            let relative = components.dropFirst(base.count).joined(separator: "/")
            guard CoreSupport.safeRelativePath(relative) else { throw AIManagerError.unsafePath(relative) }
            let destination = destinationRoot.appending(path: relative)
            if !fileManager.fileExists(atPath: destination.path) {
                try replaceRecoverably(source: source, destination: destination, operation: &operation, backupName: "history-created-files/\(relative)")
                imported += 1
            } else if try treeDigest(source) != treeDigest(destination) {
                let preserved = operation.backup.appending(path: "conflicts/files/\(relative)")
                try copyPortable(source, to: preserved)
                unresolved.append("\(relative): divergent referenced file preserved in backup")
            }
        }
        return (imported, unresolved)
    }

    private func preserveConflict(_ source: URL, identity: String, operation: RecoveryOperation) throws {
        let safe = identity.replacingOccurrences(of: "/", with: "_")
        let destination = operation.backup.appending(path: "conflicts/\(safe)/\(source.lastPathComponent)")
        try CoreSupport.privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        try copyPortable(source, to: destination)
    }

    private func recoverOperation(_ operation: RecoveryOperation) throws -> RecoveryResult {
        var operation = operation
        var registry = try loadRegistry()
        let registryCommitted: Bool
        if operation.kind == "switch" {
            registryCommitted = registry.defaultAccountID == operation.registryAccountID
        } else if let accountID = operation.registryAccountID, let expectedCredential = operation.registryCredentialDigest {
            registryCommitted = registry.accounts.first(where: { $0.id == accountID })?.credentialDigest == expectedCredential
        } else {
            registryCommitted = false
        }
        let currentDigest = fileManager.fileExists(atPath: operation.destination.path) ? try? treeDigest(operation.destination) : nil
        if registryCommitted, currentDigest == operation.expectedDigest {
            try finishOperation(&operation)
            return .init(operationID: operation.id, outcome: .completed, message: "The published files and registry agree; recovery finalized the operation.")
        }

        if let expected = operation.expectedDigest {
            if currentDigest == expected {
                if fileManager.fileExists(atPath: operation.destination.path) { try fileManager.removeItem(at: operation.destination) }
            } else if currentDigest != nil, currentDigest != operation.previousDigest {
                operation.phase = .conflicted
                try saveOperation(operation)
                return .init(operationID: operation.id, outcome: .conflict, message: "Later edits were preserved; choose a recovery version.")
            }
        }

        var conflict = false
        for item in (operation.touchedItems ?? []).reversed() {
            if let temporary = item.temporary, fileManager.fileExists(atPath: temporary.path) {
                let preserved = operation.backup.appending(path: "interrupted-staging/\(UUID().uuidString)-\(temporary.lastPathComponent)")
                try CoreSupport.privateDirectory(preserved.deletingLastPathComponent(), fileManager: fileManager)
                do { try fileManager.moveItem(at: temporary, to: preserved) }
                catch { try copyPortable(temporary, to: preserved); try fileManager.removeItem(at: temporary) }
            }
            if fileManager.fileExists(atPath: item.destination.path) {
                let current = try? treeDigest(item.destination)
                if current == item.expectedDigest { try fileManager.removeItem(at: item.destination) }
                else if current == item.previousDigest { continue }
                else { conflict = true; continue }
            }
            if let backup = item.backup, fileManager.fileExists(atPath: backup.path) {
                try copyPortable(backup, to: item.destination)
            }
        }
        if operation.expectedDigest != nil {
            if !conflict, !fileManager.fileExists(atPath: operation.destination.path) {
                let prior = operation.backup.appending(path: operation.kind == "switch" ? "auth.json" : "account-home")
                if fileManager.fileExists(atPath: prior.path) {
                    if operation.kind == "import" { try fileManager.copyItem(at: prior, to: operation.destination) }
                    else { try copyPortable(prior, to: operation.destination) }
                }
            }
        }
        guard !conflict else {
            operation.phase = .conflicted; try saveOperation(operation)
            return .init(operationID: operation.id, outcome: .conflict, message: "Later edits were preserved; choose a recovery version.")
        }
        if registryCommitted {
            if operation.kind == "switch" {
                registry.defaultAccountID = operation.previousDefaultAccountID
                if let previous = operation.previousAccount,
                   let index = registry.accounts.firstIndex(where: { $0.id == previous.id }) {
                    registry.accounts[index] = previous
                }
            } else if let accountID = operation.registryAccountID {
                if let previous = operation.previousAccount, let index = registry.accounts.firstIndex(where: { $0.id == accountID }) {
                    registry.accounts[index] = previous
                } else {
                    registry.accounts.removeAll { $0.id == accountID }
                }
            }
            try saveRegistry(registry)
        }
        let staging = paths.applicationSupport.appending(path: "staging/\(operation.id.uuidString)")
        if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
        operation.phase = .rolledBack
        try saveOperation(operation)
        try? fileManager.removeItem(at: operationItemsURL(operation.id))
        return .init(operationID: operation.id, outcome: .rolledBack, message: "The incomplete operation was rolled back.")
    }
}
