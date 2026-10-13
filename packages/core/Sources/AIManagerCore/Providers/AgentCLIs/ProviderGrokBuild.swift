import Foundation

extension ProviderCatalog {
    fileprivate static let grokAuthFile = LiveFile(".grok/auth.json", homeEnv: "GROK_HOME")

    /// Reads the Grok CLI sign-in. A live credential belongs to the Grok CLI and is never refreshed;
    /// only a saved vault copy, which Switch alone holds, is refreshed.
    static let agentGrok = ProviderSpec(
        id: "grok-build", name: "Grok Build", style: .files,
        files: [grokAuthFile],
        dashboard: "https://grok.com/?_s=usage",
        identify: { GrokBuildUsage.identity($0.json(grokAuthFile.id)) },
        fetch: { try await GrokBuildUsage.fetch($0, fileID: grokAuthFile.id) })
}

enum GrokBuildUsage {
    static let refreshMessage = "Open Grok to refresh this sign-in."
    static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let tokenURL = "https://auth.x.ai/oauth2/token"

    /// (url, method, headers, body) -> response. Tests replace it so nothing touches the network.
    typealias Send = @Sendable (String, String, [String: String], Data?) async throws -> HTTPResponse
    static let liveSend: Send = { try await HTTP.send($0, method: $1, headers: $2, body: $3) }

    static func fetch(_ credential: ProviderCredential, fileID: String, now: Date = Date(),
                      send: @escaping Send = liveSend) async throws -> FetchResult {
        if credential.isLive {
            let auth = try token(credential.json(fileID), now: now)
            return FetchResult(try await usage(token: auth.token, email: auth.email, send: send, live: true))
        }
        guard let data = credential.files[fileID],
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = entryKey(JSON(root)), var entry = root[key] as? [String: Any],
              let access = entry["key"] as? String else {
            throw ProviderError.missingCredential("Sign in to Grok first, then import the sign-in.")
        }
        var refreshed = false
        let email = entry["email"] as? String
        let result = try await IDEAuth.authorized(
            access: access, expiry: expiry(JSON(entry), token: access), live: false, hint: refreshMessage,
            refresh: {
                let fresh = try await refresh(key: key, entry: entry, now: now, send: send)
                entry = fresh.entry
                root[key] = entry
                refreshed = true
                return fresh.token
            },
            call: { try await usage(token: $0, email: email, send: send) })
        guard refreshed else { return FetchResult(result) }
        var updated = credential
        updated.files[fileID] = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return FetchResult(result, updated: updated)
    }

