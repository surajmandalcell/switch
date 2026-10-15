import Foundation
import XCTest
@testable import AIManagerCore

final class DroidUsageTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_773_144_000) // 2026-03-10T12:00:00Z
    private let account = "dddddddd-0000-0000-0000-000000000001"
    private let rates = ["claude-sonnet-4-5": ModelRate(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)]

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(
            path: "DroidUsageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    private func write(_ name: String, folder: String = "-Projects-web", model: String? = "claude-sonnet-4-5",
                       tokens: [Int], inclusive: Int = 0, age: TimeInterval = 86_400, cwd: String? = nil) throws {
        let dir = root.appending(path: folder, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        func usage(_ extra: Int) -> [String: Any] {
            ["inputTokens": tokens[0] + extra, "outputTokens": tokens[1] + extra, "cacheReadTokens": tokens[2] + extra,
             "cacheCreationTokens": tokens[3] + extra, "thinkingTokens": 5]
        }
        var object: [String: Any] = ["tokenUsage": usage(0), "inclusiveTokenUsage": usage(inclusive)]
        if let model { object["model"] = model }
        let file = dir.appending(path: "\(name).settings.json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        if let cwd {
            let line = try JSONSerialization.data(withJSONObject: ["type": "session_start", "cwd": cwd])
            try (line + Data("\n{\"type\":\"message\"}\n".utf8)).write(to: dir.appending(path: "\(name).jsonl"))
        }
    }

    func testReaderSumsOwnTokensPerDayAndSkipsBadAndOldFiles() async throws {
        try write("parent", tokens: [100, 50, 1_000, 10], inclusive: 999, cwd: "/Projects/web")
        try write("child", tokens: [20, 10, 0, 0], inclusive: 999)  // a child session has its own file
        try write("older", tokens: [1, 1, 1, 1], age: 3 * 86_400)
        try write("unknown-model", model: "mystery", tokens: [7, 3, 0, 0])
        try Data("not json".utf8).write(to: root.appending(path: "-Projects-web/bad.settings.json"))
        try Data("{}".utf8).write(to: root.appending(path: "-Projects-web/empty.settings.json"))
        try Data("{}".utf8).write(to: root.appending(path: "-Projects-web/parent.settings.json.bak"))

        let from = now.addingTimeInterval(-2 * 86_400)
        let found = DroidUsage.sessions(in: root, from: from).sorted { $0.id < $1.id }
        XCTAssertEqual(found.map(\.id), ["child", "parent", "unknown-model"])
        let parent = try XCTUnwrap(found.first { $0.id == "parent" })
        XCTAssertEqual(parent.tokens, 1_160, "tokenUsage only; thinking and inclusive totals are not added")
        XCTAssertEqual(parent.project, "/Projects/web")
        XCTAssertEqual(found.first { $0.id == "child" }?.project, "/Projects/web", "no .jsonl: the folder name stands in")
        XCTAssertEqual(found.first { $0.id == "child" }?.tokens, 30)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let daily = DroidUsage.daily(found, rates: rates, calendar: utc)
        XCTAssertEqual(daily.map(\.date), ["2026-03-09"])
        XCTAssertEqual(daily[0].inputTokens, 127)
        XCTAssertEqual(daily[0].cacheReadTokens, 1_000)
        XCTAssertEqual(daily[0].unpricedModels, ["mystery"])
        let priced = (Double(120) * 3 + 60 * 15 + 1_000 * 0.3 + 10 * 3.75) / 1e6
        XCTAssertEqual(try XCTUnwrap(daily[0].costUSD), priced, accuracy: 1e-9)

        let history = UsageHistory(sources: .init(
            droidSessions: root, accounts: ["droid": [account]], pricing: { [rates] in rates }))
        let snap = await history.snapshot(now: now)
        let byAccount = snap.summary(period: .week, grouping: .account)
        XCTAssertEqual(byAccount.groups.map(\.key), [account])
        XCTAssertEqual(byAccount.groups.first?.tokens, 1_204, "the 3-day-old file is in the week too")
        XCTAssertEqual(snap.summary(period: .week, grouping: .model).groups.map(\.key).sorted(), ["claude-sonnet-4-5", "mystery"])
        let sessions = await history.daySessions(day: "2026-03-09")
        XCTAssertEqual(sessions.count, 3)
        XCTAssertTrue(sessions.allSatisfy { $0.service == "droid" && $0.accountID == account })
        XCTAssertEqual(sessions.first?.id, "droid:parent")
        XCTAssertNil(sessions.first { $0.id == "droid:unknown-model" }?.costUSD)
    }

    func testUnattributedPointsGoToTheOnlyAccountElseASharedGroupNeverDropped() async throws {
        try write("one", tokens: [100, 0, 0, 0])
        for (accounts, key) in [([account], account), ([account, "other"], "shared:droid"), ([], "shared:droid")] {
            let history = UsageHistory(sources: .init(droidSessions: root, accounts: ["droid": accounts]))
            let groups = await history.snapshot(now: now).summary(period: .week, grouping: .account).groups
            XCTAssertEqual(groups.map(\.key), [key], "accounts: \(accounts.count)")
            XCTAssertEqual(groups.first?.tokens, 100)
        }
        XCTAssertEqual(UsageHistory.owner(service: "claude-code", accountID: nil, accounts: ["claude-code": ["a"]]), "a")
        XCTAssertEqual(UsageHistory.owner(service: "claude-code", accountID: nil, accounts: ["claude-code": ["a", "b"]]),
                       "shared:claude-code")
        XCTAssertEqual(UsageHistory.owner(service: "claude-code", accountID: "b", accounts: ["claude-code": ["a"]]), "b")
        XCTAssertNil(UsageHistory.owner(service: "codex", accountID: nil, accounts: ["codex": ["a", "b"]]),
                     "Codex transcripts stay covered by the ledger's account totals")
        XCTAssertEqual(UsageHistory.sharedService("shared:grok-build"), "grok-build")
    }
}
