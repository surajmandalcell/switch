import Foundation

// Billing contract: CodexBar 2bd8936be (MIT), copyright 2026 Peter Steinberger.
extension ProviderCatalog {
    static let siliconflow = ProviderSpec(
        id: "siliconflow", name: "SiliconFlow",
        fields: [.apiKey("SILICONFLOW_API_KEY"),
                 CredentialField("region", "Region", secure: false, optional: true, placeholder: "cn or intl (default cn)")],
        dashboard: "https://cloud.siliconflow.cn",
        usage: { credential in
            let intl = credential["region"]?.lowercased() == "intl"
            return try await SiliconFlowUsage.fetch(
                key: credential.require("apiKey"),
                origin: intl ? SiliconFlowUsage.international : SiliconFlowUsage.china)
        })
}

enum SiliconFlowUsage {
    typealias Send = @Sendable (String, [String: String]) async throws -> HTTPResponse
    static let liveSend: Send = { try await HTTP.send($0, headers: $1) }
    /// The key is only ever sent to one of these two origins; each has its own currency.
    static let china = "https://api.siliconflow.cn"
    static let international = "https://api.siliconflow.com"

    static func fetch(key: String, origin: String, send: Send = liveSend) async throws -> ProviderUsage {
        guard let currency = [china: "CNY", international: "USD"][origin] else {
            throw ProviderError.unsupported("SiliconFlow API origin must be \(china) or \(international).")
        }
        let response = try await send(origin + "/v1/user/info", HTTP.bearer(key))
        if response.status == 410 { throw refused }
        try HTTP.check(response)
        guard response.status == 200 else {
            throw ProviderError.http(response.status, "SiliconFlow returned an unexpected balance response.")
        }
        return try map(response.json(), currency: currency)
    }

    private static let refused = ProviderError.unavailable(
        "SiliconFlow refused the balance query. Check the balance in the SiliconFlow console.")

    /// Amounts are numbers or plain decimal strings in the origin's currency (never converted).
    static func map(_ json: JSON, currency: String) throws -> ProviderUsage {
        guard let code = json["code"].raw as? NSNumber, !JSON.isBoolean(json["code"].raw) else {
            throw ProviderError.parse("SiliconFlow returned an unrecognized balance response.")
        }
        if code.intValue == 20092 { throw refused }
        if code.intValue == 30014 { throw ProviderError.unauthorized("The provider rejected this credential. Sign in again or replace it.") }
        guard code.intValue == 20000, json["status"].raw as? Bool == true, json["data"].exists else {
            throw ProviderError.parse("SiliconFlow returned an unrecognized balance response.")
        }
        func money(_ value: JSON) throws -> Double {
            if let number = value.raw as? NSNumber, !JSON.isBoolean(value.raw), number.doubleValue.isFinite { return number.doubleValue }
            if let text = value.raw as? String, text.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil,
               let number = Double(text), number.isFinite { return number }
            throw ProviderError.parse("SiliconFlow returned invalid balance amounts.")
        }
        let data = json["data"]
        var rows = [UsageRow("Balance", Fmt.money(try money(data["totalBalance"]), currency: currency))]
        if data["chargeBalance"].exists, data["chargeBalance"].raw as? NSNull == nil {
            rows.append(UsageRow("Purchased", Fmt.money(try money(data["chargeBalance"]), currency: currency)))
        }
        if data["balance"].exists, data["balance"].raw as? NSNull == nil {
            rows.append(UsageRow("Bonus", Fmt.money(try money(data["balance"]), currency: currency)))
        }
        if let status = data["status"].string, status != "normal" { rows.append(UsageRow("Status", status)) }
        return ProviderUsage(windows: [], sections: [UsageSection("Balance", rows)])
    }
}
