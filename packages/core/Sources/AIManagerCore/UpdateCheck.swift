import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The update check: one anonymous GET to the release server. The request carries only the platform,
// the version, the derived build, and a once-a-day (d=1) and once-a-month (m=1) counting flag.

public struct UpdateInfo: Decodable, Equatable, Sendable {
    public let app, platform, version: String
    public let build: Int
    public let url: String
    public let notes: String?
    /// True when the installed build is below the server's minimum. Decoded only; nothing acts on it yet.
    public let required: Bool
}

/// What the app keeps between launches. Day and month change only after a 2xx reply, so a failed
/// check never loses a count; the attempt time throttles retries against a failing server.
public struct UpdateCheckState: Codable, Equatable, Sendable {
    public var lastAttempt: Date?
    public var lastDay: String?    // YYYY-MM-DD, local
    public var lastMonth: String?  // YYYY-MM, local

    public init(lastAttempt: Date? = nil, lastDay: String? = nil, lastMonth: String? = nil) {
        self.lastAttempt = lastAttempt
        self.lastDay = lastDay
        self.lastMonth = lastMonth
    }
}

public enum UpdateCheck {
    public static let endpoint = "https://apps.mandalsuraj.com/v1/switch/latest"
    public static let minimumInterval: TimeInterval = 6 * 3600
    public static let timeout: TimeInterval = 8

    /// `major * 1_000_000 + minor * 1_000 + patch`: 3.9.5 is 3009005. Nil unless the version is
    /// three whole numbers and minor and patch stay under 1000.
    public static func buildNumber(version: String) -> Int? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            part.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(part) : nil
        }
        guard numbers.count == 3, numbers[1] < 1000, numbers[2] < 1000 else { return nil }
        return numbers[0] * 1_000_000 + numbers[1] * 1_000 + numbers[2]
    }

    /// Due after 6 hours since the last attempt, or on the first attempt of a new local day.
    public static func isDue(state: UpdateCheckState, now: Date, calendar: Calendar) -> Bool {
        guard let last = state.lastAttempt else { return true }
        return now.timeIntervalSince(last) >= minimumInterval || !calendar.isDate(last, inSameDayAs: now)
    }

    public static func requestURL(
        version: String, state: UpdateCheckState, now: Date, calendar: Calendar
    ) -> URL? {
        guard let build = buildNumber(version: version), var parts = URLComponents(string: endpoint) else { return nil }
        let (day, month) = keys(now: now, calendar: calendar)
        var items = [
            URLQueryItem(name: "platform", value: "macos"),
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "build", value: String(build)),
        ]
        if state.lastDay != day { items.append(URLQueryItem(name: "d", value: "1")) }
        if state.lastMonth != month { items.append(URLQueryItem(name: "m", value: "1")) }
        parts.queryItems = items
        return parts.url
    }

    /// Call after a 2xx reply: the day and month of this check are now counted.
    public static func recordSuccess(_ state: inout UpdateCheckState, now: Date, calendar: Calendar) {
        let (day, month) = keys(now: now, calendar: calendar)
        state.lastDay = day
        state.lastMonth = month
    }

    public static func isNewer(_ info: UpdateInfo, installedVersion: String) -> Bool {
        guard let installed = buildNumber(version: installedVersion) else { return false }
        return info.build > installed
    }

    /// The server's link, only when it is https: anything else is never opened.
    public static func downloadURL(_ info: UpdateInfo) -> URL? {
        guard let url = URL(string: info.url), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// A 2xx body that decodes; nil for any other status or body.
    public static func parse(status: Int, data: Data) -> UpdateInfo? {
        guard (200..<300).contains(status) else { return nil }
        return try? JSONDecoder().decode(UpdateInfo.self, from: data)
    }

    /// One check with an 8 second limit. Nil on any error, so the caller stays silent. HTTP.session
    /// takes no cookies and follows redirects only within the host.
    public static func fetch(
        _ url: URL,
        send: @escaping @Sendable (String) async throws -> HTTPResponse = { try await HTTP.send($0) }
    ) async -> UpdateInfo? {
        guard url.scheme == "https" else { return nil }
        let response = try? await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            group.addTask { try await send(url.absoluteString) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        return response.flatMap { parse(status: $0.status, data: $0.data) }
    }

    private static func keys(now: Date, calendar: Calendar) -> (day: String, month: String) {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        let month = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        return ("\(month)-" + String(format: "%02d", c.day ?? 0), month)
    }
}
