import CSQLite
import Foundation

extension ProviderCatalog {
    /// Local read only: the plan data Windsurf caches in its own database (it updates when Windsurf starts).
    static let windsurf = ProviderSpec(
        id: "windsurf", name: "Windsurf", fields: [],
        dashboard: "https://windsurf.com/profile",
        usage: { _ in try WindsurfLocal.read() })
}

/// The cached plan Windsurf stores in `state.vscdb` under `windsurf.settings.cachedPlanInfo`.
enum WindsurfLocal {
    static func databaseURL(home: URL = ProviderPaths.current.home,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        ProviderPaths(home: home, env: env).root(.windsurf).appending(path: "User/globalStorage/state.vscdb")
    }

    static func read(database: URL = databaseURL()) throws -> ProviderUsage {
        guard ProviderPaths.current.allowsRead(database) else {
            throw ProviderError.missingCredential("No Windsurf database in the test home.")
        }
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw ProviderError.missingCredential("Open Windsurf once and sign in so it writes its plan data.")
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw ProviderError.unavailable("The Windsurf database could not be opened.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo' LIMIT 1",
                                 -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError.unavailable("The Windsurf database could not be read.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
            throw ProviderError.parse("Windsurf has no cached plan data. Sign in to Windsurf first.")
        }
        // The column is declared BLOB; accept UTF-8 text, or UTF-16 text that still parses as JSON.
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        for encoding in [String.Encoding.utf8, .utf16LittleEndian] {
            if let text = String(data: data, encoding: encoding)?.trimmingCharacters(in: .controlCharacters),
               let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                return try map(JSON(object))
            }
        }
        throw ProviderError.parse("Windsurf cached plan data is not readable.")
    }

    /// Daily and weekly quota percents when present; otherwise message and flow-action counters.
    static func map(_ plan: JSON) throws -> ProviderUsage {
        var windows: [UsageWindow] = []
        let quota = plan["quotaUsage"]
        for (id, title, key, minutes) in [("daily", "Daily", "daily", 1440), ("weekly", "Weekly", "weekly", 10_080)] {
            if let left = quota["\(key)RemainingPercent"].double {
                windows.append(UsageWindow(id: id, title: title, usedPercent: 100 - left,
                                           resetsAt: quota["\(key)ResetAtUnix"].date, windowMinutes: minutes))
            }
        }
        let usage = plan["usage"]
        func counter(_ id: String, _ title: String, total: String, used: String, left: String, unit: String) -> UsageWindow? {
            guard let cap = usage[total].double, cap > 0, let spent = usage[used].double ?? usage[left].double.map({ cap - $0 }) else { return nil }
            return .amounts(id: id, title: title, used: max(0, min(cap, spent)), limit: cap, unit: unit)
        }
        if windows.isEmpty {
            windows = [counter("messages", "Messages", total: "messages", used: "usedMessages", left: "remainingMessages", unit: "messages"),
                       counter("flow", "Flow actions", total: "flowActions", used: "usedFlowActions", left: "remainingFlowActions", unit: "flow actions")]
                .compactMap { $0 }
        }
        var rows: [UsageRow] = []
        if let end = plan["endTimestamp"].date { rows.append(UsageRow("Plan ends", end.formatted(date: .abbreviated, time: .omitted))) }
        if let credits = usage["flexCredits"].double, credits > 0 {
            let left = usage["remainingFlexCredits"].double ?? usage["usedFlexCredits"].double.map { credits - $0 }
            rows.append(UsageRow("Flex credits", left.map { "\(Fmt.number($0)) of \(Fmt.number(credits)) left" } ?? Fmt.number(credits)))
        }
        guard !windows.isEmpty || plan["planName"].string != nil else { throw ProviderError.parse("Windsurf returned no plan status.") }
        return ProviderUsage(windows: windows, sections: [UsageSection(nil, rows)], plan: plan["planName"].string)
    }
}

