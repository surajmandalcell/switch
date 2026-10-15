import Foundation

// Local Claude Code cost scan: reads `projects/**/*.jsonl` session logs, dedupes replayed
// lines, buckets tokens by local day, and prices them from the LiteLLM catalog. Ported from
// OpenUsage's ClaudeLogUsageScanner and ModelPricing, trimmed to one root list and one cache file.

// MARK: - Pricing

/// Per-million-token USD rates for one model.
public struct ModelRate: Codable, Equatable, Sendable {
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    public var cacheWritePerMillion: Double
    public var cacheReadPerMillion: Double
    /// Rates for a request whose prompt exceeds 200k tokens; the whole request is billed at them.
    public var inputAbove200k: Double?
    public var outputAbove200k: Double?
    public var cacheWriteAbove200k: Double?
    public var cacheReadAbove200k: Double?
    /// Multiplier for `speed: "fast"` requests.
    public var fastMultiplier: Double

    static let longContextThreshold = 200_000

    /// A missing cache write rate is 1.25x input; a missing cache read rate is 0.1x input.
    public init(input: Double, output: Double, cacheWrite: Double? = nil, cacheRead: Double? = nil,
                inputAbove200k: Double? = nil, outputAbove200k: Double? = nil,
                cacheWriteAbove200k: Double? = nil, cacheReadAbove200k: Double? = nil,
                fastMultiplier: Double = 1) {
        inputPerMillion = input
        outputPerMillion = output
        cacheWritePerMillion = cacheWrite ?? input * 1.25
        cacheReadPerMillion = cacheRead ?? input * 0.1
        self.inputAbove200k = inputAbove200k
        self.outputAbove200k = outputAbove200k
        self.cacheWriteAbove200k = cacheWriteAbove200k
        self.cacheReadAbove200k = cacheReadAbove200k
        self.fastMultiplier = fastMultiplier
    }

    /// USD for one request. 1-hour cache writes bill at 2x the input rate.
    func cost(input: Int, output: Int, cacheRead: Int, cacheWrite5m: Int, cacheWrite1h: Int,
              fast: Bool) -> Double {
        let long = input + cacheRead + cacheWrite5m + cacheWrite1h > Self.longContextThreshold
        func pick(_ base: Double, _ above: Double?) -> Double { long ? (above ?? base) : base }
        let inputRate = pick(inputPerMillion, inputAbove200k)
        let total = Double(input) * inputRate
            + Double(output) * pick(outputPerMillion, outputAbove200k)
            + Double(cacheRead) * pick(cacheReadPerMillion, cacheReadAbove200k)
            + Double(cacheWrite5m) * pick(cacheWritePerMillion, cacheWriteAbove200k)
            + Double(cacheWrite1h) * inputRate * 2
        return total / 1_000_000 * (fast ? fastMultiplier : 1)
    }

    /// Reads LiteLLM `model_prices_and_context_window.json`. Entries need numeric input and
    /// output costs; per-token costs become per-million rates.
    public static func catalog(from data: Data) -> [String: ModelRate] {
        guard data.count <= 32 * 1_024 * 1_024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        func rate(_ entry: [String: Any], _ key: String) -> Double? {
            guard let number = entry[key] as? NSNumber, !JSON.isBoolean(entry[key]) else { return nil }
            let value = number.doubleValue * 1_000_000
            return value.isFinite && value >= 0 ? value : nil
        }
        var rates: [String: ModelRate] = [:]
        for (name, value) in root {
            guard let entry = value as? [String: Any],
                  let input = rate(entry, "input_cost_per_token"),
                  let output = rate(entry, "output_cost_per_token") else { continue }
            let fast = ((entry["provider_specific_entry"] as? [String: Any])?["fast"] as? NSNumber)?.doubleValue
            rates[name] = ModelRate(
                input: input, output: output,
                cacheWrite: rate(entry, "cache_creation_input_token_cost"),
                cacheRead: rate(entry, "cache_read_input_token_cost"),
                inputAbove200k: rate(entry, "input_cost_per_token_above_200k_tokens"),
                outputAbove200k: rate(entry, "output_cost_per_token_above_200k_tokens"),
                cacheWriteAbove200k: rate(entry, "cache_creation_input_token_cost_above_200k_tokens"),
                cacheReadAbove200k: rate(entry, "cache_read_input_token_cost_above_200k_tokens"),
                fastMultiplier: fast.flatMap { $0 >= 1 && $0.isFinite ? $0 : nil } ?? 1)
        }
        return rates
    }
}

