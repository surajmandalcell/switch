import Foundation
#if canImport(os)
import os
#endif

/// Append-only JSON Lines event log at `<app data>/logs/events.jsonl`, so a reported failure can be
/// traced after a restart. Callers pass structured fields only; `message` is sanitized and capped, and
/// request or response bodies, headers, URLs and account names never reach it. Logging never throws.
public final class EventLog: @unchecked Sendable {
    /// The config: every limit of the log in one place.
    public enum Limits {
        public static let maxFileBytes = 1_000_000
        /// Rotated files kept besides the live one (`events.1.jsonl` is the newest), so about 4 MB in all.
        public static let rotatedFiles = 3
        public static let maxAge: TimeInterval = 14 * 86_400
        /// A repeated event is written again after this long, with a `repeats` count.
        public static let repeatInterval: TimeInterval = 6 * 3_600
        public static let maxMessage = 200
        public static let osSubsystem = "com.mandalsuraj.ai-manager"
    }

    public enum Level: String, Sendable { case info, warn, error }

    public let directory: URL
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "ai-manager.event-log")
    private let fileManager = FileManager.default
    // All state below is touched on `queue` only.
    private var prepared = false
    private var size = 0
    private var prunedAt: Date?
    private var streams: [String: (key: String, written: Date, suppressed: Int)] = [:]
    private var failing = Set<UUID>()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var logs: [String: EventLog] = [:]
    }
    private static let registry = Registry()

    /// One writer per folder in a process, so queue order and flood state are shared.
    public static func shared(directory: URL) -> EventLog {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        let key = directory.standardizedFileURL.path
        if let existing = registry.logs[key] { return existing }
        let log = EventLog(directory: directory)
        registry.logs[key] = log
        return log
    }

    /// `macos`, `linux` or `windows`, for the start event.
    public static var platform: String {
        #if os(macOS)
        "macos"
        #elseif os(Windows)
        "windows"
        #else
        "linux"
        #endif
    }

    /// The start event of an app or command-line run.
    public func recordStart(event: String, version: String) {
        record(.info, area: "app", event: event, message: "version=\(version) platform=\(Self.platform)")
    }

    /// The log of the app data folder that `ManagerPaths.environment()` resolves.
    public static var standard: EventLog {
        shared(directory: ManagerPaths.environment().applicationSupport.appending(path: "logs", directoryHint: .isDirectory))
    }

    public var fileURL: URL { directory.appending(path: "events.jsonl") }

    /// Waits for queued state changes; writes themselves are synchronous.
    public func flush() { queue.sync {} }

    // MARK: Recording

    public func record(
        _ level: Level, area: String, event: String, provider: String? = nil, account: UUID? = nil,
        status: Int? = nil, message: String = "", dedupe: Bool = false
    ) {
        let at = now()
        let account = account.map { String($0.uuidString.lowercased().prefix(8)) }
        // Synchronous, so a line is on disk before the caller goes on (a test tearing down its
        // folder, or a command-line run calling exit()). One small append per event is cheap.
        queue.sync { [self] in
            write(at: at, level: level, area: area, event: event, provider: provider, account: account,
                  status: status, message: message, dedupe: dedupe)
        }
    }

    /// A usage check failed. Also notes a sign-in request (area `auth`) when the error says so.
    public func usageFailed(provider: String?, account: UUID, error: Error, status: Int?) {
        if error is CancellationError { return }
        // The probe may hold a status from an optional request, so use it only for an HTTP-shaped error.
        var status = status
        switch error as? ProviderError {
        case .http(let code, _)?: status = code
        case .unauthorized?, .rateLimited?, .unavailable?: break
        default: status = nil
        }
        queue.async { [self] in _ = failing.insert(account) }
        record(.warn, area: "usage", event: "usage_failed", provider: provider, account: account,
               status: status, message: Self.errorName(error), dedupe: true)
        if (error as? ProviderError)?.needsSignIn == true {
            record(.warn, area: "auth", event: "sign_in_required", provider: provider, account: account,
                   status: status, dedupe: true)
        }
    }

    public func isFailing(_ account: UUID) -> Bool { queue.sync { failing.contains(account) } }

    /// A check worked again after a failure seen by this process.
    public func usageRecovered(provider: String?, account: UUID) {
        let had = queue.sync { failing.remove(account) != nil }
        guard had else { return }
        let id = String(account.uuidString.lowercased().prefix(8))
        queue.async { [self] in
            for area in ["usage", "auth"] { streams["\(provider ?? "-")|\(id)|\(area)"] = nil }
        }
        record(.info, area: "usage", event: "usage_recovered", provider: provider, account: account)
    }

    /// Runs a switch, delete, import or rollback and logs its outcome (kind and class of any error only).
    public func transaction<T>(_ kind: String, _ body: () async throws -> T) async throws -> T {
        do {
            let result = try await body()
            record(.info, area: "switch", event: kind, message: "ok")
            return result
        } catch {
            record(.error, area: "switch", event: kind, message: "failed \(Self.errorName(error))")
            throw error
        }
    }

    /// `Type.case` for an enum error and `Type` otherwise, so an error's payload is never read.
    static func errorName(_ error: Error) -> String {
        let name = String(describing: type(of: error))
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return name }
        return "\(name).\(mirror.children.first?.label ?? String(describing: error))"
    }

    // MARK: Writing (on the queue)

    private func write(
        at date: Date, level: Level, area: String, event: String, provider: String?, account: String?,
        status: Int?, message: String, dedupe: Bool
    ) {
        var repeats: Int?
        if dedupe {
            let stream = "\(provider ?? "-")|\(account ?? "-")|\(area)"
            let key = "\(event)|\(status.map(String.init) ?? "-")"
            if var last = streams[stream], last.key == key {
                if date.timeIntervalSince(last.written) < Limits.repeatInterval {
                    last.suppressed += 1
                    streams[stream] = last
                    return
                }
                repeats = last.suppressed
            }
            streams[stream] = (key, date, 0)
        }
        let line = Line(
            t: formatter.string(from: date), level: level.rawValue, area: Self.sanitize(area, limit: 32),
            provider: provider.map { Self.sanitize($0, limit: 64) }, account: account.map { Self.sanitize($0, limit: 8) },
            event: Self.sanitize(event, limit: 64), status: status,
            message: Self.sanitize(message, limit: Limits.maxMessage), repeats: repeats.flatMap { $0 > 0 ? $0 : nil })
        guard var data = try? Self.encoder.encode(line) else { return }
        data.append(0x0A)
        append(data, at: date)
        #if canImport(os)
        let text = "\(line.event) provider=\(line.provider ?? "-") account=\(line.account ?? "-") status=\(status.map(String.init) ?? "-") \(line.message)"
        let logger = Logger(subsystem: Limits.osSubsystem, category: line.area)
        switch level {
        case .info: logger.info("\(text, privacy: .public)")
        case .warn: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        #endif
    }

    private func append(_ data: Data, at date: Date) {
        do {
            // A long-running app prunes again once a day; preparing again also re-reads the size.
            if let prunedAt, date.timeIntervalSince(prunedAt) > 86_400 { prepared = false }
            if !prepared {
                try CoreSupport.privateDirectory(directory, fileManager: fileManager)
                prune(at: date)
                if !CoreSupport.entryExists(fileURL) {
                    try CoreSupport.atomicWrite(Data(), to: fileURL, fileManager: fileManager)
                }
                size = (try fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
                prepared = true
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            size += data.count
            if size > Limits.maxFileBytes { try rotate(at: date) }
        } catch {
            prepared = false
        }
    }

    private func rotated(_ index: Int) -> URL { directory.appending(path: "events.\(index).jsonl") }

    private func rotate(at date: Date) throws {
        try? fileManager.removeItem(at: rotated(Limits.rotatedFiles))
        for index in stride(from: Limits.rotatedFiles - 1, through: 1, by: -1) where CoreSupport.entryExists(rotated(index)) {
            try fileManager.moveItem(at: rotated(index), to: rotated(index + 1))
        }
        try fileManager.moveItem(at: fileURL, to: rotated(1))
        try CoreSupport.atomicWrite(Data(), to: fileURL, fileManager: fileManager)
        size = 0
        prune(at: date)
    }

    /// Deletes rotated files whose newest entry (their last write) is older than the age limit, and
    /// drops the live file's lines older than that limit.
    private func prune(at date: Date) {
        prunedAt = date
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("events.") && name.hasSuffix(".jsonl") && name != "events.jsonl" {
            let url = directory.appending(path: name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, date.timeIntervalSince(modified) > Limits.maxAge { try? fileManager.removeItem(at: url) }
        }
        guard let data = fileManager.contents(atPath: fileURL.path), !data.isEmpty else { return }
        let cutoff = date.addingTimeInterval(-Limits.maxAge)
        let lines = data.split(separator: 0x0A)
        let kept = lines.filter { line in
            guard let stamp = try? JSONDecoder().decode(Stamp.self, from: line),
                  let written = formatter.date(from: stamp.t) else { return true }
            return written >= cutoff
        }
        guard kept.count < lines.count else { return }
        var rest = Data(kept.joined(separator: [0x0A]))
        if !kept.isEmpty { rest.append(0x0A) }
        try? CoreSupport.atomicWrite(rest, to: fileURL, fileManager: fileManager)
    }

    private struct Stamp: Decodable { let t: String }

    private struct Line: Encodable {
        let t: String, level: String, area: String
        let provider: String?, account: String?
        let event: String
        let status: Int?
        let message: String
        let repeats: Int?

        private enum Keys: String, CodingKey { case t, level, area, provider, account, event, status, message, repeats }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(t, forKey: .t)
            try c.encode(level, forKey: .level)
            try c.encode(area, forKey: .area)
            try c.encode(provider, forKey: .provider)
            try c.encode(account, forKey: .account)
            try c.encode(event, forKey: .event)
            try c.encode(status, forKey: .status)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(repeats, forKey: .repeats)
        }
    }

    // MARK: Sanitizer

    // Over-redacting is fine; leaking is not. Order matters: emails and key=value pairs go first.
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+"#, "<redacted>"),
        (#"(?i)\b(?:bearer|basic|digest)\s+[^\s,;"'}&]+"#, "<redacted>"),
        (#"(?i)([A-Za-z0-9_\-]*(?:key|token|secret|password|passwd|authorization|cookie|session))["']?\s*[=:]\s*["']?[^\s,;"'}&]+"#, "$1=<redacted>"),
        (#"\b(?:sk|pk|rk)[-_][A-Za-z0-9_\-]{8,}"#, "<redacted>"),
        (#"\b(?:gh[pousr]_|github_pat_|xox[abprs]-|AKIA)[A-Za-z0-9_\-]{8,}"#, "<redacted>"),
        (#"[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, "<redacted>"),
        // A long base64 or hex run; the lookahead keeps long class names (no digit or +/=) intact.
        (#"(?=[A-Za-z0-9+/_\-]*[0-9+/=])[A-Za-z0-9+/_\-]{32,}={0,2}"#, "<redacted>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Replaces credential-like and email-like text with `<redacted>`, flattens newlines, and caps the length.
    public static func sanitize(_ text: String, limit: Int = Limits.maxMessage) -> String {
        var value = String(text.prefix(4_000)).replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        for (regex, template) in patterns {
            value = regex.stringByReplacingMatches(
                in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
        }
        return String(value.prefix(limit))
    }
}

/// The first non-2xx HTTP status of one usage check, set by `HTTP.send`.
public final class HTTPStatusProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Int?
    public init() {}
    func note(_ status: Int) { lock.lock(); if first == nil { first = status }; lock.unlock() }
    public var status: Int? { lock.lock(); defer { lock.unlock() }; return first }
}

/// Who a usage check belongs to, so `HTTP.send` and a provider's parser can log without extra parameters.
public struct UsageLogContext: Sendable {
    public let log: EventLog
    public let account: UUID
    public let probe: HTTPStatusProbe

    @TaskLocal public static var current: UsageLogContext?
}
