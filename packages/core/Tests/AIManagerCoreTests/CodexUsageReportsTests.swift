import Foundation
import XCTest
@testable import AIManagerCore

/// ChatGPT's daily Codex reports (openusage 53d04144 fixture shapes): turns and tokens from the usage
/// counts, credits charged from the personal credit events. Mapped days equal the fixture sums.
final class CodexUsageReportsTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    private static let counts = #"""
    {"balance_unit":"credit","group_by":"day","data":[
     {"date":"2026-10-29","clients":[],"totals":{"credits":486,"text_total_tokens":1200,"threads":2,"turns":10}},
     {"date":"2026-10-29","clients":[],"totals":{"text_total_tokens":300,"turns":2}},
     {"date":"2026-10-30","clients":[],"totals":{"text_total_tokens":null,"turns":3}}]}
    """#

    private static let events = #"""
    {"data":[
     {"credit_amount":486.5,"date":"2026-10-29","product_surface":"desktop_app","usage_id":"usage-1"},
     {"credit_amount":2005.5,"date":"2026-10-17T00:00:00Z","product_surface":"desktop_app","usage_id":"usage-2"},
     {"credit_amount":-1.5,"date":"2026-10-17","product_surface":"exec","usage_id":"usage-3"}]}
    """#

    func testDailyChartsSumEachDayFromBothReports() throws {
        let now = Date(timeIntervalSince1970: 1_793_392_200) // 2026-10-30 20:30 UTC
        let charts = try XCTUnwrap(CodexUsageReports.charts(counts: json(Self.counts), credits: json(Self.events), now: now))
        let byID = Dictionary(uniqueKeysWithValues: charts.map { ($0.id, $0) })
        XCTAssertEqual(Set(byID.keys), ["daily-tokens", "daily-turns", "daily-credits"])

        let tokens = try XCTUnwrap(byID["daily-tokens"])
        XCTAssertEqual(tokens.unit, "tokens")
        XCTAssertEqual(tokens.points.count, 30, "every UTC day of the last 30 days")
        XCTAssertEqual(tokens.points.last?.label, "Oct 30")
        XCTAssertEqual(tokens.points.suffix(2).map(\.value), [1_500, 0], "a day without a token count reads 0")
        XCTAssertEqual(try XCTUnwrap(byID["daily-turns"]).total, 15)

        let credits = try XCTUnwrap(byID["daily-credits"])
        XCTAssertEqual(credits.unit, "credits")
        XCTAssertEqual(credits.total, 2_490.5, accuracy: 1e-9)
        XCTAssertEqual(credits.points.first { $0.label == "Oct 17" }?.value ?? -1, 2_004, accuracy: 1e-9,
                       "a refund lowers its day")
    }

    func testOneMalformedRecordRejectsTheWholeReport() throws {
        let now = Date(timeIntervalSince1970: 1_793_392_200)
        for bad in [#"{"data":{}}"#, #"{"data":[{"date":"2026-10-30"}]}"#,
                    #"{"data":[{"date":"2026-10-30","totals":{"turns":-1}}]}"#,
                    #"{"data":[{"date":"2026-10-30","totals":{"turns":3,"text_total_tokens":"lots"}}]}"#,
                    #"{"data":[{"totals":{"turns":3}}]}"#] {
            XCTAssertNil(CodexUsageReports.charts(counts: try json(bad), credits: try json(Self.events), now: now), bad)
        }
        for bad in [#"{"data":[{"date":"2026-10-30","credit_amount":"$5"}]}"#,
                    #"{"data":[{"date":"2026-10-30","credit_amount":"NaN"}]}"#] {
            XCTAssertNil(CodexUsageReports.charts(counts: try json(Self.counts), credits: try json(bad), now: now), bad)
        }
    }

    func testClientReadsBothReportsForTheLast30UTCDays() async throws {
        let auth = FileManager.default.temporaryDirectory.appending(path: "codex-reports-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: auth) }
        let now = Date(timeIntervalSince1970: 1_793_392_200)
        let payload = Data(#"{"exp":\#(Int(now.timeIntervalSince1970) + 3_600)}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let token = "e30.\(payload).sig"
        try Data(#"{"tokens":{"access_token":"\#(token)","account_id":"acct-synthetic"}}"#.utf8).write(to: auth)

        let seen = Recorder()
        let client = CodexWhamClient { url, headers in
            await seen.add(url, headers["ChatGPT-Account-Id"])
            let body = url.contains("daily-workspace-usage-counts") ? Self.counts : Self.events
            return HTTPResponse(status: 200, data: Data(body.utf8), headers: [:])
        }
        let fetched = await client.fetchHistory(authFile: auth, now: now)
        let charts = try XCTUnwrap(fetched)
        XCTAssertEqual(charts.count, 3)
        let urls = await seen.urls
        XCTAssertEqual(urls.sorted(), [
            "https://chatgpt.com/backend-api/wham/analytics/daily-workspace-usage-counts"
                + "?start_date=2026-10-01&end_date=2026-10-30&group_by=day&workspace_user=true",
            "https://chatgpt.com/backend-api/wham/usage/credit-usage-events",
        ])
        let accounts = await seen.accounts
        XCTAssertEqual(accounts, ["acct-synthetic", "acct-synthetic"])

        let failing = CodexWhamClient { _, _ in HTTPResponse(status: 500, data: Data(), headers: [:]) }
        let none = await failing.fetchHistory(authFile: auth, now: now)
        XCTAssertNil(none)
    }

    private actor Recorder {
        var urls: [String] = []
        var accounts: [String?] = []
        func add(_ url: String, _ account: String?) {
            urls.append(url)
            accounts.append(account)
        }
    }
}
