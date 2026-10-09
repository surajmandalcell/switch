import Foundation

extension ProviderCatalog {
    static let t3chat = ProviderSpec(
        id: "t3chat", name: "T3 Chat",
        fields: [.cookie("Cookie header from t3.chat"),
                 CredentialField("headers", "Captured headers (JSON)", optional: true,
                                 placeholder: "Only needed after a Vercel security challenge")],
        dashboard: "https://t3.chat/settings/customization",
        usage: { credential in
            let input = #"{"0":{"json":{"sessionId":null},"meta":{"values":{"sessionId":["undefined"]}}}}"#
            var headers = [
                "Accept": "*/*", "Accept-Language": "en-US,en;q=0.9",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
                "Sec-Fetch-Dest": "empty", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Site": "same-origin", "Priority": "u=4",
                "Referer": "https://t3.chat/settings/customization", "trpc-accept": "application/jsonl",
                "x-trpc-source": "web-client", "x-trpc-batch": "true",
            ]
            if let extra = credential["headers"].flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }) {
                headers.merge(extra) { _, new in new }
            }
            headers["Cookie"] = try credential.require("cookie")
            headers["Origin"] = "https://t3.chat"
            let query = input.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? input
            let response = try await HTTP.send("https://t3.chat/api/trpc/getCustomerData?batch=1&input=\(query)", headers: headers)
            if response.status == 429, response.headers["x-vercel-mitigated"] == "challenge" {
                throw ProviderError.unavailable("T3 Chat returned a Vercel security challenge. Paste the captured request headers as JSON.")
            }
            try HTTP.check(response)
            return try T3ChatUsage.map(jsonLines: response.text)
        })
}

enum T3ChatUsage {
    /// The tRPC batch answers with one JSON document per line; the customer data sits inside one of them.
    static func map(jsonLines: String) throws -> ProviderUsage {
        let data = jsonLines.split(whereSeparator: \.isNewline).lazy
            .compactMap { try? JSON(data: Data($0.utf8)) }.compactMap { find($0) }.first
        guard let data else { throw ProviderError.parse("Could not parse T3 Chat usage: invalid customer data.") }
        let band = data["usageBand"].string
        let plan = (data.at("subscription.productName").string ?? data["subTier"].string)?
            .split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let windows = [
            UsageWindow(id: "base", title: "Base", usedPercent: data["usageFourHourPercentage"].double ?? 0,
                        resetsAt: (data["usageFourHourNextResetAt"].double ?? data["usageWindowNextResetAt"].double).flatMap(Fmt.epoch),
                        windowMinutes: 240, detail: band.map { "Base - \($0)" }),
            UsageWindow(id: "overage", title: "Overage",
                        usedPercent: data["usageMonthPercentage"].double ?? data["usagePeriodPercentage"].double ?? 0,
                        resetsAt: data.at("subscription.currentPeriodEnd").double.flatMap(Fmt.epoch)),
        ]
        return ProviderUsage(windows: windows, plan: plan)
    }

    private static func find(_ json: JSON) -> JSON? {
        if let object = json.raw as? [String: Any] {
            if object["usageFourHourPercentage"] != nil || object["usageMonthPercentage"] != nil
                || (object["subscription"] != nil && object["usageBand"] != nil) { return json }
            return object.values.lazy.compactMap { find(JSON($0)) }.first
        }
        return (json.raw as? [Any])?.lazy.compactMap { find(JSON($0)) }.first
    }
}
