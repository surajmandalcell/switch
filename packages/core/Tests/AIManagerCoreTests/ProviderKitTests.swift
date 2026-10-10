import Foundation
import XCTest
@testable import AIManagerCore

final class ProviderKitTests: XCTestCase {
    func testSanitizedStripsTerminalControlCharacters() {
        let escape = "\u{1B}[2J\u{1B}]0;pwned\u{07}"
        let usage = ProviderUsage(
            windows: [.init(id: "w", title: "Week\(escape)", usedPercent: 10, detail: "1\u{9B}31m")],
            cost: .init(used: 1, currency: "US\u{1B}D", period: "Mo\nnth"),
            sections: [.init("T\u{7F}", [.init("L\u{0}", "V\u{1B}c")])],
            plan: "Pro\u{1B}[31m", email: "a@b\r.c", organization: "Org\u{85}"
        ).sanitized()
        let text = [usage.windows[0].title, usage.windows[0].detail ?? "", usage.cost?.currency ?? "",
                    usage.cost?.period ?? "", usage.sections[0].title ?? "",
                    usage.sections[0].rows[0].label, usage.sections[0].rows[0].value,
                    usage.plan ?? "", usage.email ?? "", usage.organization ?? ""].joined()
        XCTAssertFalse(text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) })
        XCTAssertEqual(usage.plan, "Pro [31m")
        XCTAssertEqual(ProviderError.parse("bad\u{1B}[0m").errorDescription, "bad [0m")
    }

    func testChartsRoundTripSanitizeAndDecodeOldCache() throws {
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let chart = UsageChart(id: "c\u{1B}", title: "Spend\u{7}", unit: "USD",
                               points: [UsagePoint(label: "Oct 3\u{1B}", date: day, value: 2.1)])
        let usage = ProviderUsage(plan: "Pro", fetchedAt: day, charts: [chart])
        XCTAssertFalse(usage.isEmpty)
        let clean = usage.sanitized().charts[0]
        XCTAssertEqual([clean.id, clean.title, clean.points[0].label], ["c ", "Spend ", "Oct 3 "])
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(ProviderUsage.self, from: encoder.encode(usage)), usage)
        // Cached JSON written before charts existed has no `charts` key.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(usage)) as? [String: Any])
        object["charts"] = nil
        let old = try decoder.decode(ProviderUsage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.charts, [])
        XCTAssertEqual(old.plan, "Pro")
    }

    func testDailyChartFillsMissingDaysAndFormatsUnits() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z
        let chart = try XCTUnwrap(UsageChart.daily(id: "d", title: "Daily", unit: "USD",
                                                   values: ["2026-09-21": 1.5, "2026-09-19T10:00:00Z": 0.5, "2026-08-01": 9],
                                                   fill: (4, now)))
        XCTAssertEqual(chart.points.map(\.label), ["Sep 18", "Sep 19", "Sep 20", "Sep 21"])
        XCTAssertEqual(chart.points.map(\.value), [0, 0.5, 0, 1.5])
        XCTAssertEqual(chart.total, 2)
        XCTAssertEqual(chart.peak?.label, "Sep 21")
        XCTAssertEqual(chart.format(1.5), "$1.50")
        XCTAssertEqual(UsageChart(id: "t", title: "T", unit: "tokens", points: []).format(1234), "1,234")
        XCTAssertEqual(UsageChart(id: "t", title: "T", unit: "EUR", points: []).format(2), "\u{20AC}2.00")
        XCTAssertNil(UsageChart.daily(id: "e", title: "E", unit: "USD", values: [:]))
        // An empty chart never reaches a usage value.
        XCTAssertTrue(ProviderUsage(charts: [UsageChart(id: "x", title: "X", unit: "USD", points: [])]).charts.isEmpty)
    }

    func testOverageSurvivesAndSubCentMoneyKeepsDecimals() {
        XCTAssertEqual(UsageWindow(id: "w", title: "W", usedPercent: 130).usedPercent, 130)
        XCTAssertEqual(UsageWindow(id: "w", title: "W", usedPercent: -4).usedPercent, 0)
        XCTAssertEqual(Fmt.money(0.0042), "$0.0042")
        XCTAssertEqual(Fmt.money(0.005), "$0.005")
        XCTAssertEqual(Fmt.money(0), "$0.00")
        XCTAssertEqual(Fmt.money(12.4), "$12.40")
        XCTAssertEqual(Fmt.money(0.0123), "$0.01")
    }

    func testPrivateHostsAllowPlainHTTPOnly() {
        for host in ["localhost", "127.0.0.1", "10.2.3.4", "192.168.1.9", "172.16.0.1", "172.31.255.255",
                     "nas.local"] {
            XCTAssertTrue(HTTP.isPrivate(host), host)
        }
        for host in ["example.com", "172.32.0.1", "11.0.0.1", "192.169.0.1", "10.0.0", nil] {
            XCTAssertFalse(HTTP.isPrivate(host), host ?? "nil")
        }
    }

    func testJSONAndDates() throws {
        let json = try JSON(data: Data(#"{"a":{"b":[1,"2.5",true,null]},"t":"2026-01-02T03:04:05.123456Z"}"#.utf8))
        XCTAssertEqual(json.at("a.b")[0].int, 1)
        XCTAssertEqual(json.at("a.b")[1].double, 2.5)
        XCTAssertNil(json.at("a.b")[2].double, "booleans are not numbers")
        XCTAssertEqual(json.at("a.b")[0].string, "1", "the number 1 is not a boolean")
        XCTAssertNil(json.at("a.b")[2].string)
        XCTAssertTrue(JSON.isBoolean(json.at("a.b")[2].raw))
        XCTAssertFalse(JSON.isBoolean(json.at("a.b")[0].raw))
        XCTAssertFalse(json.at("a.b")[3].exists)
        XCTAssertEqual(json["t"].date?.timeIntervalSince1970 ?? 0, 1_767_323_045.123, accuracy: 0.001)
        XCTAssertEqual(Fmt.epoch(1_700_000_000_000), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(Fmt.cookie("b", in: "a=1; b=two=2; c=3"), "two=2")
    }
}
