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
            async let activity = try? OllamaUsage.send(key, "GET", "/api/usage", ts: now)
            // /api/balance is the documented source (monthly credits, legacy session and weekly limits,
            // purchased credits). /api/usage adds the four-week spend and is the fallback.
            let balance = try await OllamaUsage.send(key, "GET", "/api/balance", ts: now)
            let me = await account.flatMap { $0.status == 200 ? try? $0.json() : nil }
            let spend = await activity.flatMap { $0.status == 200 ? try? $0.json() : nil }
            if balance.status == 401 || balance.status == 403 {
                throw ProviderError.unauthorized("Not signed in to Ollama Cloud. Run ollama signin.")
            }
            if (200..<300).contains(balance.status), let json = try? balance.json(),
               json["included"].exists || json["purchased"].exists {
                return try OllamaUsage.map(balance: json, usage: spend, account: me)
            }
            guard let spend else { try HTTP.check(balance); throw ProviderError.parse("Ollama returned no usage limits.") }
            return try OllamaUsage.map(spend, account: me)
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

    /// Current plans carry a monthly dollar allowance; legacy plans keep session and weekly limits as
    /// percent REMAINING. `purchased.balance_usd` is the extra credit used after the allowance runs out.
    /// `usage` (`/api/usage`) only adds the four-week spend and fills limits that `balance` lacks.
    static func map(balance: JSON, usage: JSON?, account: JSON?) throws -> ProviderUsage {
        let included = balance["included"]
        var windows: [UsageWindow] = []
        for (id, title, minutes) in [("session", "Session", 300), ("weekly", "Weekly", 10_080)] {
            guard let remaining = included[id]["remaining_percent"].double else { continue }
            let reset = included[id]["resets_at"].date
            windows.append(UsageWindow(id: id, title: title, usedPercent: 100 - remaining, resetsAt: reset,
                                       windowMinutes: reset == nil ? nil : minutes))
        }
        var cost: UsageCost?
        let purchased = balance.at("purchased.balance_usd").double.map { max(0, $0) }
        if let allowance = included["allowance_usd"].double, allowance > 0, let left = included["balance_usd"].double {
            let used = min(allowance, max(0, allowance - left))
            let from = included.at("period.from").date, until = included.at("period.until").date
            let minutes = from.flatMap { start in until.map { Int($0.timeIntervalSince(start) / 60) } }.flatMap { $0 > 0 ? $0 : nil }
            var monthly = UsageWindow.amounts(id: "monthly", title: "Monthly", used: used, limit: allowance,
                                              resetsAt: until, windowMinutes: minutes ?? 43_200)
            monthly?.detail = "\(Fmt.money(used)) / \(Fmt.money(allowance))"
            windows += monthly.map { [$0] } ?? []
            cost = UsageCost(used: used, limit: allowance, balance: purchased, period: "Monthly credits", resetsAt: until)
        } else if let purchased {
            cost = UsageCost(balance: purchased)
        }
        guard !windows.isEmpty || cost != nil else { throw ProviderError.parse("Ollama returned no usage limits.") }
        var sections: [UsageSection] = []
        if let spend = usage?.at("activity.cost").double {
            sections.append(UsageSection(nil, [UsageRow("Cost, last 4 weeks", Fmt.money(spend))]))
        }
        let plan = (account?["Plan"].string ?? account?["plan"].string)?.capitalized
        return ProviderUsage(windows: windows, cost: cost, sections: sections, plan: plan,
                             email: account?["Email"].string ?? account?["email"].string)
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
