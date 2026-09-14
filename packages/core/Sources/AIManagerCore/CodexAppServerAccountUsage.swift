import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct CodexAppServerSource: Sendable, Equatable {
    public let codexHome: URL
    public let authFile: URL

    public init(codexHome: URL, authFile: URL) {
        self.codexHome = codexHome
        self.authFile = authFile
    }
}

public struct CodexAppServerLimits: Sendable, Equatable {
    public let timeout: TimeInterval
    public let maximumOutputBytes: Int
    public let maximumLineBytes: Int

    public init(
        timeout: TimeInterval = 12,
        maximumOutputBytes: Int = 512 * 1_024,
        maximumLineBytes: Int = 128 * 1_024
    ) {
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumLineBytes = maximumLineBytes
    }
}

public struct CodexAppServerLaunch: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let source: CodexAppServerSource

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        source: CodexAppServerSource
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.source = source
    }
}

public protocol CodexAppServerRPCTransport: Sendable {
    func performAccountRead(
        launch: CodexAppServerLaunch,
        limits: CodexAppServerLimits
    ) async throws -> [Data]
}

public enum CodexAppServerError: Error, Equatable, LocalizedError, Sendable {
    case invalidSource(String)
    case invalidLimits
    case launchFailed(String)
    case timedOut
    case outputLimitExceeded
    case malformedResponse
    case missingResponse(String)
    case rpcFailure(code: Int?, message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let detail): return detail
        case .invalidLimits: return "Codex app-server limits are invalid."
        case .launchFailed(let detail): return detail
        case .timedOut: return "Codex app-server did not respond in time."
        case .outputLimitExceeded: return "Codex app-server exceeded the response limit."
        case .malformedResponse: return "Codex app-server returned an invalid response."
        case .missingResponse(let method): return "Codex app-server did not return \(method)."
        case .rpcFailure(_, let message): return message
        case .cancelled: return "Codex app-server read was cancelled."
        }
    }
}

public struct CodexAccountDetailsSnapshot: Sendable, Equatable, Codable {
    public let kind: String?
    public let email: String?
    public let plan: String?

    public init(kind: String?, email: String?, plan: String?) {
        self.kind = kind
        self.email = email
        self.plan = plan
    }
}

public struct CodexRateLimitWindowSnapshot: Sendable, Equatable, Codable {
    public let usedPercent: Int?
    public let windowDurationMinutes: Int64?
    public let resetsAt: Date?

