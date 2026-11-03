import Foundation
import XCTest
@testable import AIManagerCore

final class SonioxUsageTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private let balance = #"{"available_balance_usd":"18.50","invoice_billing_enabled":false}"#
    private let monthly = #"{"month":"2026-10","usage_usd":"6.00","monthly_budget_usd":"100.00"}"#

    func testPrepaidBalanceAndMonthlyBudgetStaySeparate() throws {
        let usage = try SonioxUsage.map(balance: json(balance), monthly: json(monthly))
        XCTAssertEqual(usage.windows.first?.usedPercent, 6)
        XCTAssertEqual(usage.cost?.used, 6)
        XCTAssertEqual(usage.cost?.limit, 100)
        XCTAssertEqual(usage.cost?.balance, 18.5)
        XCTAssertEqual(usage.cost?.period, "This month")
        XCTAssertEqual(usage.cost?.resetsAt, ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        XCTAssertEqual(usage.sections.first?.rows.first?.label, "Prepaid")
    }

    func testInvoiceSignedBalanceZeroBudgetAndOverage() throws {
        let invoice = try SonioxUsage.map(balance: json(#"{"available_balance_usd":"0","invoice_billing_enabled":true}"#), monthly: json(monthly))
        XCTAssertNil(invoice.cost?.balance)
        XCTAssertEqual(invoice.sections.first?.rows.first?.label, "Invoice billing")
        let debt = try SonioxUsage.map(balance: json(#"{"available_balance_usd":"-0.125","invoice_billing_enabled":false}"#), monthly: json(monthly))
        XCTAssertEqual(debt.cost?.balance, -0.125)
        let zero = try SonioxUsage.map(balance: json(balance), monthly: json(#"{"month":"2026-10","usage_usd":"0","monthly_budget_usd":"0"}"#))
        XCTAssertTrue(zero.windows.isEmpty)
        XCTAssertEqual(zero.cost?.limit, 0)
        XCTAssertEqual(zero.sections.first?.rows.last?.value, "$0.00")
        let overage = try SonioxUsage.map(balance: json(balance), monthly: json(#"{"month":"2026-10","usage_usd":"100.25","monthly_budget_usd":"100"}"#))
        XCTAssertEqual(overage.windows.first?.usedPercent, 100)
        XCTAssertEqual(overage.cost?.used, 100.25)
    }

    func testResetUsesReportedUtcMonthAcrossYearAndLeapBoundaries() throws {
        for (month, expected) in [("2026-12", "2027-01-01T00:00:00Z"), ("2028-02", "2028-03-01T00:00:00Z")] {
            let usage = try SonioxUsage.map(balance: json(balance), monthly: json("{\"month\":\"\(month)\",\"usage_usd\":\"0\",\"monthly_budget_usd\":\"100\"}"))
            XCTAssertEqual(usage.windows.first?.resetsAt, ISO8601DateFormatter().date(from: expected))
        }
    }

    func testRejectsCoercibleOrInvalidBillingData() throws {
        for invalid in [#"{"available_balance_usd":18.5,"invoice_billing_enabled":false}"#,
                        #"{"available_balance_usd":"NaN","invoice_billing_enabled":false}"#,
                        #"{"available_balance_usd":"1e3","invoice_billing_enabled":false}"#,
                        #"{"available_balance_usd":"1","invoice_billing_enabled":0}"#,
                        #"{"available_balance_usd":"1","invoice_billing_enabled":"false"}"#] {
            XCTAssertThrowsError(try SonioxUsage.map(balance: json(invalid), monthly: json(monthly)), invalid)
        }
        for invalid in [#"{"month":"2026-13","usage_usd":"6","monthly_budget_usd":"100"}"#,
                        #"{"month":"2026-10","usage_usd":"-1","monthly_budget_usd":"100"}"#,
                        #"{"month":"2026-10","usage_usd":"6","monthly_budget_usd":100}"#,
                        #"{"month":"2026-10","usage_usd":"6","monthly_budget_usd":null}"#,
                        #"{"month":"2026-10","usage_usd":"","monthly_budget_usd":"100"}"#, "{}"] {
            XCTAssertThrowsError(try SonioxUsage.map(balance: json(balance), monthly: json(invalid)), invalid)
        }
    }

    func testFetchUsesOnlyOrganizationReadEndpointsWithBearerKey() async throws {
        let balance = self.balance, monthly = self.monthly
        let usage = try await SonioxUsage.fetch(key: "synthetic-key") { url, headers in
            XCTAssertEqual(headers["Authorization"], "Bearer synthetic-key")
            let payload: String
            switch url {
            case "https://api.soniox.com/v1/organization/balance": payload = balance
            case "https://api.soniox.com/v1/organization/usage/monthly": payload = monthly
            default: XCTFail("Unexpected or billable endpoint: \(url)"); payload = "{}"
            }
            return HTTPResponse(status: 200, data: Data(payload.utf8), headers: [:])
        }
        XCTAssertEqual(usage.cost?.used, 6)
        let field = try XCTUnwrap(ProviderCatalog.soniox.fields.first)
        XCTAssertEqual(field.env, ["SONIOX_ORG_API_KEY"])
        XCTAssertEqual(field.title, "Organization API key")
        XCTAssertTrue(field.secure)
    }

    func testFetchDistinguishesOrganizationPermissionFromRejectedKey() async throws {
        for status in [201, 401, 403, 429, 500] {
            do {
                _ = try await SonioxUsage.fetch(key: "synthetic-key") { _, _ in
                    HTTPResponse(status: status, data: Data(), headers: [:])
                }
                XCTFail("Accepted HTTP \(status)")
            } catch let error as ProviderError {
                switch (status, error) {
                case (401, .unauthorized), (429, .rateLimited), (500, .unavailable), (201, .http): break
                case (403, .http):
                    XCTAssertFalse(error.needsSignIn)
                    XCTAssertTrue(error.localizedDescription.contains("organization API key"))
                    XCTAssertTrue(error.localizedDescription.contains("Project API keys"))
                default: XCTFail("Wrong HTTP \(status) error: \(error)")
                }
            }
        }
    }
}
