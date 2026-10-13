import CryptoKit
import Foundation

/// The z.ai coding-plan API keys that the Z Code app saves in `~/.zcode/v2/credentials.json`.
/// Each value is `enc:v1:` + base64url(nonce).base64url(tag).base64url(ciphertext), AES-256-GCM
/// with no extra data. The key is SHA-256 of `ZCODE_CREDENTIAL_SECRET`, else of
/// `zcode-credential-fallback:<platform>:<home folder>:<user name>`. Never touches the Keychain.
enum ZCodeCredentials {
    struct PlanKey: Equatable {
        let plan: String
        let apiKey: String
        var accountName: String { "Z Code \(plan) plan" }
    }

    private static let prefix = "enc:v1:"
    private static let entry = try! NSRegularExpression(
        pattern: "^account-provider:coding-plan:account:zai-(individual|team)-coding-plan:account:.+:api-key$")

    /// Decrypted keys, one entry for each distinct key. Entry names sort "individual" before "team",
    /// so a key that both plans share is named after the individual plan. Empty when the file
    /// is missing or unreadable; an entry that fails to decrypt is skipped.
    static func apiKeys(home: URL, username: String = NSUserName(),
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> [PlanKey] {
        let file = home.appending(path: ".zcode/v2/credentials.json")
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: file),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [] }
        let secret = environment["ZCODE_CREDENTIAL_SECRET"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "zcode-credential-fallback:darwin:\(home.path):\(username)"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        var result: [PlanKey] = []
        for name in values.keys.sorted() {
            let range = NSRange(name.startIndex..., in: name)
            guard let match = entry.firstMatch(in: name, range: range), let plan = Range(match.range(at: 1), in: name),
                  let text = decrypt(values[name] ?? "", key: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, !result.contains(where: { $0.apiKey == text }) else { continue }
            result.append(PlanKey(plan: String(name[plan]), apiKey: text))
        }
        return result
    }

    private static func decrypt(_ value: String, key: SymmetricKey) -> String? {
        guard value.hasPrefix(prefix) else { return value }
        let parts = value.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let nonce = base64url(parts[0]), let tag = base64url(parts[1]),
              let body = base64url(parts[2]), nonce.count == 12, tag.count == 16,
              let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: body, tag: tag),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    private static func base64url(_ text: Substring) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}
