import Foundation

extension ProviderCatalog {
    static let bifrost = ProviderSpec(
        id: "bifrost", name: "Bifrost",
        fields: [.init("apiKey", "Virtual key", env: ["BIFROST_API_KEY"]),
                 .init("baseURL", "Base URL", secure: false, placeholder: "https://bifrost.example.com",
                       env: ["BIFROST_BASE_URL"])],
        usage: { credential in
            let key = try credential.require("apiKey")
            var base = try credential.require("baseURL", "Add the Bifrost base URL for this account.")
            var suffix = ""
            if let cut = base.firstIndex(where: { "?#".contains($0) }) {
                suffix = String(base[cut...])
                base = String(base[..<cut])
            }
            while base.hasSuffix("/") { base.removeLast() }
            let json = try await HTTP.json("\(base)/api/governance/virtual-keys/quota\(suffix)", headers: ["x-bf-vk": key])
            return try BifrostUsage.map(json)
        })
}

enum BifrostUsage {
    private static let labels = ["1h": "Hourly", "1d": "Daily", "1w": "Weekly", "1M": "Monthly", "1Q": "Quarterly",
                                 "1Y": "Yearly"]
    private static let units: [String: Double] = ["Y": 31_536_000, "Q": 7_776_000, "M": 2_592_000, "w": 604_800,
                                                  "d": 86_400, "h": 3600, "m": 60, "s": 1, "ms": 0.001,
                                                  "us": 1e-6, "µs": 1e-6, "μs": 1e-6, "ns": 1e-9]

    /// Seconds in "1d", "1M" style or Go-style "1h30m" durations.
    private static func duration(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        let number = #"(?:\d+(?:\.\d*)?|\.\d+)"#
        var seconds = 0.0
        if raw.range(of: #"^\d+(?:\.\d+)?[dwMQY]$"#, options: .regularExpression) != nil {
            seconds = (Double(raw.dropLast()) ?? 0) * (units[String(raw.last!)] ?? 0)
        } else if raw.range(of: "^(?:\(number)(?:ns|us|µs|μs|ms|s|m|h))+$", options: .regularExpression) != nil {
            var rest = Substring(raw)
            while let range = rest.range(of: "^\(number)(?:ns|us|µs|μs|ms|s|m|h)", options: .regularExpression) {
                let part = rest[range]
                let unitStart = part.firstIndex { !$0.isNumber && $0 != "." }!
                seconds += (Double(part[..<unitStart]) ?? 0) * (units[String(part[unitStart...])] ?? 0)
                rest = rest[range.upperBound...]
            }
        } else { return nil }
        return seconds > 0 ? seconds : nil
    }

    private struct Timing {
        var label: String?, windowMinutes: Int?, resetsAt: Date?, seconds: Double?
    }

    private static func timing(_ reset: String?, last: String?, now: Date) -> Timing {
        let seconds = duration(reset)
        // Calendar-aligned resets (d, w, M, Q, Y) are not derivable from the quota response.
        let fixed = reset != nil && reset!.range(of: "[dwMQY]$", options: .regularExpression) == nil
        var resetsAt: Date?
        if fixed, let seconds, let start = last.flatMap(Fmt.iso)?.timeIntervalSince1970 {
            let elapsed = max(0, (now.timeIntervalSince1970 - start) / seconds).rounded(.down)
            resetsAt = Date(timeIntervalSince1970: start + (elapsed + 1) * seconds)
        }
        let minutes = seconds.map { Int($0 / 60) } ?? 0
        return Timing(label: reset.flatMap { labels[$0] }, windowMinutes: fixed && minutes > 0 ? minutes : nil,
                      resetsAt: resetsAt, seconds: seconds)
    }

