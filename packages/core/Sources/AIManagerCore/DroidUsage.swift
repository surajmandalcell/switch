import Foundation

// Local Droid (Factory) usage: `sessions/<working folder>/<uuid>.settings.json` keeps one set of
// token totals for each session. `tokenUsage` is the session's own total; `inclusiveTokenUsage` adds
// its child sessions, which have files of their own, so only `tokenUsage` is read. Thinking tokens
// are part of the output tokens (never larger in any real file), so they are not added again.

public struct DroidSession: Equatable, Sendable {
    /// The file name's UUID.
    public var id: String
    /// The working folder from the paired `.jsonl` first line, else the decoded folder name.
    public var project: String
    public var model: String?
    /// When the session was last active: its settings file's modification date.
    public var modified: Date
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public var tokens: Int64 { Int64(input) + Int64(output) + Int64(cacheRead) + Int64(cacheWrite) }
}

public enum DroidUsage {
    /// Settings files larger than this are skipped (a real one is tens of kilobytes).
    static let maxFileBytes = 5_000_000
    private static let suffix = ".settings.json"

    /// `~/.factory/sessions` of a Droid home.
    public static func sessionsFolder(droidHome: URL) -> URL {
        droidHome.appending(path: "sessions", directoryHint: .isDirectory)
    }

    /// Sessions last active in `[from, to)`. Unreadable, oversized, or token-less files are skipped.
    public static func sessions(in root: URL, from: Date, to: Date = .distantFuture) -> [DroidSession] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var found: [DroidSession] = []
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard let modified = values?.contentModificationDate, modified >= from, modified < to,
                  let size = values?.fileSize, size <= maxFileBytes,
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = object["tokenUsage"] as? [String: Any] else { continue }
            func count(_ key: String) -> Int { max((usage[key] as? NSNumber)?.intValue ?? 0, 0) }
            let session = DroidSession(
                id: String(url.lastPathComponent.dropLast(suffix.count)),
                project: project(settings: url), model: (object["model"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                modified: modified, input: count("inputTokens"), output: count("outputTokens"),
                cacheRead: count("cacheReadTokens"), cacheWrite: count("cacheCreationTokens"))
            if session.tokens > 0 { found.append(session) }
        }
        return found
    }

    /// The first line of the paired `.jsonl` holds `cwd`; only its first 64 KB are read. Without it,
    /// the folder name (the path with `/` written as `-`) stands in.
    private static func project(settings url: URL) -> String {
        let log = url.deletingLastPathComponent().appending(
            path: String(url.lastPathComponent.dropLast(suffix.count)) + ".jsonl")
        if let handle = try? FileHandle(forReadingFrom: log) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 65_536),
               let line = head.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false).first,
               let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               object["type"] as? String == "session_start", let cwd = object["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
        }
        let folder = url.deletingLastPathComponent().lastPathComponent
        return folder.hasPrefix("-") ? folder.replacingOccurrences(of: "-", with: "/") : (folder.isEmpty ? "Unknown project" : folder)
    }

    /// Estimated USD at the model's catalog rate; nil for an unknown model.
    static func cost(_ session: DroidSession, table: inout ModelRateTable) -> Double? {
        guard let model = session.model, let rate = table.resolve(model) else { return nil }
        return rate.cost(input: session.input, output: session.output, cacheRead: session.cacheRead,
                         cacheWrite5m: session.cacheWrite, cacheWrite1h: 0, fast: false)
    }

    /// One entry per local calendar day (`calendar`) with usage, oldest first, for the activity panel.
    /// ponytail: a session's tokens all land on its last-active day (Droid stores per-session totals
    /// only); split by message timestamps if multi-day sessions skew the chart.
    public static func daily(
        _ sessions: [DroidSession], rates: [String: ModelRate], calendar: Calendar = .current
    ) -> [ClaudeDailyCost] {
        var table = ModelRateTable(rates)
        var days: [String: ClaudeDailyCost] = [:]
        for session in sessions {
            let parts = calendar.dateComponents([.year, .month, .day], from: session.modified)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            var day = days[key] ?? ClaudeDailyCost(date: key)
            day.inputTokens += session.input
            day.outputTokens += session.output
            day.cacheReadTokens += session.cacheRead
            day.cacheWriteTokens += session.cacheWrite
            if let cost = cost(session, table: &table) {
                day.costUSD = (day.costUSD ?? 0) + cost
            } else if let model = session.model, !day.unpricedModels.contains(model) {
                day.unpricedModels.append(model)
            }
            days[key] = day
        }
        return days.values.sorted { $0.date < $1.date }.map { var day = $0; day.unpricedModels.sort(); return day }
    }
}
