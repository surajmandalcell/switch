import Foundation
import XCTest
@testable import AIManagerCore

final class NewProvidersTripoSiliconFlowTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private func reply(_ status: Int, _ body: String = "") -> HTTPResponse {
        HTTPResponse(status: status, data: Data(body.utf8), headers: [:])
    }

    // MARK: Tripo

    func testTripoBalanceAndReserved() throws {
        let usage = try TripoUsage.map(json(#"{"code":0,"data":{"balance":1234.5,"frozen":20}}"#))
        XCTAssertEqual(usage.sections.first?.rows.map(\.label), ["Balance", "Reserved"])
        XCTAssertEqual(usage.sections.first?.rows.map(\.value), ["1,234.5", "20"])
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertNil(usage.cost)
    }

    func testTripoRejectsBadBodies() throws {
        XCTAssertThrowsError(try TripoUsage.map(json(#"{"code":2000,"data":{"balance":1,"frozen":0}}"#)))
        for body in [#"{"code":0,"data":{"balance":"1","frozen":0}}"#, #"{"code":0,"data":{"balance":-1,"frozen":0}}"#,
                     #"{"code":0,"data":{"balance":1}}"#, #"{"code":0}"#, #"{"data":{"balance":1,"frozen":0}}"#, "{}"] {
            XCTAssertThrowsError(try TripoUsage.map(json(body)), body)
        }
    }

    func testTripoFetchUsesBearerEndpointAndMapsHttpFailures() async throws {
        let usage = try await TripoUsage.fetch(key: "synthetic-key") { url, headers in
            XCTAssertEqual(url, "https://openapi.tripo3d.ai/v3/account/balance")
            XCTAssertEqual(headers["Authorization"], "Bearer synthetic-key")
            return self.reply(200, #"{"code":0,"data":{"balance":10,"frozen":2}}"#)
        }
        XCTAssertEqual(usage.sections.first?.rows.first?.value, "10")
        for status in [201, 401, 403, 429, 500] {
            do {
                _ = try await TripoUsage.fetch(key: "synthetic-key") { _, _ in self.reply(status) }
                XCTFail("Accepted HTTP \(status)")
            } catch let error as ProviderError {
                switch (status, error) {
                case (401, .unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .unavailable), (201, .http): break
                default: XCTFail("Wrong HTTP \(status) error: \(error)")
                }
            }
        }
        let field = try XCTUnwrap(ProviderCatalog.tripo.fields.first)
        XCTAssertEqual(field.env, ["TRIPO_API_KEY"])
        XCTAssertTrue(field.secure)
    }

    // MARK: SiliconFlow

    private let okBody = #"{"code":20000,"message":"OK","status":true,"data":{"balance":"0.88","chargeBalance":"88.00","totalBalance":"88.88","status":"normal"}}"#

    func testSiliconFlowBothOriginsAndCurrencies() async throws {
        for (origin, expected) in [("https://api.siliconflow.cn", ["CN¥88.88", "CN¥88.00", "CN¥0.88"]),
                                   ("https://api.siliconflow.com", ["$88.88", "$88.00", "$0.88"])] {
            let body = okBody
            let usage = try await SiliconFlowUsage.fetch(key: "synthetic-key", origin: origin) { url, headers in
                XCTAssertEqual(url, origin + "/v1/user/info")
                XCTAssertEqual(headers["Authorization"], "Bearer synthetic-key")
                return self.reply(200, body)
            }
            XCTAssertEqual(usage.sections.first?.rows.map(\.label), ["Balance", "Purchased", "Bonus"])
            XCTAssertEqual(usage.sections.first?.rows.map(\.value), expected)
        }
    }

    func testSiliconFlowNumbersNegativeTotalAndStatus() throws {
        let usage = try SiliconFlowUsage.map(json(#"{"code":20000,"status":true,"data":{"totalBalance":-1.5,"status":"frozen"}}"#), currency: "USD")
        XCTAssertEqual(usage.sections.first?.rows.map(\.label), ["Balance", "Status"])
        XCTAssertEqual(usage.sections.first?.rows.map(\.value), ["-$1.50", "frozen"])
        for body in [#"{"code":20000,"status":true,"data":{"totalBalance":"abc"}}"#, #"{"code":20000,"status":true,"data":{}}"#,
                     #"{"code":20000,"status":false,"data":{"totalBalance":"1"}}"#, #"{"code":20001,"status":true,"data":{"totalBalance":"1"}}"#,
                     #"{"code":20000,"status":true,"data":{"totalBalance":"1","balance":"x"}}"#, "{}"] {
            XCTAssertThrowsError(try SiliconFlowUsage.map(json(body), currency: "USD"), body)
        }
    }

    func testSiliconFlowErrorsAndOriginGuard() async throws {
        for status in [201, 401, 403, 410, 429, 500] {
            do {
                _ = try await SiliconFlowUsage.fetch(key: "k", origin: SiliconFlowUsage.china) { _, _ in self.reply(status) }
                XCTFail("Accepted HTTP \(status)")
            } catch let error as ProviderError {
                switch (status, error) {
                case (401, .unauthorized), (403, .unauthorized), (410, .unavailable), (429, .rateLimited), (500, .unavailable), (201, .http): break
                default: XCTFail("Wrong HTTP \(status) error: \(error)")
                }
            }
        }
        for (code, wantAuth) in [(30014, true), (20092, false)] {
            do {
                _ = try await SiliconFlowUsage.fetch(key: "k", origin: SiliconFlowUsage.china) { _, _ in
                    self.reply(200, #"{"code":\#(code),"status":false,"data":null}"#)
                }
                XCTFail("Accepted code \(code)")
            } catch let error as ProviderError {
                XCTAssertEqual(error.needsSignIn, wantAuth, "\(code)")
            }
        }
        do {
            _ = try await SiliconFlowUsage.fetch(key: "k", origin: "https://evil.example") { _, _ in
                XCTFail("Sent the key to an unlisted origin"); return self.reply(200)
            }
            XCTFail("Accepted an unlisted origin")
        } catch let error as ProviderError {
            guard case .unsupported = error else { return XCTFail("Wrong error: \(error)") }
        }
        let field = try XCTUnwrap(ProviderCatalog.siliconflow.fields.first)
        XCTAssertEqual(field.env, ["SILICONFLOW_API_KEY"])
        XCTAssertTrue(field.secure)
    }
}
