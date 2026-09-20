import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct GrokProviderAdapter {
    let fileManager: FileManager
    let id = ProviderID.grokBuild

    func sameIdentity(_ lhs: AccountIdentity, _ rhs: AccountIdentity) -> Bool {
        lhs.providerID == id
            && rhs.providerID == id
            && lhs.authMode == .oauth
            && rhs.authMode == .oauth
            && lhs.userID != nil
            && lhs.userID == rhs.userID
            && lhs.accountID == rhs.accountID
            && lhs.workspaceID == rhs.workspaceID
    }

    func validateManagedCredential(_ account: AccountRecord) throws {
        guard account.identity.providerID == id else {
            throw AIManagerError.unsupportedSource(
                "Provider \(account.identity.providerID.rawValue) is not Grok Build.")
        }
        try validatePrivateCredentialFile(account.credentialFile)
        let inspection = inspect(credentialFile: account.credentialFile)
        guard inspection.support == .supportedOAuth,
              let identity = inspection.identity,
              sameIdentity(account.identity, identity),
              inspection.digest == account.credentialDigest else {
            throw AIManagerError.credentialConflict
        }
    }

    func validatePrivateCredentialFile(_ auth: URL) throws {
        var info = stat()
        guard lstat(auth.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600 else {
            throw AIManagerError.credentialConflict
        }
    }

    func inspect(home selected: URL) -> AuthInspection {
        let home = selected.lastPathComponent == "auth.json"
            ? selected.deletingLastPathComponent() : selected
        return inspect(authFile: home.appending(path: "auth.json"))
    }

    func inspect(credentialFile: URL) -> AuthInspection {
        inspect(authFile: credentialFile)
    }

    private func inspect(authFile auth: URL) -> AuthInspection {
        guard fileManager.fileExists(atPath: auth.path) else {
            return .init(
                data: Data(), digest: "", identity: nil, support: .missingAuth,
                error: "auth.json is missing. Sign in with Grok Build or choose another source.")
        }
        do {
            let values = try auth.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AIManagerError.invalidSource("auth.json is not a regular file")
            }
            guard let count = values.fileSize, count <= CoreSupport.maxAuthBytes else {
                throw AIManagerError.invalidSource("auth.json exceeds the 2 MiB inspection limit")
            }
            let data = try Data(contentsOf: auth, options: .mappedIfSafe)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIManagerError.invalidSource("auth.json must contain a JSON object")
            }
            let entries = root.values.compactMap { $0 as? [String: Any] }.compactMap(identity)
            let unique = Dictionary(grouping: entries, by: identityKey).values.compactMap(\.first)
            guard unique.count == 1, let identity = unique.first else {
                return .init(
                    data: Data(), digest: "", identity: nil, support: .unknown,
                    error: entries.isEmpty
                        ? "auth.json does not contain a supported Grok subscription OAuth session."
                        : "auth.json contains more than one Grok account identity.")
            }
            return .init(
                data: data,
                digest: CoreSupport.digest(data),
                identity: identity,
                support: .supportedOAuth,
                error: nil
            )
        } catch {
            return .init(
                data: Data(), digest: "", identity: nil, support: .malformedAuth,
                error: "auth.json could not be inspected: permission denied, unreadable, or malformed data")
        }
    }

    private func identity(_ entry: [String: Any]) -> AccountIdentity? {
        guard let mode = entry["auth_mode"] as? String,
              ["oidc", "external"].contains(mode),
              let key = entry["key"] as? String, !key.isEmpty,
              let userID = entry["user_id"] as? String, !userID.isEmpty else {
            return nil
        }
        if mode == "external",
           nonempty(entry["oidc_issuer"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            != "https://auth.x.ai" {
            return nil
        }
        let principalID = nonempty(entry["principal_id"] as? String) ?? userID
        let workspaceID = nonempty(entry["team_id"] as? String)
            ?? nonempty(entry["organization_id"] as? String)
        return .init(
            providerID: id,
            email: nonempty(entry["email"] as? String),
            userID: userID,
            accountID: principalID,
            workspaceID: workspaceID,
            authMode: .oauth
        )
    }

    private func identityKey(_ identity: AccountIdentity) -> String {
        [identity.userID, identity.accountID, identity.workspaceID]
            .map { $0 ?? "" }
            .joined(separator: "\u{0}")
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
