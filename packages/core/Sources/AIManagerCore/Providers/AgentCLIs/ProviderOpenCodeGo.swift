import CSQLite
import Foundation

extension ProviderCatalog {
    private static let openCodeAuth = LiveFile(".local/share/opencode/auth.json", key: "opencode-go", databaseRow: "opencode-go")

    // OpenCode Zen (id "opencode") is not ported: its balance needs a browser cookie, and no key endpoint exists.
    static let agentOpenCodeGo = ProviderSpec(
        id: "opencodego", name: "OpenCode Go", style: .files,
        files: [openCodeAuth],
        dashboard: "https://opencode.ai/auth",
        identify: { credential in
            credential.json(openCodeAuth.id)?["key"].string.map { CredentialIdentity(key: AgentCLIsKit.fingerprint($0), plan: "Go") }
        },
        usage: { credential in
            guard let key = credential.json(openCodeAuth.id)?["key"].string else {
                throw ProviderError.missingCredential("Sign in with opencode auth login, then import the sign-in.")
            }
            let response = try await HTTP.send("https://opencode.ai/zen/go/v1/usage", headers: HTTP.bearer(key))
            if response.status == 403, response.text.contains("EntitlementError") {
                // The key is valid (a new sign-in would not help), so this is not `.unauthorized`.
                throw ProviderError.unavailable("This OpenCode account has no Go subscription.")
            }
            try HTTP.check(response)
            var usage = try OpenCodeGoUsage.map(response.json(), serverDate: OpenCodeGoUsage.httpDate(response.headers["date"]))
            // The local logs belong to the signed-in OpenCode, so only a live credential may read them.
            if credential.isLive, let spend = OpenCodeGoUsage.localSpend(directory: OpenCodeGoUsage.dataDirectory()) {
                usage.sections += [spend.section].compactMap { $0 }
                usage.charts += [spend.chart].compactMap { $0 }
            }
            return usage
        })
}

enum OpenCodeGoUsage {
    /// Mirrors OpenCode: OPENCODE_DATA_DIR, then $XDG_DATA_HOME/opencode, then ~/.local/share/opencode.
    static func dataDirectory(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        func text(_ name: String) -> String? {
            env[name]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyText
        }
        if let dir = text("OPENCODE_DATA_DIR") { return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath) }
        if let xdg = text("XDG_DATA_HOME") {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath).appendingPathComponent("opencode")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode")
    }

    /// The active `credential` row of one integration in `opencode.db` (OpenCode 2 keeps logins there,
    /// not in auth.json). Read only; nil when the database, the table or the row is missing, or the
    /// value is not JSON with a non-empty `key`.
    static func databaseLogin(_ integration: String, directory: URL) -> (value: Data, key: String)? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("opencode.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_500)
        var statement: OpaquePointer?
        let sql = "SELECT value FROM credential WHERE integration_id = ?1 AND active = 1 ORDER BY time_updated DESC LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { sqlite3_finalize(statement); return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, integration, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        let value = Data(bytes: text, count: Int(sqlite3_column_bytes(statement, 0)))
        guard let object = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any],
              let key = (object["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return nil }
        return (value, key)
    }

    /// True when `opencode.db` is an OpenCode 2 database, which holds the logins.
    static func hasCredentialTable(directory: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("opencode.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_500)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        return sqlite3_prepare_v2(db, "SELECT 1 FROM credential LIMIT 0", -1, &statement, nil) == SQLITE_OK
    }

    private static let provider = "COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID'))"
    private static let tokens = """
        COALESCE(json_extract(data,'$.tokens.total'),
                 COALESCE(json_extract(data,'$.tokens.input'),0) + COALESCE(json_extract(data,'$.tokens.output'),0)
                 + COALESCE(json_extract(data,'$.tokens.reasoning'),0) + COALESCE(json_extract(data,'$.tokens.cache.read'),0)
                 + COALESCE(json_extract(data,'$.tokens.cache.write'),0))
        """

    /// Today, Yesterday and Last 30 days from the cost OpenCode records on each hosted (Go and Zen)
    /// assistant message in `opencode*.db`. OpenCode 1 writes `message`, OpenCode 2 `session_message`
    /// and copies old rows under the same id, so ids are counted once. Read only.
    static func localSpend(directory: URL, now: Date = Date(), calendar: Calendar = .current) -> MajorsSpend.Report? {
        let since = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }.sorted()
        var seen = Set<String>()
        var entries: [MajorsSpend.Entry] = []
        for name in files {
            var db: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent(name).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db)
                continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1_500)
            let hosted = "\(provider) IN ('opencode-go','opencode') AND json_type(data,'$.cost') IN ('integer','real')"
            let queries = [
                ("message", "json_extract(data,'$.role') = 'assistant'"),
                ("session_message", "(type = 'assistant' OR (type = 'compaction' AND json_extract(data,'$.status') = 'completed'))"),
            ]
            for (table, role) in queries {
                var statement: OpaquePointer?
                let sql = "SELECT id, time_created, json_extract(data,'$.cost'), \(tokens) FROM \(table) "
                    + "WHERE time_created >= ?1 AND json_valid(data) AND \(role) AND \(hosted)"
                // A missing table fails to prepare, which only means that OpenCode generation is absent.
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { sqlite3_finalize(statement); continue }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(statement, 1, since.timeIntervalSince1970 * 1000)
                while sqlite3_step(statement) == SQLITE_ROW {
                    let id = sqlite3_column_text(statement, 0).map { String(cString: $0) }
                    if let id, !seen.insert(id).inserted { continue }
                    let ms = sqlite3_column_double(statement, 1)
                    guard ms > 0 else { continue }
                    entries.append(MajorsSpend.Entry(
                        date: Date(timeIntervalSince1970: ms / 1000), cost: max(0, sqlite3_column_double(statement, 2)),
                        tokens: Int(min(max(sqlite3_column_double(statement, 3), 0), 1e15))))
                }
            }
        }
        return MajorsSpend.report(entries, now: now, calendar: calendar, title: "Spend (this Mac)")
    }

    static func httpDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    static func map(_ json: JSON, serverDate: Date? = nil) throws -> ProviderUsage {
        let usage = json["usage"]
        var windows: [UsageWindow] = []
        for (id, source, title, minutes) in [("session", "rolling", "Session", 300), ("weekly", "weekly", "Weekly", 10080),
                                              ("monthly", "monthly", "Monthly", 43200)] {
            let entry = usage[source]
            guard let percent = entry["percent"].double else { continue }
            let reset = entry["resetsAt"].date
            // A 5-hour window that has not started yet reports a reset exactly 5 hours after the server time.
            if id == "session", percent == 0, let reset, let serverDate,
               abs(reset.timeIntervalSince(serverDate.addingTimeInterval(5 * 3600))) <= 2 {
                windows.append(UsageWindow(id: id, title: title, usedPercent: 0, windowMinutes: minutes, detail: "Not started"))
                continue
            }
            windows.append(UsageWindow(id: id, title: title, usedPercent: percent, resetsAt: reset, windowMinutes: minutes))
        }
        guard !windows.isEmpty else { throw ProviderError.parse("OpenCode Go returned no usage windows.") }
        return ProviderUsage(windows: windows, plan: "Go")
    }
}

private extension String {
    var nonEmptyText: String? { isEmpty ? nil : self }
}
