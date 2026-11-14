import Foundation
import AIManagerCore
import SwitchAppModel

/// `switch-core serve`: JSON-RPC 2.0 over stdio, one object per line (specs/port/architecture.md section 2).
/// Requests run concurrently; each reply carries its request's id. Replies and errors carry no token, key, cookie,
/// or password; the log line holds method, id, time, and outcome only.
public final class RPCServer: @unchecked Sendable {
    public static let protocolVersion = 1
    /// Bumped when a settings key changes type or meaning; the client then rereads its settings cache.
    public static let settingsSchemaVersion = SettingsRegistry.schemaVersion
    public static let methods = ["initialize", "initialized", "shutdown", "$/cancelRequest", "accounts.status", "usage.detail",
                                 "state.subscribe", "state.unsubscribe", "settings.get", "settings.set", "settings.reset"]
        + readMethods + writeMethods + backupMethods + cleanupMethods
    public static let defaultTimeout: TimeInterval = 60
    /// Methods that may run past `defaultTimeout`; `$/cancelRequest` stops them.
    static let longMethods: Set<String> = ["backup.run", "backup.restore", "cleanup.scan"]
    static let maximumFrame = 16 * 1024 * 1024

    let manager: AccountManager?
    let paths: ManagerPaths
    let engine: AppEngine
    /// Topics this client subscribed to; only their changes are sent.
    private var subscribed: Set<Topic> = []
    private let version: String
    private let log: (String) -> Void
    private let timeout: TimeInterval
    let codexCache: CodexUsageStatisticsCache?
    let clock: any AppClock
    /// Open confirmation tokens (WriteMethods.swift), under `lock`.
    var confirmations: [String: (binding: Int, grants: Set<ConfirmationRequest.Kind>, expires: Date)] = [:]
    let lock = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Test seam: methods tried after the built-in ones. Set before `serve`.
    var extraMethods: [String: @Sendable (Data) async throws -> any Encodable] = [:]

    /// Requests without a reply yet, by id. Whoever removes the entry first (work, timer, or cancel) sends the reply.
    private final class Pending {
        let method: String
        let started = Date()
        var tasks: [Task<Void, Never>] = []
        init(method: String) { self.method = method }
    }

    private var pending: [RPCID: Pending] = [:]
    /// The last started request of each order key (`orderKey`), under `lock`.
    private var tails: [String: Task<Void, Never>] = [:]
    private let unanswered = DispatchGroup()
    private let writeLock = NSLock()
    private var write: @Sendable (Data) -> Void = { _ in }

    /// `manager` is nil when the private data folder cannot open; core methods then answer `unavailable`.
    public init(manager: AccountManager?, paths: ManagerPaths, version: String,
                timeout: TimeInterval = RPCServer.defaultTimeout, clock: any AppClock = SystemClock(),
                log: @escaping (String) -> Void = RPCServer.standardError) {
        self.manager = manager
        self.paths = paths
        self.version = version
        self.timeout = timeout
        self.log = log
        self.clock = clock
        codexCache = try? CodexUsageStatisticsCache(
            databaseURL: paths.applicationSupport.appending(path: "cache/account-usage.sqlite"),
            activityDatabaseURL: paths.applicationSupport.appending(path: "activity/daily.sqlite"))
        engine = AppEngine(manager: manager, paths: paths, clock: clock, codexCache: codexCache)
    }

    public static func standardError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Reads frames until end of input or `shutdown`, then waits until every request has its reply.
    /// A bad frame gets an error reply and reading goes on.
    public func serve(input: FileHandle, write: @escaping @Sendable (Data) -> Void) async {
        self.write = write
        let notifier = Task {
            for await change in engine.changes where isSubscribed(change.topic) {
                send(notification("state.changed", WireTopicChange(
                    topic: change.topic.rawValue, rev: change.rev, value: AnyEncodable(value: change.value))))
            }
        }
        defer { notifier.cancel() }
        reading: for await frame in Self.frames(input) {
            switch frame {
            case .tooLarge:
                send(reply(.null, .failure(.init(-32600, "invalidRequest", "The frame is larger than 16 MiB."))))
            case .line(let line):
                if await receive(line) { break reading }
            }
        }
        await allAnswered()
        await engine.stop()
    }

