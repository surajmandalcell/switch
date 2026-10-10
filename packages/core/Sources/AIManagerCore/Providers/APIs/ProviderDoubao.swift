import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension ProviderCatalog {
    static let doubao = ProviderSpec(
        id: "doubao", name: "Doubao",
        fields: [
            CredentialField("accessKeyId", "Access key ID", optional: true,
                            env: ["VOLCENGINE_ACCESS_KEY_ID", "VOLCENGINE_ACCESS_KEY", "VOLC_ACCESSKEY", "DOUBAO_ACCESS_KEY_ID"]),
            CredentialField("secretAccessKey", "Secret access key", optional: true,
                            env: ["VOLCENGINE_SECRET_ACCESS_KEY", "VOLCENGINE_SECRET_KEY", "VOLCENGINE_ACCESS_KEY_SECRET",
                                  "VOLC_SECRETKEY", "DOUBAO_SECRET_ACCESS_KEY"]),
            CredentialField("region", "Region", secure: false, optional: true, placeholder: "cn-beijing (default)",
                            env: ["VOLCENGINE_REGION", "VOLCENGINE_REGION_ID", "VOLC_REGION", "DOUBAO_REGION"]),
            CredentialField("apiKey", "Ark API key", optional: true,
                            placeholder: "Request limits only, when no access key pair is set",
                            env: ["ARK_API_KEY", "VOLCENGINE_API_KEY", "DOUBAO_API_KEY"]),
        ],
        dashboard: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe",
        usage: { credential in
            let apiKey = credential["apiKey"]
            var signedError: Error?
            // 1) Signed plan usage with the access key pair; 2) the Ark key probe when that fails or is absent.
            if let id = credential["accessKeyId"], let secret = credential["secretAccessKey"] {
                let region = credential["region"] ?? "cn-beijing"
                func call(_ action: String) async throws -> HTTPResponse {
                    let query = [("Action", action), ("Version", "2024-01-01")]
                    let headers = DoubaoUsage.sign(accessKeyID: id, secret: secret, region: region, query: query, date: Date())
                    return try await HTTP.send("https://open.volcengineapi.com/?Action=\(action)&Version=2024-01-01",
                                               method: "POST", headers: headers)
                }
                do {
                    let coding = try await call("GetCodingPlanUsage")
                    if coding.status == 403 {
                        throw ProviderError.unauthorized("Volcengine denied access. Check the keys and the IAM permission ark:GetCodingPlanUsage.")
                    }
                    try HTTP.check(coding)
                    // Agent plan is best effort: 403 or 404 means the account has none.
                    let agent = try? await call("GetAFPUsage")
                    return try DoubaoUsage.map(coding: try coding.json(),
                                               agent: agent.flatMap { $0.status == 200 ? try? $0.json() : nil })
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard apiKey != nil else { throw error }
                    signedError = error
                }
            }
            guard let apiKey else {
                throw signedError ?? ProviderError.missingCredential("Add an access key pair or an Ark API key for Doubao.")
            }
            return try await DoubaoUsage.probe(key: apiKey)
        })
}

enum DoubaoUsage {
    private static let signedHeaders = "content-type;host;x-content-sha256;x-date"

