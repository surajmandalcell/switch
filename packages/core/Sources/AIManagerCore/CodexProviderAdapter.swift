import Foundation

struct CodexProviderAdapter {
    let fileManager: FileManager
    let id = ProviderID.codex

    func discoveryCandidates(paths: ManagerPaths, explicit: URL?) -> [URL] {
        var candidates = [
            paths.defaultHome,
            paths.defaultHome.deletingLastPathComponent().appending(path: ".codex2")
        ]
        if let homes = try? fileManager.contentsOfDirectory(
            at: paths.orcaAccountsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates += homes.map { $0.appending(path: "home", directoryHint: .isDirectory) }
        }
        if let explicit { candidates.append(CoreSupport.home(for: explicit)) }
        return candidates
    }

    func sameIdentity(_ lhs: AccountIdentity, _ rhs: AccountIdentity) -> Bool {
        guard lhs.providerID == id, rhs.providerID == id, lhs.authMode == rhs.authMode else {
            return false
        }
        guard lhs.authMode == .chatGPT,
              let leftUser = lhs.userID, let rightUser = rhs.userID,
              let leftAccount = lhs.accountID, let rightAccount = rhs.accountID else {
            return false
        }
        return leftUser == rightUser
            && leftAccount == rightAccount
            && lhs.workspaceID == rhs.workspaceID
    }

    func requireSupported(_ providerID: ProviderID) throws {
        guard providerID == id else {
            throw AIManagerError.unsupportedSource("Provider \(providerID.rawValue) is not supported by this release.")
        }
    }

    func inspect(home selected: URL) -> AuthInspection {
        let home = CoreSupport.home(for: selected)
        let auth = selected.lastPathComponent == "auth.json" ? selected : home.appending(path: "auth.json")
        guard fileManager.fileExists(atPath: auth.path) else {
            let config = home.appending(path: "config.toml")
            if let values = try? config.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576,
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
            guard let root = object as? [String: Any] else {
                throw AIManagerError.invalidSource("auth.json must contain a JSON object")
            }
            let tokens = root["tokens"] as? [String: Any]
            let hasChatGPT = ["access_token", "refresh_token", "id_token"].contains {
                tokens?[$0] is String
            }
            let apiKey = (root["OPENAI_API_KEY"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (root["openai_api_key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let mode: AuthMode = hasChatGPT ? .chatGPT : (apiKey == nil ? .unknown : .apiKey)
            let support: SourceSupport = hasChatGPT ? .supportedChatGPT : (apiKey == nil ? .unknown : .apiKey)
            let claims = decodeClaims(tokens?["id_token"] as? String)
                ?? decodeClaims(tokens?["access_token"] as? String) ?? [:]
            if hasChatGPT, claims.isEmpty {
                return .init(data: Data(), digest: "", identity: nil, support: .malformedAuth, error: "ChatGPT token metadata is malformed.")
            }
            let accountID = string(tokens?["account_id"])
                ?? findString(in: claims, keys: ["chatgpt_account_id", "account_id"])
            let identity = AccountIdentity(
                providerID: id,
                email: findString(in: claims, keys: ["email", "preferred_username"]),
                userID: findString(in: claims, keys: ["chatgpt_user_id"]),
                accountID: accountID,
                workspaceID: findString(in: claims, keys: ["workspace_id", "organization_id", "org_id"]),
                authMode: mode
            )
            let message = support == .unknown
                ? "Credential format is not a supported file-based ChatGPT or API-key shape."
                : nil
            return .init(
                data: data,
                digest: CoreSupport.digest(data),
                identity: identity,
                support: support,
                error: message
            )
        } catch {
            return .init(
                data: Data(),
                digest: "",
                identity: nil,
                support: .malformedAuth,
                error: "auth.json could not be inspected: \(safeError(error))"
            )
        }
    }

    private func decodeClaims(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), data.count <= CoreSupport.maxAuthBytes,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return value
    }

    private func findString(in value: Any, keys: Set<String>, depth: Int = 0) -> String? {
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

    private func string(_ value: Any?) -> String? {
        guard let result = value as? String, !result.isEmpty else { return nil }
        return result
    }

    private func safeError(_ error: Error) -> String {
        if error is CocoaError { return "permission denied, unreadable, or malformed data" }
        return "unsupported data"
    }
}

struct AuthInspection {
    let data: Data
    let digest: String
    let identity: AccountIdentity?
    let support: SourceSupport
    let error: String?
}