    // MARK: - Framing

    private enum Frame { case line(Data), tooLarge }

    /// Lines from `input`. The blocking read runs on its own thread, not on a thread of the shared async pool.
    private static func frames(_ input: FileHandle) -> AsyncStream<Frame> {
        AsyncStream { continuation in
            Thread {
                var buffer = Data()
                var skipping = false
                while case let chunk = input.availableData, !chunk.isEmpty {
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[buffer.startIndex..<newline])
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if skipping { skipping = false } else { continuation.yield(.line(line)) }
                    }
                    if buffer.count > maximumFrame {
                        buffer.removeAll()
                        skipping = true
                        continuation.yield(.tooLarge)
                    }
                }
                if !skipping, !buffer.isEmpty { continuation.yield(.line(buffer)) }
                continuation.finish()
            }.start()
        }
    }

    /// Handles one frame. Returns true after `shutdown`, when reading must stop.
    private func receive(_ frame: Data) async -> Bool {
        var line = frame
        if line.last == 0x0D { line.removeLast() }
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { return false }
        guard (try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed)) != nil else {
            send(reply(.null, .failure(.init(-32700, "parse", "The frame is not valid JSON."))))
            return false
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else {
            send(reply(.null, .failure(.init(-32600, "invalidRequest", "The frame must be a JSON-RPC 2.0 object."))))
            return false
        }
        guard envelope.jsonrpc == "2.0", let method = envelope.method, envelope.idIsValid else {
            send(reply(envelope.id ?? .null,
                       .failure(.init(-32600, "invalidRequest", "The frame must be a JSON-RPC 2.0 request."))))
            return false
        }
        guard envelope.hasID, let id = envelope.id else {
            if method == "$/cancelRequest", let target = try? JSONDecoder().decode(ParamsBox<CancelParams>.self, from: line) {
                cancel(target.params.id)
            }
            if method == "initialized" { await engine.start() }
            return false
        }
        if method == "shutdown" {
            await allAnswered()
            await engine.stop()
            log("rpc shutdown id=\(id) 0ms ok")
            send(reply(id, .success(String?.none)))
            return true
        }
        start(id, method, line)
        return false
    }

    // MARK: - Request lifetime

    private func start(_ id: RPCID, _ method: String, _ frame: Data) {
        let request = Pending(method: method)
        lock.lock()
        guard pending[id] == nil else {
            lock.unlock()
            send(reply(id, .failure(.init(-32600, "invalidRequest", "Request id \(id) is already waiting for a reply."))))
            return
        }
        pending[id] = request
        unanswered.enter()
        let order = Self.orderKey(method)
        let previous = order.flatMap { tails[$0] }
        lock.unlock()
        let work = Task {
            // Same-state requests take effect in arrival order: wait for the one before, even if it was cancelled.
            await previous?.value
            guard !Task.isCancelled else { return }
            let outcome: Result<any Encodable, RPCError>
            do {
                outcome = .success(try await self.call(method, frame: frame))
            } catch let error as RPCError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.failed(error, text: self.engine.describe(error)))
            }
            self.finish(id, request, outcome)
        }
        // A long method has no time limit; `$/cancelRequest` stops it.
        let timer = Self.longMethods.contains(method) ? nil : Task {
            guard (try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))) != nil else { return }
            self.finish(id, request, .failure(.init(
                -32007, "failed", "Switch did not finish \(method) within \(Int(self.timeout)) seconds.", retryable: true)))
        }
        lock.lock()
        if let order { tails[order] = work }
        if pending[id] === request { request.tasks = [work] + [timer].compactMap { $0 } } else { timer?.cancel() }
        lock.unlock()
    }

    /// Requests with the same key run one at a time in arrival order, so a client reads its own earlier write.
    /// Nil: the request runs at once beside the others (slow reads such as `usage.detail` and `usage.history`).
    static func orderKey(_ method: String) -> String? {
        if method.hasPrefix("settings.") { return "settings" }
        if method.hasPrefix("backup.") { return "backups" }
        if method.hasPrefix("cleanup.") { return "cleanup" }
        let accounts = ["accounts.", "providers.", "login.", "import.", "droid.", "autoSwitch."]
        if accounts.contains(where: method.hasPrefix) || method == "usage.refresh" { return "accounts" }
        return nil
    }

    /// `$/cancelRequest`: the request gets -32800 now; its work is cancelled and any later result is dropped.
    private func cancel(_ id: RPCID) {
        lock.lock()
        let request = pending[id]
        lock.unlock()
        if let request { finish(id, request, .failure(.cancelled)) }
    }

    /// Sends the reply once per request: the first of work, timer, or cancel wins.
    private func finish(_ id: RPCID, _ request: Pending, _ outcome: Result<any Encodable, RPCError>) {
        lock.lock()
        guard pending[id] === request else {
            lock.unlock()
            return
        }
        pending[id] = nil
        let tasks = request.tasks
        lock.unlock()
        tasks.forEach { $0.cancel() }
        let milliseconds = Int(Date().timeIntervalSince(request.started) * 1_000)
        switch outcome {
        case .success: log("rpc \(request.method) id=\(id) \(milliseconds)ms ok")
        case .failure(let error): log("rpc \(request.method) id=\(id) \(milliseconds)ms \(error.code) \(error.data.kind)")
        }
        send(reply(id, outcome))
        unanswered.leave()
    }

    private func allAnswered() async {
        await withCheckedContinuation { continuation in
            unanswered.notify(queue: .global()) { continuation.resume() }
        }
    }

    private func send(_ frame: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        write(frame + [0x0A])
    }

    // MARK: - Methods

    private func call(_ method: String, frame: Data) async throws -> any Encodable {
        switch method {
        case "initialize":
            return InitializeResult(
                protocolVersion: Self.protocolVersion, serverVersion: version,
                buildNumber: UpdateCheck.buildNumber(version: version) ?? 0, platform: Self.platform,
                methods: Self.methods, topics: Topic.allCases.map(\.rawValue),
                settingsSchemaVersion: Self.settingsSchemaVersion,
                features: .init(autoSwitchRestart: false, claudeUsageProbe: false))
        case "initialized":
            await engine.start()
            return String?.none
        case "state.subscribe":
            let topics = try topics(method: method, frame: frame)
            setSubscribed(topics, true)
            let snapshot = await engine.snapshot(topics)
            return Dictionary(uniqueKeysWithValues: snapshot.map {
                ($0.key.rawValue, WireTopicState(rev: $0.value.rev, value: AnyEncodable(value: $0.value.value)))
            })
        case "settings.get":
            let keys = (try? params(SettingsGetParams.self, method: method, frame: frame))?.keys
            return try await engine.settingsValues(keys)
        case "settings.set":
            let params = try params(SettingsSetParams.self, method: method, frame: frame)
            try await engine.setSetting(params.key, params.value)
            return try await engine.settingsValues([params.key])
        case "settings.reset":
            let name = (try? params(SettingsResetParams.self, method: method, frame: frame))?.group ?? "settings"
            guard let group = SettingKey.ResetGroup(rawValue: name) else {
                throw RPCError(-32602, "invalidParams", "group must be settings or kept.")
            }
            try await engine.resetSettings(group)
            return try await engine.settingsValues(nil)
        case "state.unsubscribe":
            setSubscribed(try topics(method: method, frame: frame), false)
            return String?.none
        case "accounts.status":
            return WireStatus(try await requireManager().status())
        case "usage.detail":
            let params = try params(UsageDetailParams.self, method: method, frame: frame)
            return try await usageDetail(try accountID(params.accountID), force: params.force ?? false)
        default:
            if let result = try await readMethod(method, frame: frame) { return result }
            if let result = try await writeMethod(method, frame: frame) { return result }
            if let result = try await backupMethod(method, frame: frame) { return result }
            if let result = try await cleanupMethod(method, frame: frame) { return result }
            guard let extra = extraMethods[method] else {
                throw RPCError(-32601, "unknownMethod", "Switch has no method '\(method)'.")
            }
            return try await extra(frame)
        }
    }

    /// Codex: the cached app-server snapshot unless it is stale or `force`; then a live check, as `ai-manager usage` does.
    /// Every other provider: one read through its `ProviderSpec`.
    private func usageDetail(_ id: UUID, force: Bool) async throws -> WireUsage {
        let account = try await account(id)
        let manager = try requireManager()
        guard account.identity.providerID == .codex else {
            return WireUsage(account, usage: try await manager.readProviderUsage(accountID: id))
        }
        if !force, let cached = try? await codexCache?.latest(for: id), let snapshot = cached.snapshot, !cached.isStale {
            return WireUsage(account, codex: snapshot)
        }
        let result = await manager.checkAccount(accountID: id)
        guard let snapshot = result.usage else {
            throw result.verification.state == .needsSignIn
                ? RPCError(-32006, "needsSignIn", result.verification.detail)
                : RPCError(-32007, "failed", result.verification.detail)
        }
        try? await codexCache?.upsertSuccess(accountID: id, snapshot: snapshot)
        return WireUsage(account, codex: snapshot)
    }

    func requireManager() throws -> AccountManager {
        guard let manager else {
            throw RPCError(-32002, "unavailable", "Switch cannot open its private data folder.")
        }
        return manager
    }

    func account(_ id: UUID) async throws -> AccountRecord {
        guard let account = try await requireManager().status().accounts.first(where: { $0.id == id }) else {
            throw RPCError.notFound
        }
        return account
    }

    func accountID(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else {
            throw RPCError(-32602, "invalidParams", "accountID must be an account UUID.")
        }
        return id
    }

    func params<P: Decodable>(_ type: P.Type, method: String, frame: Data) throws -> P {
        do {
            return try JSONDecoder().decode(ParamsBox<P>.self, from: frame).params
        } catch {
            throw RPCError(-32602, "invalidParams", "The params do not fit \(method).")
        }
    }

    private func topics(method: String, frame: Data) throws -> [Topic] {
        let names = try params(StateParams.self, method: method, frame: frame).topics
        return try names.map { name in
            guard let topic = Topic(rawValue: name) else {
                throw RPCError(-32602, "invalidParams", "Switch has no topic '\(name)'.")
            }
            return topic
        }
    }

    private func setSubscribed(_ topics: [Topic], _ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if on { subscribed.formUnion(topics) } else { subscribed.subtract(topics) }
    }

    private func isSubscribed(_ topic: Topic) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscribed.contains(topic)
    }

    /// `$/progress {token, value}` for a request that sent `progressToken`, at most every 100 ms (architecture.md 2.5).
    /// Nil when the request sent no token.
    func progress(_ frame: Data) -> (@Sendable (any Encodable) -> Void)? {
        guard let token = (try? JSONDecoder().decode(ParamsBox<ProgressTokenParams>.self, from: frame))?.params.progressToken
        else { return nil }
        let throttle = ProgressThrottle()
        return { [weak self] value in
            guard let self, throttle.due() else { return }
            self.send(self.notification("$/progress", ProgressParams(token: token, value: AnyEncodable(value: value))))
        }
    }

    private func notification(_ method: String, _ params: some Encodable) -> Data {
        (try? encoder.encode(Notification(method: method, params: params))) ?? Data()
    }

    private func reply(_ id: RPCID, _ outcome: Result<any Encodable, RPCError>) -> Data {
        if let data = try? encoder.encode(Reply(id: id, outcome: outcome)) { return data }
        let internalError = RPCError(-32603, "internal", "The reply could not be encoded.")
        return try! encoder.encode(Reply(id: id, outcome: .failure(internalError)))
    }

    static var platform: String {
        #if os(macOS)
        "macos"
        #elseif os(Windows)
        "windows"
        #else
        "linux"
        #endif
    }
}

