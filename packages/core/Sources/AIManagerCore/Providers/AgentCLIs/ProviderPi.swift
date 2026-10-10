import Foundation

extension ProviderCatalog {
    /// Local read-only history: Pi has no account or quota, only session logs.
    static let agentPi = ProviderSpec(
        id: "pi", name: "Pi",
        usage: { _ in try PiUsage.scan(now: Date()) })
}

enum PiUsage {
    struct Entry: Equatable {
        var id: String?
        var date: Date
        var model: String?
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0
        var cost = 0.0
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    /// Assistant lines of one session log. Lines without a usage block are skipped without parsing.
    static func entries(in data: Data) -> [Entry] {
        let marker = Data(#""usage":{"#.utf8)
        var result: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
            let object = JSON((try? JSONSerialization.jsonObject(with: Data(line))))
            let message = object["message"]
            guard object["type"].string == "message", message["role"].string == "assistant",
                  let stamp = object["timestamp"].string, let date = fractional.date(from: stamp) ?? plain.date(from: stamp)
            else { continue }
            let usage = message["usage"]
            var entry = Entry(id: object["id"].string, date: date, model: message["model"].string ?? object["model"].string)
            entry.input = usage["input"].int ?? 0
            entry.output = usage["output"].int ?? 0
            entry.cacheRead = usage["cacheRead"].int ?? 0
            entry.cacheWrite = usage["cacheWrite"].int ?? 0
            entry.total = usage["totalTokens"].int ?? entry.input + entry.output + entry.cacheRead + entry.cacheWrite
            entry.cost = usage.at("cost.total").double ?? 0
            result.append(entry)
        }
        return result
    }

    /// Today and the last 30 days, in the local time zone. Tokens and Pi's own recorded cost only.
    static func map(_ entries: [Entry], now: Date, calendar: Calendar = .current) -> ProviderUsage {
        var seen = Set<String>()
        let unique = entries.filter { $0.id.map { seen.insert($0).inserted } ?? true }
        let today = calendar.startOfDay(for: now)
        let month = now.addingTimeInterval(-30 * 86400)
        func section(_ title: String, _ items: [Entry]) -> UsageSection {
            let sum = { (value: KeyPath<Entry, Int>) in items.reduce(0) { $0 + $1[keyPath: value] } }
            var rows = [UsageRow("Messages", Fmt.number(Double(items.count))),
                        UsageRow("Tokens", Fmt.number(Double(sum(\.total)))),
                        UsageRow("Input", Fmt.number(Double(sum(\.input)))),
                        UsageRow("Output", Fmt.number(Double(sum(\.output)))),
                        UsageRow("Cache", Fmt.number(Double(sum(\.cacheRead) + sum(\.cacheWrite))))]
            let cost = items.reduce(0) { $0 + $1.cost }
            if cost > 0 { rows.append(UsageRow("Recorded cost", Fmt.money(cost))) }
            // Per-model split, heaviest first. Only the model Pi recorded on the message is used.
            let byModel = Dictionary(grouping: items.filter { $0.model != nil }, by: { $0.model! })
                .sorted { $0.value.reduce(0) { $0 + $1.total } > $1.value.reduce(0) { $0 + $1.total } }
            for (model, group) in byModel.prefix(5) {
                let spent = group.reduce(0) { $0 + $1.cost }
                rows.append(UsageRow("Model \(model)", "\(Fmt.number(Double(group.reduce(0) { $0 + $1.total }))) tokens · "
                    + "\(group.count) \(group.count == 1 ? "message" : "messages")" + (spent > 0 ? " · \(Fmt.money(spent))" : "")))
            }
            return UsageSection(title, rows)
        }
        return ProviderUsage(sections: [section("Today", unique.filter { $0.date >= today && $0.date <= now }),
                                        section("Last 30 days", unique.filter { $0.date >= month && $0.date <= now })])
    }

    static func sessionsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        func path(_ name: String) -> String? { environment[name].flatMap { $0.isEmpty ? nil : $0 } }
        if let sessions = path("PI_CODING_AGENT_SESSION_DIR") { return URL(fileURLWithPath: sessions) }
        if let agent = path("PI_CODING_AGENT_DIR") { return URL(fileURLWithPath: agent).appending(path: "sessions") }
        return home.appending(path: ".pi/agent/sessions")
    }

    /// Session roots of Pi and its OMP fork: the Pi root, then the OMP default or named-profile roots.
    /// A relative PI_CONFIG_DIR is read from the home folder, as OMP does.
    static func sessionDirectories(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        func path(_ name: String) -> String? { environment[name].flatMap { $0.isEmpty ? nil : $0 } }
        let config = home.appending(path: path("PI_CONFIG_DIR").flatMap { $0.hasPrefix("/") ? nil : $0 } ?? ".omp")
        let share = path("XDG_DATA_HOME").map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".local/share")
        let profile = (path("OMP_PROFILE") ?? path("PI_PROFILE")).flatMap {
            $0 != "default" && $0.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil ? $0 : nil
        }
        var roots = [sessionsDirectory(environment: environment, home: home)]
        if let profile {
            for base in [config, share.appending(path: "omp")] {
                let named = base.appending(path: "profiles/\(profile)")
                roots += [named.appending(path: "sessions"), named.appending(path: "agent/sessions")]
            }
        } else {
            roots += [config.appending(path: "agent/sessions"), share.appending(path: "omp/sessions")]
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Reads only logs changed in the last 31 days.
    static func scan(now: Date, directory: URL) throws -> ProviderUsage {
        try scan(now: now, directories: [directory])
    }

    static func scan(now: Date, directories: [URL] = sessionDirectories()) throws -> ProviderUsage {
        let existing = directories.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { throw ProviderError.unavailable("Pi has no session history on this Mac.") }
        let cutoff = now.addingTimeInterval(-31 * 86400)
        var entries: [Entry] = []
        for directory in existing {
            guard let walker = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true, (values?.contentModificationDate ?? .distantPast) >= cutoff,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                entries += self.entries(in: data)
            }
        }
        return map(entries, now: now)
    }
}
