import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security
#endif

public enum DroidLoginError: LocalizedError, Equatable, Sendable {
    case needsKeychainAccess
    case invalidLogin
    case expired

    public var errorDescription: String? {
        switch self {
        case .needsKeychainAccess: "Allow Switch to read Droid's login"
        case .invalidLogin: "Droid's saved login could not be read. Open Droid to check its sign-in."
        case .expired: "Droid sign-in token expired; usage returns after Droid refreshes it"
        }
    }
}

public struct DroidLoginReader: Sendable {
    public protocol KeyProvider: Sendable {
        /// Returns the decoded 32-byte key. Only an owner click may pass true.
        func key(interactive: Bool) throws -> Data
    }

    public struct KeychainKeyProvider: KeyProvider {
        public init() {}

        public func key(interactive: Bool) throws -> Data {
            #if canImport(Security)
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Factory CLI",
                kSecAttrAccount as String: "auth-encryption-key-security-cli",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if !interactive { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip }
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let encoded = result as? Data else { throw DroidLoginError.needsKeychainAccess }
            return try DroidLoginReader.decodeKey(encoded)
            #else
            throw DroidLoginError.needsKeychainAccess
            #endif
        }
    }

    /// Keeps Keychain prompts behind the owner's click. A background call never reaches the base
    /// provider unless a click already succeeded (persisted flag). A click keeps the key in memory
    /// for this app session only. Any failed background read clears the flag and the key.
    public final class GatedKeyProvider: KeyProvider, @unchecked Sendable {
        public static let allowedFlag = "switch.droid.keychainAllowed"
        private let base: any KeyProvider
        private let defaults: UserDefaults
        private let lock = NSLock()
        private var cached: Data?

        public init(base: any KeyProvider = KeychainKeyProvider(), defaults: UserDefaults = .standard) {
            self.base = base
            self.defaults = defaults
        }

        public func key(interactive: Bool) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let cached { return cached }
            guard interactive || defaults.bool(forKey: Self.allowedFlag) else {
                throw DroidLoginError.needsKeychainAccess
            }
            do {
                let key = try base.key(interactive: interactive)
                cached = key
                if interactive { defaults.set(true, forKey: Self.allowedFlag) }
                return key
            } catch {
                cached = nil
                defaults.set(false, forKey: Self.allowedFlag)
                throw interactive ? error : DroidLoginError.needsKeychainAccess
            }
        }
    }

    public struct Login: Sendable {
        public let accessToken: String
        public let expiresAt: Date
    }

    private let keyProvider: any KeyProvider

    public init(keyProvider: any KeyProvider = GatedKeyProvider()) {
        self.keyProvider = keyProvider
    }

    /// Droid v2 uses base64(16-byte IV):base64(16-byte tag):base64(ciphertext), with AES-256-GCM.
    /// Files have already passed the adapter's private-file and size checks.
    func read(files: [String: Data], interactive: Bool = false, now: Date = Date()) throws -> Login {
        let login = try decrypt(files: files, interactive: interactive)
        guard login.expiresAt > now else { throw DroidLoginError.expired }
        return login
    }

    /// The token's `sub` claim, read without a prompt. An expired token still names its account,
    /// so two logins whose doctor masks match ("s***@gmail.com") can still be told apart.
    func subject(files: [String: Data]) -> String? {
        guard let login = try? decrypt(files: files, interactive: false),
              let subject = Fmt.jwtClaims(login.accessToken)?["sub"].string, !subject.isEmpty else { return nil }
        return subject
    }

    private func decrypt(files: [String: Data], interactive: Bool) throws -> Login {
        let secure = files["auth.v2.loginkeychain"] != nil
        guard let data = files[secure ? "auth.v2.loginkeychain" : "auth.v2.file"],
              let text = String(data: data, encoding: .utf8) else { throw DroidLoginError.invalidLogin }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ":")
        guard parts.count == 3,
              let iv = Data(base64Encoded: parts[0]), iv.count == 16,
              let tag = Data(base64Encoded: parts[1]), tag.count == 16,
              let ciphertext = Data(base64Encoded: parts[2]), !ciphertext.isEmpty else {
            throw DroidLoginError.invalidLogin
        }
        let key: Data
        if secure {
            key = try keyProvider.key(interactive: interactive)
        } else {
            guard let encoded = files["auth.v2.key"] else { throw DroidLoginError.invalidLogin }
            key = try Self.decodeKey(encoded)
        }
        guard key.count == 32 else { throw DroidLoginError.invalidLogin }
        let login: Login
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            let clear = try AES.GCM.open(box, using: SymmetricKey(data: key))
            guard let object = try JSONSerialization.jsonObject(with: clear) as? [String: Any],
                  let token = object["access_token"] as? String, !token.isEmpty,
                  !token.contains(where: { $0.isWhitespace || $0.isNewline }),
                  let expiry = Fmt.jwtClaims(token)?["exp"].double, expiry.isFinite else {
                throw DroidLoginError.invalidLogin
            }
            login = Login(accessToken: token, expiresAt: Date(timeIntervalSince1970: expiry))
        } catch { throw DroidLoginError.invalidLogin }
        return login
    }

    private static func decodeKey(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8),
              let key = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32 else {
            throw DroidLoginError.invalidLogin
        }
        return key
    }
}
