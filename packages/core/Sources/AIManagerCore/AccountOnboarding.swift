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
    /// Returns whether this process still owns, or observed completion of, the matching launch.
    public let launch: @Sendable (UUID, LaunchSpec) throws -> Void
    public let cancel: @Sendable (UUID) -> Bool
    public let submit: @Sendable (UUID, String) throws -> Bool

    public init(
        launch: @escaping @Sendable (UUID, LaunchSpec) throws -> Void,
        cancel: @escaping @Sendable (UUID) -> Bool = { _ in false },
        submit: @escaping @Sendable (UUID, String) throws -> Bool = { _, _ in false }
    ) {
        self.launch = launch
        self.cancel = cancel
        self.submit = submit
    }

    public static let foundation = AccountLoginRunner(
        launch: { id, spec in try FoundationLoginProcesses.shared.launch(id: id, spec: spec) },
        cancel: { id in FoundationLoginProcesses.shared.cancel(id: id) },
        submit: { id, input in try FoundationLoginProcesses.shared.submit(input, id: id) }
    )
}

private final class FoundationLoginProcesses: @unchecked Sendable {
    private struct RunningLogin {
        let process: Process
        let input: FileHandle?
    }

    static let shared = FoundationLoginProcesses()

    private let lock = NSLock()
    private var processes: [UUID: RunningLogin] = [:]
    private var completed: Set<UUID> = []

    func launch(id: UUID, spec: LaunchSpec) throws {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.workingDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let (input, childInput) = try privateTerminal(for: spec)
        if let childInput { process.standardInput = childInput }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            lock.lock()
            let finished = processes.removeValue(forKey: id)
            completed.insert(id)
            lock.unlock()
            try? finished?.input?.close()
        }
        lock.lock()
        completed.remove(id)
        processes[id] = RunningLogin(process: process, input: input)
        lock.unlock()
        do {
            try process.run()
            try? childInput?.close()
        } catch {
            lock.lock()
            processes.removeValue(forKey: id)
            lock.unlock()
            try? input?.close()
            try? childInput?.close()
            throw error
        }
    }

    func cancel(id: UUID) -> Bool {
        lock.lock()
        let running = processes.removeValue(forKey: id)
        let observedCompletion = completed.remove(id) != nil
        lock.unlock()
        guard let running else { return observedCompletion }
        let process = running.process
        defer { try? running.input?.close() }
        guard process.isRunning else { return true }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        return true
    }

    func submit(_ input: String, id: UUID) throws -> Bool {
        lock.lock()
        let running = processes[id]
        lock.unlock()
        guard let running, running.process.isRunning, let destination = running.input else {
            return false
        }
        try destination.write(contentsOf: Data((input + "\n").utf8))
        return true
    }

    private func privateTerminal(for spec: LaunchSpec) throws -> (FileHandle?, FileHandle?) {
        guard spec.environment["GROK_HOME"] != nil, spec.arguments == ["login", "--oauth"] else {
            return (nil, nil)
        }
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw AIManagerError.operationFailed("Could not open a private sign-in terminal.")
        }
        var settings = termios()
        if tcgetattr(slave, &settings) == 0 {
            settings.c_lflag &= ~tcflag_t(ECHO)
            _ = tcsetattr(slave, TCSANOW, &settings)
        }
        return (
            FileHandle(fileDescriptor: master, closeOnDealloc: true),
            FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        )
    }
}

extension ProviderID {
    public static let claudeCode = ProviderID(rawValue: "claude-code")
    public static let geminiCLI = ProviderID(rawValue: "gemini-cli")
    public static let antigravityCLI = ProviderID(rawValue: "antigravity-cli")

    public var displayName: String {
        switch self {
        case .codex: "Codex CLI"
        case .grokBuild: "Grok Build"
        case .claudeCode: "Claude Code"
        case .geminiCLI: "Gemini CLI"
        case .antigravityCLI: "Antigravity CLI"
        default:
            rawValue
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}
