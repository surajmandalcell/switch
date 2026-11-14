import Foundation

/// State topics (architecture.md 2.7). Each holds one whole value; a change replaces it and bumps `rev` by one.
public enum Topic: String, CaseIterable, Sendable {
    case app, notices, accounts, settings, tray, login
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
}

/// `notices`: the last error (the red bar) and the last notice (also posted as a notification by the UI).
public struct NoticesValue: Codable, Equatable, Sendable {
    public var error: String?
    public var notice: String?
}
