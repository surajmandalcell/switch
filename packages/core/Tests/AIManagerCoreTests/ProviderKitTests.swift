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
        XCTAssertFalse(json.at("a.b")[3].exists)
        XCTAssertEqual(json["t"].date?.timeIntervalSince1970 ?? 0, 1_767_323_045.123, accuracy: 0.001)
        XCTAssertEqual(Fmt.epoch(1_700_000_000_000), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(Fmt.cookie("b", in: "a=1; b=two=2; c=3"), "two=2")
    }
}
