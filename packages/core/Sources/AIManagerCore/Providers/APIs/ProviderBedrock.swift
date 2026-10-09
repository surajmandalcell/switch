import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension ProviderCatalog {
    // Cost Explorer is a global service served from us-east-1, so no region field is needed.
    static let bedrock = ProviderSpec(
        id: "bedrock", name: "AWS Bedrock",
        fields: [
            CredentialField("accessKeyID", "Access key ID", secure: false, env: ["AWS_ACCESS_KEY_ID"]),
            CredentialField("secretAccessKey", "Secret access key", env: ["AWS_SECRET_ACCESS_KEY"]),
            CredentialField("sessionToken", "Session token", optional: true, env: ["AWS_SESSION_TOKEN"]),
            CredentialField("budget", "Monthly budget (USD)", secure: false, optional: true, placeholder: "100"),
        ],
        dashboard: "https://console.aws.amazon.com/bedrock",
        usage: { credential in
            let keyID = try credential.require("accessKeyID")
            let secret = try credential.require("secretAccessKey")
            let token = credential["sessionToken"]
            let now = Date()
            let (start, end) = BedrockUsage.monthToDate(now)
            var pages: [JSON] = []
            var next: String?
            repeat {
                var body: [String: Any] = [
                    "TimePeriod": ["Start": start, "End": end], "Granularity": "MONTHLY",
                    "Metrics": ["UnblendedCost"], "GroupBy": [["Type": "DIMENSION", "Key": "SERVICE"]],
                ]
                if let next { body["NextPageToken"] = next }
                let data = try JSONSerialization.data(withJSONObject: body)
                let headers = BedrockSigV4.sign(
                    method: "POST", host: "ce.us-east-1.amazonaws.com", path: "/", query: "",
                    headers: ["content-type": "application/x-amz-json-1.1",
                              "x-amz-target": "AWSInsightsIndexService.GetCostAndUsage"],
                    body: data, accessKeyID: keyID, secretKey: secret, sessionToken: token,
                    region: "us-east-1", service: "ce", date: now)
                let response = try await HTTP.send("https://ce.us-east-1.amazonaws.com/", method: "POST",
                                                   headers: headers, body: data)
                // No cost data yet (new account or first day of month) reads as zero spend.
                if response.status == 400, response.text.contains("DataUnavailableException") { break }
                try HTTP.check(response)
                let page = try response.json()
                pages.append(page)
                next = page["NextPageToken"].string
            } while next != nil && pages.count < 10
            return try BedrockUsage.map(pages, budget: credential["budget"].flatMap(Double.init), now: now)
        })
}

enum BedrockUsage {
    /// Start (first of the UTC month) and exclusive end (tomorrow) as `yyyy-MM-dd`.
    static func monthToDate(_ now: Date) -> (String, String) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = utc.date(from: utc.dateComponents([.year, .month], from: now)) ?? now
        let tomorrow = utc.date(byAdding: .day, value: 1, to: now) ?? now
        return (day(start), day(tomorrow))
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// `pages` are Cost Explorer GetCostAndUsage replies grouped by SERVICE; only Bedrock services count.
    static func map(_ pages: [JSON], budget: Double?, now: Date = Date()) throws -> ProviderUsage {
        var byService: [String: Double] = [:]
        var currency = "USD"
        for page in pages {
            guard page["ResultsByTime"].exists else { throw ProviderError.parse("AWS returned an unexpected cost reply.") }
            for result in page["ResultsByTime"].array {
                for group in result["Groups"].array {
                    guard let name = group["Keys"][0].string, name.localizedCaseInsensitiveContains("Bedrock"),
                          let amount = group.at("Metrics.UnblendedCost.Amount").double, amount.isFinite else { continue }
                    byService[name, default: 0] += amount
                    currency = group.at("Metrics.UnblendedCost.Unit").string ?? currency
                }
            }
        }
        let spend = byService.values.reduce(0, +)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let monthEnd = utc.date(byAdding: .month, value: 1, to: utc.date(from: utc.dateComponents([.year, .month], from: now)) ?? now)
        let limit = budget.flatMap { $0 > 0 ? $0 : nil }
        let windows = limit.map {
            [UsageWindow(id: "monthly", title: "Monthly budget", usedPercent: spend / $0 * 100, resetsAt: monthEnd,
                         detail: "\(Fmt.money(spend, currency: currency)) / \(Fmt.money($0, currency: currency))")]
        } ?? []
        let rows = byService.sorted { $0.value > $1.value }.prefix(5).map { UsageRow($0.key, Fmt.money($0.value, currency: currency)) }
        return ProviderUsage(
            windows: windows,
            cost: UsageCost(used: spend, limit: limit, currency: currency, period: "Month to date", resetsAt: monthEnd),
            sections: [UsageSection("Bedrock services", rows)])
    }
}

/// AWS Signature Version 4 for JSON POST calls (no query string needs encoding here).
enum BedrockSigV4 {
    /// Returns the request headers to send, including `Authorization`. `headers` use lowercase names.
    /// `host` and `x-amz-date` are added and signed; `x-amz-security-token` is added when a session token is set.
    static func sign(method: String, host: String, path: String, query: String, headers: [String: String],
                     body: Data, accessKeyID: String, secretKey: String, sessionToken: String?,
                     region: String, service: String, date: Date) -> [String: String] {
        let stamp = timestamp(date)
        let day = String(stamp.prefix(8))
        var signed = headers
        signed["x-amz-date"] = stamp
        if let sessionToken { signed["x-amz-security-token"] = sessionToken }
        // The body hash header is signed for service calls; the AWS docs vector has none.
        if !body.isEmpty { signed["x-amz-content-sha256"] = hex(SHA256.hash(data: body)) }
        var canonical = signed
        canonical["host"] = host
        let names = canonical.keys.sorted()
        let headerBlock = names.map { "\($0):\(canonical[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let request = [method, path, query, headerBlock, signedHeaders, hex(SHA256.hash(data: body))].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, hex(SHA256.hash(data: Data(request.utf8)))].joined(separator: "\n")
        var key = Data("AWS4\(secretKey)".utf8)
        for part in [day, region, service, "aws4_request"] { key = hmac(key, part) }
        let signature = hex(hmac(key, toSign))
        signed["authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return signed
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
