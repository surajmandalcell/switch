import Foundation

extension ProviderCatalog {
    static let poe = ProviderSpec(
        id: "poe", name: "Poe",
        fields: [.apiKey("POE_API_KEY")],
        dashboard: "https://poe.com/api/keys",
        usage: { credential in
            let headers = HTTP.bearer(try credential.require("apiKey"))
            let balance = try await HTTP.json("https://api.poe.com/usage/current_balance", headers: headers)
            // History is a bonus: a failure here must not hide the balance.
            var entries: [JSON] = []
            var cursor: String?
            for _ in 0..<5 {
                let query = cursor.map { "?limit=100&starting_after=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)" }
                    ?? "?limit=100"
                guard let page = try? await HTTP.json("https://api.poe.com/usage/points_history\(query)",
                                                      headers: headers) else { break }
                let rows = PoeUsage.rows(page)
                entries += rows
                cursor = PoeUsage.nextCursor(page, last: rows.last)
                if cursor == nil || rows.isEmpty { break }
            }
            return try PoeUsage.map(balance: balance, history: entries)
        })
}

enum PoeUsage {
    static func rows(_ page: JSON) -> [JSON] {
        for key in ["data", "items", "results"] where page[key].raw is [Any] { return page[key].array }
        return []
    }

    static func nextCursor(_ page: JSON, last: JSON?) -> String? {
        if let next = page["next_cursor"].string { return next }
        return page["has_more"].bool == true ? last?["query_id"].string : nil
    }

    /// Times arrive as seconds, milliseconds, or microseconds.
    private static func entryDate(_ value: JSON) -> Date? {
        guard let number = value.double else { return value.string.flatMap(Fmt.iso) }
        return Fmt.epoch(number > 100_000_000_000_000 ? number / 1000 : number)
    }

    private static func compact(_ value: Double) -> String { Fmt.number(value, digits: value >= 1000 ? 0 : 1) }

    static func map(balance: JSON, history: [JSON], now: Date = Date()) throws -> ProviderUsage {
        guard let points = balance["current_point_balance"].double else {
            throw ProviderError.parse("Failed to parse the Poe balance response.")
        }
        struct Entry { var date: Date; var points: Double; var cost: Double?; var model: String }
        let cutoff = now.addingTimeInterval(-30 * 86400)
        let entries: [Entry] = history.compactMap { row in
            guard let date = entryDate(row["creation_time"].exists ? row["creation_time"]
                                        : row["timestamp"].exists ? row["timestamp"] : row["created_at"]),
                  date >= cutoff else { return nil }
            let cost = (row["cost_points"].double ?? row["points"].double ?? row["point_cost"].double ?? 0)
            return Entry(date: date, points: max(0, cost), cost: (row["cost_usd"].double ?? row["usd"].double),
                         model: row["bot_name"].string ?? "unknown")
        }
        func summary(_ list: [Entry]) -> UsageRow? {
            guard !list.isEmpty else { return nil }
            let usd = list.compactMap(\.cost).reduce(0) { $0 + max(0, $1) }
            let hasCost = list.contains { $0.cost != nil }
            return UsageRow("", "\(compact(list.reduce(0) { $0 + $1.points })) points · \(list.count) requests"
                            + (hasCost ? " · \(Fmt.money(usd))" : ""))
        }
        var rows = [UsageRow("Current balance", "\(compact(points)) points")]
        let day = now.addingTimeInterval(-86400), week = now.addingTimeInterval(-7 * 86400)
        for (label, list) in [("Last 24 hours", entries.filter { $0.date >= day }),
                              ("Last 7 days", entries.filter { $0.date >= week }),
                              ("Last 30 days", entries)] {
            if let row = summary(list) { rows.append(UsageRow(label, row.value)) }
        }
        var byModel: [String: Double] = [:]
        for entry in entries { byModel[entry.model, default: 0] += entry.points }
        if let top = byModel.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first {
            rows.append(UsageRow("Top model", "\(top.key) · \(compact(top.value)) points"))
        }
        return ProviderUsage(sections: [UsageSection("Points", rows)])
    }
}
