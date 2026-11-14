import Foundation
import AIManagerCore

/// State topics (architecture.md 2.7). Each holds one whole value; a change replaces it and bumps `rev` by one.
public enum Topic: String, CaseIterable, Sendable {
    case app, notices, accounts, settings, tray, login, providers, providerStatus, activity
    case historyVersion = "history.version", usageHistoryVersion = "usageHistory.version"
}

/// `history.version`, `usageHistory.version`: a counter that goes up when the data behind `history.list` or
/// `usage.history` changed, so an open page fetches again.
public struct VersionValue: Codable, Equatable, Sendable {
    public var version = 0
}

/// `providers`: the file-based providers whose own login exists in the user's home (the "signed in on this
/// computer" marks of the add list), from `providers.detectSignedIn`.
public struct ProvidersValue: Codable, Equatable, Sendable {
    public var signedIn: [String] = []
}

/// `login`: the open sign-in sessions, oldest first. A session leaves once it saved an account or was cancelled.
public struct LoginValue: Codable, Equatable, Sendable {
    public var sessions: [LoginStatus] = []
}

public typealias TopicValue = Encodable & Sendable

/// One committed topic value. `state.subscribe` returns it as `{rev, value}`; `state.changed` adds `topic`.
public struct TopicChange: Sendable {
    public let topic: Topic
    public let rev: Int
    public let value: any TopicValue
}

/// `app`: lifecycle flags the window and tray read.
public struct AppStateValue: Codable, Equatable, Sendable {
    public var hasLoaded = false
    public var isUnavailable = false
    public var isBusy = false
    public var refreshedAt: Date?
    /// The private data folder, shown in Settings > Data locations.
    public var dataLocation: String
    /// The rows of Settings > Data locations in page order: `data.codex`, `data.codex-vault`, `data.grok`,
    /// `data.grok-vault`, with the Mac titles and help texts.
    public var dataLocations: [DataLocation] = []
    /// The live tool folders the Accounts page names: `codex` (defaultHome), `grok`, `droid`, and `user` (the home
    /// they sit in; the root's in a test home).
    public var homes: [String: String] = [:]

    static func homes(_ paths: ManagerPaths) -> [String: String] {
        ["codex": paths.defaultHome.path, "grok": paths.grokHome.path, "droid": paths.droidHome.path,
         "user": paths.userHome.path]
    }

    public struct DataLocation: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var detail: String
        public var path: String
    }

    static func dataLocations(_ paths: ManagerPaths) -> [DataLocation] {
        let folders = ["data.codex": paths.defaultHome, "data.codex-vault": paths.credentialStore,
                       "data.grok": paths.grokHome, "data.grok-vault": paths.grokCredentialStore]
        return SettingsSearch.entries.compactMap { entry in
            folders[entry.id].map { DataLocation(id: entry.id, title: entry.title, detail: entry.help, path: $0.path) }
        }
    }
}

/// `notices`: the last error (the red bar) and the last notice (also posted as a notification by the UI).
public struct NoticesValue: Codable, Equatable, Sendable {
    public var error: String?
    public var notice: String?
}
