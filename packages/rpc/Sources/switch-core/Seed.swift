import Foundation
import AIManagerCore

/// `switch-core seed-synthetic --root <empty folder>`: a test tool. It fills an empty root with made-up Overview
/// data through the core's own writers: 12 Codex usage accounts with 90 days of ledger rows, and 90 days of Codex
/// transcripts (4 projects, 3 models, about 6 threads a day) that the conversation index turns into model,
/// project, and session rows. No real account, credential, or home is read or written.
enum Seed {
    static let accounts = 12
    static let days = 90

    static func run(paths: ManagerPaths, root: URL) async -> Int32 {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        guard paths.isolationRoot != nil, entries.isEmpty,
              root.standardizedFileURL.path != fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path else {
            FileHandle.standardError.write(Data("seed-synthetic: the root must be an empty folder that is not a home.\n".utf8))
            return 2
        }
        do {
            let support = paths.applicationSupport
            let ledger = try CodexUsageStatisticsCache(
                databaseURL: support.appending(path: "cache/account-usage.sqlite"),
                activityDatabaseURL: support.appending(path: "activity/daily.sqlite"))
            let now = Date()
            let today = Int((now.timeIntervalSince1970 / 86_400).rounded(.down))
            let ids = (1...accounts).map { UUID(uuidString: String(format: "5EED0000-0000-4000-8000-%012d", $0))! }
            try await ledger.retainUsageAccounts(ids.map { HistoricalUsageAccount(id: $0, providerID: .codex) })
            for (index, id) in ids.enumerated() {
                // Each account works a different share of days, with a weekly rhythm.
                let daily = (0..<days).compactMap { offset -> CodexDailyUsageSnapshot? in
                    let day = today - offset
                    guard (day + index) % (index % 4 + 2) != 0 else { return nil }
                    let tokens = Int64(40_000 + (index + 1) * 9_000 + (day % 7) * 15_000 + (offset * 7_919 % 50_000))
                    return CodexDailyUsageSnapshot(startDate: dayName(day), tokens: tokens)
                }
                try await ledger.upsertSuccess(accountID: id, snapshot: .init(
                    account: nil, requiresOpenAIAuthentication: nil, rateLimits: nil, usage: nil,
                    dailyUsage: daily, fetchedAt: now))
            }
            try writeTranscripts(home: paths.sharedRoot, today: today)
            let index = ChatHistoryIndex(home: paths.sharedRoot,
                                         cacheFile: support.appending(path: "cache/chat-history-v1.json"))
            await index.attachActivityCache(ledger)
            let threads = try await index.refresh().totalThreadCount
            print("seeded \(accounts) accounts, \(days) days, \(threads) threads in \(root.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("seed-synthetic: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// A UTC day number as `2026-11-14`.
    private static func dayName(_ day: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(day) * 86_400))
    }

    private static func writeTranscripts(home: URL, today: Int) throws {
        let projects = ["alpha", "beta", "gamma", "delta"]
        let models = ["gpt-5.1-codex", "gpt-5-mini", "gpt-5.1-codex-max"]
        let iso = ISO8601DateFormatter()
        for offset in 0..<days {
            let day = today - offset
            let start = Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
            for thread in 0..<(3 + (day % 4)) {
                let id = String(format: "5eed%04d-%04d-4000-8000-000000000000", offset, thread)
                let project = projects[(day + thread) % projects.count]
                let model = models[(day * 3 + thread) % models.count]
                var lines: [[String: Any]] = [
                    ["type": "session_meta", "payload": ["id": id, "cwd": "/Projects/\(project)"]],
                    ["type": "turn_context", "payload": ["model": model, "cwd": "/Projects/\(project)"]],
                    ["type": "response_item", "payload": ["type": "message", "role": "user",
                                                          "content": [["type": "input_text", "text": "Fix the \(project) build, step \(thread + 1)."]]]],
                    ["type": "response_item", "payload": ["type": "message", "role": "assistant",
                                                          "content": [["type": "output_text", "text": "## Done\n\n- Updated the \(project) build\n- Ran the tests"]]]],
                ]
                var total: Int64 = 0
                for turn in 0..<4 {
                    let input = Int64(6_000 + (offset * 131 + thread * 977 + turn * 313) % 20_000)
                    total += input + input / 6
                    let time = start.addingTimeInterval(TimeInterval(3_600 * (8 + thread) + 600 * turn))
                    lines.append(["timestamp": iso.string(from: time), "type": "event_msg", "payload": [
                        "type": "token_count", "info": ["total_token_usage": [
                            "input_tokens": total * 6 / 7, "cached_input_tokens": total / 2,
                            "output_tokens": total / 7, "total_tokens": total]]]])
                }
                let url = home.appending(path: "sessions/\(dayName(day))/rollout-\(id).jsonl")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try lines.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                try Data(data.joined(separator: Data([0x0A]))).write(to: url)
            }
        }
    }
}
