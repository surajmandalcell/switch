import Foundation

extension ProviderCatalog {
    /// Local read only. The IDE writes its AI quota to a config file, so no credential is stored.
    static let jetBrainsAI = ProviderSpec(
        id: "jetbrains", name: "JetBrains AI", fields: [],
        dashboard: "https://account.jetbrains.com/",
        usage: { _ in try JetBrainsUsage.read(home: FileManager.default.homeDirectoryForCurrentUser) })
}

enum JetBrainsUsage {
    /// The most recently written AIAssistantQuotaManager2.xml among the installed IDE config folders.
    static func newestQuotaFile(home: URL) throws -> (URL, String) {
        let fm = FileManager.default
        var best: (url: URL, ide: String, date: Date)?
        for base in ["JetBrains", "Google"] {
            let root = home.appendingPathComponent("Library/Application Support/\(base)")
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
                let file = root.appendingPathComponent("\(name)/options/AIAssistantQuotaManager2.xml")
                guard let date = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { continue }
                if best == nil || date > best!.date { best = (file, name, date) }
            }
        }
        guard let best else {
            throw ProviderError.missingCredential("No JetBrains IDE with AI Assistant was found. Open AI Assistant in your IDE once.")
        }
        return (best.url, best.ide)
    }

    /// The quota XML, or the newer quota state the IDE logs. The IDE saves the XML rarely, so a log
    /// record written after the XML wins. Only the same IDE's log counts, because logs name no account.
    static func read(home: URL) throws -> ProviderUsage {
        let found = try? newestQuotaFile(home: home)
        let xmlUsage = found.flatMap { try? String(contentsOf: $0.0, encoding: .utf8) }.flatMap { try? map(xml: $0, ide: found?.1) }
        guard let found else {
            // No quota XML anywhere: the newest log among all installed IDEs still has a quota state.
            guard let best = logCandidates(home: home).compactMap({ ide in
                logEntry(home: home, vendor: ide.vendor, ide: ide.name).map { (ide, $0) }
            }).max(by: { $0.1.timestamp < $1.1.timestamp }) else {
                throw ProviderError.missingCredential("No JetBrains IDE with AI Assistant was found. Open AI Assistant in your IDE once.")
            }
            return try map(quota: best.1.quota, refill: best.1.refill, ide: best.0.name)
        }
        let vendor = found.0.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let xmlDate = (try? FileManager.default.attributesOfItem(atPath: found.0.path))?[.modificationDate] as? Date
        if let log = logEntry(home: home, vendor: vendor, ide: found.1), xmlUsage == nil || log.timestamp > (xmlDate ?? .distantFuture),
           let fresh = try? map(quota: log.quota, refill: log.refill, ide: found.1) {
            return fresh
        }
        guard let xmlUsage else { throw ProviderError.parse("The JetBrains AI quota file could not be read.") }
        return xmlUsage
    }

    /// Pure mapper for the XML text. Monthly use is the tariff quota only; top-up credits stay separate.
    static func map(xml: String, ide: String?) throws -> ProviderUsage {
        guard let quotaText = option("quotaInfo", in: xml),
              let quota = (try? JSONSerialization.jsonObject(with: Data(quotaText.utf8))).map(JSON.init) else {
            throw ProviderError.parse("The JetBrains AI quota file has no quota information.")
        }
        let refill = option("nextRefill", in: xml).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))).map(JSON.init) }
        return try map(quota: quota, refill: refill, ide: ide)
    }

    /// Quota JSON in the XML's shape (`current`/`maximum`, `tariffQuota`, `topUpQuota`, `until`) and the refill JSON.
    static func map(quota: JSON, refill: JSON?, ide: String?) throws -> ProviderUsage {
        let tariff = quota["tariffQuota"]
        let source = tariff["current"].double != nil && tariff["maximum"].double != nil ? tariff : quota
        let duration = refill?.at("tariff.duration").string ?? refill?["duration"].string
        // The IDE stores one displayed credit as 100,000 units.
        let used = source["current"].double ?? 0, limit = source["maximum"].double ?? 0
        var window = UsageWindow.amounts(
            id: "monthly", title: "Monthly credits", used: used, limit: limit, resetsAt: refill?["next"].date,
            windowMinutes: duration.flatMap(minutes))
        window?.detail = "\(Fmt.number(used / 100_000, digits: 2)) / \(Fmt.number(limit / 100_000, digits: 2)) credits"
        var rows: [UsageRow] = []
        if let topUp = quota.at("topUpQuota.available").double, quota.at("topUpQuota.maximum").double ?? 0 > 0 {
            rows.append(UsageRow("Top-up credits left", Fmt.number(topUp / 100_000, digits: 2)))
        }
        var details: [UsageRow] = []
        if let left = source["available"].double ?? (limit > 0 ? limit - used : nil), limit > 0 {
            details.append(UsageRow("Monthly credits left", Fmt.number(max(0, left) / 100_000, digits: 2)))
        }
        if let amount = refill?.at("tariff.amount").double ?? refill?["amount"].double, amount > 0 {
            details.append(UsageRow("Monthly refill", "\(Fmt.number(amount / 100_000, digits: 2)) credits"))
        }
        if let until = quota["until"].date { details.append(UsageRow("Subscription ends", until.formatted(date: .abbreviated, time: .omitted))) }
        guard window != nil || !rows.isEmpty else { throw ProviderError.parse("The JetBrains AI quota file has no limit.") }
        return ProviderUsage(windows: window.map { [$0] } ?? [], sections: [UsageSection(nil, rows), UsageSection("Monthly credits", details)],
                             plan: quota["type"].string, organization: ide)
    }

    // MARK: IDE log (fresher quota state)

    struct LogEntry { var timestamp: Date; var quota: JSON; var refill: JSON? }

    /// Installed IDE config folders, with their vendor folder ("JetBrains" or "Google").
    static func logCandidates(home: URL) -> [(vendor: String, name: String)] {
        ["JetBrains", "Google"].flatMap { vendor in
            ((try? FileManager.default.contentsOfDirectory(
                atPath: home.appendingPathComponent("Library/Application Support/\(vendor)").path)) ?? []).map { (vendor, $0) }
        }
    }

    static let quotaMarker = "QuotaManager2Impl - New quota state is: "
    static let refillMarker = "QuotaManager2Impl - New quota refill state is: "
    static let tailBytes: UInt64 = 4 * 1024 * 1024

    static func logEntry(home: URL, vendor: String, ide: String) -> LogEntry? {
        guard ["JetBrains", "Google"].contains(vendor), !ide.contains("/"),
              let handle = FileHandle(forReadingAtPath: home.appendingPathComponent("Library/Logs/\(vendor)/\(ide)/idea.log").path)
        else { return nil }
        defer { try? handle.close() }
        // Read a bounded tail ending at the size seen on open. A tail that stops mid-line is rejected.
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let count = min(size, tailBytes), offset = size - count
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: Int(count)),
              data.count == count, data.last == UInt8(ascii: "\n") else { return nil }
        let body = offset > 0 ? data.firstIndex(of: UInt8(ascii: "\n")).map { data[data.index(after: $0)...] } ?? Data() : data[...]
        return String(bytes: body, encoding: .utf8).flatMap { latestEntry(inLog: $0) }
    }

    /// The latest complete quota record, and the latest refill record. A newer quota line that cannot be
    /// read ends the search, so an older account's quota is never shown.
    static func latestEntry(inLog content: String) -> LogEntry? {
        var quota: (Date, JSON)?
        var refill: JSON?
        var foundRefill = false
        for line in content.split(whereSeparator: \.isNewline).reversed() {
            if line.contains(quotaMarker) {
                guard let parsed = parseQuotaLine(String(line)) else { if quota == nil { return nil } else { break } }
                if quota == nil { quota = parsed }
            } else if !foundRefill, line.contains(refillMarker) {
                foundRefill = true
                refill = parseRefillLine(String(line))
            }
            if quota != nil, foundRefill { break }
        }
        return quota.map { LogEntry(timestamp: $0.0, quota: $0.1, refill: refill) }
    }

    private static let number = #"([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)"#
    private static let details = #"QuotaDetails\(current=\#(number), maximum=\#(number), available=\#(number)\)"#
    private static let quotaPattern = #"^Available\(current=\#(number), maximum=\#(number), until=([^,)\s]+), tariffQuota=\#(details)(?:, topUpQuota=\#(details))?\)$"#
    private static let refillPattern = #"^Known\(next=([^,)\s]+), tariff=QuotaRefillInfoTariff\(amount=\#(number), duration=([^,)\s]+)\)\)$"#

    private static func logRecord(_ line: String, marker: String) -> (Date, String)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        let prefix = String(line.prefix(23))
        guard let range = line.range(of: marker), let stamp = formatter.date(from: prefix), formatter.string(from: stamp) == prefix
        else { return nil }
        return (stamp, String(line[range.upperBound...]))
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    static func parseQuotaLine(_ line: String) -> (Date, JSON)? {
        guard let (stamp, state) = logRecord(line, marker: quotaMarker), let fields = captures(quotaPattern, in: state),
              fields.count == 6 || fields.count == 9 else { return nil }
        let numbers = fields.enumerated().filter { $0.offset != 2 }.map { Double($0.element) }
        guard numbers.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 }), numbers[3]! > 0 else { return nil }
        let v = numbers.map { $0! }
        var quota: [String: Any] = ["type": "Available", "current": v[0], "maximum": v[1], "until": fields[2],
                                    "tariffQuota": ["current": v[2], "maximum": v[3], "available": v[4]]]
        if v.count == 8 { quota["topUpQuota"] = ["current": v[5], "maximum": v[6], "available": v[7]] }
        return (stamp, JSON(quota))
    }

    static func parseRefillLine(_ line: String) -> JSON? {
        guard let (_, state) = logRecord(line, marker: refillMarker), let fields = captures(refillPattern, in: state),
              fields.count == 3, let amount = Double(fields[1]), amount.isFinite else { return nil }
        return JSON(["next": fields[0], "tariff": ["amount": amount, "duration": fields[2]]] as [String: Any])
    }

    /// Value of `<option name="..." value="...">` with HTML entities decoded.
    private static func option(_ name: String, in xml: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<option\s+name="\#(name)"\s+value="([^"]*)""#),
              let hit = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(hit.range(at: 1), in: xml) else { return nil }
        return String(xml[range]).replacingOccurrences(of: "&#10;", with: "\n").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// ISO-8601 hours ("PT720H") or days ("30d").
    private static func minutes(_ duration: String) -> Int? {
        if let hit = duration.range(of: #"^PT(\d+)H$"#, options: .regularExpression) {
            return Int(duration[hit].dropFirst(2).dropLast()).map { $0 * 60 }
        }
        if let hit = duration.range(of: #"^(\d+)d$"#, options: .regularExpression) {
            return Int(duration[hit].dropLast()).map { $0 * 1440 }
        }
        return nil
    }
}
