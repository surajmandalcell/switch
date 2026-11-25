import Foundation

// Cache contract: CodexBar 43f3c2805 (MIT), copyright 2026 Peter Steinberger.
extension CursorUsage {
    /// Tokscale's canonical Cursor cache. Other accounts' `usage.account-*.json` files are never read.
    static func tokscaleCache(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/tokscale/cursor-cache/usage.json")
    }

    struct LocalEvent: Equatable {
        var id: String?
        var conversation: String?
        var model: String
        var date: Date
        var tokens: Int
        var cents: Double?
    }

    /// Spend rows from the Tokscale cache when the dashboard events do not load. The cache names no
    /// account, so the caller only uses it for this Mac's live Cursor sign-in, never a saved account.
    /// A cache with a bad row keeps its token totals but shows no dollars, since the sum would be short.
    static func tokscaleSpend(at url: URL = tokscaleCache(), now: Date = Date()) -> MajorsSpend.Report? {
        guard let data = try? Data(contentsOf: url), let document = try? JSON(data: data),
              tokscaleTagsAgree(document) else { return nil }
        let raw = document["usageEventsDisplay"].array
        let events = raw.compactMap(localEvent)
        let complete = events.count == raw.count
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        let entries = deduplicated(events).filter { $0.date >= start && $0.date <= now }.map {
            MajorsSpend.Entry(date: $0.date, cost: complete ? $0.cents.map { $0 / 100 } : nil, tokens: $0.tokens)
        }
        return MajorsSpend.report(entries, now: now, title: "Spend (Tokscale cache)")
    }

    /// Owner tags describe cache consistency only; a tagged cache must carry them all and agree.
    static func tokscaleTagsAgree(_ document: JSON) -> Bool {
        let legacy = document["_tokscale"], owner = document["_owner"], footer = document["zzTokscaleOwner"]
        guard legacy.exists || owner.exists || footer.exists else { return true }
        guard legacy["version"].int == 1, let account = legacy["accountId"].string else { return false }
        guard owner.exists || footer.exists else { return true }
        let generation = owner["generation"].string
        return owner["version"].int == 1 && footer["version"].int == 1
            && generation.flatMap(UUID.init(uuidString:)) != nil && generation == footer["generation"].string
            && owner["ownerHash"].string == CoreSupport.digest(Data(account.utf8))
    }

    /// An object row, or a positional `[conversation, timestamp, model, chargedCents, tokenUsage]` row.
    static func localEvent(_ row: JSON) -> LocalEvent? {
        func text(_ value: JSON) -> String? {
            value.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        func cents(_ value: JSON) -> Double? { value.double.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let id: String?, fields: [JSON]
        if row.raw is [String: Any] {
            id = text(row["usageEventId"])
            fields = ["conversationId", "timestamp", "model", "chargedCents", "tokenUsage"].map { row[$0] }
        } else if row.raw is [Any], row.array.count <= 5 {
            id = nil
            fields = (0..<5).map { row[$0] }
        } else {
            return nil
        }
        guard let date = fields[1].date, let model = text(fields[2]) else { return nil }
        let usage = fields[4]
        let positional = usage.raw is [Any]
        if positional, usage.array.count > 5 { return nil }
        let counts = positional ? (0..<4).map { usage[$0] }
            : ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"].map { usage[$0] }
        var tokens = 0
        for count in counts where count.exists {
            guard let value = count.double, value >= 0, value.rounded() == value, let int = Fmt.int(value) else { return nil }
            let (sum, overflow) = tokens.addingReportingOverflow(int)
            guard !overflow else { return nil }
            tokens = sum
        }
        let total = positional ? usage[4] : usage["totalCents"]
        return LocalEvent(id: id, conversation: text(fields[0]), model: model, date: date, tokens: tokens,
                          cents: cents(total) ?? cents(fields[3]))
    }

    /// Repeated snapshots of one `usageEventId` count once: the largest token total wins, then the largest
    /// cost, then the earliest row. An id-less row that matches an identified event's conversation, model
    /// and time joins the smallest such id; other id-less rows all count.
    static func deduplicated(_ events: [LocalEvent]) -> [LocalEvent] {
        struct Key: Hashable { let conversation: String?, model: String, date: Date }
        func key(_ event: LocalEvent) -> Key { Key(conversation: event.conversation, model: event.model, date: event.date) }
        var smallest: [Key: String] = [:]
        for event in events { if let id = event.id { smallest[key(event)] = min(smallest[key(event)] ?? id, id) } }
        var winner: [String: Int] = [:]
        var keep = Array(repeating: true, count: events.count)
        for (index, event) in events.enumerated() {
            guard let id = event.id ?? smallest[key(event)] else { continue }
            guard let previous = winner[id] else { winner[id] = index; continue }
            let old = events[previous]
            if event.tokens > old.tokens || (event.tokens == old.tokens && (event.cents ?? 0) > (old.cents ?? 0)) {
                keep[previous] = false
                winner[id] = index
            } else {
                keep[index] = false
            }
        }
        return events.indices.filter { keep[$0] }.map { events[$0] }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
