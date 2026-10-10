import CSQLite
import Foundation

extension ProviderCatalog {
    /// Web session first. With no session bundle, or when the web call is refused, the plan data
    /// Windsurf caches in its own database is read (it only updates when Windsurf starts).
    static let windsurf = ProviderSpec(
        id: "windsurf", name: "Windsurf",
        fields: [.init("session", "Session bundle (optional)", optional: true,
                       placeholder: "JSON with devin_session_token, devin_auth1_token, devin_account_id, devin_primary_org_id")],
        dashboard: "https://windsurf.com/profile",
        usage: { credential in
            guard let bundle = credential["session"] else { return try WindsurfLocal.read() }
            do {
                return try await WindsurfProto.fetch(bundle: bundle)
            } catch let error as ProviderError where error.needsSignIn {
                if let local = try? WindsurfLocal.read() { return local }
                throw error
            }
        })
}

/// The cached plan Windsurf stores in `state.vscdb` under `windsurf.settings.cachedPlanInfo`.
enum WindsurfLocal {
    static func databaseURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
    }

    static func read(database: URL = databaseURL()) throws -> ProviderUsage {
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw ProviderError.missingCredential("Add a Windsurf session bundle, or open Windsurf once so it writes its plan data.")
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

extension WindsurfProto {
    static func fetch(bundle: String) async throws -> ProviderUsage {
        let session = try parseSession(bundle)
        let response = try await HTTP.send(
            "https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus",
            method: "POST",
            headers: [
                "Content-Type": "application/proto", "Accept": "application/proto", "Connect-Protocol-Version": "1",
                "Origin": "https://windsurf.com", "Referer": "https://windsurf.com/profile",
                "x-auth-token": session.token, "x-devin-session-token": session.token,
                "x-devin-auth1-token": session.auth1, "x-devin-account-id": session.account,
                "x-devin-primary-org-id": session.org,
            ],
            body: encodeRequest(authToken: session.token))
        if response.status == 400 { throw ProviderError.unauthorized("The Windsurf session expired. Paste a new session bundle.") }
        try HTTP.check(response)
        return try map(decodeResponse(response.data))
    }
}

/// Minimal protobuf reader and writer for Windsurf's GetPlanStatus call. Field numbers follow CodexBar's
/// codec: response 1 = PlanStatus {1 PlanInfo {2 plan name}, 3 plan end (Timestamp), 14 and 15 daily and
/// weekly remaining percent, 17 and 18 daily and weekly reset (unix seconds)}.
enum WindsurfProto {
    struct PlanStatus: Equatable {
        var planName: String?
        var planEnd: Date?
        var dailyRemaining: Int?, weeklyRemaining: Int?
        var dailyReset: Date?, weeklyReset: Date?
    }

    enum Value: Equatable { case varint(UInt64), bytes(Data) }

    // MARK: Writer

    static func varint(_ field: Int, _ value: UInt64) -> Data { key(field, 0) + encode(value) }
    static func bytes(_ field: Int, _ data: Data) -> Data { key(field, 2) + encode(UInt64(data.count)) + data }

    private static func key(_ field: Int, _ wire: UInt64) -> Data { encode(UInt64(field) << 3 | wire) }

    private static func encode(_ value: UInt64) -> Data {
        var out = Data(), rest = value
        while rest >= 0x80 { out.append(UInt8(rest & 0x7F | 0x80)); rest >>= 7 }
        out.append(UInt8(rest))
        return out
    }

    static func encodeRequest(authToken: String) -> Data {
        bytes(1, Data(authToken.utf8)) + varint(2, 1)
    }

    // MARK: Reader

    /// Fields in order. Fixed-width values are skipped; groups are rejected.
    static func fields(_ data: Data) throws -> [(Int, Value)] {
        let b = [UInt8](data)
        var i = 0
        func read() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            throw ProviderError.parse("The Windsurf response is truncated.")
        }
        var out: [(Int, Value)] = []
        while i < b.count {
            let tag = try read(), number = Int(tag >> 3)
            guard number > 0 else { throw ProviderError.parse("The Windsurf response is malformed.") }
            switch tag & 7 {
            case 0: out.append((number, .varint(try read())))
            case 2:
                guard let length = Int(exactly: try read()), length <= b.count - i else {
                    throw ProviderError.parse("The Windsurf response is truncated.")
                }
                out.append((number, .bytes(Data(b[i..<i + length])))); i += length
            case 1: i += 8
            case 5: i += 4
            default: throw ProviderError.parse("The Windsurf response is malformed.")
            }
            guard i <= b.count else { throw ProviderError.parse("The Windsurf response is truncated.") }
        }
        return out
    }

    static func decodeResponse(_ data: Data) throws -> PlanStatus {
        var status = PlanStatus()
        guard case .bytes(let body)? = try fields(data).first(where: { $0.0 == 1 })?.1 else { return status }
        for (number, value) in try fields(body) {
            switch (number, value) {
            case (1, .bytes(let info)):
                for case (2, .bytes(let name)) in try fields(info) { status.planName = String(data: name, encoding: .utf8) }
            case (3, .bytes(let stamp)):
                for case (1, .varint(let seconds)) in try fields(stamp) {
                    status.planEnd = Date(timeIntervalSince1970: TimeInterval(seconds))
                }
            case (14, .varint(let v)): status.dailyRemaining = Int(v)
            case (15, .varint(let v)): status.weeklyRemaining = Int(v)
            case (17, .varint(let v)): status.dailyReset = Date(timeIntervalSince1970: TimeInterval(v))
            case (18, .varint(let v)): status.weeklyReset = Date(timeIntervalSince1970: TimeInterval(v))
            default: break
            }
        }
        return status
    }

    /// Pure mapper. Used share is 100 minus the remaining percent.
    static func map(_ status: PlanStatus) throws -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let left = status.dailyRemaining {
            windows.append(UsageWindow(id: "daily", title: "Daily", usedPercent: 100 - Double(left),
                                       resetsAt: status.dailyReset, windowMinutes: 1440))
        }
        if let left = status.weeklyRemaining {
            windows.append(UsageWindow(id: "weekly", title: "Weekly", usedPercent: 100 - Double(left),
                                       resetsAt: status.weeklyReset, windowMinutes: 10_080))
        }
        guard !windows.isEmpty || status.planName != nil else { throw ProviderError.parse("Windsurf returned no plan status.") }
        let end = status.planEnd.map { UsageRow("Plan ends", $0.formatted(date: .abbreviated, time: .omitted)) }
        return ProviderUsage(windows: windows, sections: [UsageSection(nil, end.map { [$0] } ?? [])], plan: status.planName)
    }

    /// Accepts the JSON bundle or `key=value` lines copied from the browser.
    static func parseSession(_ text: String) throws -> (token: String, auth1: String, account: String, org: String) {
        var values: [String: String] = [:]
        if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            values = object.compactMapValues { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        } else {
            for part in text.trimmingCharacters(in: CharacterSet(charactersIn: "{} \n")).components(separatedBy: CharacterSet(charactersIn: "\n,;")) {
                guard let split = part.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
                values[part[..<split].trimmingCharacters(in: .whitespaces)] = part[part.index(after: split)...]
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            }
        }
        func pick(_ names: [String]) -> String? { names.lazy.compactMap { values[$0] }.first { !$0.isEmpty } }
        guard let token = pick(["devin_session_token", "devinSessionToken", "sessionToken"]),
              let auth1 = pick(["devin_auth1_token", "devinAuth1Token", "auth1Token"]),
              let account = pick(["devin_account_id", "devinAccountId", "accountID", "accountId"]),
              let org = pick(["devin_primary_org_id", "devinPrimaryOrgId", "primaryOrgID", "primaryOrgId"]) else {
            throw ProviderError.missingCredential("The session bundle needs devin_session_token, devin_auth1_token, devin_account_id and devin_primary_org_id.")
        }
        return (token, auth1, account, org)
    }
}
