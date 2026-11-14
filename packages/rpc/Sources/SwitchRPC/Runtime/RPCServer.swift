import Foundation
import AIManagerCore

/// `switch-core serve`: JSON-RPC 2.0 over stdio, one object per line (specs/port/architecture.md section 2).
/// Replies and errors carry no token, key, cookie, or password; the log line holds method, id, time, and outcome only.
// shortcut: requests run one at a time in arrival order, so a slow provider blocks the next request;
// run each request in its own Task when `$/cancelRequest` and progress land (plan unit R1).
public final class RPCServer {
    public static let protocolVersion = 1
    public static let methods = ["initialize", "initialized", "shutdown", "accounts.status", "usage.detail"]
    static let maximumFrame = 16 * 1024 * 1024

    private let manager: AccountManager?
    private let paths: ManagerPaths
    private let version: String
    private let log: (String) -> Void
    private lazy var codexCache: CodexUsageStatisticsCache? = try? CodexUsageStatisticsCache(
        databaseURL: paths.applicationSupport.appending(path: "cache/account-usage.sqlite"),
        activityDatabaseURL: paths.applicationSupport.appending(path: "activity/daily.sqlite"))
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// True after `shutdown`; `serve` then stops reading.
    public private(set) var isShutDown = false

    /// `manager` is nil when the private data folder cannot open; core methods then answer `unavailable`.
    public init(manager: AccountManager?, paths: ManagerPaths, version: String,
                log: @escaping (String) -> Void = RPCServer.standardError) {
        self.manager = manager
        self.paths = paths
        self.version = version
        self.log = log
    }

    public static func standardError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Reads frames until end of input or `shutdown`. A bad frame gets an error reply and reading goes on.
    public func serve(input: FileHandle, write: (Data) -> Void) async {
        var buffer = Data()
        var skipping = false
        func emit(_ reply: Data?) { if let reply { write(reply + [0x0A]) } }
        while !isShutDown {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while !isShutDown, let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if skipping { skipping = false } else { emit(await handle(line)) }
            }
            if buffer.count > Self.maximumFrame {
                buffer.removeAll()
                skipping = true
                emit(reply(.null, .failure(.init(-32600, "invalidRequest", "The frame is larger than 16 MiB."))))
            }
        }
        if !isShutDown, !skipping, !buffer.isEmpty { emit(await handle(buffer)) }
    }

    /// One frame in, the reply frame out (without the newline), or nil for a notification or a blank line.
    public func handle(_ frame: Data) async -> Data? {
        var line = frame
        if line.last == 0x0D { line.removeLast() }
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { return nil }
        guard (try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed)) != nil else {
            return reply(.null, .failure(.init(-32700, "parse", "The frame is not valid JSON.")))
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else {
            return reply(.null, .failure(.init(-32600, "invalidRequest", "The frame must be a JSON-RPC 2.0 object.")))
        }
        guard envelope.jsonrpc == "2.0", let method = envelope.method, envelope.idIsValid else {
            return reply(envelope.id ?? .null,
                         .failure(.init(-32600, "invalidRequest", "The frame must be a JSON-RPC 2.0 request.")))
        }
        guard envelope.hasID, let id = envelope.id else { return nil }
        let started = Date()
        let outcome: Result<any Encodable, RPCError>
        do {
            outcome = .success(try await call(method, frame: line))
        } catch let error as RPCError {
            outcome = .failure(error)
        } catch {
            outcome = .failure(.failed(error))
        }
        let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        let result: String
        switch outcome {
        case .success: result = "ok"
        case .failure(let error): result = "\(error.code) \(error.data.kind)"
        }
        log("rpc \(method) id=\(id) \(milliseconds)ms \(result)")
        return reply(id, outcome)
    }

    // MARK: - Methods

    private func call(_ method: String, frame: Data) async throws -> any Encodable {
        switch method {
        case "initialize":
            return InitializeResult(protocolVersion: Self.protocolVersion, serverVersion: version,
                                    platform: Self.platform, methods: Self.methods)
        case "initialized":
            return String?.none
        case "shutdown":
            isShutDown = true
            return String?.none
        case "accounts.status":
            return WireStatus(try await requireManager().status())
        case "usage.detail":
            let params = try params(UsageDetailParams.self, method: method, frame: frame)
            guard let id = UUID(uuidString: params.accountID) else {
                throw RPCError(-32602, "invalidParams", "accountID must be an account UUID.")
            }
            return try await usageDetail(id, force: params.force ?? false)
        default:
            throw RPCError(-32601, "unknownMethod", "Switch has no method '\(method)'.")
        }
    }

    /// Codex: the cached app-server snapshot unless it is stale or `force`; then a live check, as `ai-manager usage` does.
    /// Every other provider: one read through its `ProviderSpec`.
    private func usageDetail(_ id: UUID, force: Bool) async throws -> WireUsage {
        let manager = try requireManager()
        guard let account = try await manager.status().accounts.first(where: { $0.id == id }) else {
            throw RPCError.notFound
        }
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

    private func requireManager() throws -> AccountManager {
        guard let manager else {
            throw RPCError(-32002, "unavailable", "Switch cannot open its private data folder.")
        }
        return manager
    }

    private func params<P: Decodable>(_ type: P.Type, method: String, frame: Data) throws -> P {
        do {
            return try JSONDecoder().decode(ParamsBox<P>.self, from: frame).params
        } catch {
            throw RPCError(-32602, "invalidParams", "The params do not fit \(method).")
        }
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
enum RPCID: Codable, Equatable, CustomStringConvertible {
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

    /// Core errors carry display text only, the same text the CLI prints.
    static func failed(_ error: Error) -> RPCError {
        if let error = error as? AIManagerError, case .accountNotFound = error { return notFound }
        return RPCError(-32007, "failed", error.localizedDescription)
    }
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
