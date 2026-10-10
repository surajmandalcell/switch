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
            CredentialField("region", "Region (for Claude activity)", secure: false, optional: true,
                            placeholder: "us-east-1", env: ["AWS_REGION", "AWS_DEFAULT_REGION"]),
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
                    "TimePeriod": ["Start": start, "End": end], "Granularity": "DAILY",
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
            // CloudWatch is optional: a missing permission or region keeps the Cost Explorer numbers.
            var activity: BedrockActivity?
            do {
                activity = try await BedrockUsage.fetchActivity(
                    keyID: keyID, secret: secret, token: token, region: credential["region"] ?? "us-east-1", now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
            return try BedrockUsage.map(pages, budget: credential["budget"].flatMap(Double.init), now: now,
                                        activity: activity, daily: true)
        })
}

struct BedrockActivity: Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let requests: Int
}

enum BedrockUsage {
    /// Rolling window of the CloudWatch Claude totals.
    static let lookbackDays = 14

    /// CloudWatch endpoint host for a region; nil when the region name is malformed.
    static func monitoringHost(_ region: String) -> String? {
        guard region.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)+-[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        let suffix = switch region {
        case _ where region.hasPrefix("cn-"): "amazonaws.com.cn"
        case _ where region.hasPrefix("eusc-"): "amazonaws.eu"
        case _ where region.hasPrefix("us-iso-"): "c2s.ic.gov"
        case _ where region.hasPrefix("us-isob-"): "sc2s.sgov.gov"
        case _ where region.hasPrefix("eu-isoe-"): "cloud.adc-e.uk"
        case _ where region.hasPrefix("us-isof-"): "csp.hci.ic.gov"
        default: "amazonaws.com"
        }
        return "monitoring.\(region).\(suffix)"
    }

    private static let metrics = [("inputTokens", "InputTokenCount"), ("outputTokens", "OutputTokenCount"),
                                  ("requests", "Invocations")]

    /// Claude token and request totals of the last 14 days from CloudWatch `AWS/Bedrock` metrics.
    static func fetchActivity(keyID: String, secret: String, token: String?, region: String,
                              now: Date) async throws -> BedrockActivity {
        guard let host = monitoringHost(region) else { throw ProviderError.parse("Invalid AWS region.") }
        var pages: [JSON] = []
        var next: String?
        repeat {
            var payload: [String: Any] = [
                "StartTime": now.timeIntervalSince1970 - Double(lookbackDays) * 86_400,
                "EndTime": now.timeIntervalSince1970, "ScanBy": "TimestampAscending",
                "MetricDataQueries": metrics.map { id, name in
                    ["Id": id, "ReturnData": true,
                     "Expression": "SUM(SEARCH('{AWS/Bedrock,ModelId} MetricName=\"\(name)\" claude', 'Sum', 86400))"] as [String: Any]
                },
            ]
            if let next { payload["NextToken"] = next }
            let data = try JSONSerialization.data(withJSONObject: payload)
            let headers = BedrockSigV4.sign(
                method: "POST", host: host, path: "/", query: "",
                headers: ["content-type": "application/x-amz-json-1.0",
                          "x-amz-target": "GraniteServiceVersion20100801.GetMetricData"],
                body: data, accessKeyID: keyID, secretKey: secret, sessionToken: token,
                region: region, service: "monitoring", date: now)
            pages.append(try await HTTP.json("https://\(host)/", method: "POST", headers: headers, body: data))
            next = pages.last?["NextToken"].string
        } while next != nil && pages.count < 20
        return try activity(pages)
    }

    /// Sums `GetMetricData` replies. Incomplete or malformed results throw, so a partial total never shows.
    static func activity(_ pages: [JSON]) throws -> BedrockActivity {
        var totals: [String: Double] = [:]
        for page in pages {
            if !page["Messages"].array.isEmpty { throw ProviderError.parse("CloudWatch reported incomplete results.") }
            for result in page["MetricDataResults"].array {
                guard let id = result["Id"].string, metrics.contains(where: { $0.0 == id }),
                      result["StatusCode"].string == "Complete" else {
                    throw ProviderError.parse("CloudWatch returned an unexpected metric result.")
                }
                for value in result["Values"].array {
                    guard let number = value.double, number.isFinite, number >= 0 else {
                        throw ProviderError.parse("CloudWatch returned an invalid metric value.")
                    }
                    totals[id, default: 0] += number
                }
            }
        }
        func count(_ id: String) throws -> Int {
            guard let value = Int(exactly: (totals[id] ?? 0).rounded()) else {
                throw ProviderError.parse("CloudWatch returned an invalid metric total.")
            }
            return value
        }
        return BedrockActivity(inputTokens: try count("inputTokens"), outputTokens: try count("outputTokens"),
                               requests: try count("requests"))
    }

    /// Compact count such as 1.5M or 2.0K.
    static func compact(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM", Double(count) / 1_000_000)
            : count >= 1000 ? String(format: "%.1fK", Double(count) / 1000) : "\(count)"
    }

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
    /// `daily` pages (DAILY granularity) also give a per-day cost list; `activity` adds the CloudWatch Claude totals.
    static func map(_ pages: [JSON], budget: Double?, now: Date = Date(), activity: BedrockActivity? = nil,
                    daily: Bool = false) throws -> ProviderUsage {
        var byService: [String: Double] = [:]
        var byDay: [String: Double] = [:]
        var currency = "USD"
        for page in pages {
            guard page["ResultsByTime"].exists else { throw ProviderError.parse("AWS returned an unexpected cost reply.") }
            for result in page["ResultsByTime"].array {
                for group in result["Groups"].array {
                    guard let name = group["Keys"][0].string, name.localizedCaseInsensitiveContains("Bedrock"),
                          let amount = group.at("Metrics.UnblendedCost.Amount").double, amount.isFinite else { continue }
                    byService[name, default: 0] += amount
                    if daily, let day = result.at("TimePeriod.Start").string { byDay[day, default: 0] += amount }
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
        var sections = [UsageSection("Bedrock services", rows)]
        if let activity {
            sections.append(UsageSection("Claude activity (14d)", [
                UsageRow("Tokens", compact(activity.inputTokens + activity.outputTokens)),
                UsageRow("Input tokens", compact(activity.inputTokens)),
                UsageRow("Output tokens", compact(activity.outputTokens)),
                UsageRow("Requests", compact(activity.requests)),
            ]))
        }
        let chart = daily ? UsageChart.daily(id: "daily-cost", title: "Daily cost (this month)", unit: currency, values: byDay,
                                            fill: (utc.component(.day, from: now), now)) : nil
        return ProviderUsage(
            windows: windows,
            cost: UsageCost(used: spend, limit: limit, currency: currency, period: "Month to date", resetsAt: monthEnd),
            sections: sections, charts: [chart].compactMap { $0 }.filter { $0.total > 0 })
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
