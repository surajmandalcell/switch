import XCTest
@testable import AIManagerCore

/// CodexBar ports: Amp enterprise workspaces, OpenCode Go spend budget, Pi projects and sessions,
/// agy inside Gemini.app, and the OpenAI organisation on the legacy balance request.
final class UpstreamSmallPortsTests: XCTestCase {
    func testAmpEnterprisePaidWorkspaceHasNoMeter() throws {
        let usage = try AmpUsage.map(displayText: "Signed in as dev@example.com\nWorkspace Acme: usage paid by your enterprise\n",
                                     now: Date())
        XCTAssertEqual(usage.plan, "Enterprise")
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertNil(usage.cost)
        XCTAssertEqual(usage.sections.first?.rows.first?.label, "Workspace Acme")
        XCTAssertEqual(usage.sections.first?.rows.first?.value, "Enterprise")
    }

    func testOpenCodeGoSpendKeepsPreviousWhileScanIsPending() async throws {
        let scans = OpenCodeGoUsage.SpendScans()
        let old = MajorsSpend.Report(section: UsageSection("Spend", [UsageRow("Today", "$1.00")]), chart: nil)
        let new = MajorsSpend.Report(section: UsageSection("Spend", [UsageRow("Today", "$2.00")]), chart: nil)
        let first = await scans.spend(account: "a", budget: .seconds(5)) { old }
        XCTAssertEqual(first?.section?.rows.first?.value, "$1.00")
        let start = ContinuousClock.now
        let pending = await scans.spend(account: "a", budget: .milliseconds(200)) { Thread.sleep(forTimeInterval: 1); return new }
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(900), "quota must not wait for the scan")
        XCTAssertEqual(pending?.section?.rows.first?.value, "$1.00", "previous spend of the same account")
        let other = await scans.spend(account: "b", budget: .milliseconds(100)) { Thread.sleep(forTimeInterval: 1); return new }
        XCTAssertNil(other, "another account never sees account a's spend")
        let done = await scans.spend(account: "a", budget: .seconds(5)) { new }
        XCTAssertEqual(done?.section?.rows.first?.value, "$2.00")
    }

    func testPiProjectsAndSessionsAddUpAndCopiedSessionCountsOnce() throws {
        func line(_ id: String, cost: Double) -> String {
            #"{"type":"message","id":"\#(id)","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","usage":{"input":10,"output":5,"totalTokens":15,"cost":{"total":\#(cost)}}}}"#
        }
        let folder = URL(fileURLWithPath: "/x/sessions/--Users-me-alpha--")
        let original = [#"{"type":"session","id":"sess-one-1234","cwd":"/Users/me/alpha"}"#, line("m1", cost: 1), line("m2", cost: 2)]
        let copy = [#"{"type":"session","id":"sess-two-5678","cwd":"/Users/me/alpha"}"#, line("m1", cost: 1), line("m2", cost: 2),
                    line("m3", cost: 4)]
        let other = [line("m4", cost: 8)]
        let entries = PiUsage.entries(in: Data(original.joined(separator: "\n").utf8), file: folder.appending(path: "a.jsonl"))
            + PiUsage.entries(in: Data(copy.joined(separator: "\n").utf8), file: folder.appending(path: "b.jsonl"))
            + PiUsage.entries(in: Data(other.joined(separator: "\n").utf8),
                              file: URL(fileURLWithPath: "/x/sessions/--Users-me-beta--/c.jsonl"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let usage = PiUsage.map(entries, now: Fmt.iso("2026-07-12T12:00:00Z")!, calendar: calendar)
        let total = usage.sections[1].rows.first { $0.label == "Recorded cost" }?.value
        XCTAssertEqual(total, "$15.00")
        let projects = usage.sections.first { $0.title == "Projects, last 30 days" }!.rows
        XCTAssertEqual(projects.map(\.label), ["Users-me-beta", "alpha"])
        XCTAssertEqual(projects.map(\.value), ["$8.00 · 15 tokens", "$7.00 · 45 tokens"])
        let sessions = usage.sections.first { $0.title == "Recent sessions" }!.rows
        XCTAssertEqual(Set(sessions.map(\.value)), ["$3.00 · 30 tokens", "$4.00 · 15 tokens", "$8.00 · 15 tokens"])
        let json = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
        XCTAssertTrue(json.contains("Projects, last 30 days") && json.contains("alpha · sess-one"))
    }

    func testAgyFoundInsideGeminiAppAndStandaloneWins() throws {
        let root = testTemporaryDirectory.appending(path: "UpstreamSmallPorts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appending(path: "user")
        let paths = ManagerPaths(applicationSupport: root.appending(path: "support"),
                                 credentialStore: user.appending(path: ".switch/codex"),
                                 defaultHome: user.appending(path: ".codex"), sharedRoot: user.appending(path: ".codex"),
                                 orcaAccountsRoot: root.appending(path: "orca"),
                                 codexExecutable: TestCLI.trueExecutable, grokExecutable: TestCLI.trueExecutable,
                                 isolationRoot: root)
        func executable(_ relative: String) throws -> URL {
            let url = user.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let bundled = try executable("Applications/Gemini.app/Contents/Helpers/agy")
        let store = try ProviderAccountStore(paths: paths, environment: ["PATH": TestCLI.searchPath], specs: [])
        // A real agy on this machine comes first; only without one must the Gemini.app helper be found.
        let system = ["/opt/homebrew/bin/agy", "/usr/local/bin/agy", "/Applications/Gemini.app/Contents/Helpers/agy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        XCTAssertEqual(store.resolveExecutable("agy")?.path, system ?? bundled.path)
        let standalone = try executable(".local/bin/agy")
        XCTAssertEqual(store.resolveExecutable("agy")?.path, standalone.path)
        XCTAssertNil(store.resolveExecutable("not-agy"))
    }

    func testOpenAIOrganizationOnlyOnLegacyBalance() {
        let headers = ["Authorization": "Bearer sk-test"]
        XCTAssertEqual(OpenAIUsage.balanceHeaders(headers, organization: nil), headers)
        XCTAssertEqual(OpenAIUsage.balanceHeaders(headers, organization: "  "), headers)
        XCTAssertEqual(OpenAIUsage.balanceHeaders(headers, organization: " org-test ")["OpenAI-Organization"], "org-test")
        XCTAssertTrue(ProviderCatalog.openai.fields.contains { $0.key == "organizationID" && !$0.secure && $0.optional })
    }
}
