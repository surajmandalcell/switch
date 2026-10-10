import Foundation

extension ProviderCatalog {
    /// Local read only. The IDE writes its AI quota to a config file, so no credential is stored.
    static let jetBrainsAI = ProviderSpec(
        id: "jetbrains", name: "JetBrains AI", fields: [],
        dashboard: "https://account.jetbrains.com/",
        usage: { _ in
            let (url, ide) = try JetBrainsUsage.newestQuotaFile(
                home: FileManager.default.homeDirectoryForCurrentUser)
            guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
                throw ProviderError.parse("The JetBrains AI quota file could not be read.")
            }
            return try JetBrainsUsage.map(xml: xml, ide: ide)
        })
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

    /// Pure mapper for the XML text. Monthly use is the tariff quota only; top-up credits stay separate.
    static func map(xml: String, ide: String?) throws -> ProviderUsage {
        guard let quotaText = option("quotaInfo", in: xml),
              let quota = (try? JSONSerialization.jsonObject(with: Data(quotaText.utf8))).map(JSON.init) else {
            throw ProviderError.parse("The JetBrains AI quota file has no quota information.")
        }
        let tariff = quota["tariffQuota"]
        let source = tariff["current"].double != nil && tariff["maximum"].double != nil ? tariff : quota
        let refill = option("nextRefill", in: xml).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))).map(JSON.init) }
        let duration = refill?.at("tariff.duration").string ?? refill?["duration"].string
        let window = UsageWindow.amounts(
            id: "monthly", title: "Monthly credits", used: source["current"].double ?? 0,
            limit: source["maximum"].double ?? 0, resetsAt: refill?["next"].date,
            windowMinutes: duration.flatMap(minutes))
        var rows: [UsageRow] = []
        if let topUp = quota.at("topUpQuota.available").double, quota.at("topUpQuota.maximum").double ?? 0 > 0 {
            // The IDE stores one displayed credit as 100,000 units.
            rows.append(UsageRow("Top-up credits left", Fmt.number(topUp / 100_000, digits: 2)))
        }
        guard window != nil || !rows.isEmpty else { throw ProviderError.parse("The JetBrains AI quota file has no limit.") }
        return ProviderUsage(windows: window.map { [$0] } ?? [], sections: [UsageSection(nil, rows)],
                             plan: quota["type"].string, organization: ide)
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
