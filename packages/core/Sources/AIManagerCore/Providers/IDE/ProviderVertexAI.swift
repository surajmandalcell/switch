import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension ProviderCatalog {
    private static let vertexADC = LiveFile(".config/gcloud/application_default_credentials.json",
                                            homeEnv: "CLOUDSDK_CONFIG")

    static let vertexAI = ProviderSpec(
        id: "vertexai", name: "Vertex AI", style: .files,
        files: [vertexADC], login: ["gcloud", "auth", "application-default", "login"],
        dashboard: "https://console.cloud.google.com/vertex-ai",
        identify: { credential in VertexAIUsage.identity(credential.json(vertexADC.id)) },
        usage: { credential in
            guard let adc = credential.json(vertexADC.id) else {
                throw ProviderError.missingCredential("Run gcloud auth application-default login first.")
            }
            guard adc["type"].string == "authorized_user", let clientID = adc["client_id"].string,
                  let secret = adc["client_secret"].string, let refresh = adc["refresh_token"].string else {
                throw ProviderError.unsupported("Only user sign-ins from gcloud auth application-default login are supported.")
            }
            // The access token is never saved. Google does not rotate the refresh token, so this is safe
            // while gcloud holds the same file.
            let fresh = try await IDEAuth.googleRefresh(clientID: clientID, clientSecret: secret, refreshToken: refresh)
            let claims = fresh.idToken.flatMap(Fmt.jwtClaims)
            guard let project = VertexAIUsage.project(adc) else {
                return VertexAIUsage.map(usage: nil, limit: nil, project: nil, email: claims?["email"].string)
            }
            let usage = try await VertexAIUsage.series(token: fresh.accessToken, project: project, metric: "usage")
            let limit = try await VertexAIUsage.series(token: fresh.accessToken, project: project, metric: "limit")
            return VertexAIUsage.map(usage: usage, limit: limit, project: project, email: claims?["email"].string)
        })
}

enum VertexAIUsage {
    /// Pure mapper. Quota percent is the highest usage/limit across Vertex AI quotas in the last 24 hours.
    /// Without a project it shows identity only.
    static func map(usage: [JSON]?, limit: [JSON]?, project: String?, email: String?) -> ProviderUsage {
        var windows: [UsageWindow] = []
        var rows: [UsageRow] = []
        if let usage, let limit {
            let used = peaks(usage), caps = peaks(limit)
            let percents = used.compactMap { key, value -> Double? in
                // A usage series without a limit name pairs with the single limit of the same metric and location.
                let cap = caps[key] ?? (key.limitName.isEmpty ? uniqueCap(caps, key) : nil)
                return cap.flatMap { Fmt.percent(value, of: $0) }
            }
            if let worst = percents.max() {
                windows = [UsageWindow(id: "quota", title: "Vertex AI quota", usedPercent: worst, windowMinutes: 1440)]
            } else {
                rows = [UsageRow("Quota", "No Vertex AI quota data in the last 24 hours")]
            }
        } else {
            rows = [UsageRow("Quota", "Set a project with gcloud auth application-default set-quota-project")]
        }
        return ProviderUsage(windows: windows, sections: [UsageSection(nil, rows)], plan: "gcloud",
                             email: email, organization: project)
    }

    private struct Key: Hashable { let metric: String; let limitName: String; let location: String }

    private static func peaks(_ series: [JSON]) -> [Key: Double] {
        var result: [Key: Double] = [:]
        for entry in series {
            guard let metric = entry.at("metric.labels.quota_metric").string ?? entry.at("resource.labels.quota_id").string,
                  let peak = entry["points"].array.compactMap({ $0.at("value.doubleValue").double ?? $0.at("value.int64Value").double }).max()
            else { continue }
            let key = Key(metric: metric, limitName: entry.at("metric.labels.limit_name").string ?? "",
                          location: entry.at("resource.labels.location").string ?? "global")
            result[key] = max(result[key] ?? 0, peak)
        }
        return result
    }

    private static func uniqueCap(_ caps: [Key: Double], _ key: Key) -> Double? {
        let same = caps.filter { $0.key.metric == key.metric && $0.key.location == key.location && $0.value > 0 }
        return same.count == 1 ? same.first?.value : nil
    }

    static func project(_ adc: JSON, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        adc["quota_project_id"].string ?? ["GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT", "CLOUDSDK_CORE_PROJECT"]
            .lazy.compactMap { env[$0] }.first { !$0.isEmpty }
    }

    /// Stable offline identity: the account email when the file has one, else a short hash of the refresh token.
    static func identity(_ adc: JSON?) -> CredentialIdentity? {
        guard let adc else { return nil }
        let email = Fmt.jwtClaims(adc["id_token"].string ?? "")?["email"].string ?? adc["account"].string
        if let email { return CredentialIdentity(key: email.lowercased(), email: email) }
        guard let refresh = adc["refresh_token"].string else { return nil }
        let digest = SHA256.hash(data: Data(refresh.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return CredentialIdentity(key: "adc-\(digest)")
    }

    /// One Cloud Monitoring query, all pages (capped).
    static func series(token: String, project: String, metric: String) async throws -> [JSON] {
        let filter = "metric.type=\"serviceruntime.googleapis.com/quota/\(metric == "usage" ? "allocation/usage" : "limit")\" "
            + "AND resource.type=\"consumer_quota\" AND resource.label.service=\"aiplatform.googleapis.com\""
        let end = Date(), formatter = ISO8601DateFormatter()
        var all: [JSON] = []
        var page: String?
        for _ in 0..<20 {
            var components = URLComponents(string: "https://monitoring.googleapis.com/v3/projects/\(project)/timeSeries")
            components?.queryItems = [
                .init(name: "filter", value: filter),
                .init(name: "interval.startTime", value: formatter.string(from: end.addingTimeInterval(-86_400))),
                .init(name: "interval.endTime", value: formatter.string(from: end)),
                .init(name: "aggregation.alignmentPeriod", value: "3600s"),
                .init(name: "aggregation.perSeriesAligner", value: "ALIGN_MAX"),
                .init(name: "view", value: "FULL"),
            ] + (page.map { [.init(name: "pageToken", value: $0)] } ?? [])
            guard let url = components?.url?.absoluteString else { throw ProviderError.parse("Invalid project id.") }
            let response = try await HTTP.send(url, headers: HTTP.bearer(token))
            if response.status == 403 {
                throw ProviderError.unauthorized("Grant this account Cloud Monitoring viewer access on project \(project).")
            }
            try HTTP.check(response)
            let json = try response.json()
            all += json["timeSeries"].array
            guard let next = json["nextPageToken"].string, next != page else { break }
            page = next
        }
        return all
    }
}
