import Foundation
import AIManagerCore

/// The engine's Keychain rule: only a user-started action reads the login Keychain. Startup, subscriptions, read
/// methods, and the usage timers never do, even after the user allowed it once. The Mac app differs today: its
/// `GatedKeyProvider` lets background reads through after one click (persisted `switch.droid.keychainAllowed`).
public struct UserActionKeyProvider: DroidLoginReader.KeyProvider {
    private let base: any DroidLoginReader.KeyProvider

    public init(base: any DroidLoginReader.KeyProvider = DroidLoginReader.KeychainKeyProvider()) {
        self.base = base
    }

    public func key(interactive: Bool) throws -> Data {
        guard interactive else { throw DroidLoginError.needsKeychainAccess }
        return try base.key(interactive: true)
    }
}

extension AppEngine {
    /// The account manager every engine host uses, with the Keychain rule above. The parameters after `paths` are
    /// test seams.
    public static func makeManager(paths: ManagerPaths,
                                   keychain: any DroidLoginReader.KeyProvider = DroidLoginReader.KeychainKeyProvider(),
                                   writerCheck: AccountManager.WriterCheck? = nil) throws -> AccountManager {
        try AccountManager(paths: paths, writerCheck: writerCheck,
                           droidLoginReader: DroidLoginReader(keyProvider: UserActionKeyProvider(base: keychain)))
    }
}
