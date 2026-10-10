import XCTest
@testable import AIManagerCore

final class ProviderStatusTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testStatuspageStatusJSON() throws {
        let incident = try XCTUnwrap(ProviderStatusFetcher.parseStatuspage(data(#"""
        {"page":{"id":"x","updated_at":"2026-03-10T12:30:45.123Z"},
         "status":{"indicator":"minor","description":"Partially Degraded Service"}}
        """#)))
        XCTAssertEqual(incident.indicator, .minor)
        XCTAssertEqual(incident.description, "Partially Degraded Service")
        XCTAssertEqual(incident.updatedAt, Fmt.iso("2026-03-10T12:30:45.123Z"))

        let plain = try XCTUnwrap(ProviderStatusFetcher.parseStatuspage(data(#"""
        {"page":{"updated_at":"2026-03-10T12:30:45Z"},"status":{"indicator":"none","description":"All Systems Operational"}}
        """#)))
        XCTAssertEqual(plain.indicator, .none)
        XCTAssertNotNil(plain.updatedAt)

        XCTAssertEqual(ProviderStatusFetcher.parseStatuspage(data(#"{"status":{"indicator":"weird"}}"#))?.indicator, .unknown)
        XCTAssertNil(ProviderStatusFetcher.parseStatuspage(data("not json")))
        XCTAssertNil(ProviderStatusFetcher.parseStatuspage(data(#"{"page":{}}"#)))
    }

    private let incidentIO = #"""
    {"summary":{
      "affected_components":[
        {"component_id":"c-chat","status":"full_outage"},
        {"component_id":"c-codex","status":"degraded_performance"},
        {"component_id":"c-resp","status":"partial_outage"}],
      "structure":{"items":[
        {"group":{"id":"g1","name":"APIs","hidden":false,"components":[
           {"component_id":"c-resp","name":"Responses"},{"component_id":"c-img","name":"Images"}]}},
        {"group":{"id":"g2","name":"ChatGPT","hidden":false,"components":[
           {"component_id":"c-chat","name":"Login"}]}},
        {"group":{"id":"g3","name":"Codex","hidden":false,"components":[
           {"component_id":"c-codex","name":"Codex Web"},{"component_id":"c-cli","name":"CLI","hidden":true}]}}
      ]}}}
    """#

    func testIncidentIOUsesWorstCodexOrAPIsLeaf() throws {
        // ChatGPT is a full outage but not a Codex/APIs group; Responses (partial_outage) wins.
        let incident = try XCTUnwrap(ProviderStatusFetcher.parseIncidentIO(data(incidentIO)))
        XCTAssertEqual(incident.indicator, .major)
        XCTAssertNil(incident.description)
    }

    func testIncidentIOFallsBackToAllLeavesAndRejectsEmpty() throws {
        let other = #"""
        {"summary":{"affected_components":[{"component_id":"a","status":"under_maintenance"}],
         "structure":{"items":[{"component":{"component_id":"a","name":"Web"}},
                               {"component":{"component_id":"b","name":"Api"}}]}}}
        """#
        XCTAssertEqual(ProviderStatusFetcher.parseIncidentIO(data(other))?.indicator, .maintenance)
        XCTAssertNil(ProviderStatusFetcher.parseIncidentIO(data(#"{"summary":{"structure":{"items":[]}}}"#)))
        XCTAssertNil(ProviderStatusFetcher.parseIncidentIO(data("[]")))
    }

    func testComponentStatusMapping() {
        let map = ProviderStatusFetcher.indicator(forComponentStatus:)
        XCTAssertEqual(map("operational"), .none)
        XCTAssertEqual(map("degraded_performance"), .minor)
        XCTAssertEqual(map("partial_outage"), .major)
        XCTAssertEqual(map("major_outage"), .critical)
        XCTAssertEqual(map("full_outage"), .critical)
        XCTAssertEqual(map("under_maintenance"), .maintenance)
        XCTAssertEqual(map("???"), .unknown)
    }

    private let google = #"""
    [
     {"begin":"2026-03-01T00:00:00Z","end":"2026-03-01T02:00:00Z","status_impact":"SERVICE_OUTAGE","severity":"high",
      "currently_affected_products":[{"title":"Gemini","id":"npdyhgECDJ6tB66MxXyo"}]},
     {"begin":"2026-03-10T08:00:00Z","modified":"2026-03-10T09:00:00Z","status_impact":"SERVICE_INFORMATION","severity":"low",
      "external_desc":"fallback text",
      "currently_affected_products":[{"title":"Gemini","id":"npdyhgECDJ6tB66MxXyo"}],
      "most_recent_update":{"when":"2026-03-10T09:30:00Z","status":"SERVICE_DISRUPTION",
        "text":"**Summary**\n- Elevated [error rates](https://x.test) in **Gemini**\nMore detail"}},
     {"begin":"2026-03-10T08:00:00Z","status_impact":"SERVICE_OUTAGE",
      "currently_affected_products":[{"title":"Gmail","id":"other-product"}]},
     {"begin":"2026-03-10T07:00:00Z","status_impact":"SERVICE_MAINTENANCE","affected_products":[{"id":"npdyhgECDJ6tB66MxXyo"}],
      "updates":[{"when":"2026-03-10T07:05:00Z","status":"SCHEDULED_MAINTENANCE","text":"Planned work"}]}
    ]
    """#

    func testGoogleWorkspaceActiveWorstIncident() throws {
        let incident = try XCTUnwrap(ProviderStatusFetcher.parseGoogleWorkspace(
            data(google), productID: ProviderStatusFetcher.googleProductID))
        // Ended outage and other-product outage are ignored; the disruption outranks maintenance.
        XCTAssertEqual(incident.indicator, .major)
        XCTAssertEqual(incident.description, "Elevated error rates in Gemini")
        XCTAssertEqual(incident.updatedAt, Fmt.iso("2026-03-10T09:30:00Z"))
    }

    func testGoogleWorkspaceNoActiveIncidentAndSeverityFallback() throws {
        let ended = #"""
        [{"begin":"2026-03-01T00:00:00Z","end":"2026-03-01T02:00:00Z","status_impact":"SERVICE_OUTAGE",
          "currently_affected_products":[{"id":"npdyhgECDJ6tB66MxXyo"}]}]
        """#
        XCTAssertEqual(ProviderStatusFetcher.parseGoogleWorkspace(data(ended), productID: "npdyhgECDJ6tB66MxXyo"),
                       ProviderIncident(indicator: .none))
        let bySeverity = #"""
        [{"begin":"2026-03-01T00:00:00Z","severity":"high","external_desc":"Outage",
          "currently_affected_products":[{"id":"p"}]}]
        """#
        let incident = try XCTUnwrap(ProviderStatusFetcher.parseGoogleWorkspace(data(bySeverity), productID: "p"))
        XCTAssertEqual(incident.indicator, .critical)
        XCTAssertEqual(incident.description, "Outage")
        XCTAssertNil(ProviderStatusFetcher.parseGoogleWorkspace(data(#"{"a":1}"#), productID: "p"))
    }

    func testStatusPageTable() {
        for id in ["claude-code", "cursor", "copilot", "factory", "augment", "huggingface"] {
            XCTAssertNotNil(ProviderStatusFetcher.statusPages[id].flatMap(URL.init(string:)), id)
        }
        XCTAssertTrue(ProviderStatusFetcher.openAIProviders.contains(ProviderID.codex.rawValue))
    }

    func testFetchReturnsNilWithoutFeed() async {
        let nothing = await ProviderStatusFetcher.fetch(ProviderID(rawValue: "no-such-provider"), statusPage: nil)
        XCTAssertNil(nothing)
    }
}
