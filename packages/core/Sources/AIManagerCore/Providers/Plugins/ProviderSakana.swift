import Foundation

extension ProviderCatalog {
    static let sakana = ProviderSpec(
        id: "sakana", name: "Sakana AI",
        fields: [.cookie("Cookie header from console.sakana.ai/billing")],
        dashboard: "https://console.sakana.ai/billing",
        usage: { credential in
            let headers = ["Cookie": try credential.require("cookie"), "Accept": "text/html,application/xhtml+xml"]
            let page = try await HTTP.send("https://console.sakana.ai/billing", headers: headers)
            try HTTP.check(page)
            // Pay-as-you-go credit is a separate tab and optional.
            let payg = try? await HTTP.send("https://console.sakana.ai/billing?tab=payAsYouGo", headers: headers)
            return try SakanaUsage.map(html: page.text, paygHTML: payg?.status == 200 ? payg?.text : nil)
        })
}

enum SakanaUsage {
    static func map(html: String, paygHTML: String? = nil) throws -> ProviderUsage {
        let windows = [try window(html, label: "5-hour", id: "session", minutes: 300),
                       try window(html, label: "Weekly", id: "weekly", minutes: 10080)].compactMap { $0 }
        guard !windows.isEmpty else {
            throw ProviderError.parse("Sakana billing page has no usage limits. The cookie may be expired.")
        }
        let plan = [capture("<div[^>]*data-slot=\"card-title\"[^>]*>[\\s\\S]*?<span>\\s*([^<]+?)\\s*</span>", html),
                    capture("<div[^>]*data-slot=\"card-title\"[^>]*>[\\s\\S]*?<span>[^<]+</span>\\s*<span[^>]*>\\s*([^<]+?)\\s*</span>", html)]
            .compactMap { $0 }.joined(separator: " ")
        var cost: UsageCost?
        var sections: [UsageSection] = []
        if let paygHTML,
           let balance = capture("<h2[^>]*>\\s*Credit balance\\s*</h2>[\\s\\S]{0,900}?<p[^>]*tabular-nums[^\"]*\"[^>]*>\\$?([0-9][0-9,]*(?:\\.[0-9]+)?)</p>", paygHTML).flatMap(amount) {
            let spent = capture("<h2[^>]*>\\s*Usage\\s*</h2>\\s*<span[^>]*>\\s*Total(?:<!--\\s*-->)?:\\s*(?:<!--\\s*-->)?\\$?([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*</span>", paygHTML).flatMap(amount)
            cost = UsageCost(used: spent, balance: balance, period: "Pay as you go")
            // The usage date range ("Sep 1 - Sep 21") sits in a button; strip its comments and extra spaces.
            let period = capture("aria-label=\"Usage date range\"[^>]*>([\\s\\S]*?)</button>", paygHTML)?
                .replacingOccurrences(of: "<!--.*?-->", with: "", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            sections.append(UsageSection("Extra usage", [UsageRow("Balance", Fmt.money(balance))]
                + (spent.map { [PluginFmt.row("Usage", Fmt.money($0), period.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) })] } ?? [])))
        }
        return ProviderUsage(windows: windows, cost: cost, sections: sections, plan: plan.isEmpty ? nil : plan)
    }

    private static func window(_ html: String, label: String, id: String, minutes: Int) throws -> UsageWindow? {
        guard let start = firstMatch("<p[^>]*>\\s*\(label)\\s*</p>", html) else { return nil }
        var rest = String(html[start.upperBound...])
        // The section ends at the next window title or card.
        if let end = firstMatch("<p[^>]*>\\s*(?:5-hour|Weekly)\\s*</p>|<div[^>]*data-slot=[\"'](?:card|card-title)[\"'][^>]*>", rest) {
            rest = String(rest[..<end.lowerBound])
        }
        guard let percent = capture("<p[^>]*>\\s*([0-9]+(?:\\.[0-9]+)?)% used\\s*</p>", rest).flatMap(Double.init),
              (0...100).contains(percent) else {
            throw ProviderError.parse("Invalid Sakana \(label) usage percentage.")
        }
        return UsageWindow(id: id, title: label == "Weekly" ? "Weekly" : "5-hour", usedPercent: percent,
                           resetsAt: capture("<p[^>]*>\\s*Resets on ([^<]+?)\\s*</p>", rest).flatMap(resetDate),
                           windowMinutes: minutes)
    }

    /// "October 14, 2026 at 3:00 PM" in UTC.
    private static func resetDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return formatter.date(from: text)
    }

    private static func amount(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: "")) }

    private static func firstMatch(_ pattern: String, _ text: String) -> Range<String.Index>? {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
