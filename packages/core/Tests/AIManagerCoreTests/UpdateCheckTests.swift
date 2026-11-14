import XCTest
@testable import AIManagerCore

final class UpdateCheckTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ iso: String) -> Date { Fmt.iso(iso)! }

    private let body = #"""
    {"app":"switch","platform":"macos","version":"3.10.0","build":3010000,
     "url":"https://apps.mandalsuraj.com/d/Switch-3.10.0.dmg","notes":"Fixes","required":false}
    """#

    private func info(build: Int = 3_010_000, url: String = "https://example.com/a.dmg") -> UpdateInfo {
        UpdateInfo(app: "switch", platform: "macos", version: "3.10.0", build: build, url: url, notes: nil, required: false)
    }

    func testBuildNumber() {
        XCTAssertEqual(UpdateCheck.buildNumber(version: "3.9.5"), 3_009_005)
        XCTAssertEqual(UpdateCheck.buildNumber(version: "0.1.0"), 1_000)
        XCTAssertNil(UpdateCheck.buildNumber(version: "3.9"))
        XCTAssertNil(UpdateCheck.buildNumber(version: "3.9.5.1"))
        XCTAssertNil(UpdateCheck.buildNumber(version: "3.9.x"))
        XCTAssertNil(UpdateCheck.buildNumber(version: "3.9.-1"))
        XCTAssertNil(UpdateCheck.buildNumber(version: "3.1000.0"))
        XCTAssertNil(UpdateCheck.buildNumber(version: ""))
    }

    func testCountingFlagsAndRecordedState() throws {
        var state = UpdateCheckState()
        let first = date("2026-11-14T10:00:00Z")
        var url = try XCTUnwrap(UpdateCheck.requestURL(version: "3.9.5", state: state, now: first, calendar: calendar))
        XCTAssertEqual(url.absoluteString,
                       "https://apps.mandalsuraj.com/v1/switch/latest?platform=macos&version=3.9.5&build=3009005&d=1&m=1")

        // A failed check records nothing, so the next request still counts.
        url = try XCTUnwrap(UpdateCheck.requestURL(version: "3.9.5", state: state, now: first, calendar: calendar))
        XCTAssertTrue(url.query!.hasSuffix("&d=1&m=1"))

        UpdateCheck.recordSuccess(&state, now: first, calendar: calendar)
        XCTAssertEqual(state.lastDay, "2026-11-14")
        XCTAssertEqual(state.lastMonth, "2026-11")
        let second = try XCTUnwrap(UpdateCheck.requestURL(
            version: "3.9.5", state: state, now: first.addingTimeInterval(7 * 3600), calendar: calendar))
        XCTAssertEqual(second.query, "platform=macos&version=3.9.5&build=3009005")

        let nextDay = try XCTUnwrap(UpdateCheck.requestURL(
            version: "3.9.5", state: state, now: date("2026-11-15T09:00:00Z"), calendar: calendar))
        XCTAssertTrue(nextDay.query!.hasSuffix("&d=1"))
        let nextMonth = try XCTUnwrap(UpdateCheck.requestURL(
            version: "3.9.5", state: state, now: date("2026-12-01T09:00:00Z"), calendar: calendar))
        XCTAssertTrue(nextMonth.query!.hasSuffix("&d=1&m=1"))
        XCTAssertNil(UpdateCheck.requestURL(version: "bad", state: state, now: first, calendar: calendar))
    }

    func testDueRule() {
        let last = date("2026-11-14T08:00:00Z")
        let state = UpdateCheckState(lastAttempt: last)
        XCTAssertTrue(UpdateCheck.isDue(state: UpdateCheckState(), now: last, calendar: calendar))
        XCTAssertFalse(UpdateCheck.isDue(state: state, now: last.addingTimeInterval(5 * 3600 + 3599), calendar: calendar))
        XCTAssertTrue(UpdateCheck.isDue(state: state, now: last.addingTimeInterval(6 * 3600), calendar: calendar))
        XCTAssertTrue(UpdateCheck.isDue(state: state, now: date("2026-11-15T00:30:00Z"), calendar: calendar))
        XCTAssertTrue(UpdateCheck.isDue(state: state, now: last.addingTimeInterval(-3600), calendar: calendar))  // clock moved back
    }

    func testNewerAndDownloadURL() {
        XCTAssertTrue(UpdateCheck.isNewer(info(), installedVersion: "3.9.5"))
        XCTAssertFalse(UpdateCheck.isNewer(info(), installedVersion: "3.10.0"))
        XCTAssertFalse(UpdateCheck.isNewer(info(), installedVersion: "4.0.0"))
        XCTAssertFalse(UpdateCheck.isNewer(info(), installedVersion: "dev"))
        XCTAssertEqual(UpdateCheck.downloadURL(info())?.absoluteString, "https://example.com/a.dmg")
        XCTAssertNil(UpdateCheck.downloadURL(info(url: "http://example.com/a.dmg")))
        XCTAssertNil(UpdateCheck.downloadURL(info(url: "file:///etc/passwd")))
        XCTAssertNil(UpdateCheck.downloadURL(info(url: "javascript:alert(1)")))
        XCTAssertNil(UpdateCheck.downloadURL(info(url: "not a url")))
    }

    func testParseAndFetch() async throws {
        let ok = try XCTUnwrap(UpdateCheck.parse(status: 200, data: Data(body.utf8)))
        XCTAssertEqual(ok.build, 3_010_000)
        XCTAssertEqual(ok.notes, "Fixes")
        XCTAssertFalse(ok.required)
        XCTAssertNil(UpdateCheck.parse(status: 404, data: Data(#"{"error":"No release published"}"#.utf8)))
        XCTAssertNil(UpdateCheck.parse(status: 200, data: Data("not json".utf8)))

        let url = try XCTUnwrap(URL(string: "https://apps.mandalsuraj.com/v1/switch/latest?platform=macos"))
        let sample = body
        let found = await UpdateCheck.fetch(url) { _ in .init(status: 200, data: Data(sample.utf8), headers: [:]) }
        XCTAssertTrue(found.counted)
        XCTAssertEqual(found.info?.version, "3.10.0")
        let missing = await UpdateCheck.fetch(url) { _ in
            .init(status: 404, data: Data(#"{"error":"No release published"}"#.utf8), headers: [:])
        }
        XCTAssertFalse(missing.counted)
        XCTAssertNil(missing.info)
        let failed = await UpdateCheck.fetch(url) { _ in throw ProviderError.network("down") }
        XCTAssertFalse(failed.counted)
        XCTAssertNil(failed.info)
        // The server counts any 2xx, so a bad body still records the day and month, and shows no update.
        let garbled = await UpdateCheck.fetch(url) { _ in .init(status: 200, data: Data("<html>".utf8), headers: [:]) }
        XCTAssertTrue(garbled.counted)
        XCTAssertNil(garbled.info)
        let plain = await UpdateCheck.fetch(try XCTUnwrap(URL(string: "http://apps.mandalsuraj.com/x"))) { _ in
            .init(status: 200, data: Data(sample.utf8), headers: [:])
        }
        XCTAssertFalse(plain.counted)
        XCTAssertNil(plain.info)
    }
}
