import Foundation

extension ProviderCatalog {
    static let qwencloudTeam = ProviderSpec(
        id: "qwencloud-team", name: "Qwen Cloud Team",
        fields: [.cookie("Cookie header from home.qwencloud.com")],
        dashboard: "https://home.qwencloud.com/analytics/token-plan/team",
        usage: { credential in
            let base = "https://home.qwencloud.com"
            let headers = ["Cookie": try credential.require("cookie"), "Referer": "\(base)/analytics/token-plan/team"]
            let info = try await QwenCloudTeamUsage.envelope(HTTP.send("\(base)/tool/user/info.json", headers: headers))
            guard let token = info["data"]["secToken"].string else {
                throw ProviderError.unauthorized("Qwen Cloud Team login required.")
            }
            func rpc(_ product: String, _ action: String, _ params: [String: String], region: String) async throws -> JSON {
                var form = ["product": product, "action": action, "sec_token": token, "region": region,
                            "params": String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)]
                if action == "GetSeatSubscriptionSummary" { form["language"] = "zh-CN" }
                let response = try await HTTP.send(
                    "\(base)/data/api.json?product=\(product)&action=\(action)", method: "POST",
                    headers: headers.merging(["Origin": base, "Content-Type": "application/x-www-form-urlencoded"]) { $1 },
                    body: HTTP.form(form))
                return try QwenCloudTeamUsage.result(QwenCloudTeamUsage.envelope(response), action: action)
            }
            // The console discovers a billing selector (Nbid); it is not the login UID.
            let human = try await rpc("ea-service", "LoadHumanInfo", [:], region: "ap-southeast-1")
            var params = ["productCode": QwenCloudTeamUsage.productCode]
            if let nbid = human.at("Data.SellerInfoDto.Nbid").string { params["Nbid"] = nbid }
            let summary = try await rpc("BssOpenAPI-V3", "GetSeatSubscriptionSummary", params, region: "cn-hangzhou")
            return try QwenCloudTeamUsage.map(summary)
        })
}

enum QwenCloudTeamUsage {
    static let productCode = "sfm_tokenplanteams_dp_intl"

    static func envelope(_ response: HTTPResponse) throws -> JSON {
        try HTTP.check(response)
        let root = try response.json()
        if let code = root["code"].string, ["ConsoleNeedLogin", "BailianGateway.Login.NotLogined", "NO_LOGIN"].contains(code) {
            throw ProviderError.unauthorized("Qwen Cloud Team login required.")
        }
        return root
    }

    /// The gateway wraps each RPC result in `data`.
    static func result(_ root: JSON, action: String) throws -> JSON {
        let data = root["data"]
        if root["successResponse"].bool == false || data["Success"].bool == false {
            throw ProviderError.unavailable("Qwen Cloud Team \(action) failed.")
        }
        guard root["successResponse"].bool == true || root["code"].string == "200", data.exists else {
            throw ProviderError.parse("Unsupported Qwen Cloud Team gateway envelope. Check the usage dashboard.")
        }
        return data
    }

    /// `summary` is the `GetSeatSubscriptionSummary` result. No active plan gives an empty usage.
    static func map(_ summary: JSON, now: Date = Date()) throws -> ProviderUsage {
        func fail(_ field: String) -> ProviderError {
            .parse("Unsupported Qwen Cloud Team \(field). Check the usage dashboard.")
        }
        let data = summary["Data"]
        guard data.exists else { return ProviderUsage() }
        let groups = data["SubscriptionGroupList"].array
        guard data["SubscriptionGroupList"].raw is [Any] else { throw fail("subscription groups") }
        guard !groups.isEmpty else { return ProviderUsage() }
        guard let start = data["StartTime"].double, let end = data["EndTime"].double, start > 0, end > start else {
            throw fail("subscription period")
        }
        let nowMs = now.timeIntervalSince1970 * 1000
        guard nowMs >= start, nowMs < end else { return ProviderUsage() }
        guard data["ProductCode"].string == productCode else { throw fail("subscription product") }
        guard groups.count == 1 else { throw fail("multiple credit pools") }
        let group = groups[0]
        let equities = group["EquityList"].array.filter { $0["EquityCode"].string == "credit_value" }
        guard equities.count == 1, let total = equities[0]["TotalValue"].double,
              let remaining = equities[0]["SurplusValue"].double, total > 0, remaining >= 0, remaining <= total else {
            throw fail("credit count")
        }
        let used = total - remaining
        let reset = group["NextCycleFlushTime"].double.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        var rows = [UsageRow("Credits", "\(Fmt.number(used)) / \(Fmt.number(total)) credits used"),
                    UsageRow("Remaining", "\(Fmt.number(remaining)) credits")]
        if let assigned = group["SubscriptionAssignedNumber"].int, let seats = group["SubscriptionTotalNumber"].int,
           assigned >= 0, seats >= assigned {
            rows.append(UsageRow("Seats", "\(assigned) / \(seats)"))
        }
        let spec = group["SpecType"].string.flatMap {
            $0.range(of: "^[a-z][a-z0-9_-]{0,39}$", options: .regularExpression) != nil ? "\($0.capitalized) Team" : nil
        }
        return ProviderUsage(
            windows: [UsageWindow(id: "credits", title: "Team credits", usedPercent: used / total * 100,
                                  resetsAt: reset, detail: "\(Fmt.number(used)) / \(Fmt.number(total)) credits")],
            sections: [UsageSection("Team Token Plan", rows)], plan: spec ?? "Team Token Plan")
    }
}
