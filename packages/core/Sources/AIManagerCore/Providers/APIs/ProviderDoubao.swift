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
            CredentialField("accessKeyId", "Access key ID",
                            env: ["VOLCENGINE_ACCESS_KEY_ID", "VOLCENGINE_ACCESS_KEY", "VOLC_ACCESSKEY", "DOUBAO_ACCESS_KEY_ID"]),
            CredentialField("secretAccessKey", "Secret access key",
                            env: ["VOLCENGINE_SECRET_ACCESS_KEY", "VOLCENGINE_SECRET_KEY", "VOLC_SECRETKEY", "DOUBAO_SECRET_ACCESS_KEY"]),
            CredentialField("region", "Region", secure: false, optional: true, placeholder: "cn-beijing (default)",
                            env: ["VOLCENGINE_REGION", "VOLC_REGION", "DOUBAO_REGION"]),
        ],
        dashboard: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe",
        usage: { credential in
            let id = try credential.require("accessKeyId"), secret = try credential.require("secretAccessKey")
            let region = credential["region"] ?? "cn-beijing"
            func call(_ action: String) async throws -> HTTPResponse {
                let query = [("Action", action), ("Version", "2024-01-01")]
                let headers = DoubaoUsage.sign(accessKeyID: id, secret: secret, region: region, query: query, date: Date())
                return try await HTTP.send("https://open.volcengineapi.com/?Action=\(action)&Version=2024-01-01",
                                           method: "POST", headers: headers)
            }
            let coding = try await call("GetCodingPlanUsage")
            if coding.status == 403 {
                throw ProviderError.unauthorized("Volcengine denied access. Check the keys and the IAM permission ark:GetCodingPlanUsage.")
            }
            try HTTP.check(coding)
            // Agent plan is best effort: 403 or 404 means the account has none.
            let agent = try? await call("GetAFPUsage")
            return try DoubaoUsage.map(coding: try coding.json(),
                                       agent: agent.flatMap { $0.status == 200 ? try? $0.json() : nil })
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
        for item in result["QuotaUsage"].array {
            let level = (item["Level"].string ?? "").lowercased()
            let slot: (String, String, Int)
            switch level {
            case "session", "5-hour", "five_hour", "5h": slot = ("session", "Session", 300)
            case "weekly", "week": slot = ("weekly", "Weekly", 10080)
            case "monthly", "month": slot = ("monthly", "Monthly", 43200)
            default: continue
            }
            guard let percent = item["Percent"].double else { continue }
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
        return ProviderUsage(windows: windows, plan: plan, fetchedAt: now)
    }
}
