import CryptoKit
import Darwin
import Foundation

enum CoreSupport {
    static let settings = ["config.toml", "AGENTS.md", "agents", "rules", "context", "skills", "hooks.json"]
    static let historyDirectories = ["sessions", "archived_sessions"]
    static let historyIndexes = ["history.jsonl", "session_index.jsonl"]
    static let sharedHistoryEntries = historyDirectories + historyIndexes
    static let maxAuthBytes = 2 * 1_024 * 1_024

    static func home(for selected: URL) -> URL {
        selected.lastPathComponent == "auth.json" ? selected.deletingLastPathComponent() : selected
    }

    static func canonical(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var existing = standardized
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix { resolved.append(path: component) }
        return resolved.standardizedFileURL
    }

    static func isContained(_ candidate: URL, by parent: URL) -> Bool {
        let candidateParts = canonical(candidate).pathComponents
        let parentParts = canonical(parent).pathComponents
        return candidateParts.count >= parentParts.count && Array(candidateParts.prefix(parentParts.count)) == parentParts
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            var ended = false
            try autoreleasepool {
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                hasher.update(data: data)
            }
            if ended { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func privateDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func atomicWrite(_ data: Data, to destination: URL, permissions: Int = 0o600, fileManager: FileManager) throws {
        try privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

struct AuthInspection {
    let data: Data
    let digest: String
    let identity: AccountIdentity?
    let support: SourceSupport
    let error: String?

    static func inspect(home selected: URL, fileManager: FileManager) -> Self {
        let home = CoreSupport.home(for: selected)
        let auth = selected.lastPathComponent == "auth.json" ? selected : home.appending(path: "auth.json")
        guard fileManager.fileExists(atPath: auth.path) else {
            let config = home.appending(path: "config.toml")
            if let values = try? config.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
               let size = values.fileSize, size <= 1_048_576,
               let text = try? String(contentsOf: config, encoding: .utf8),
               text.contains("cli_auth_credentials_store"), text.contains("keyring") {
                return .init(data: Data(), digest: "", identity: nil, support: .keychainOnly, error: "This home is configured for Keychain-only credentials. Use Codex sign-in with file storage for a managed profile.")
            }
            return .init(data: Data(), digest: "", identity: nil, support: .missingAuth, error: "auth.json is missing. Sign in with Codex or choose another source.")
        }
        do {
            let values = try auth.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                return .init(data: Data(), digest: "", identity: nil, support: .malformedAuth, error: "auth.json is not a regular file.")
            }
            guard let count = values.fileSize, count <= CoreSupport.maxAuthBytes else {
                return .init(data: Data(), digest: "", identity: nil, support: .malformedAuth, error: "auth.json exceeds the 2 MiB inspection limit.")
            }
            let data = try Data(contentsOf: auth, options: .mappedIfSafe)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any] else { throw AIManagerError.invalidSource("auth.json must contain a JSON object") }
            let tokens = root["tokens"] as? [String: Any]
            let hasChatGPT = ["access_token", "refresh_token", "id_token"].contains { tokens?[$0] is String }
            let apiKey = (root["OPENAI_API_KEY"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (root["openai_api_key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let mode: AuthMode = hasChatGPT ? .chatGPT : (apiKey == nil ? .unknown : .apiKey)
            let support: SourceSupport = hasChatGPT ? .supportedChatGPT : (apiKey == nil ? .unknown : .apiKey)
            let claims = decodeClaims(tokens?["id_token"] as? String) ?? decodeClaims(tokens?["access_token"] as? String) ?? [:]
            if hasChatGPT, claims.isEmpty {
                return .init(data: Data(), digest: "", identity: nil, support: .malformedAuth, error: "ChatGPT token metadata is malformed.")
            }
            let accountID = string(tokens?["account_id"]) ?? findString(in: claims, keys: ["chatgpt_account_id", "account_id"])
            let identity = AccountIdentity(
                email: findString(in: claims, keys: ["email", "preferred_username"]),
                accountID: accountID,
                workspaceID: findString(in: claims, keys: ["workspace_id", "organization_id", "org_id"]),
                authMode: mode
            )
            let message = support == .unknown ? "Credential format is not a supported file-based ChatGPT or API-key shape." : nil
            return .init(data: data, digest: CoreSupport.digest(data), identity: identity, support: support, error: message)
        } catch {
            return .init(data: Data(), digest: "", identity: nil, support: .malformedAuth, error: "auth.json could not be inspected: \(safeError(error))")
        }
    }

    private static func decodeClaims(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), data.count <= CoreSupport.maxAuthBytes,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value
    }

    private static func findString(in value: Any, keys: Set<String>, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        if let dictionary = value as? [String: Any] {
            for (key, item) in dictionary where keys.contains(key) {
                if let result = string(item) { return result }
            }
            for item in dictionary.values {
                if let result = findString(in: item, keys: keys, depth: depth + 1) { return result }
            }
        } else if let array = value as? [Any] {
            for item in array.prefix(100) {
                if let result = findString(in: item, keys: keys, depth: depth + 1) { return result }
            }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let result = value as? String, !result.isEmpty else { return nil }
        return result
    }

    private static func safeError(_ error: Error) -> String {
        if error is CocoaError { return "permission denied, unreadable, or malformed data" }
        return "unsupported data"
    }
}

final class OperationLock: @unchecked Sendable {
    private let descriptor: Int32

    init(at url: URL, fileManager: FileManager) throws {
        try CoreSupport.privateDirectory(url.deletingLastPathComponent(), fileManager: fileManager)
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AIManagerError.operationFailed("Could not open the operation lock.") }
    }

    deinit { close(descriptor) }

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AIManagerError.operationFailed("Another AI Manager process is changing accounts.") }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