// MARK: - Framing types

/// A request id: a number, a string, or null. Echoed exactly in the reply.
enum RPCID: Codable, Hashable, CustomStringConvertible {
    case number(Int)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let number = try? value.decode(Int.self) { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .number(let number): try value.encode(number)
        case .string(let text): try value.encode(text)
        case .null: try value.encodeNil()
        }
    }

    var description: String {
        switch self {
        case .number(let number): "\(number)"
        case .string(let text): text
        case .null: "null"
        }
    }
}

/// The request fields every frame is checked for; `params` is decoded later by the method.
private struct Envelope: Decodable {
    var jsonrpc: String?
    var method: String?
    var id: RPCID?
    var hasID = false
    var idIsValid = true

    enum CodingKeys: String, CodingKey { case jsonrpc, method, id }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try? values.decode(String.self, forKey: .jsonrpc)
        method = try? values.decode(String.self, forKey: .method)
        guard values.contains(.id) else { return }
        hasID = true
        id = (try? values.decodeNil(forKey: .id)) == true ? .null : try? values.decode(RPCID.self, forKey: .id)
        idIsValid = id != nil
    }
}

private struct ParamsBox<P: Decodable>: Decodable { let params: P }

private struct CancelParams: Decodable { let id: RPCID }
private struct ProgressTokenParams: Decodable { let progressToken: RPCID }
private struct ProgressParams: Encodable {
    let token: RPCID
    let value: AnyEncodable
}