/// Model name lookup over a catalog: exact, then the same name without provider prefix, date
/// suffix and version noise, then the longest key that matches at word boundaries.
struct ModelRateTable {
    private let rates: [String: ModelRate]
    private let byBase: [String: ModelRate]
    private let bases: [(base: String, rate: ModelRate)]
    private var memo: [String: ModelRate?] = [:]

    init(_ rates: [String: ModelRate]) {
        self.rates = rates
        // The shortest original key wins a base name (`claude-sonnet-4-5` over `bedrock/...`).
        var index: [String: (key: String, rate: ModelRate)] = [:]
        for (key, rate) in rates {
            let base = Self.baseName(key)
            if let current = index[base], (current.key.count, current.key) <= (key.count, key) { continue }
            index[base] = (key, rate)
        }
        byBase = index.mapValues(\.rate)
        bases = index.sorted { ($0.key.count, $1.key) > ($1.key.count, $0.key) }.map { ($0.key, $0.value.rate) }
    }

    mutating func resolve(_ model: String) -> ModelRate? {
        if let known = memo[model] { return known }
        let found = lookup(model)
        memo[model] = .some(found)
        return found
    }

    private func lookup(_ model: String) -> ModelRate? {
        if let exact = rates[model] { return exact }
        let base = Self.baseName(model)
        if let hit = byBase[base] { return hit }
        // `bases` runs longest key first, so the first boundary match is the longest.
        return bases.first { Self.contains(base, key: $0.base) || Self.contains($0.base, key: base) }?.rate
    }

    /// Lowercase, no provider prefix (`anthropic/`, `us.anthropic.`), no `[1m]`, `-v1:0` or
    /// date suffix, and `.` or `@` read as `-`.
    static func baseName(_ raw: String) -> String {
        var name = raw.lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let range = name.range(of: "anthropic.") { name = String(name[range.upperBound...]) }
        for pattern in [#"\[[^\]]*\]$"#, #"-v\d+(:\d+)?$"#, #"[-@]\d{8}$"#] {
            name = name.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return name.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "@", with: "-")
    }

    /// `key` inside `value` between non-alphanumerics, where the rest does not continue a numeric
    /// version: `claude-sonnet-4` matches `claude-sonnet-4-20250514` but not `claude-sonnet-4-5`.
    static func contains(_ value: String, key: String) -> Bool {
        let v = Array(value.utf8), k = Array(key.utf8)
        guard !k.isEmpty, k.count <= v.count else { return false }
        func alnum(_ b: UInt8) -> Bool { (48...57).contains(b) || (97...122).contains(b) || (65...90).contains(b) }
        for start in 0...(v.count - k.count) where v[start..<start + k.count].elementsEqual(k) {
            if start > 0, alnum(v[start - 1]) { continue }
            let rest = Array(v[(start + k.count)...])
            guard let first = rest.first else { return true }
            if alnum(first) { continue }
            guard let last = k.last, (48...57).contains(last), first == UInt8(ascii: "-") || first == UInt8(ascii: ".")
            else { return true }
            let digits = rest.dropFirst().prefix { (48...57).contains($0) }.count
            let after = rest.dropFirst(1 + digits).first
            if digits == 0 || (digits == 8 && after.map { !alnum($0) } ?? true) { return true }
        }
        return false
    }
}