    /// Grok CLI OAuth refresh. Only the token fields change; every other key of the entry is kept.
    private static func refresh(key: String, entry: [String: Any], now: Date,
                                send: Send) async throws -> (token: String, entry: [String: Any]) {
        func text(_ name: String) -> String? {
            (entry[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        guard let refreshToken = text("refresh_token") ?? text("refresh") else {
            throw ProviderError.unauthorized(refreshMessage)
        }
        let suffix = key.contains("::") ? key.components(separatedBy: "::").last?.nonEmpty : nil
        let client = text("oidc_client_id") ?? suffix ?? defaultClientID
        let response = try await send(
            tokenURL, "POST", ["Content-Type": "application/x-www-form-urlencoded"],
            HTTP.form(["grant_type": "refresh_token", "client_id": client, "refresh_token": refreshToken]))
        if (400...403).contains(response.status) {
            throw ProviderError.unauthorized("This Grok sign-in expired. Sign in again.")
        }
        try HTTP.check(response)
        let json = try response.json()
        guard let access = json["access_token"].string?.nonEmpty else {
            throw ProviderError.parse("Grok returned no access token.")
        }
        var fresh = entry
        fresh["key"] = access
        if let rotated = json["refresh_token"].string?.nonEmpty {
            fresh[entry["refresh_token"] == nil && entry["refresh"] != nil ? "refresh" : "refresh_token"] = rotated
        }
        if let idToken = json["id_token"].string?.nonEmpty, entry["id_token"] != nil {
            fresh["id_token"] = idToken
        }
        let lifetime = json["expires_in"].double.map { now.addingTimeInterval($0) }
            ?? Fmt.jwtClaims(access)?["exp"].date ?? now.addingTimeInterval(3600)
        fresh[entry["expires_at"] == nil && entry["expires"] != nil ? "expires" : "expires_at"] =
            ISO8601DateFormatter().string(from: lifetime)
        return (access, fresh)
    }

    private static func usage(token: String, email: String?, send: @escaping Send, live: Bool = false) async throws -> ProviderUsage {
        let headers = headers(token)
        async let settings = try? send("https://cli-chat-proxy.grok.com/v1/settings", "GET", headers, nil)
        async let resets = resetCredits(token: token, send: send)
        let response = try await send("https://cli-chat-proxy.grok.com/v1/billing?format=credits", "GET", headers, nil)
        let plan = await settings.flatMap { (200..<300).contains($0.status) ? try? $0.json() : nil }?["subscription_tier_display"].string
        if response.status == 401 || response.status == 403 {
            throw ProviderError.unauthorized(refreshMessage)
        }
        var usage: ProviderUsage
        if isTeamResponse(status: response.status, body: response.text) {
            usage = teamOnly(plan: plan, email: email)
        } else {
            try HTTP.check(response)
            usage = try map(billing: response.json(), plan: plan, email: email)
            if let credits = await resets { usage.sections.append(credits) }
        }
        // The CLI's session logs belong to the signed-in account, so only a live credential may read them.
        if live, let spend = localSpend(sessions: grokHome().appendingPathComponent("sessions")) {
            usage.sections += [spend.section].compactMap { $0 }
            usage.charts += [spend.chart].compactMap { $0 }
        }
        return usage
    }

    // MARK: Limit reset credits

    /// Unused weekly-limit reset tokens from grok.com's billing RPC (gRPC-web, protobuf). Best effort,
    /// bounded to a few seconds so a slow grok.com cannot delay the weekly pool.
    private static func resetCredits(token: String, send: @escaping Send, now: Date = Date()) async -> UsageSection? {
        let request: @Sendable () async -> HTTPResponse? = {
            try? await send(
                "https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets", "POST",
                ["Authorization": "Bearer \(token)", "Content-Type": "application/grpc-web+proto", "Accept": "*/*",
                 "x-grpc-web": "1", "Origin": "https://grok.com", "Referer": "https://grok.com/?_s=usage"],
                Data([0, 0, 0, 0, 0]))
        }
        let response = await withTaskGroup(of: HTTPResponse?.self) { group -> HTTPResponse? in
            group.addTask { await request() }
            group.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        guard let response, response.status == 200,
              let expiries = resetExpiries(response.data, now: now), !expiries.isEmpty else { return nil }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "MMM d, yyyy"
        let value = "\(expiries.count) available \u{00B7} next expires \(day.string(from: expiries[0]))"
        return UsageSection(nil, [UsageRow("Limit reset credits", value)])
    }

    /// Expiry dates (soonest first) of the unexpired tokens in a GetRemainingResets reply. Nil when the
    /// bytes are not the expected protobuf. Token records are field 10; inside, field 30 holds the expiry.
    static func resetExpiries(_ data: Data, now: Date) -> [Date]? {
        var payloads: [Data] = []
        var offset = data.startIndex
        // gRPC-web frames: 1 flag byte, 4 length bytes. A raw protobuf reply is also accepted.
        var framed = data.count >= 5 && data[offset] & 0x7F == 0
        while framed, offset + 5 <= data.endIndex {
            let length = data[(offset + 1)..<(offset + 5)].reduce(0) { $0 << 8 | Int($1) }
            guard offset + 5 + length <= data.endIndex else { framed = false; break }
            if data[offset] & 0x80 == 0 { payloads.append(data[(offset + 5)..<(offset + 5 + length)]) }
            offset += 5 + length
        }
        if !framed { payloads = [data] }
        var expiries: [Date] = []
        for payload in payloads {
            guard let fields = ProtoReader.fields(payload) else { return nil }
            for record in fields where record.number == 10 {
                guard let inner = record.bytes.flatMap(ProtoReader.fields) else { return nil }
                let seconds = inner.first { $0.number == 30 }?.bytes.flatMap(ProtoReader.fields)?
                    .first { $0.number == 1 }?.varint
                if let seconds, (1_700_000_000...4_100_000_000).contains(seconds) {
                    let date = Date(timeIntervalSince1970: TimeInterval(seconds))
                    if date > now { expiries.append(date) }
                }
            }
        }
        return expiries.sorted()
    }

    /// Minimal protobuf wire reader: varints and length-delimited fields only matter here.
    private enum ProtoReader {
        struct Field { var number: Int; var varint: UInt64?; var bytes: Data? }

        static func fields(_ data: Data) -> [Field]? {
            var out: [Field] = []
            var i = data.startIndex
            func varint() -> UInt64? {
                var value: UInt64 = 0
                var shift: UInt64 = 0
                while i < data.endIndex, shift < 64 {
                    let byte = data[i]
                    i += 1
                    value |= UInt64(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { return value }
                    shift += 7
                }
                return nil
            }
            while i < data.endIndex {
                guard let tag = varint(), tag >> 3 > 0 else { return nil }
                switch tag & 7 {
                case 0:
                    guard let value = varint() else { return nil }
                    out.append(Field(number: Int(tag >> 3), varint: value, bytes: nil))
                case 2:
                    guard let length = varint(), length <= UInt64(data.endIndex - i) else { return nil }
                    out.append(Field(number: Int(tag >> 3), varint: nil, bytes: data[i..<(i + Int(length))]))
                    i += Int(length)
                case 1: guard data.endIndex - i >= 8 else { return nil }; i += 8
                case 5: guard data.endIndex - i >= 4 else { return nil }; i += 4
                default: return nil
                }
            }
            return out
        }
    }

    // MARK: Local spend

    private static func grokHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    /// Today, Yesterday and Last 30 days from completed turns in `sessions/**/updates.jsonl`. Grok records
    /// the cost of each turn (`costUsdTicks`, ten billion to the dollar), so nothing is priced here.
    /// ponytail: re-reads every session log touched in the last 31 days on each refresh (files over
    /// 200 MB are skipped); add an incremental cache if a refresh gets slow.
    static func localSpend(sessions: URL, now: Date = Date(), calendar: Calendar = .current) -> MajorsSpend.Report? {
        let since = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now)) ?? now
        guard let walker = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        var seen = Set<String>()
        var entries: [MajorsSpend.Entry] = []
        for case let url as URL in walker where url.lastPathComponent == "updates.jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard (values?.contentModificationDate ?? .distantPast) >= since,
                  (values?.fileSize ?? 0) < 200_000_000 else { continue }
            // A copied transcript repeats an event; count it once per model.
            entries += turns(in: url).filter { $0.date >= since && ($0.key.map { seen.insert($0).inserted } ?? true) }
        }
        return MajorsSpend.report(entries, now: now, calendar: calendar, title: "Spend (this Mac)")
    }

    /// Completed turns of one `updates.jsonl`, one entry per model, with the model and a key for
    /// cross-file dedup. Reads the file once and keeps no message text.
    static func turns(in url: URL) -> [MajorsSpend.Entry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let marker = Data("turn_completed".utf8)
        var entries: [MajorsSpend.Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
            guard let object = (try? JSONSerialization.jsonObject(with: line)).map(JSON.init) else { continue }
            entries += turnEntries(object)
        }
        return entries
    }

    private static func turnEntries(_ object: JSON) -> [MajorsSpend.Entry] {
        let params = object["params"]
        let update = params["update"].exists ? params["update"] : object["update"]
        guard update["sessionUpdate"].string == "turn_completed", let models = update.at("usage.modelUsage").raw as? [String: Any]
        else { return [] }
        let meta = params["_meta"].exists ? params["_meta"] : object["_meta"]
        guard let date = meta["agentTimestampMs"].double.flatMap({ $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil })
                ?? object["timestamp"].date else { return [] }
        let eventID = meta["eventId"].string
        let topTicks = update.at("usage.costUsdTicks").double
        return models.sorted { $0.key < $1.key }.compactMap { name, raw in
            let model = JSON(raw)
            let ticks = model["costUsdTicks"].double ?? (models.count == 1 ? topTicks : nil)
            // inputTokens already includes cache reads and writes; reasoning is a subset of output.
            let tokens = max(0, model["inputTokens"].double ?? 0) + max(0, model["outputTokens"].double ?? 0)
            return MajorsSpend.Entry(date: date, cost: ticks.flatMap { $0 >= 0 ? $0 / 10_000_000_000 : nil },
                                     tokens: Int(min(tokens, 1e15)), model: name,
                                     key: eventID.map { "\($0)\0\(name)" })
        }
    }

    /// Earliest of the file's expiry field and the access token's `exp`.
    private static func expiry(_ entry: JSON, token: String) -> Date? {
        [(entry["expires_at"].date ?? entry["expires"].date), Fmt.jwtClaims(token)?["exp"].date]
            .compactMap { $0 }.min()
    }

    /// Key of the login record Grok itself would use: OIDC entry first, then the legacy session entry.
    private static func entryKey(_ file: JSON?) -> String? {
        let entries = (file?.object ?? [:]).filter { $0.value["key"].string != nil }
        let ordered = entries.sorted { $0.key < $1.key }
        return (ordered.first { $0.key.hasPrefix("https://auth.x.ai::") }
            ?? ordered.first { $0.key.contains("/sign-in") } ?? ordered.first)?.key
    }

    /// True when the login's access token is past its expiry or within `margin` seconds of it.
    static func expiresSoon(_ data: Data?, now: Date = Date(), margin: TimeInterval = 300) -> Bool {
        guard let data, let file = try? JSON(data: data), let entry = entry(file), let token = entry["key"].string,
              let expiry = expiry(entry, token: token) else { return false }
        return expiry <= now.addingTimeInterval(margin)
    }

    private static func entry(_ file: JSON?) -> JSON? {
        entryKey(file).flatMap { file?.object[$0] }
    }

    static func identity(_ file: JSON?) -> CredentialIdentity? {
        guard let entry = entry(file),
              let key = entry["user_id"].string ?? entry["email"].string else { return nil }
        return CredentialIdentity(key: key, email: entry["email"].string)
    }

    static func token(_ file: JSON?, now: Date) throws -> (token: String, email: String?) {
        guard let entry = entry(file), let token = entry["key"].string else {
            throw ProviderError.missingCredential("Sign in to Grok first, then import the sign-in.")
        }
        let expiry = (entry["expires_at"].date ?? entry["expires"].date)
            ?? Fmt.jwtClaims(token)?["exp"].date
        if let expiry, expiry <= now { throw ProviderError.unauthorized(refreshMessage) }
        return (token, entry["email"].string)
    }

    static func headers(_ token: String) -> [String: String] {
        HTTP.bearer(token).merging(["X-XAI-Token-Auth": "xai-grok-cli"]) { $1 }
    }

    /// HTTP 412 "no personal team": the sign-in is fine, but a team has no personal quota.
    static func isTeamResponse(status: Int, body: String) -> Bool {
        status == 412 && body.localizedCaseInsensitiveContains("no personal team")
    }

    static func teamOnly(plan: String?, email: String?) -> ProviderUsage {
        ProviderUsage(sections: [UsageSection(nil, [UsageRow("Weekly limit", "Team accounts have no personal quota")])],
                      plan: plan, email: email)
    }

    /// `GET /v1/billing?format=credits`. Proto3 JSON drops zero values, so a missing percent means 0.
    static func map(billing: JSON, plan: String? = nil, email: String? = nil) throws -> ProviderUsage {
        let config = billing["config"]
        guard config.exists else { throw ProviderError.parse("Grok returned an unexpected billing reply.") }
        var windows: [UsageWindow] = []
        let period = config["currentPeriod"]
        // Older replies carry only billingPeriodStart/End; the length of the span then names the window.
        let spanStart = period["start"].date ?? config["billingPeriodStart"].date
        let spanEnd = period["end"].date ?? config["billingPeriodEnd"].date
        if let start = spanStart, let end = spanEnd, end > start {
            let type = period["type"].string ?? ""
            let days = end.timeIntervalSince(start) / 86_400
            let title = type.hasSuffix("WEEKLY") ? "Weekly" : type.hasSuffix("MONTHLY") ? "Monthly"
                : type.isEmpty ? (days < 10 ? "Weekly" : days < 40 ? "Monthly" : nil) : nil
            if let title {
                windows.append(UsageWindow(
                    id: title.lowercased(), title: title, usedPercent: config["creditUsagePercent"].double ?? 0,
                    resetsAt: end, windowMinutes: Int(end.timeIntervalSince(start) / 60)))
            }
        }
        let cap = config.at("onDemandCap.val").double ?? 0
        var rows = [UsageRow("Pay as you go", cap > 0 ? "\(Fmt.number(cap)) credit cap" : "Disabled")]
        if cap > 0, let used = config.at("onDemandUsed.val").double {
            rows.append(UsageRow("On-demand used", Fmt.number(used), progress: used / cap))
        }
        let prepaid = config.at("prepaidBalance.val").double ?? 0
        return ProviderUsage(windows: windows, cost: prepaid > 0 ? UsageCost(balance: prepaid / 100) : nil,
                             sections: [UsageSection(nil, rows)],
                             plan: plan ?? config["subscriptionTier"].string, email: email)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