    public init(usedPercent: Int?, windowDurationMinutes: Int64?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

public struct CodexCreditsSnapshot: Sendable, Equatable, Codable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: String?

    public init(hasCredits: Bool?, unlimited: Bool?, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct CodexRateLimitBucketSnapshot: Sendable, Equatable, Codable {
    public let id: String?
    public let name: String?
    public let plan: String?
    public let model: String?
    public let primary: CodexRateLimitWindowSnapshot?
    public let secondary: CodexRateLimitWindowSnapshot?
    public let credits: CodexCreditsSnapshot?
    public let spendControlReached: Bool?

    public init(
        id: String?,
        name: String?,
        plan: String?,
        model: String?,
        primary: CodexRateLimitWindowSnapshot?,
        secondary: CodexRateLimitWindowSnapshot?,
        credits: CodexCreditsSnapshot?,
        spendControlReached: Bool?
    ) {
        self.id = id
        self.name = name
        self.plan = plan
        self.model = model
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.spendControlReached = spendControlReached
    }
}

public struct CodexRateLimitsSnapshot: Sendable, Equatable, Codable {
    public let accountID: String?
    public let ordinaryUsageAllowed: Bool?
    public let defaultBucket: CodexRateLimitBucketSnapshot?
    public let buckets: [String: CodexRateLimitBucketSnapshot]

    public init(
        accountID: String?,
        ordinaryUsageAllowed: Bool?,
        defaultBucket: CodexRateLimitBucketSnapshot?,
        buckets: [String: CodexRateLimitBucketSnapshot]
    ) {
        self.accountID = accountID
        self.ordinaryUsageAllowed = ordinaryUsageAllowed
        self.defaultBucket = defaultBucket
        self.buckets = buckets
    }
}

public struct CodexUsageSummarySnapshot: Sendable, Equatable, Codable {
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let currentStreakDays: Int64?
    public let longestStreakDays: Int64?
    public let longestRunningTurnSeconds: Int64?

    public init(
        lifetimeTokens: Int64?,
        peakDailyTokens: Int64?,
        currentStreakDays: Int64?,
        longestStreakDays: Int64?,
        longestRunningTurnSeconds: Int64?
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.longestRunningTurnSeconds = longestRunningTurnSeconds
    }
}

public struct CodexDailyUsageSnapshot: Sendable, Equatable, Codable {
    public let startDate: String?
    public let tokens: Int64?

    public init(startDate: String?, tokens: Int64?) {
        self.startDate = startDate
        self.tokens = tokens
    }
}

public struct CodexAccountUsageSnapshot: Sendable, Equatable, Codable {
    public let account: CodexAccountDetailsSnapshot?
    public let requiresOpenAIAuthentication: Bool?
    public let rateLimits: CodexRateLimitsSnapshot?
    public let usage: CodexUsageSummarySnapshot?
    public let dailyUsage: [CodexDailyUsageSnapshot]
    public let fetchedAt: Date

    public init(
        account: CodexAccountDetailsSnapshot?,
        requiresOpenAIAuthentication: Bool?,
        rateLimits: CodexRateLimitsSnapshot?,
        usage: CodexUsageSummarySnapshot?,
        dailyUsage: [CodexDailyUsageSnapshot],
        fetchedAt: Date
    ) {
        self.account = account
        self.requiresOpenAIAuthentication = requiresOpenAIAuthentication
        self.rateLimits = rateLimits
        self.usage = usage
        self.dailyUsage = dailyUsage
        self.fetchedAt = fetchedAt
    }
}

public struct CodexAppServerAccountReader: Sendable {
    private let transport: any CodexAppServerRPCTransport
    private let environment: @Sendable () -> [String: String]
    private let now: @Sendable () -> Date

    public init(
        transport: any CodexAppServerRPCTransport = ProcessCodexAppServerRPCTransport(),
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.environment = environment
        self.now = now
    }

    public func read(
        executable: URL,
        source: CodexAppServerSource,
        limits: CodexAppServerLimits = .init()
    ) async throws -> CodexAccountUsageSnapshot {
        try Self.validate(source: source, limits: limits)
        let launch = CodexAppServerLaunch(
            executable: executable,
            arguments: ["app-server", "--stdio"],
            environment: Self.scrubbedEnvironment(environment(), codexHome: source.codexHome),
            source: source
        )
        let records = try await transport.performAccountRead(launch: launch, limits: limits)
        return try Self.decode(records: records, fetchedAt: now())
    }

    static func scrubbedEnvironment(_ source: [String: String], codexHome: URL) -> [String: String] {
        let credentialSuffixes = [
            "_API_KEY", "_ACCESS_KEY", "_TOKEN", "_CLIENT_SECRET", "_PASSWORD", "_CREDENTIAL",
        ]
        var result = source.filter { key, _ in
            let normalized = key.uppercased()
            return !credentialSuffixes.contains(where: normalized.hasSuffix)
                && normalized != "OPENAI_TOKEN"
                && normalized != "CODEX_TOKEN"
        }
        result["CODEX_HOME"] = codexHome.path
        return result
    }

    private static func validate(source: CodexAppServerSource, limits: CodexAppServerLimits) throws {
        guard limits.timeout > 0, limits.maximumOutputBytes > 0, limits.maximumLineBytes > 0,
              limits.maximumLineBytes <= limits.maximumOutputBytes else {
            throw CodexAppServerError.invalidLimits
        }
        guard source.codexHome.path.hasPrefix("/"), source.authFile.path.hasPrefix("/") else {
            throw CodexAppServerError.invalidSource("Codex app-server paths must be absolute.")
        }
        let expected = source.codexHome.appending(path: "auth.json").standardizedFileURL
        guard source.authFile.standardizedFileURL == expected else {
            throw CodexAppServerError.invalidSource("The auth source must be CODEX_HOME/auth.json.")
        }
        var homeInfo = stat()
        guard lstat(source.codexHome.path, &homeInfo) == 0,
              homeInfo.st_mode & S_IFMT == S_IFDIR,
              homeInfo.st_uid == getuid(),
              homeInfo.st_mode & 0o777 == 0o700 else {
            throw CodexAppServerError.invalidSource("CODEX_HOME must be a private regular directory.")
        }
        var info = stat()
        guard lstat(source.authFile.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600 else {
            throw CodexAppServerError.invalidSource("The auth source must be a private regular file with one link.")
        }
    }

    private static func decode(records: [Data], fetchedAt: Date) throws -> CodexAccountUsageSnapshot {
        var results: [Int: [String: Any]] = [:]
        for record in records {
            guard record.count <= 512 * 1_024,
                  let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
                  let id = integer(object["id"]) else { continue }
            if let error = object["error"] as? [String: Any] {
                let message = (error["message"] as? String).map { String($0.prefix(512)) }
                    ?? "Codex app-server request failed."
                throw CodexAppServerError.rpcFailure(code: integer(error["code"]), message: message)
            }
            if let result = object["result"] as? [String: Any] { results[id] = result }
        }

        guard let accountResult = results[2] else { throw CodexAppServerError.missingResponse("account/read") }
        guard let rateResult = results[3] else { throw CodexAppServerError.missingResponse("account/rateLimits/read") }
        guard let usageResult = results[4] else { throw CodexAppServerError.missingResponse("account/usage/read") }

        let accountObject = accountResult["account"] as? [String: Any]
        let account = accountObject.map {
            CodexAccountDetailsSnapshot(
                kind: $0["type"] as? String,
                email: $0["email"] as? String,
                plan: $0["planType"] as? String
            )
        }
        let rawBuckets = rateResult["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        var buckets: [String: CodexRateLimitBucketSnapshot] = [:]
        for (id, value) in rawBuckets {
            if let value = value as? [String: Any] { buckets[id] = rateLimitBucket(value) }
        }
        let defaultBucket = (rateResult["rateLimits"] as? [String: Any]).map(rateLimitBucket)
        let rateLimits = CodexRateLimitsSnapshot(
            accountID: rateResult["accountId"] as? String,
            ordinaryUsageAllowed: rateResult["ordinaryUsageAllowed"] as? Bool,
            defaultBucket: defaultBucket,
            buckets: buckets
        )
        let summaryObject = usageResult["summary"] as? [String: Any]
        let usage = summaryObject.map {
            CodexUsageSummarySnapshot(
                lifetimeTokens: integer64($0["lifetimeTokens"]),
                peakDailyTokens: integer64($0["peakDailyTokens"]),
                currentStreakDays: integer64($0["currentStreakDays"]),
                longestStreakDays: integer64($0["longestStreakDays"]),
                longestRunningTurnSeconds: integer64($0["longestRunningTurnSec"])
            )
        }
        let dailyUsage = (usageResult["dailyUsageBuckets"] as? [[String: Any]] ?? []).map {
            CodexDailyUsageSnapshot(startDate: $0["startDate"] as? String, tokens: integer64($0["tokens"]))
        }
        return CodexAccountUsageSnapshot(
            account: account,
            requiresOpenAIAuthentication: accountResult["requiresOpenaiAuth"] as? Bool,
            rateLimits: rateLimits,
            usage: usage,
            dailyUsage: dailyUsage,
            fetchedAt: fetchedAt
        )
    }

    private static func rateLimitBucket(_ object: [String: Any]) -> CodexRateLimitBucketSnapshot {
        CodexRateLimitBucketSnapshot(
            id: object["limitId"] as? String,
            name: object["limitName"] as? String,
            plan: object["planType"] as? String,
            model: object["normalModelSlug"] as? String,
            primary: (object["primary"] as? [String: Any]).map(rateLimitWindow),
            secondary: (object["secondary"] as? [String: Any]).map(rateLimitWindow),
            credits: (object["credits"] as? [String: Any]).map {
                CodexCreditsSnapshot(
                    hasCredits: $0["hasCredits"] as? Bool,
                    unlimited: $0["unlimited"] as? Bool,
                    balance: $0["balance"] as? String
                )
            },
            spendControlReached: object["spendControlReached"] as? Bool
        )
    }

    private static func rateLimitWindow(_ object: [String: Any]) -> CodexRateLimitWindowSnapshot {
        CodexRateLimitWindowSnapshot(
            usedPercent: integer(object["usedPercent"]),
            windowDurationMinutes: integer64(object["windowDurationMins"]),
            resetsAt: integer64(object["resetsAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func integer64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        return (value as? NSNumber)?.int64Value
    }
}

public struct ProcessCodexAppServerRPCTransport: CodexAppServerRPCTransport {
    public init() {}

    public func performAccountRead(
        launch: CodexAppServerLaunch,
        limits: CodexAppServerLimits
    ) async throws -> [Data] {
        let processBox = ProcessBox()
        return try await withTaskCancellationHandler {
            do {
                return try await Task.detached(priority: .utility) {
                    try Self.run(launch: launch, limits: limits, processBox: processBox)
                }.value
            } catch {
                if processBox.isCancelled { throw CodexAppServerError.cancelled }
                throw error
            }
        } onCancel: {
            processBox.cancel()
        }
    }

    private static func run(
        launch: CodexAppServerLaunch,
        limits: CodexAppServerLimits,
        processBox: ProcessBox
    ) throws -> [Data] {
        if Task.isCancelled { throw CodexAppServerError.cancelled }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        processBox.set(process)
        if processBox.isCancelled { throw CodexAppServerError.cancelled }
        defer {
            try? input.fileHandleForWriting.close()
            processBox.stop()
        }
        do { try process.run() } catch {
            throw CodexAppServerError.launchFailed("Could not start Codex app-server: \(error.localizedDescription)")
        }
        if processBox.isCancelled {
            processBox.stop()
            throw CodexAppServerError.cancelled
        }

        let deadline = Date().addingTimeInterval(limits.timeout)
        let reader = BoundedJSONLReader(
            descriptor: output.fileHandleForReading.fileDescriptor,
            maximumTotalBytes: limits.maximumOutputBytes,
            maximumLineBytes: limits.maximumLineBytes
        )
        try write(request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "switch", "title": "Switch", "version": "1"],
            "capabilities": ["experimentalApi": true],
        ]), to: input.fileHandleForWriting)
        var records: [Data] = []
        _ = try readResponse(id: 1, reader: reader, deadline: deadline, records: &records)

        try write(notification(method: "initialized"), to: input.fileHandleForWriting)
        try write(request(id: 2, method: "account/read", params: ["refreshToken": false]), to: input.fileHandleForWriting)
        try write(request(id: 3, method: "account/rateLimits/read", params: [
            "excludeResetCreditDetails": true,
            "supportsLunaReserve": false,
        ]), to: input.fileHandleForWriting)
        try write(request(id: 4, method: "account/usage/read", params: [String: Any]()), to: input.fileHandleForWriting)

        var pending = Set(2...4)
        while !pending.isEmpty {
            let line = try reader.nextLine(deadline: deadline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CodexAppServerError.malformedResponse
            }
            guard let responseID = (object["id"] as? NSNumber)?.intValue else { continue }
            try throwRPCError(from: object)
            records.append(line)
            pending.remove(responseID)
        }
        return records
    }

    private static func request(id: Int, method: String, params: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params], options: [.sortedKeys])
    }

    private static func notification(method: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["method": method], options: [.sortedKeys])
    }

    private static func write(_ data: Data, to handle: FileHandle) throws {
        var line = data
        line.append(0x0A)
        do { try handle.write(contentsOf: line) } catch {
            if Task.isCancelled { throw CodexAppServerError.cancelled }
            throw CodexAppServerError.launchFailed("Could not write to Codex app-server.")
        }
    }

    private static func readResponse(
        id: Int,
        reader: BoundedJSONLReader,
        deadline: Date,
        records: inout [Data]
    ) throws -> Data {
        while true {
            let line = try reader.nextLine(deadline: deadline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CodexAppServerError.malformedResponse
            }
            guard let responseID = (object["id"] as? NSNumber)?.intValue else { continue }
            try throwRPCError(from: object)
            records.append(line)
            if responseID == id { return line }
        }
    }

    private static func throwRPCError(from object: [String: Any]) throws {
        guard let error = object["error"] as? [String: Any] else { return }
        let message = (error["message"] as? String).map { String($0.prefix(512)) }
            ?? "Codex app-server request failed."
        throw CodexAppServerError.rpcFailure(
            code: (error["code"] as? NSNumber)?.intValue,
            message: message
        )
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        stop()
    }

    func stop() {
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGTERM)
        usleep(100_000)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

private final class BoundedJSONLReader {
    private let descriptor: Int32
    private let maximumTotalBytes: Int
    private let maximumLineBytes: Int
    private var totalBytes = 0
    private var buffer = Data()

    init(descriptor: Int32, maximumTotalBytes: Int, maximumLineBytes: Int) {
        self.descriptor = descriptor
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumLineBytes = maximumLineBytes
    }

    func nextLine(deadline: Date) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard line.count <= maximumLineBytes else { throw CodexAppServerError.outputLimitExceeded }
                return Data(line)
            }
            if Task.isCancelled { throw CodexAppServerError.cancelled }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexAppServerError.timedOut }
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(100, max(1, Int(remaining * 1_000))))
            let pollResult = poll(&descriptorState, 1, milliseconds)
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CodexAppServerError.launchFailed("Could not read from Codex app-server.")
            }
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = read(descriptor, &bytes, bytes.count)
            if count == 0 { throw CodexAppServerError.malformedResponse }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CodexAppServerError.launchFailed("Could not read from Codex app-server.")
            }
            totalBytes += count
            guard totalBytes <= maximumTotalBytes else { throw CodexAppServerError.outputLimitExceeded }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= maximumLineBytes else { throw CodexAppServerError.outputLimitExceeded }
        }
    }
}
