import XCTest
@testable import AIManagerCore

/// Providers keep only official sign-in files or the provider's own API key (specs/product.md 1a).
final class SignInTypesTests: XCTestCase {
    func testNoProviderAsksForACookieOrWebSession() {
        for spec in ProviderCatalog.all {
            for field in spec.fields {
                XCTAssertFalse(["cookie", "session"].contains(field.key), "\(spec.id).\(field.key)")
                XCTAssertFalse(field.title.lowercased().contains("cookie"), "\(spec.id).\(field.key)")
            }
        }
    }

    // MARK: MiMo Token Plan

    private func mimo(_ quota: String, period: String = #"{"start_at":"2026-11-01 00:00:00","end_at":"2026-12-01 00:00:00"}"#)
        throws -> JSON {
        try JSON(data: Data(#"{"object":"token_plan","plan_code":"pro","quota":\#(quota),"period":\#(period)}"#.utf8))
    }

    func testMiMoTokenPlanMapsCreditsAndUTCPeriod() throws {
        let usage = try MiMoUsage.map(mimo(#"{"total_credits":1000,"used_credits":250,"remaining_credits":750}"#))
        let window = try XCTUnwrap(usage.windows.first)
        XCTAssertEqual(window.usedPercent, 25)
        XCTAssertEqual(window.detail, "250 / 1,000 Credits")
        XCTAssertEqual(window.resetsAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
        XCTAssertEqual(window.windowMinutes, 30 * 1440)
        XCTAssertEqual(usage.plan, "pro")
    }

    func testMiMoTokenPlanRejectsBadShapes() throws {
        for quota in [#"{"total_credits":1000,"used_credits":250,"remaining_credits":700}"#,
                      #"{"total_credits":-1,"used_credits":0,"remaining_credits":0}"#,
                      #"{"total_credits":"1000","used_credits":0,"remaining_credits":1000}"#] {
            XCTAssertThrowsError(try MiMoUsage.map(mimo(quota)), quota)
        }
        let ok = #"{"total_credits":10,"used_credits":0,"remaining_credits":10}"#
        XCTAssertThrowsError(try MiMoUsage.map(mimo(ok, period: #"{"start_at":"2026-12-01 00:00:00","end_at":"2026-11-01 00:00:00"}"#)))
        XCTAssertThrowsError(try MiMoUsage.map(mimo(ok, period: #"{"start_at":"2026-11-01T00:00:00Z","end_at":"2026-12-01 00:00:00"}"#)))
        XCTAssertThrowsError(try MiMoUsage.map(JSON(data: Data(#"{"object":"balance"}"#.utf8))))
    }

    func testMiMoAsksForTheKeyNotACookie() {
        let fields = ProviderCatalog.mimo.fields.map(\.key)
        XCTAssertTrue(fields.contains("apiKey"))
        XCTAssertTrue(fields.contains("region"))
    }

    // MARK: Muse Code

    func testMuseReadsTheFileBackedToken() throws {
        let file = Data(#"{"providers":{"meta":{"access_token":"dca:synthetic"}}}"#.utf8)
        XCTAssertEqual(try MuseUsage.token(ProviderCredential(files: [".config/muse/auth.json": file])), "dca:synthetic")
        XCTAssertEqual(ProviderCatalog.muse.loginEnv["TBH_CREDENTIAL_BACKEND"], "file")
    }

    func testMuseKeychainLoginGetsFileBackendGuidance() {
        let file = Data(#"{"storage":"keychain","providers":{"meta":{}}}"#.utf8)
        XCTAssertThrowsError(try MuseUsage.token(ProviderCredential(files: [".config/muse/auth.json": file]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("TBH_CREDENTIAL_BACKEND=file muse login"))
            XCTAssertTrue(error.localizedDescription.contains("Keychain"))
        }
    }
}