    /// Drops the region and vendor prefixes, the "-v1:0" suffix, and a trailing date from a model id.
    private static func modelName(_ raw: String) -> String {
        var name = raw
        for pattern in [#"^(us-gov|us|eu|apac|global)\."#,
                        #"^(ai21|amazon|anthropic|cohere|deepseek|luma|meta|mistral|openai|qwen|stability|twelvelabs|writer)\."#,
                        #"-v\d+:\d+$"#, #"(?:-|\s)(?:\d{8}|\d{4}-\d{2}-\d{2})$"#, #"[ \t-]+$"#] {
            name = name.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return name.isEmpty ? raw : name
    }

    /// 1,200 -> "1.2K", 2,500,000 -> "2.5M".
    private static func tokenCount(_ value: Int) -> String {
        let magnitude = Double(abs(value)), sign = value < 0 ? "-" : ""
        for (threshold, divisor, unit) in [(999_500_000.0, 1e9, "B"), (999_500.0, 1e6, "M"), (1000.0, 1000.0, "K")]
        where magnitude >= threshold {
            let scaled = magnitude / divisor
            var text = String(format: scaled >= 10 ? "%.0f" : "%.1f", scaled)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return sign + text + unit
        }
        return String(value)
    }

    private struct Scope { var id: String, title: String?, body: JSON }
    private struct Budget {
        var id: String, scope: Scope, source: String?, limit: Double, used: Double, timing: Timing, models: [JSON]
    }

    static func map(_ root: JSON, now: Date = Date()) throws -> ProviderUsage {
        guard root.raw is [String: Any] else { throw ProviderError.parse("Bifrost: expected an object.") }
        var scopes = [Scope(id: "", title: nil, body: root)]
        for (index, body) in root["provider_configs"].array.enumerated() {
            scopes.append(Scope(id: "provider-\(index)-", title: "Provider \(body["provider"].string ?? String(index + 1))", body: body))
        }
        for (index, body) in root["model_configs"].array.enumerated() {
            let name = [body["provider"].string, body["model_name"].string ?? String(index + 1)].compactMap { $0 }
            scopes.append(Scope(id: "model-\(index)-", title: "Model \(name.joined(separator: " · "))", body: body))
        }
        let budgets: [Budget] = scopes.flatMap { scope in
            scope.body["budgets"].array.compactMap { raw -> Budget? in
                guard let id = raw["id"].string else { return nil }
                let override = raw["override_amount"].double ?? 0
                let mode = raw["override_mode"].string
                let active = override > 0 && (mode == "forever" || (mode == "cycles" && (raw["override_cycles_remaining"].int ?? 0) > 0))
                return Budget(id: id, scope: scope, source: raw["source_name"].string,
                              limit: (raw["max_limit"].double ?? 0) + (active ? override : 0),
                              used: raw["current_usage"].double ?? 0,
                              timing: timing(raw["reset_duration"].string, last: raw["last_reset"].string, now: now),
                              models: raw["per_model_usage"].array)
            }
        }.sorted { ($0.timing.seconds ?? .infinity, $0.id) < ($1.timing.seconds ?? .infinity, $1.id) }

        struct Limit { var scope: Scope, json: JSON, index: Int }
        let limits: [Limit] = scopes.flatMap { scope -> [Limit] in
            let components = scope.body["rate_limits"].array
            // rate_limit is a compatibility merge of the components, not another pool.
            let picked = components.isEmpty ? (scope.body["rate_limit"].exists ? [scope.body["rate_limit"]] : []) : components
            return picked.enumerated().map { Limit(scope: scope, json: $1, index: $0) }
        }
        if root["is_active"].bool == false, budgets.isEmpty, limits.isEmpty {
            throw ProviderError.unauthorized("Bifrost virtual key is inactive and has no budgets or rate limits to display.")
        }

        func title(_ scope: Scope, _ part: String?) -> String {
            String([scope.title, part].compactMap { $0 }.joined(separator: " · ").prefix(120))
        }
        func detail(_ budget: Budget) -> String {
            [budget.source.map { String($0.prefix(24)) }, budget.timing.label,
             "\(Fmt.money(budget.used)) / \(Fmt.money(budget.limit))"].compactMap { $0 }.joined(separator: " · ")
        }
        let budgetWindows = budgets.filter { $0.limit > 0 }.map { budget in
            UsageWindow(id: "bifrost-\(budget.scope.id)budget-\(budget.id)",
                        title: title(budget.scope, budget.source ?? "Budget"),
                        usedPercent: budget.used / budget.limit * 100, resetsAt: budget.timing.resetsAt,
                        windowMinutes: budget.timing.windowMinutes, detail: detail(budget))
        }
        // Key-level budgets lead; provider and model scoped budgets follow the rate limits.
        let rootBudgets = budgetWindows.filter { !$0.id.hasPrefix("bifrost-provider") && !$0.id.hasPrefix("bifrost-model") }
        var windows = rootBudgets
        windows += budgetWindows.filter { !rootBudgets.contains($0) }
        for limit in limits {
            let source = limit.json["source_name"].string
            for (key, name) in [("token", "Tokens"), ("request", "Requests")] {
                let max = limit.json["\(key)_max_limit"].double
                let reset = limit.json["\(key)_reset_duration"].string
                let known = (max ?? 0) > 0
                if !known && reset == nil { continue }
                let time = timing(reset, last: limit.json["\(key)_last_reset"].string, now: now)
                let used = limit.json["\(key)_current_usage"].double ?? 0
                windows.append(UsageWindow(
                    id: "bifrost-\(limit.scope.id)\(key)s-\(limit.index)",
                    title: String([limit.scope.title, source, name].compactMap { $0 }.joined(separator: " ").prefix(120)),
                    usedPercent: known ? used / max! * 100 : nil, resetsAt: time.resetsAt,
                    windowMinutes: time.windowMinutes, detail: time.label))
            }
        }
        if root["is_active"].bool == false {
            // The plugin puts this first among the extra windows, after the two lead budget windows.
            windows.insert(UsageWindow(id: "bifrost-key-inactive", title: "Key inactive", usedPercent: nil),
                           at: min(2, rootBudgets.count))
        }

        var sections: [UsageSection] = []
        let first = budgets.first { $0.scope.id.isEmpty }
        let models = (first?.models ?? []).map {
            (raw: $0["model"].string ?? "Model", provider: $0["provider"].string, cost: $0["total_cost"].double,
             tokens: $0["total_tokens"].double.map { Int($0) })
        }.filter { ($0.cost ?? 0) != 0 || ($0.tokens ?? 0) != 0 }
            .sorted {
                if ($0.cost ?? 0) != ($1.cost ?? 0) { return ($0.cost ?? 0) > ($1.cost ?? 0) }
                if ($0.tokens ?? 0) != ($1.tokens ?? 0) { return ($0.tokens ?? 0) > ($1.tokens ?? 0) }
                return $0.raw < $1.raw
            }
        if !models.isEmpty {
            let visible = Array(models.prefix(5))
            let names = visible.map { modelName($0.raw) }
            let mixed = Set(visible.compactMap(\.provider)).count > 1
            var rows = visible.enumerated().map { index, model -> UsageRow in
                let duplicate = names.filter { $0 == names[index] }.count > 1
                let label = [mixed ? model.provider : nil, duplicate ? model.raw : names[index]]
                    .compactMap { $0 }.joined(separator: " · ")
                return PluginFmt.row(String(label.prefix(120)), model.cost.map { Fmt.money($0) } ?? "—",
                                     model.tokens.map { "\(tokenCount($0)) tokens" })
            }
            if models.count > 5 { rows.append(.init("Other models", String(models.count - 5))) }
            sections.append(.init("Models", rows))
        }
        if budgets.count > 1 || budgets.contains(where: { !$0.scope.id.isEmpty }) {
            sections.append(.init("Budgets", budgets.prefix(24).map { budget in
                PluginFmt.row(title(budget.scope, budget.source ?? "Budget \(budget.id)"),
                              budget.limit > 0 ? "\(Fmt.money(budget.used)) / \(Fmt.money(budget.limit))" : Fmt.money(budget.used),
                              budget.timing.label,
                              progress: budget.limit > 0 ? budget.used / budget.limit : nil)
            }))
        }
        let cost = first.map {
            UsageCost(used: $0.used, limit: max(0, $0.limit), period: $0.timing.label ?? ($0.limit > 0 ? "Budget" : "Spend"),
                      resetsAt: $0.timing.resetsAt)
        }
        return ProviderUsage(windows: windows, cost: cost, sections: sections, email: root["virtual_key_name"].string,
                             organization: first?.source)
    }
}
