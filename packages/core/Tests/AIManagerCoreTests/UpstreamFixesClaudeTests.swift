import Foundation
import XCTest
@testable import AIManagerCore

/// Synthetic Claude Code cases from the OpenUsage, claude-swap and caam audit. No real account data.
final class UpstreamFixesClaudeTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    func testMax20xIsNamedUltraAndOtherPlansKeepTheirNames() {
        XCTAssertEqual(ClaudeUsage.planName(type: "max", tier: "default_claude_max_20x"), "Ultra")
        XCTAssertEqual(ClaudeUsage.planName(type: "max", tier: "default_claude_ultra"), "Ultra")
        XCTAssertEqual(ClaudeUsage.planName(type: "ultra", tier: nil), "Ultra")
        XCTAssertEqual(ClaudeUsage.planName(type: "max", tier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(ClaudeUsage.planName(type: "max", tier: nil), "Max")
        XCTAssertEqual(ClaudeUsage.planName(type: "pro", tier: "default_claude_ai"), "Pro")
        XCTAssertEqual(ClaudeUsage.planName(type: "team", tier: "default_claude_max_5x"), "Team 5x")
    }

    /// Inferred: no real Ultra panel was seen. Ultra has no 5-hour window, so the panel has no Session row.
    func testPanelWithoutASessionRowCompletesOnceDrawn() throws {
        let insights = "\nWhat's contributing to your limits usage?\nScanning local sessions…"
        let weekly = "Current week (all models)\n██  40% used\nResets Dec 2 at 12am (UTC)"
        let scoped = "Current week (Example Model)\n██  12% used\nResets Dec 2 at 12am (UTC)"
        XCTAssertFalse(ClaudeUsage.panelIsComplete(weekly))
        XCTAssertTrue(ClaudeUsage.panelIsComplete(weekly + insights))
        XCTAssertTrue(ClaudeUsage.panelIsComplete(weekly + "\n" + scoped + insights))
        // Only other rows: a model row without an all-models row still counts once the panel is drawn.
        XCTAssertFalse(ClaudeUsage.panelIsComplete(scoped))
        XCTAssertTrue(ClaudeUsage.panelIsComplete(scoped + insights))
        let usage = try ClaudeUsage.parseUsageText(weekly + "\n" + scoped + insights,
                                                   now: ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z")!)
        XCTAssertEqual(usage.windows.map(\.id), ["weekly", "weekly-example-model"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [40, 12])
    }

    func testHugeOrNonFiniteResetCountsDoNotTrap() throws {
        func available(_ left: String) throws -> String? {
            let body = try json("""
            {"cedar_ember":{"eligible":true,"grants":[{"ends_at":"2099-01-01T00:00:00Z","resets_left":\(left)},
                                                      {"ends_at":"2099-01-01T00:00:00Z","resets_left":2}]}}
            """)
            return ClaudeUsage.map(body, credentials: nil).sections.first?.rows.first?.value
        }
        XCTAssertEqual(try available("1e30"), "1000002")
        XCTAssertEqual(try available(#""inf""#), "2")
        XCTAssertEqual(try available(#""nan""#), "2")
        XCTAssertEqual(try available("3"), "5")
    }

    func testOrganizationPolicy403IsAFailureWithItsReasonNotASignInPrompt() {
        let policy = Data(#"{"error":{"details":{"error_code":"oauth_not_allowed_for_organization"}}}"#.utf8)
        func check(_ status: Int, _ body: Data) -> ProviderError? {
            do { try ClaudeUsage.check(HTTPResponse(status: status, data: body, headers: [:])) } catch {
                return error as? ProviderError
            }
            return nil
        }
        guard case .unavailable(let text)? = check(403, policy) else { return XCTFail("policy 403 must be unavailable") }
        XCTAssertTrue(text.contains("organization"), text)
        XCTAssertFalse(check(403, policy)?.needsSignIn ?? true)
        // Any other 403 and any other status keep the shared mapping.
        guard case .unauthorized? = check(403, Data(#"{"error":{"details":{"error_code":"other"}}}"#.utf8)) else {
            return XCTFail("other 403 stays unauthorized")
        }
        guard case .unauthorized? = check(403, Data("<html>forbidden</html>".utf8)) else {
            return XCTFail("unreadable 403 stays unauthorized")
        }
        guard case .unauthorized? = check(401, policy) else { return XCTFail("401 stays unauthorized") }
        XCTAssertNil(check(200, Data()))
    }

    func testExtraUsageHonoursDecimalPlaces() throws {
        func cost(_ extra: String) throws -> UsageCost? {
            ClaudeUsage.map(try json(#"{"extra_usage":{"is_enabled":true,\#(extra)}}"#), credentials: nil).cost
        }
        let yen = try cost(#""used_credits":1500,"monthly_limit":50000,"currency":"JPY","decimal_places":0"#)
        XCTAssertEqual(yen?.used, 1500)
        XCTAssertEqual(yen?.limit, 50000)
        XCTAssertEqual(yen?.currency, "JPY")
        let dollars = try cost(#""used_credits":1250,"monthly_limit":50000,"currency":"USD""#)
        XCTAssertEqual(dollars?.used, 12.5)
        XCTAssertEqual(dollars?.limit, 500)
        let three = try cost(#""used_credits":1500,"monthly_limit":0,"decimal_places":3"#)
        XCTAssertEqual(three?.used, 1.5)
        XCTAssertNil(three?.limit)
        // A garbled or absurd value falls back to cents or is clamped; it never traps.
        XCTAssertEqual(try cost(#""used_credits":1250,"decimal_places":"nan""#)?.used, 12.5)
        XCTAssertEqual(try cost(#""used_credits":1250,"decimal_places":1e30"#)?.used, 0.00125)
    }
}