/// The 100 ms throttle of one request's `$/progress`.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func due() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Date().timeIntervalSince(last) >= 0.1 else { return false }
        last = Date()
        return true
    }
}

struct RPCError: Error, Encodable {
    struct Detail: Encodable {
        let kind: String
        let retryable: Bool
    }

    let code: Int
    let message: String
    let data: Detail

    init(_ code: Int, _ kind: String, _ message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        data = .init(kind: kind, retryable: retryable)
    }

    static let notFound = RPCError(-32003, "notFound", "No saved account has that ID.")
    static let cancelled = RPCError(-32800, "cancelled", "The request was cancelled.")

    /// Core errors carry display text only, the same text the CLI prints.
    /// `text`: the privacy-masked message (`AppEngine.describe`); the plain description when nil.
    static func failed(_ error: Error, text: String? = nil) -> RPCError {
        let text = text ?? error.localizedDescription
        if let error = error as? AIManagerError, case .accountNotFound = error { return notFound }
        if let error = error as? SettingsError {
            return error == .readOnly ? RPCError(-32007, "failed", text) : RPCError(-32602, "invalidParams", text)
        }
        switch error as? AppEngineError {
        case .busy: return RPCError(-32001, "busy", text, retryable: true)
        case .unavailable: return RPCError(-32002, "unavailable", text)
        case .stale: return RPCError(-32004, "stale", text)
        case .unsupported: return RPCError(-32005, "unsupported", text)
        case .notFound: return RPCError(-32003, "notFound", text)
        case nil: return RPCError(-32007, "failed", text)
        }
    }
}

private struct Notification<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: P
}

private struct Reply: Encodable {
    let id: RPCID
    let outcome: Result<any Encodable, RPCError>

    enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("2.0", forKey: .jsonrpc)
        try values.encode(id, forKey: .id)
        switch outcome {
        case .success(let result): try values.encode(result, forKey: .result)
        case .failure(let error): try values.encode(error, forKey: .error)
        }
    }
}
