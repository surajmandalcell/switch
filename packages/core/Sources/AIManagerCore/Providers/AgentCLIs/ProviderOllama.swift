import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension ProviderCatalog {
    private static let ollamaKey = LiveFile(".ollama/id_ed25519")
    private static let ollamaPublic = LiveFile(".ollama/id_ed25519.pub", optional: true)

    // No login command: Ollama creates the key pair on first run and `ollama signin` only links it to an account,
    // and the sources do not confirm that either step honors a temporary HOME.
    static let agentOllama = ProviderSpec(
        id: "ollama", name: "Ollama", style: .files,
        files: [ollamaKey, ollamaPublic],
        dashboard: "https://ollama.com/settings",
        identify: { credential in
            credential.files[ollamaKey.id].flatMap(OllamaUsage.key).map { CredentialIdentity(key: $0.publicKeyBase64) }
        },
        usage: { credential in
            guard let key = credential.files[ollamaKey.id].flatMap(OllamaUsage.key) else {
                throw ProviderError.missingCredential("Ollama has no usable ~/.ollama/id_ed25519 key. Run ollama signin.")
            }
            let now = Int(Date().timeIntervalSince1970)
            async let account = try? OllamaUsage.send(key, "POST", "/api/me", ts: now)
            let response = try await OllamaUsage.send(key, "GET", "/api/usage", ts: now)
            if response.status == 401 || response.status == 403 {
                throw ProviderError.unauthorized("Not signed in to Ollama Cloud. Run ollama signin.")
            }
            try HTTP.check(response)
            let me = await account.flatMap { $0.status == 200 ? try? $0.json() : nil }
            return try OllamaUsage.map(response.json(), account: me)
        })
}

enum OllamaUsage {
    struct Key: Equatable {
        var publicKeyBase64: String
        var seed: Data
    }

    /// `Authorization` value: base64 public key blob, then the base64 Ed25519 signature of "METHOD,uri".
    static func authorization(_ key: Key, method: String, requestURI: String) throws -> String {
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: key.seed)
        let signature = try signer.signature(for: Data("\(method),\(requestURI)".utf8))
        return "\(key.publicKeyBase64):\(signature.base64EncodedString())"
    }

    /// The signature covers the exact URI sent, including the `ts` query that stops replay.
    static func send(_ key: Key, _ method: String, _ path: String, ts: Int) async throws -> HTTPResponse {
        let uri = "\(path)?ts=\(ts)"
        return try await HTTP.send("https://ollama.com\(uri)", method: method,
                                   headers: ["Authorization": try authorization(key, method: method, requestURI: uri)])
    }

    static func map(_ usage: JSON, account: JSON?) throws -> ProviderUsage {
        let limits = usage["limits"]
        guard limits.exists else { throw ProviderError.parse("Ollama returned no usage limits.") }
        // `usage` is a fraction of the plan allowance. The API sends no reset time, so none is shown.
        let windows = [("session", "Session", 300), ("weekly", "Weekly", 10080), ("monthly", "Monthly", 0)]
            .compactMap { id, title, minutes -> UsageWindow? in
                limits[id]["usage"].double.map {
                    UsageWindow(id: id, title: title, usedPercent: $0 * 100, windowMinutes: minutes > 0 ? minutes : nil)
                }
            }
        let spend = usage.at("activity.cost").double
        guard !windows.isEmpty || spend != nil else { throw ProviderError.parse("Ollama returned no usage limits.") }
        let plan = (account?["Plan"].string ?? account?["plan"].string)?.capitalized
        return ProviderUsage(windows: windows, cost: spend.map { UsageCost(used: $0, period: "Last 4 weeks") },
                             plan: plan, email: account?["Email"].string ?? account?["email"].string)
    }

    // MARK: OpenSSH key container

    private static let magic = Array("openssh-key-v1\0".utf8)
    private static let keyType = Data("ssh-ed25519".utf8)

    /// Reads an unencrypted OpenSSH `ssh-ed25519` private key, the only kind Ollama writes.
    static func key(_ pem: Data) -> Key? {
        let body = String(decoding: pem, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("-----") }.joined()
        guard let blob = Data(base64Encoded: body), blob.starts(with: magic) else { return nil }
        var reader = Reader(blob, offset: magic.count)
        guard reader.string() == Data("none".utf8), reader.string() == Data("none".utf8), reader.string() != nil,
              reader.uint32() == 1, let publicBlob = reader.string(), let privateSection = reader.string() else { return nil }
        var inner = Reader(privateSection, offset: 0)
        guard inner.uint32() != nil, inner.uint32() != nil, inner.string() == keyType, inner.string() != nil,
              let secret = inner.string(), secret.count == 64,
              let derived = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)),
              derived.publicKey.rawRepresentation == Data(secret.suffix(32)) else { return nil }
        var declared = Reader(publicBlob, offset: 0)
        guard declared.string() == keyType, declared.string() == derived.publicKey.rawRepresentation else { return nil }
        return Key(publicKeyBase64: publicBlob.base64EncodedString(), seed: Data(secret.prefix(32)))
    }

    /// Bounds-checked cursor over SSH wire format: big-endian uint32 lengths, then payloads.
    private struct Reader {
        let bytes: Data
        var offset: Int

        init(_ bytes: Data, offset: Int) {
            self.bytes = Data(bytes)
            self.offset = offset
        }

        mutating func uint32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }

        mutating func string() -> Data? {
            guard let length = uint32(), offset + Int(length) <= bytes.count else { return nil }
            defer { offset += Int(length) }
            return Data(bytes[offset..<offset + Int(length)])
        }
    }
}
