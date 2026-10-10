import XCTest
@testable import AIManagerCore

final class ProvidersIDETests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    /// Unsigned JWT with the given claims.
    private func jwt(_ claims: String) -> String {
        let part = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(part).sig"
    }

    private func credential(_ id: String, _ text: String) -> ProviderCredential {
        ProviderCredential(files: [id: Data(text.utf8)])
    }

    func testCatalogListsGroup() {
        XCTAssertEqual(ProviderCatalog.ide.map(\.id.rawValue),
                       ["gemini-cli", "antigravity-cli", "vertexai", "copilot", "cursor", "windsurf", "jetbrains"])
        let agy = ProviderCatalog.ide[1]
        XCTAssertEqual(agy.login, ["agy"])
        XCTAssertEqual(agy.loginEnv, ["SSH_TTY": "1"])
        XCTAssertEqual(ProviderCatalog.ide[2].files.first?.homeEnv, "CLOUDSDK_CONFIG")
    }

    // MARK: Gemini CLI

    func testGeminiMapsFamiliesWithLowestFraction() throws {
        let quota = try json("""
        {"buckets":[
          {"modelId":"gemini-2.5-pro","remainingFraction":0.6,"resetTime":"2026-01-01T00:00:00Z"},
          {"modelId":"gemini-3-pro-preview","remainingFraction":0.25,"resetTime":"2026-01-02T00:00:00Z"},
          {"modelId":"gemini-2.5-flash","remainingFraction":0.9,"resetTime":"2026-01-01T00:00:00Z"},
          {"modelId":"gemini-2.5-flash-lite","remainingFraction":1}]}
        """)
        let assist = try json(#"{"currentTier":{"id":"free-tier"},"cloudaicompanionProject":{"id":"p1"}}"#)
        let claims = Fmt.jwtClaims(jwt(#"{"email":"a@corp.com","hd":"corp.com","sub":"42"}"#))
        let usage = try GeminiCLIUsage.map(quota: quota, assist: assist, claims: claims)
        XCTAssertEqual(usage.windows.map(\.id), ["pro", "flash", "flash-lite"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(usage.windows[1].usedPercent ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(usage.windows[2].usedPercent ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(usage.windows[0].windowMinutes, 1440)
        XCTAssertEqual(usage.plan, "Workspace")
        XCTAssertEqual(usage.email, "a@corp.com")
        XCTAssertEqual(IDEAuth.project(assist), "p1")
    }

    func testGeminiIdentityFromIdTokenAndAccountsFile() {
        let spec = ProviderCatalog.ide[0]
        let creds = spec.files[0].id, accounts = spec.files[1].id
        var credential = credential(creds, #"{"id_token":"\#(jwt(#"{"email":"me@x.com","sub":"7"}"#))"}"#)
        XCTAssertEqual(spec.identify?(credential), CredentialIdentity(key: "7", email: "me@x.com"))
        credential = self.credential(creds, #"{"access_token":"a"}"#)
        credential.files[accounts] = Data(#"{"active":"Pat@X.com","old":[]}"#.utf8)
        XCTAssertEqual(spec.identify?(credential), CredentialIdentity(key: "pat@x.com", email: "Pat@X.com"))
        XCTAssertNil(spec.identify?(self.credential(creds, "{}")))
    }

    func testGeminiParsesClientFromInstalledJavaScript() {
        let js = """
        const OAUTH_CLIENT_ID = '123-abc.apps.googleusercontent.com';
        const OAUTH_CLIENT_SECRET = 'TEST-secret_value';
        """
        let client = GeminiCLIUsage.parseClient(js: js)
        XCTAssertEqual(client?.id, "123-abc.apps.googleusercontent.com")
        XCTAssertEqual(client?.secret, "TEST-secret_value")
        XCTAssertNil(GeminiCLIUsage.parseClient(js: "const x = 1;"))
        let env = ["GEMINI_OAUTH_CLIENT_ID": "i", "GEMINI_OAUTH_CLIENT_SECRET": "s"]
        XCTAssertEqual(GeminiCLIUsage.oauthClient(env: env)?.secret, "s")
    }

    // MARK: Antigravity CLI

    func testAntigravityMapsFourSummaryBucketsByExactId() throws {
        let summary = try json("""
        {"groups":[
          {"displayName":"Claude and other models","buckets":[
            {"bucketId":"3p-weekly","remainingFraction":1,"resetTime":"2026-07-06T07:00:00Z"},
            {"bucketId":"3p-5h","remainingFraction":0.4,"resetTime":"2026-07-02T15:30:00Z"}]},
          {"displayName":"Gemini models","buckets":[
            {"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2026-07-02T16:00:00Z"},
            {"bucketId":"gemini-weekly","remainingFraction":0.9},
            {"bucketId":"gemini-image-5h","remainingFraction":0.1},
            {"bucketId":"gemini-5h","remainingFraction":0.0}]}]}
        """)
        let assist = try json(#"{"paidTier":{"name":"Google AI Pro"},"currentTier":{"id":"standard-tier"}}"#)
        let usage = try AntigravityCLIUsage.map(assist: assist, summary: summary, models: nil, claims: nil)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "claude-session", "claude-weekly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [25, 10, 60, 0])
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[1].windowMinutes, 10_080)
        XCTAssertEqual(usage.windows[0].resetsAt, Fmt.iso("2026-07-02T16:00:00Z"))
        XCTAssertEqual(usage.plan, "Google AI Pro")
    }

    func testAntigravityWrappedSummaryAndModelFallback() throws {
        let wrapped = try json(#"{"response":{"groups":[{"buckets":[{"bucketId":"gemini-5h","remaining":{"remainingFraction":0.5}}]}]}}"#)
        XCTAssertTrue(AntigravityCLIUsage.hasSummary(wrapped))
        XCTAssertEqual(try AntigravityCLIUsage.map(assist: json("{}"), summary: wrapped, models: nil, claims: nil).windows.first?.usedPercent, 50)

        let models = try json("""
        {"models":{"a":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.8}},
                   "b":{"displayName":"Gemini 3 Flash","quotaInfo":{"remainingFraction":0.3}},
                   "c":{"displayName":"Claude Sonnet","quotaInfo":{"remainingFraction":0.5}},
                   "d":{"displayName":"Claude Opus"},
                   "e":{"displayName":"Hidden","isInternal":true,"quotaInfo":{"remainingFraction":0}}}}
        """)
        let usage = try AntigravityCLIUsage.map(assist: json("{}"), summary: nil, models: models, claims: nil)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "claude-session"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 70, accuracy: 0.001)
        XCTAssertEqual(usage.windows[1].usedPercent ?? -1, 50, accuracy: 0.001)
    }

    func testAntigravityIdentitySecretsAndRejectedClient() throws {
        let spec = ProviderCatalog.ide[1]
        let token = #"{"token":{"access_token":"a"},"auth_method":"consumer","id_token":"\#(jwt(#"{"email":"u@gmail.com","sub":"99"}"#))"}"#
        XCTAssertEqual(spec.identify?(credential(spec.files[0].id, token)), CredentialIdentity(key: "99", email: "u@gmail.com"))

        let secret = "GOCSPX-" + String(repeating: "a", count: 28)
        let blob = Data("junk\0".utf8) + Data(secret.utf8) + Data("\0GOCSPX-short\0".utf8) + Data(secret.utf8)
        XCTAssertEqual(AntigravityCLIUsage.secrets(in: blob), [secret])

        let rejected = try json(#"{"ineligibleTiers":[{"reasonCode":"GOOGLE_TOS_NOT_SUPPORTED_BY_CLIENT"}]}"#)
        XCTAssertTrue(AntigravityCLIUsage.rejectsClient(rejected))
        XCTAssertFalse(AntigravityCLIUsage.rejectsClient(try json(#"{"currentTier":{"id":"free-tier"}}"#)))
    }

    func testLiveCredentialNeverRefreshes() async throws {
        do {
            _ = try await IDEAuth.authorized(access: "old", expiry: Date().addingTimeInterval(-10), live: true,
                                             hint: "Open it.", refresh: { XCTFail("must not refresh"); return "" },
                                             call: { $0 })
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unauthorized("Open it."))
        }
        let vault = try await IDEAuth.authorized(access: "old", expiry: Date().addingTimeInterval(-10), live: false,
                                                 hint: "x", refresh: { "new" }, call: { $0 })
        XCTAssertEqual(vault, "new")
    }

    // MARK: Vertex AI

    func testVertexMapsPeakQuotaAcrossSeries() throws {
        let usage = [try json("""
        {"metric":{"labels":{"quota_metric":"aiplatform.googleapis.com/online_prediction_requests","limit_name":"L1"}},
         "resource":{"labels":{"location":"us-central1"}},
         "points":[{"value":{"int64Value":"30"}},{"value":{"int64Value":"60"}}]}
        """), try json("""
        {"metric":{"labels":{"quota_metric":"aiplatform.googleapis.com/tokens"}},
         "resource":{"labels":{"location":"global"}},"points":[{"value":{"doubleValue":10}}]}
        """)]
        let limit = [try json("""
        {"metric":{"labels":{"quota_metric":"aiplatform.googleapis.com/online_prediction_requests","limit_name":"L1"}},
         "resource":{"labels":{"location":"us-central1"}},"points":[{"value":{"int64Value":"100"}}]}
        """), try json("""
        {"metric":{"labels":{"quota_metric":"aiplatform.googleapis.com/tokens","limit_name":"T"}},
         "resource":{"labels":{"location":"global"}},"points":[{"value":{"doubleValue":1000}}]}
        """)]
        let mapped = VertexAIUsage.map(usage: usage, limit: limit, project: "proj", email: "me@x.com")
        XCTAssertEqual(mapped.windows.first?.usedPercent ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(mapped.windows.first?.windowMinutes, 1440)
        XCTAssertEqual(mapped.organization, "proj")
        XCTAssertEqual(mapped.email, "me@x.com")
        XCTAssertTrue(VertexAIUsage.map(usage: nil, limit: nil, project: nil, email: nil).windows.isEmpty)
    }

    func testVertexIdentityAndProject() throws {
        let spec = ProviderCatalog.ide[2]
        let id = spec.files[0].id
        let withEmail = credential(id, #"{"type":"authorized_user","account":"Dev@X.com","refresh_token":"r"}"#)
        XCTAssertEqual(spec.identify?(withEmail), CredentialIdentity(key: "dev@x.com", email: "Dev@X.com"))
        let anonymous = credential(id, #"{"type":"authorized_user","refresh_token":"r1"}"#)
        XCTAssertEqual(spec.identify?(anonymous), spec.identify?(anonymous))
        XCTAssertNotEqual(spec.identify?(anonymous)?.key, spec.identify?(credential(id, #"{"refresh_token":"r2"}"#))?.key)
        XCTAssertEqual(VertexAIUsage.project(try json(#"{"quota_project_id":"qp"}"#), env: [:]), "qp")
        XCTAssertEqual(VertexAIUsage.project(try json("{}"), env: ["GOOGLE_CLOUD_PROJECT": "envp"]), "envp")
    }

    // MARK: Copilot

    func testCopilotMapsPremiumAndChatSnapshots() throws {
        let body = try json("""
        {"copilot_plan":"individual_pro","quota_reset_date":"2026-02-01T00:00:00Z","quota_snapshots":{
         "premium_interactions":{"entitlement":500,"remaining":450,"percent_remaining":90,"overage_permitted":true,"overage_count":3},
         "chat":{"entitlement":-1,"remaining":-1,"unlimited":true},
         "completions":{"entitlement":2000,"remaining":1500}}}
        """)
        let usage = try CopilotUsage.map(body)
        XCTAssertEqual(usage.windows.map(\.id), ["credits", "completions"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(usage.windows[1].usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(usage.windows[0].resetsAt, Fmt.iso("2026-02-01T00:00:00Z"))
        XCTAssertEqual(usage.plan, "Individual Pro")
        XCTAssertEqual(usage.sections.first?.rows.first?.label, "Extra usage")
    }

    func testCopilotLegacyFreeAndOrgSeat() throws {
        let free = try CopilotUsage.map(json(#"{"copilot_plan":"free","limited_user_reset_date":"2026-03-01","limited_user_quotas":{"chat":182},"monthly_quotas":{"chat":200}}"#))
        XCTAssertEqual(free.windows.first?.usedPercent ?? -1, 9, accuracy: 0.001)
        let org = try CopilotUsage.map(json(#"{"copilot_plan":"business","token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":0,"credits_used":12}}}"#))
        XCTAssertTrue(org.windows.isEmpty)
        XCTAssertEqual(org.sections.first?.rows.first?.value, "12")
        XCTAssertThrowsError(try CopilotUsage.map(json(#"{"copilot_plan":"free"}"#)))
    }

    func testCopilotIdentityFromAppsFile() {
        let spec = ProviderCatalog.ide[3]
        let id = spec.files[0].id
        let apps = #"{"github.example.com:Iv1.x":{"user":"corp","oauth_token":"gho_c"},"github.com:Iv1.b507a08c87ecfe98":{"user":"Octo","oauth_token":"gho_a","githubAppId":"Iv1.b507a08c87ecfe98"}}"#
        XCTAssertEqual(spec.identify?(credential(id, apps)), CredentialIdentity(key: "github:octo"))
        XCTAssertNil(spec.identify?(credential(id, #"{"github.example.com":{"oauth_token":"x"}}"#)))
    }

    // MARK: Cursor

    func testCursorMapsPoolsOnDemandAndCredits() throws {
        let usage = try json("""
        {"billingCycleStart":"1770000000000","billingCycleEnd":"1772592000000","enabled":true,
         "planUsage":{"limit":2000,"remaining":1500,"totalSpend":500,"totalPercentUsed":25,"autoPercentUsed":10,"apiPercentUsed":40},
         "spendLimitUsage":{"limitType":"individual","individualLimit":5000,"individualRemaining":4000,"individualUsed":1000}}
        """)
        let plan = try json(#"{"planInfo":{"planName":"Pro"}}"#)
        let credits = try json(#"{"hasCreditGrants":true,"totalCents":"1000","usedCents":"250"}"#)
        let mapped = try CursorUsage.map(usage: usage, plan: plan, credits: credits, membership: "pro", email: "c@x.com")
        XCTAssertEqual(mapped.windows.map(\.id), ["total", "auto", "api"])
        XCTAssertEqual(mapped.windows.map(\.usedPercent), [25, 10, 40])
        XCTAssertEqual(mapped.windows[0].windowMinutes, 43_200)
        XCTAssertEqual(mapped.windows[0].resetsAt, Date(timeIntervalSince1970: 1_772_592_000))
        XCTAssertEqual(mapped.cost?.used, 10)
        XCTAssertEqual(mapped.cost?.limit, 50)
        XCTAssertEqual(mapped.cost?.balance, 7.5)
        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(mapped.email, "c@x.com")
    }

    func testCursorTeamDollarsAndDisabled() throws {
        let team = try json(#"{"enabled":true,"planUsage":{"limit":2000,"totalSpend":500},"spendLimitUsage":{"limitType":"team","pooledLimit":10000}}"#)
        let mapped = try CursorUsage.map(usage: team, plan: nil, credits: nil, membership: "team", email: nil)
        XCTAssertEqual(mapped.windows.first?.usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(mapped.windows.first?.detail, "$5.00 / $20.00")
        XCTAssertThrowsError(try CursorUsage.map(usage: json(#"{"enabled":false}"#), plan: nil, credits: nil, membership: nil, email: nil))
    }

    func testCursorIdentityFromRows() {
        let spec = ProviderCatalog.ide[4]
        let rows = #"{"cursorAuth/accessToken":"\#(jwt(#"{"sub":"auth0|user_01ABC","exp":4102444800}"#))","cursorAuth/cachedEmail":"c@x.com","cursorAuth/stripeMembershipType":"pro_plus"}"#
        XCTAssertEqual(spec.identify?(credential(spec.files[0].id, rows)),
                       CredentialIdentity(key: "user_01ABC", email: "c@x.com", plan: "Pro Plus"))
        XCTAssertEqual(spec.files[0].sqliteTable, "ItemTable")
        XCTAssertTrue(spec.files[0].sqliteKeys.contains("cursorAuth/refreshToken"))
    }

    // MARK: Windsurf

    func testWindsurfProtoRejectsOversizedLengths() {
        // Field 1, wire type 2, then a 10-byte varint length of UInt64.max.
        let hostile = Data([0x0A] + [UInt8](repeating: 0xFF, count: 9) + [0x01])
        XCTAssertThrowsError(try WindsurfProto.fields(hostile))
        XCTAssertThrowsError(try WindsurfProto.fields(Data([0x0A, 0x05, 0x01])))
    }

    func testWindsurfProtoRoundTrip() throws {
        let request = WindsurfProto.encodeRequest(authToken: "tok")
        let decoded = try WindsurfProto.fields(request)
        XCTAssertEqual(decoded.map(\.0), [1, 2])
        XCTAssertEqual(decoded[0].1, .bytes(Data("tok".utf8)))
        XCTAssertEqual(decoded[1].1, .varint(1))

        let info = WindsurfProto.bytes(2, Data("Pro".utf8))
        let end = WindsurfProto.varint(1, 1_774_029_950)
        let status = WindsurfProto.bytes(1, info) + WindsurfProto.bytes(3, end) + WindsurfProto.varint(12, 0)
            + WindsurfProto.varint(14, 9) + WindsurfProto.varint(15, 54)
            + WindsurfProto.varint(17, 1_774_080_000) + WindsurfProto.varint(18, 1_774_166_400)
        let parsed = try WindsurfProto.decodeResponse(WindsurfProto.bytes(1, status))
        XCTAssertEqual(parsed.planName, "Pro")
        XCTAssertEqual(parsed.dailyRemaining, 9)
        XCTAssertEqual(parsed.weeklyReset, Date(timeIntervalSince1970: 1_774_166_400))
        XCTAssertEqual(parsed.planEnd, Date(timeIntervalSince1970: 1_774_029_950))
        XCTAssertThrowsError(try WindsurfProto.fields(Data([0x0A, 0x05, 0x41])))

        let usage = try WindsurfProto.map(parsed)
        XCTAssertEqual(usage.windows.map(\.id), ["daily", "weekly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [91, 46])
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_774_080_000))
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.sections.first?.rows.first?.label, "Plan ends")
    }

    func testWindsurfParsesJSONAndKeyValueSessions() throws {
        let fromJSON = try WindsurfProto.parseSession(#"{"devin_session_token":"s","devin_auth1_token":"a","devin_account_id":"acc","devin_primary_org_id":"org"}"#)
        XCTAssertEqual([fromJSON.token, fromJSON.auth1, fromJSON.account, fromJSON.org], ["s", "a", "acc", "org"])
        let fromLines = try WindsurfProto.parseSession("devin_session_token=s\ndevin_auth1_token=\"a\"\ndevin_account_id: acc\ndevin_primary_org_id=org")
        XCTAssertEqual([fromLines.token, fromLines.auth1, fromLines.account, fromLines.org], ["s", "a", "acc", "org"])
        XCTAssertThrowsError(try WindsurfProto.parseSession(#"{"devin_session_token":"s"}"#))
    }

    // MARK: JetBrains AI

    private let jetBrainsXML = """
    <application><component name="AIAssistantQuotaManager2">
    <option name="quotaInfo" value="{&quot;type&quot;:&quot;Available&quot;,&quot;current&quot;:&quot;9000000&quot;,&quot;maximum&quot;:&quot;9000000&quot;,&quot;tariffQuota&quot;:{&quot;current&quot;:&quot;250000&quot;,&quot;maximum&quot;:&quot;1000000&quot;,&quot;available&quot;:&quot;750000&quot;},&quot;topUpQuota&quot;:{&quot;current&quot;:&quot;0&quot;,&quot;maximum&quot;:&quot;500000&quot;,&quot;available&quot;:&quot;500000&quot;}}" />
    <option name="nextRefill" value="{&quot;type&quot;:&quot;Known&quot;,&quot;next&quot;:&quot;2026-11-09T21:00:00Z&quot;,&quot;tariff&quot;:{&quot;amount&quot;:&quot;1000000&quot;,&quot;duration&quot;:&quot;PT720H&quot;}}" />
    </component></application>
    """

    func testJetBrainsMapsTariffQuotaOnly() throws {
        let usage = try JetBrainsUsage.map(xml: jetBrainsXML, ide: "IntelliJIdea2026.1")
        XCTAssertEqual(usage.windows.first?.usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(usage.windows.first?.windowMinutes, 43_200)
        XCTAssertEqual(usage.windows.first?.resetsAt, Fmt.iso("2026-11-09T21:00:00Z"))
        XCTAssertEqual(usage.plan, "Available")
        XCTAssertEqual(usage.organization, "IntelliJIdea2026.1")
        XCTAssertEqual(usage.sections.first?.rows.first?.value, "5")
        XCTAssertThrowsError(try JetBrainsUsage.map(xml: "<application/>", ide: nil))
    }

    func testJetBrainsPicksNewestQuotaFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ide-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for (name, age) in [("PyCharm2025.3", -3600.0), ("WebStorm2026.1", 0)] {
            let options = home.appendingPathComponent("Library/Application Support/JetBrains/\(name)/options")
            try FileManager.default.createDirectory(at: options, withIntermediateDirectories: true)
            let file = options.appendingPathComponent("AIAssistantQuotaManager2.xml")
            try jetBrainsXML.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: file.path)
        }
        XCTAssertEqual(try JetBrainsUsage.newestQuotaFile(home: home).1, "WebStorm2026.1")
        XCTAssertThrowsError(try JetBrainsUsage.newestQuotaFile(home: home.appendingPathComponent("none")))
    }
}