/// Loads LiteLLM rates with the Codex price cache rules: one catalog URL, 24 h cache, and the
/// stale cache when the network fails. Pass the same `cacheURL` as `CodexAPIPricingResolver` to
/// share one file.
public actor ClaudePricingSource {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let cacheURL: URL
    private let now: @Sendable () -> Date
    private let fetch: Fetch
    private var loaded: (rates: [String: ModelRate], at: Date)?
    private var failedAt: Date?
    /// A failed fetch is not retried for this long.
    static let retryAfter: TimeInterval = 30 * 60

    public init(cacheURL: URL, now: @escaping @Sendable () -> Date = { Date() },
                fetch: @escaping Fetch = { url in
                    let response = try await HTTP.send(url.absoluteString)
                    guard (200..<300).contains(response.status) else { throw URLError(.badServerResponse) }
                    return response.data
                }) {
        self.cacheURL = cacheURL
        self.now = now
        self.fetch = fetch
    }

    /// Never throws: returns the stale catalog, or an empty table, when nothing is reachable.
    public func rates() async -> [String: ModelRate] {
        let current = now()
        if let loaded, current.timeIntervalSince(loaded.at) < CodexAPIPricingResolver.cacheTTL { return loaded.rates }
        let disk = try? Data(contentsOf: cacheURL, options: [.mappedIfSafe])
        let modified = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let disk, let modified, current.timeIntervalSince(modified) < CodexAPIPricingResolver.cacheTTL {
            let parsed = ModelRate.catalog(from: disk)
            if !parsed.isEmpty { return remember(parsed, at: current) }
        }
        if let failedAt, current.timeIntervalSince(failedAt) < Self.retryAfter {
            return loaded?.rates ?? disk.map(ModelRate.catalog(from:)) ?? [:]
        }
        do {
            let data = try await fetch(CodexAPIPricingResolver.catalogURL)
            let parsed = ModelRate.catalog(from: data)
            guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
            store(data)
            failedAt = nil
            return remember(parsed, at: current)
        } catch {
            failedAt = current
            return loaded?.rates ?? disk.map(ModelRate.catalog(from:)) ?? [:]
        }
    }

    /// The closure form `ClaudeCostScanner` takes.
    public nonisolated func loader() -> @Sendable () async -> [String: ModelRate] {
        { await self.rates() }
    }

    private func remember(_ rates: [String: ModelRate], at date: Date) -> [String: ModelRate] {
        loaded = (rates, date)
        return rates
    }

    private func store(_ data: Data) {
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: cacheURL, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}

// MARK: - Scan

public struct ClaudeDailyCost: Codable, Equatable, Sendable {
    /// Local calendar day, yyyy-MM-dd.
    public var date: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    /// Sum of the priced share of the day; nil when nothing that day could be priced.
    public var costUSD: Double?
    /// Models with tokens that day that have no rate. Their cost is not in `costUSD`.
    public var unpricedModels: [String]

    public init(date: String, inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
                cacheWriteTokens: Int = 0, costUSD: Double? = nil, unpricedModels: [String] = []) {
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
        self.unpricedModels = unpricedModels
    }
}

/// One parsed usage line. Stored in the cache as tokens, never dollars, so a price change
/// reprices without re-reading the logs.
struct ClaudeUsageEvent: Codable, Equatable {
    var time: Date
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite5m: Int
    var cacheWrite1h: Int
    var fast: Bool
    /// The line had a `speed` field (dedup tiebreaker).
    var hasSpeed: Bool
    var messageID: String?
    var requestID: String?
    var sidechain: Bool
    var costUSD: Double?
    /// Raw model name, `<synthetic>` included.
    var model: String?
    /// Index of the source file while one scan runs. Never stored.
    var origin = 0

    var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    private enum CodingKeys: String, CodingKey {
        case time, input, output, cacheRead, cacheWrite5m, cacheWrite1h, fast, hasSpeed
        case messageID, requestID, sidechain, costUSD, model
    }
}

/// Turns JSONL bytes into events. Owns its date formatters, so use one per scan.
struct ClaudeLogParser {
    static let maxLineBytes = 1_048_576
    private static let marker = Data(#""usage":{"#.utf8)
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plain = ISO8601DateFormatter()

    /// The first working directory a log names. Reads only the bytes up to that value.
    static func cwd(in data: Data) -> String? {
        guard let found = data.range(of: Data(#""cwd":""#.utf8)) else { return nil }
        var end = found.upperBound
        var escaped = false
        while end < data.endIndex, end - found.upperBound < 4_096 {
            if escaped { escaped = false } else if data[end] == 0x5C { escaped = true } else if data[end] == 0x22 { break }
            end += 1
        }
        guard end < data.endIndex, data[end] == 0x22 else { return nil }
        let quoted = Data([0x22]) + data[found.upperBound..<end] + Data([0x22])
        return (try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed)) as? String
    }

    func parse(_ data: Data) -> [ClaudeUsageEvent] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [ClaudeUsageEvent] in
            guard let base = raw.baseAddress else { return [] }
            var events: [ClaudeUsageEvent] = []
            var start = 0
            while start < raw.count {
                let found = memchr(base + start, 10, raw.count - start)
                let end = found.map { base.distance(to: UnsafeRawPointer($0)) } ?? raw.count
                defer { start = end + 1 }
                guard end - start <= Self.maxLineBytes else { continue }
                // Zero-copy view for the cheap substring prefilter; copy only matching lines.
                let view = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                                count: end - start, deallocator: .none)
                if view.range(of: Self.marker) != nil { events += parseLine(Data(view)) }
            }
            return events
        }
    }

    func parseLine(_ line: Data) -> [ClaudeUsageEvent] {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let time = fractional.date(from: stamp) ?? plain.date(from: stamp),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              Self.isValid(object, message: message, usage: usage),
              let tokens = Self.tokens(usage) else { return [] }
        let model = message["model"] as? String
        var parent = ClaudeUsageEvent(
            time: time, input: tokens.input, output: tokens.output, cacheRead: tokens.cacheRead,
            cacheWrite5m: tokens.cw5m, cacheWrite1h: tokens.cw1h, fast: tokens.fast,
            hasSpeed: tokens.hasSpeed, messageID: message["id"] as? String,
            requestID: object["requestId"] as? String,
            sidechain: object["isSidechain"] as? Bool ?? false,
            costUSD: (object["costUSD"] as? NSNumber)?.doubleValue, model: model)
        var events = [parent]
        // Advisor iterations are extra requests on their own model; other iterations are
        // already inside the parent totals.
        var advisor = 0
        for iteration in usage["iterations"] as? [[String: Any]] ?? []
        where iteration["type"] as? String == "advisor_message" {
            guard let name = iteration["model"] as? String, !name.isEmpty,
                  let t = Self.tokens(iteration) else { continue }
            parent.input = t.input; parent.output = t.output; parent.cacheRead = t.cacheRead
            parent.cacheWrite5m = t.cw5m; parent.cacheWrite1h = t.cw1h; parent.fast = t.fast
            parent.hasSpeed = t.hasSpeed; parent.costUSD = nil; parent.model = name
            parent.messageID = (message["id"] as? String).map { "\($0):advisor:\(advisor)" }
            events.append(parent)
            advisor += 1
        }
        return events
    }

    private static func tokens(_ usage: [String: Any])
        -> (input: Int, output: Int, cacheRead: Int, cw5m: Int, cw1h: Int, fast: Bool, hasSpeed: Bool)? {
        guard let input = usage["input_tokens"] as? NSNumber, let output = usage["output_tokens"] as? NSNumber
        else { return nil }
        let speed = usage["speed"] as? String
        if let speed, speed != "fast", speed != "standard" { return nil }
        var cw5m = 0, cw1h = 0
        if let split = usage["cache_creation"] as? [String: Any] {
            cw5m = (split["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0
            cw1h = (split["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        } else {
            cw5m = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
        }
        return (max(input.intValue, 0), max(output.intValue, 0),
                max((usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0, 0),
                max(cw5m, 0), max(cw1h, 0), speed == "fast", speed != nil)
    }

    /// Claude never writes null into these fields, an empty id or model, or a non-semver version;
    /// a line that does comes from a foreign tool.
    private static func isValid(_ object: [String: Any], message: [String: Any], usage: [String: Any]) -> Bool {
        let nullable: [([String: Any], [String])] = [
            (object, ["cwd", "costUSD", "version", "sessionId", "requestId", "isApiErrorMessage"]),
            (message, ["id", "model"]),
            (usage, ["speed", "cache_read_input_tokens", "cache_creation_input_tokens"]),
        ]
        for (container, keys) in nullable where keys.contains(where: { container[$0] is NSNull }) { return false }
        if let version = object["version"] as? String,
           version.range(of: #"^\d+\.\d+\.\d"#, options: .regularExpression) == nil { return false }
        for value in [object["sessionId"], object["requestId"], message["id"], message["model"]] {
            if let text = value as? String, text.isEmpty { return false }
        }
        return true
    }
}

/// One UTC day of Claude Code usage for one model and project. `accountID` is set only when the
/// log file lives in a single account's own home (see `ClaudeCostScanner.history`).
public struct ClaudeHistoryRow: Equatable, Sendable {
    public var day: String
    public var model: String?
    public var project: String
    public var accountID: String?
    public var tokens: Int64
    public var costUSD: Double?
}

/// One Claude Code session (log file) on one UTC day.
public struct ClaudeDaySession: Equatable, Sendable {
    public var sessionID: String
    public var project: String
    public var accountID: String?
    public var model: String?
    public var start: Date
    public var tokens: Int64
    public var costUSD: Double?
}

public actor ClaudeCostScanner {
    public typealias Pricing = @Sendable () async -> [String: ModelRate]

    private struct FileRecord: Codable {
        var size: Int
        var mtime: Double
        var events: [ClaudeUsageEvent]
        /// First working directory the log names; nil in records saved before this field existed.
        var project: String?
    }

    private struct HistoryMemo {
        var signature: [String]
        var day: Int
        var builtAt: Date
        var unpriced: Bool
        var rows: [ClaudeHistoryRow]
    }

    private var historyCache: CacheFile?
    private var historyMemo: HistoryMemo?

    private struct CacheFile: Codable {
        var version: Int
        var files: [String: FileRecord]
    }

    static let cacheVersion = 1

    private let roots: [URL]
    private let cacheURL: URL
    private let pricing: Pricing
    private let calendar: Calendar
    /// Files parsed (not served from the cache) over this scanner's life.
    private(set) var filesParsed = 0

    public init(roots: [URL] = ClaudeCostScanner.defaultRoots(), cacheURL: URL,
                pricing: @escaping Pricing, calendar: Calendar = .current) {
        self.roots = roots
        self.cacheURL = cacheURL
        self.pricing = pricing
        self.calendar = calendar
    }

    /// `projects/` dirs of `$CLAUDE_CONFIG_DIR` (comma list), `$XDG_CONFIG_HOME/claude` and
    /// `~/.claude` that exist.
    public static func defaultRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var candidates = (environment["CLAUDE_CONFIG_DIR"] ?? "").split(separator: ",")
            .map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces)) }
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".config", directoryHint: .isDirectory)
        candidates += [xdg.appending(path: "claude", directoryHint: .isDirectory),
                       home.appending(path: ".claude", directoryHint: .isDirectory)]
        return candidates.compactMap(projectsDirectory)
    }

    /// The root itself, or its `projects/` child when it is a config dir.
    private static func projectsDirectory(_ root: URL) -> URL? {
        let inner = root.appending(path: "projects", directoryHint: .isDirectory)
        for url in [inner, root] where isDirectory(url) { return url }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// One entry per local day with usage in the last `days` days (today included), oldest first.
    public func daily(days: Int = 30, now: Date = Date()) async throws -> [ClaudeDailyCost] {
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
        var cache = loadCache()
        let parsedBefore = filesParsed
        var next: [String: FileRecord] = [:]
        let parser = ClaudeLogParser()
        var events: [ClaudeUsageEvent] = []

        for file in discover() where file.mtime >= since.timeIntervalSince1970 {
            if let record = cache.files[file.path], record.size == file.size, record.mtime == file.mtime {
                next[file.path] = record
            } else {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: [.mappedIfSafe])
                else { continue }
                filesParsed += 1
                next[file.path] = FileRecord(size: file.size, mtime: file.mtime, events: parser.parse(data))
            }
            events += next[file.path]?.events ?? []
        }
        // ponytail: records outside this window are dropped, so a shorter `days` call trims the
        // cache; keep a union with a 35 day purge if two windows alternate.
        if filesParsed != parsedBefore || Set(next.keys) != Set(cache.files.keys) {
            cache.files = next
            saveCache(cache)
        }

        let kept = Self.dedup(events).filter { $0.time >= since }
        var table = ModelRateTable([:])
        if kept.contains(where: { $0.costUSD == nil && $0.model != nil && $0.model != "<synthetic>" }) {
            table = ModelRateTable(await pricing())
        }
        return aggregate(kept, table: &table)
    }

    /// Usage per UTC day, model and project for the last `days` days (today included). Give this
    /// scanner its own `cacheURL`: it keeps files up to a year old, which would trim the 30 day cache.
    /// `account` maps a log file's real path to the account whose own home holds it, nil for shared
    /// homes. Parsing stays incremental (unchanged files are served from the cache, and an unchanged
    /// file set returns the previous rows), and no message text is kept.
    /// ponytail: the cache holds every event of the window as JSON; store per-day sums instead if
    /// it grows past tens of megabytes.
    public func history(days: Int = 365, now: Date = Date(),
                        account: (String) -> String? = { _ in nil }) async -> [ClaudeHistoryRow] {
        let today = Int((now.timeIntervalSince1970 / 86_400).rounded(.down))
        let first = today - (max(days, 1) - 1)
        let since = Double(first) * 86_400
        let files = discover().filter { $0.mtime >= since }
        let signature = files.map { "\($0.path)\0\($0.size)\0\($0.mtime)" }
        if let memo = historyMemo, memo.signature == signature, memo.day == today,
           !memo.unpriced || now.timeIntervalSince(memo.builtAt) < 30 * 60 { return memo.rows }

        var cache = historyCache ?? loadCache()
        var next: [String: FileRecord] = [:]
        let parser = ClaudeLogParser()
        var parsedAny = false
        for file in files {
            if let record = cache.files[file.path], record.size == file.size, record.mtime == file.mtime,
               record.project != nil {
                next[file.path] = record
            } else {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: [.mappedIfSafe])
                else { continue }
                filesParsed += 1
                parsedAny = true
                next[file.path] = FileRecord(size: file.size, mtime: file.mtime, events: parser.parse(data),
                                             project: ClaudeLogParser.cwd(in: data) ?? "")
            }
        }
        if parsedAny || Set(next.keys) != Set(cache.files.keys) {
            cache.files = next
            saveCache(cache)
        }
        historyCache = cache

        var origins: [(project: String, account: String?)] = []
        var events: [ClaudeUsageEvent] = []
        for file in files {
            guard let record = next[file.path] else { continue }
            let project = record.project.flatMap { $0.isEmpty ? nil : $0 }
                ?? URL(fileURLWithPath: file.path).deletingLastPathComponent().lastPathComponent
            origins.append((project, account(file.path)))
            events += record.events.map { var event = $0; event.origin = origins.count - 1; return event }
        }
        let kept = Self.dedup(events).filter {
            $0.time.timeIntervalSince1970 >= since && $0.model != "<synthetic>" && $0.total > 0
        }
        var table = ModelRateTable([:])
        if kept.contains(where: { $0.costUSD == nil && $0.model != nil }) {
            table = ModelRateTable(await pricing())
        }
        struct Key: Hashable { var day: Int; var model: String?; var origin: Int }
        var sums: [Key: (tokens: Int64, cost: Double?)] = [:]
        var unpriced = false
        for event in kept {
            let key = Key(day: Int((event.time.timeIntervalSince1970 / 86_400).rounded(.down)),
                          model: event.model, origin: event.origin)
            let cost = Self.cost(of: event, table: &table)
            if cost == nil { unpriced = true }
            var sum = sums[key] ?? (0, nil)
            sum.tokens += Int64(event.total)
            if let cost { sum.cost = (sum.cost ?? 0) + cost }
            sums[key] = sum
        }
        var dayNames: [Int: String] = [:]
        struct RowKey: Hashable { var day: Int; var model: String?; var project: String; var account: String? }
        var merged: [RowKey: (tokens: Int64, cost: Double?)] = [:]
        for (key, sum) in sums {
            let origin = origins[key.origin]
            let rowKey = RowKey(day: key.day, model: key.model, project: origin.project, account: origin.account)
            var row = merged[rowKey] ?? (0, nil)
            row.tokens += sum.tokens
            if let cost = sum.cost { row.cost = (row.cost ?? 0) + cost }
            merged[rowKey] = row
        }
        func dayName(_ day: Int) -> String {
            if let known = dayNames[day] { return known }
            let name = Self.utcDayName(day)
            dayNames[day] = name
            return name
        }
        let rows = merged.map { key, sum in
            ClaudeHistoryRow(day: dayName(key.day), model: key.model, project: key.project,
                             accountID: key.account, tokens: sum.tokens, costUSD: sum.cost)
        }.sorted { ($0.day, $0.project, $0.model ?? "") < ($1.day, $1.project, $1.model ?? "") }
        historyMemo = HistoryMemo(signature: signature, day: today, builtAt: now, unpriced: unpriced, rows: rows)
        return rows
    }

    /// The sessions (one log file each) with usage on one UTC day, from the same cache and dedup as
    /// `history`. Nothing is saved; a log the cache lacks is parsed once for this call.
    public func daySessions(day: String, account: (String) -> String? = { _ in nil }) async -> [ClaudeDaySession] {
        guard let epoch = UsageHistory.epochDay(day) else { return [] }
        let (from, until) = (Double(epoch) * 86_400, Double(epoch + 1) * 86_400)
        let cache = historyCache ?? loadCache()
        let parser = ClaudeLogParser()
        var origins: [(id: String, project: String, account: String?)] = []
        var events: [ClaudeUsageEvent] = []
        for file in discover() where file.mtime >= from {
            var record = cache.files[file.path]
            if record == nil || record?.size != file.size || record?.mtime != file.mtime || record?.project == nil {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: [.mappedIfSafe])
                else { continue }
                record = FileRecord(size: file.size, mtime: file.mtime, events: parser.parse(data),
                                    project: ClaudeLogParser.cwd(in: data) ?? "")
            }
            guard let record else { continue }
            let url = URL(fileURLWithPath: file.path)
            let project = record.project.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingLastPathComponent().lastPathComponent
            origins.append((url.deletingPathExtension().lastPathComponent, project, account(file.path)))
            events += record.events.map { var event = $0; event.origin = origins.count - 1; return event }
        }
        let kept = Self.dedup(events).filter {
            (from..<until).contains($0.time.timeIntervalSince1970) && $0.model != "<synthetic>" && $0.total > 0
        }
        var table = ModelRateTable([:])
        if kept.contains(where: { $0.costUSD == nil && $0.model != nil }) { table = ModelRateTable(await pricing()) }
        struct Sum { var tokens: Int64 = 0; var cost: Double?; var start = Date.distantFuture; var models: [String: Int64] = [:] }
        var sums: [Int: Sum] = [:]
        for event in kept {
            var sum = sums[event.origin] ?? Sum()
            sum.tokens += Int64(event.total)
            if let cost = Self.cost(of: event, table: &table) { sum.cost = (sum.cost ?? 0) + cost }
            sum.start = min(sum.start, event.time)
            if let model = event.model { sum.models[model, default: 0] += Int64(event.total) }
            sums[event.origin] = sum
        }
        return sums.map { origin, sum in
            ClaudeDaySession(
                sessionID: origins[origin].id, project: origins[origin].project, accountID: origins[origin].account,
                model: sum.models.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key, start: sum.start,
                tokens: sum.tokens, costUSD: sum.cost)
        }
    }

    /// `yyyy-MM-dd` of a day count since 1970-01-01 (UTC).
    static func utcDayName(_ epochDay: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(epochDay) * 86_400))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Discovery

    private struct Found { var path: String; var size: Int; var mtime: Double }

    /// Every `*.jsonl` under the roots, symlinks followed, one entry per real path, path-sorted.
    private func discover() -> [Found] {
        var visited = Set<String>()
        var files: [String: Found] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        func walk(_ directory: URL) {
            let real = directory.resolvingSymlinksInPath()
            guard visited.insert(real.path).inserted,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: real, includingPropertiesForKeys: nil) else { return }
            for child in children {
                let target = child.resolvingSymlinksInPath()
                guard let values = try? target.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    walk(target)
                } else if values.isRegularFile == true, target.pathExtension == "jsonl",
                          let mtime = values.contentModificationDate {
                    files[target.path] = Found(path: target.path, size: values.fileSize ?? 0,
                                               mtime: mtime.timeIntervalSince1970)
                }
            }
        }
        for root in roots { walk(Self.projectsDirectory(root) ?? root) }
        return files.values.sorted { $0.path < $1.path }
    }

    // MARK: Cache

    private func loadCache() -> CacheFile {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
              cache.version == Self.cacheVersion else { return CacheFile(version: Self.cacheVersion, files: [:]) }
        return cache
    }

    private func saveCache(_ cache: CacheFile) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: cacheURL, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    // MARK: Dedup and aggregation

    private struct ExactKey: Hashable { var messageID: String; var requestID: String? }

    /// Drops replayed lines. Key `(message.id, requestId)`; a second index on `message.id` alone
    /// catches a sidechain replaying a parent under a new request id. On a collision the
    /// non-sidechain line wins, then the larger token total, then the one with a `speed` field.
    /// Lines without a message id always stay.
    static func dedup(_ events: [ClaudeUsageEvent]) -> [ClaudeUsageEvent] {
        var kept: [ClaudeUsageEvent] = []
        var exact: [ExactKey: Int] = [:]
        var byMessage: [String: [Int]] = [:]
        for event in events {
            guard let id = event.messageID else { kept.append(event); continue }
            let key = ExactKey(messageID: id, requestID: event.requestID)
            let hit = exact[key] ?? byMessage[id]?.first { event.sidechain || kept[$0].sidechain }
            guard let index = hit else {
                exact[key] = kept.count
                byMessage[id, default: []].append(kept.count)
                kept.append(event)
                continue
            }
            if replaces(event, kept[index]) {
                let old = kept[index]
                if let oldID = old.messageID { exact[ExactKey(messageID: oldID, requestID: old.requestID)] = nil }
                kept[index] = event
                exact[key] = index
            }
        }
        return kept
    }

    private static func replaces(_ candidate: ClaudeUsageEvent, _ existing: ClaudeUsageEvent) -> Bool {
        if candidate.sidechain != existing.sidechain { return existing.sidechain }
        if candidate.total != existing.total { return candidate.total > existing.total }
        return candidate.hasSpeed && !existing.hasSpeed
    }

    private struct Day {
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        var cost: Double?
        var unpriced = Set<String>()
    }

    private func aggregate(_ events: [ClaudeUsageEvent], table: inout ModelRateTable) -> [ClaudeDailyCost] {
        var days: [String: Day] = [:]
        for event in events {
            let parts = calendar.dateComponents([.year, .month, .day], from: event.time)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            var day = days[key] ?? Day()
            day.input += event.input
            day.output += event.output
            day.cacheRead += event.cacheRead
            day.cacheWrite += event.cacheWrite5m + event.cacheWrite1h
            if let cost = Self.cost(of: event, table: &table) {
                day.cost = (day.cost ?? 0) + cost
            } else if let model = event.model, !model.isEmpty, event.total > 0 {
                day.unpriced.insert(model)
            }
            days[key] = day
        }
        return days.sorted { $0.key < $1.key }.map { key, day in
            ClaudeDailyCost(date: key, inputTokens: day.input, outputTokens: day.output,
                            cacheReadTokens: day.cacheRead, cacheWriteTokens: day.cacheWrite,
                            costUSD: day.cost, unpricedModels: day.unpriced.sorted())
        }
    }

    /// The line's own `costUSD`, else tokens times the model rate; `<synthetic>` is free.
    private static func cost(of event: ClaudeUsageEvent, table: inout ModelRateTable) -> Double? {
        if let carried = event.costUSD { return carried }
        guard let model = event.model else { return nil }
        if model == "<synthetic>" { return 0 }
        return table.resolve(model)?.cost(
            input: event.input, output: event.output, cacheRead: event.cacheRead,
            cacheWrite5m: event.cacheWrite5m, cacheWrite1h: event.cacheWrite1h, fast: event.fast)
    }
}
