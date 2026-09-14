import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ProviderAvailability: String, Codable, Sendable {
    case enabled
    case disabled
}

public struct ProviderDescriptor: Codable, Sendable, Identifiable {
    public var id: ProviderID
    public var displayName: String
    public var availability: ProviderAvailability
    public var unavailableReason: String?

    public init(
        id: ProviderID,
        displayName: String,
        availability: ProviderAvailability,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.availability = availability
        self.unavailableReason = unavailableReason
    }
}

public enum AccountLoginState: String, Codable, Sendable {
    case waitingForLogin
    case needsAttention
    case credentialChoiceRequired
    case completed
}

public struct AccountLoginSession: Codable, Sendable, Identifiable {
    public var id: UUID
    public var providerID: ProviderID
    public var createdAt: Date

    public init(id: UUID, providerID: ProviderID, createdAt: Date) {
        self.id = id
        self.providerID = providerID
        self.createdAt = createdAt
    }
}

public struct AccountLoginStart: Sendable {
    public var session: AccountLoginSession
    public var launchSpec: LaunchSpec

    public init(session: AccountLoginSession, launchSpec: LaunchSpec) {
        self.session = session
        self.launchSpec = launchSpec
    }
}

public struct AccountLoginCheck: Sendable {
    public var session: AccountLoginSession
    public var state: AccountLoginState
    public var account: AccountRecord?
    public var message: String

    public init(
        session: AccountLoginSession,
        state: AccountLoginState,
        account: AccountRecord? = nil,
        message: String
    ) {
        self.session = session
        self.state = state
        self.account = account
        self.message = message
    }
}

public struct AccountSnapshot: Sendable {
    public var status: ManagerStatus
    public var providers: [ProviderDescriptor]
    public var discoveries: [DiscoveredSource]
    public var pendingLoginSessions: [AccountLoginSession]

    public init(
        status: ManagerStatus,
        providers: [ProviderDescriptor],
        discoveries: [DiscoveredSource],
        pendingLoginSessions: [AccountLoginSession]
    ) {
        self.status = status
        self.providers = providers
        self.discoveries = discoveries
        self.pendingLoginSessions = pendingLoginSessions
    }
}

public struct AccountLoginRunner: @unchecked Sendable {
    /// `cancel` must stop writes for the matching launch before it returns.
    public let launch: @Sendable (UUID, LaunchSpec) throws -> Void
    public let cancel: @Sendable (UUID) -> Void

    public init(
        launch: @escaping @Sendable (UUID, LaunchSpec) throws -> Void,
        cancel: @escaping @Sendable (UUID) -> Void = { _ in }
    ) {
        self.launch = launch
        self.cancel = cancel
    }

    public static let foundation = AccountLoginRunner(
        launch: { id, spec in try FoundationLoginProcesses.shared.launch(id: id, spec: spec) },
        cancel: { id in FoundationLoginProcesses.shared.cancel(id: id) }
    )
}

private final class FoundationLoginProcesses: @unchecked Sendable {
    static let shared = FoundationLoginProcesses()

    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]

    func launch(id: UUID, spec: LaunchSpec) throws {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.workingDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            self?.lock.lock()
            self?.processes.removeValue(forKey: id)
            self?.lock.unlock()
        }
        lock.lock()
        processes[id] = process
        lock.unlock()
        do {
            try process.run()
        } catch {
            lock.lock()
            processes.removeValue(forKey: id)
            lock.unlock()
            throw error
        }
    }

    func cancel(id: UUID) {
        lock.lock()
        let process = processes.removeValue(forKey: id)
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

extension ProviderID {
    public static let claudeCode = ProviderID(rawValue: "claude-code")
    public static let geminiCLI = ProviderID(rawValue: "gemini-cli")
    public static let antigravityCLI = ProviderID(rawValue: "antigravity-cli")
}