    /// Volcengine V4 signature (AWS SigV4 style) for an empty-body POST to open.volcengineapi.com.
    static func sign(accessKeyID: String, secret: String, region: String, query: [(String, String)],
                     date: Date, host: String = "open.volcengineapi.com",
                     contentType: String = "application/x-www-form-urlencoded; charset=utf-8",
                     body: Data = Data()) -> [String: String] {
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = utc.string(from: date)
        let dateStamp = String(timestamp.prefix(8))
        let payloadHash = hex(SHA256.hash(data: body))
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-_.~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text }
        let canonicalQuery = query.map { (encode($0.0), encode($0.1)) }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let canonical = ["POST", "/", canonicalQuery, "content-type:\(contentType)", "host:\(host)",
                         "x-content-sha256:\(payloadHash)", "x-date:\(timestamp)", "", signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(dateStamp)/\(region)/ark/request"
        let toSign = "HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hex(SHA256.hash(data: Data(canonical.utf8))))"
        var key = Data(secret.utf8)
        for part in [dateStamp, region, "ark", "request"] { key = hmac(key, part) }
        let signature = hex(hmac(key, toSign))
        return [
            "Content-Type": contentType, "X-Date": timestamp, "X-Content-Sha256": payloadHash, "Host": host,
            "Authorization": "HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
        ]
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `coding` is the GetCodingPlanUsage body; `agent` the optional GetAFPUsage body.
    static func map(coding: JSON, agent: JSON?, now: Date = Date()) throws -> ProviderUsage {
        let result = coding["Result"]
        guard result.exists else { throw ProviderError.parse("Volcengine returned an unexpected usage shape.") }
        var windows: [UsageWindow] = []
        // One window per slot, session first so it drives the menu bar whatever the response order.
        let quotas = result["QuotaUsage"].array
        for (levels, slot) in [(["session", "5-hour", "five_hour", "5h"], ("session", "Session", 300)),
                               (["weekly", "week"], ("weekly", "Weekly", 10080)),
                               (["monthly", "month"], ("monthly", "Monthly", 43200))] {
            guard let item = quotas.first(where: { levels.contains(($0["Level"].string ?? "").lowercased()) }),
                  let percent = item["Percent"].double else { continue }
            windows.append(UsageWindow(id: slot.0, title: slot.1, usedPercent: percent,
                                       resetsAt: item["ResetTimestamp"].double.flatMap(Fmt.epoch), windowMinutes: slot.2))
        }
        var plan = result["Status"].string
        if let agent {
            let data = agent["Result"]
            for (key, slot) in [("AFPFiveHour", ("agent-session", "Agent 5-hour", 300)),
                                ("AFPWeekly", ("agent-weekly", "Agent weekly", 10080)),
                                ("AFPMonthly", ("agent-monthly", "Agent monthly", 43200))] {
                let node = data[key]
                guard let quota = node["Quota"].double,
                      let window = UsageWindow.amounts(id: slot.0, title: slot.1, used: node["Used"].double ?? 0, limit: quota,
                                                       resetsAt: node["ResetTime"].double.flatMap(Fmt.epoch),
                                                       windowMinutes: slot.2) else { continue }
                windows.append(window)
            }
            if plan == nil { plan = data["PlanType"].string?.capitalized }
        }
        return ProviderUsage(windows: windows, plan: plan, fetchedAt: result["UpdateTimestamp"].double.flatMap(Fmt.epoch) ?? now)
    }

    // MARK: Ark API key probe

    /// Request-limit headers of one `chat/completions` call (200 or 429 both carry them).
    struct Probe: Equatable {
        var status: Int
        var remaining: Int?
        var limit: Int?
        var reset: Date?

        /// A 429 with a limit header proves the request bucket is empty; a 200 needs both headers.
        var reliable: Bool { status == 429 ? limit != nil : limit != nil && remaining != nil }
        var ambiguousZero: Bool { status == 200 && reliable && (limit ?? 0) > 0 && remaining == 0 }
    }

    static func probe(status: Int, headers: [String: String], now: Date = Date()) -> Probe {
        Probe(status: status, remaining: headers["x-ratelimit-remaining-requests"].flatMap { Int($0) },
              limit: headers["x-ratelimit-limit-requests"].flatMap { Int($0) },
              reset: headers["x-ratelimit-reset-requests"].flatMap { resetDate($0, now: now) })
    }

    /// ISO 8601, a duration such as "1m30s", or plain seconds.
    static func resetDate(_ text: String, now: Date) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if let date = Fmt.iso(value) { return date }
        let units: [Character: Double] = ["d": 86400, "h": 3600, "m": 60, "s": 1]
        var seconds = 0.0
        if let regex = try? NSRegularExpression(pattern: #"(\d+)([dhms])"#) {
            let range = NSRange(value.startIndex..., in: value)
            for match in regex.matches(in: value, range: range) {
                if let n = Range(match.range(at: 1), in: value).flatMap({ Double(value[$0]) }),
                   let u = Range(match.range(at: 2), in: value).flatMap({ value[$0].first }) {
                    seconds += n * (units[u] ?? 0)
                }
            }
        }
        if seconds > 0 { return now.addingTimeInterval(seconds) }
        return Double(value).map { now.addingTimeInterval($0) }
    }

    /// A trustworthy request-limit pair becomes the "Requests" window; a valid key without one shows as active.
    static func map(probe: Probe, now: Date = Date()) -> ProviderUsage {
        guard probe.reliable, let limit = probe.limit, limit > 0 else {
            return ProviderUsage(sections: [UsageSection(nil, [UsageRow("API key", "Active, request limits unavailable")])],
                                 fetchedAt: now)
        }
        let used = max(0, limit - (probe.remaining ?? 0))
        let window = UsageWindow(id: "requests", title: "Requests", usedPercent: Double(used) / Double(limit) * 100,
                                 resetsAt: probe.reset, detail: "\(used)/\(limit) requests")
        return ProviderUsage(windows: [window], fetchedAt: now)
    }

    private static let probeModels = ["doubao-seed-2.0-code", "doubao-1.5-pro-32k", "doubao-lite-32k"]

    private static func probeOnce(key: String, model: String) async throws -> Probe {
        let body: [String: Any] = ["model": model, "max_tokens": 1, "messages": [["role": "user", "content": "hi"]]]
        let response = try await HTTP.send("https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions",
                                           method: "POST", headers: HTTP.bearer(key),
                                           body: try JSONSerialization.data(withJSONObject: body))
        guard response.status == 200 || response.status == 429 else {
            try HTTP.check(response)
            throw ProviderError.http(response.status, "")
        }
        return probe(status: response.status, headers: response.headers)
    }

    /// Tries each model (403 or 404 means the key lacks it) and confirms a zero remaining count once.
    static func probe(key: String) async throws -> ProviderUsage {
        var last: Error = ProviderError.unavailable("Doubao is unavailable.")
        for model in probeModels {
            do {
                let first = try await probeOnce(key: key, model: model)
                guard first.ambiguousZero else { return map(probe: first) }
                guard let second = try? await probeOnce(key: key, model: model) else { return map(probe: first) }
                if second.status == 429 { return map(probe: second.reliable ? second : first) }
                // Two 200s with zero remaining: treat the headers as unreliable.
                return map(probe: second.ambiguousZero ? Probe(status: 200, remaining: nil, limit: nil, reset: nil) : second)
            } catch let error as ProviderError {
                switch error {
                case .unauthorized, .http(404, _): last = error
                default: throw error
                }
            }
        }
        throw last
    }
}
