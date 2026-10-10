import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Generic provider layer. Every provider beyond the Codex and Grok transaction engines
// is a `ProviderSpec`: a credential style plus one async `fetch` that returns `ProviderUsage`.
// Usage shapes follow CodexBar's plugin snapshot and OpenUsage's provider snapshot, trimmed.

// MARK: - Usage

public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Consumed share, 0...100. Nil keeps the reset visible without inventing a value.
    public var usedPercent: Double?
    public var resetsAt: Date?
    public var windowMinutes: Int?
    /// Short amount text such as "120 / 500 requests".
    public var detail: String?

    public init(id: String, title: String, usedPercent: Double?, resetsAt: Date? = nil,
                windowMinutes: Int? = nil, detail: String? = nil) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent.map { min(max($0, 0), 100) }
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
        self.detail = detail
    }

    /// Builds a window from used and limit amounts; nil when the limit is not positive.
    public static func amounts(id: String, title: String, used: Double, limit: Double,
                               resetsAt: Date? = nil, windowMinutes: Int? = nil,
                               unit: String? = nil) -> UsageWindow? {
        guard limit > 0, used.isFinite, limit.isFinite else { return nil }
        let text = unit.map { "\(Fmt.number(used)) / \(Fmt.number(limit)) \($0)" }
        return .init(id: id, title: title, usedPercent: used / limit * 100, resetsAt: resetsAt,
                     windowMinutes: windowMinutes, detail: text)
    }
}

public struct UsageRow: Codable, Equatable, Sendable {
    public var label: String
    public var value: String
    /// Consumed fraction, 0...1.
    public var progress: Double?

    public init(_ label: String, _ value: String, progress: Double? = nil) {
        self.label = label
        self.value = value
        self.progress = progress.map { min(max($0, 0), 1) }
    }
}

public struct UsageSection: Codable, Equatable, Sendable {
    public var title: String?
    public var rows: [UsageRow]

    public init(_ title: String?, _ rows: [UsageRow]) {
        self.title = title
        self.rows = rows
    }
}

public struct UsageCost: Codable, Equatable, Sendable {
    public var used: Double?
    public var limit: Double?
    /// Remaining prepaid balance or credits.
    public var balance: Double?
    public var currency: String
    public var period: String?
    public var resetsAt: Date?

    public init(used: Double? = nil, limit: Double? = nil, balance: Double? = nil,
                currency: String = "USD", period: String? = nil, resetsAt: Date? = nil) {
        self.used = used
        self.limit = limit
        self.balance = balance
        self.currency = currency
        self.period = period
        self.resetsAt = resetsAt
    }
}

public struct ProviderUsage: Codable, Equatable, Sendable {
    public var windows: [UsageWindow]
    public var cost: UsageCost?
    public var sections: [UsageSection]
    public var plan: String?
    public var email: String?
    public var organization: String?
    public var fetchedAt: Date

    public init(windows: [UsageWindow] = [], cost: UsageCost? = nil, sections: [UsageSection] = [],
                plan: String? = nil, email: String? = nil, organization: String? = nil,
                fetchedAt: Date = Date()) {
        self.windows = windows
        self.cost = cost
        self.sections = sections.filter { !$0.rows.isEmpty }
        self.plan = plan
        self.email = email
        self.organization = organization
        self.fetchedAt = fetchedAt
    }

    public var isEmpty: Bool {
        windows.isEmpty && cost == nil && sections.isEmpty && plan == nil && email == nil
    }

    /// Provider text with control characters replaced, so a hostile response cannot inject
    /// terminal escape sequences into the TUI or CLI output.
    public func sanitized() -> ProviderUsage {
        var copy = self
        copy.windows = windows.map {
            var window = $0
            window.id = window.id.printable
            window.title = window.title.printable
            window.detail = window.detail?.printable
            return window
        }
        copy.sections = sections.map { section in
            UsageSection(section.title?.printable, section.rows.map {
                var row = $0
                row.label = row.label.printable
                row.value = row.value.printable
                return row
            })
        }
        copy.cost?.currency = cost?.currency.printable ?? "USD"
        copy.cost?.period = cost?.period?.printable
        copy.plan = plan?.printable
        copy.email = email?.printable
        copy.organization = organization?.printable
        return copy
    }
}

extension String {
    /// Replaces C0, DEL, and C1 control characters with spaces.
    public var printable: String {
        String(String.UnicodeScalarView(unicodeScalars.map {
            $0.value < 0x20 || (0x7F...0x9F).contains($0.value) ? " " : $0
        }))
    }
}

// MARK: - Credentials

/// How a provider account is stored and what Switching changes.
public enum CredentialStyle: String, Codable, Sendable {
    /// Typed secrets (API key, bearer token, pasted Cookie header). Switching selects the default.
    case secret
    /// CLI-owned files in the provider's home. Switching swaps only these files; conversations stay.
    case files
}

public struct CredentialField: Sendable, Equatable {
    public let key: String
    public let title: String
    public let secure: Bool
    public let optional: Bool
    public let placeholder: String?
    /// Environment variables that may prefill the field during import.
    public let env: [String]

    public init(_ key: String, _ title: String, secure: Bool = true, optional: Bool = false,
                placeholder: String? = nil, env: [String] = []) {
        self.key = key
        self.title = title
        self.secure = secure
        self.optional = optional
        self.placeholder = placeholder
        self.env = env
    }

    public static func apiKey(_ env: String...) -> CredentialField {
        .init("apiKey", "API key", env: env)
    }
    public static func token(_ title: String = "Access token", env: String...) -> CredentialField {
        .init("token", title, env: env)
    }
    public static func cookie(_ hint: String) -> CredentialField {
        .init("cookie", "Cookie header", placeholder: hint)
    }
}

/// A CLI-owned credential. `path` is relative to the user's home directory, such as
/// ".grok/auth.json". When `$homeEnv` is set, its value replaces the parent directory (every
/// component before the file name), so GROK_HOME=/x resolves ".grok/auth.json" to
/// "/x/auth.json" and CLOUDSDK_CONFIG=/y resolves ".config/gcloud/adc.json" to "/y/adc.json".
/// - `key`: the account owns only that top-level JSON member, for shared files such as
///   OpenCode's or Kilo's auth.json.
/// - `sqliteTable` + `sqliteKeys`: the account owns only those rows of a `key`/`value` table,
///   for app databases such as Cursor's state.vscdb or Kiro's data.sqlite3.
public struct LiveFile: Sendable, Equatable {
    public let path: String
    public let homeEnv: String?
    public let optional: Bool
    public let key: String?
    public let sqliteTable: String?
    public let sqliteKeys: [String]

    public init(_ path: String, homeEnv: String? = nil, optional: Bool = false, key: String? = nil) {
        self.path = path
        self.homeEnv = homeEnv
        self.optional = optional
        self.key = key
        self.sqliteTable = nil
        self.sqliteKeys = []
    }

    public init(sqlite path: String, table: String, keys: [String], optional: Bool = false) {
        self.path = path
        self.homeEnv = nil
        self.optional = optional
        self.key = nil
        self.sqliteTable = table
        self.sqliteKeys = keys
    }

    /// Key into `ProviderCredential.files`.
    public var id: String {
        if let key { return "\(path)#\(key)" }
        if let sqliteTable { return "\(path)#\(sqliteTable)" }
        return path
    }
}

public struct ProviderCredential: Codable, Equatable, Sendable {
    public var fields: [String: String]
    /// LiveFile.id -> bytes. Whole file bytes; the JSON member for `key`; or a JSON object of
    /// `{row key: row value}` for SQLite rows.
    public var files: [String: Data]
    /// True when these bytes were read from the provider's live home. The official CLI also
    /// holds them, so a fetch must not spend a single-use refresh token; it may only read.
    /// Never stored.
    public var isLive = false

    public init(fields: [String: String] = [:], files: [String: Data] = [:], isLive: Bool = false) {
        self.fields = fields
        self.files = files
        self.isLive = isLive
    }

    private enum CodingKeys: String, CodingKey { case fields, files }

    public subscript(_ key: String) -> String? {
        guard let value = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    public func require(_ key: String, _ message: String? = nil) throws -> String {
        guard let value = self[key] else {
            throw ProviderError.missingCredential(message ?? "Add the \(key) for this account.")
        }
        return value
    }

    public func json(_ path: String) -> JSON? {
        files[path].flatMap { try? JSONSerialization.jsonObject(with: $0) }.map(JSON.init)
    }
}

/// Offline identity read from a credential, used to name accounts and detect the live one.
public struct CredentialIdentity: Equatable, Sendable {
    public var key: String
    public var email: String?
    public var plan: String?

    public init(key: String, email: String? = nil, plan: String? = nil) {
        self.key = key
        self.email = email
        self.plan = plan
    }
}

public struct FetchResult: Sendable {
    public var usage: ProviderUsage
    /// Refreshed credential to persist, for example rotated OAuth tokens.
    public var updated: ProviderCredential?

    public init(_ usage: ProviderUsage, updated: ProviderCredential? = nil) {
        self.usage = usage
        self.updated = updated
    }
}

public struct ProviderSpec: Sendable, Identifiable {
    public typealias Fetch = @Sendable (ProviderCredential) async throws -> FetchResult
    public typealias Identify = @Sendable (ProviderCredential) -> CredentialIdentity?

    public let id: ProviderID
    public let name: String
    public let style: CredentialStyle
    public let fields: [CredentialField]
    public let files: [LiveFile]
    /// Official sign-in command, for `files` providers. Switch runs it in Terminal with HOME and
    /// every `LiveFile.homeEnv` pointed at a private temporary home, then imports from there.
    public let login: [String]?
    /// Extra environment for the sign-in command, such as SSH_TTY=1 to force file storage.
    public let loginEnv: [String: String]
    public let dashboard: URL?
    /// Statuspage.io base such as https://status.openai.com.
    public let statusPage: URL?
    public let identify: Identify?
    public let fetch: Fetch

    public init(id: String, name: String, style: CredentialStyle = .secret,
                fields: [CredentialField] = [], files: [LiveFile] = [], login: [String]? = nil,
                loginEnv: [String: String] = [:], dashboard: String? = nil, statusPage: String? = nil,
                identify: Identify? = nil, fetch: @escaping Fetch) {
        self.id = ProviderID(rawValue: id)
        self.name = name
        self.style = style
        self.fields = fields
        self.files = files
        self.login = login
        self.loginEnv = loginEnv
        self.dashboard = dashboard.flatMap(URL.init(string:))
        self.statusPage = statusPage.flatMap(URL.init(string:))
        self.identify = identify
        self.fetch = fetch
    }

    /// Convenience for providers that never refresh credentials.
    public init(id: String, name: String, style: CredentialStyle = .secret,
                fields: [CredentialField] = [], files: [LiveFile] = [], login: [String]? = nil,
                loginEnv: [String: String] = [:], dashboard: String? = nil, statusPage: String? = nil,
                identify: Identify? = nil,
                usage: @escaping @Sendable (ProviderCredential) async throws -> ProviderUsage) {
        self.init(id: id, name: name, style: style, fields: fields, files: files, login: login,
                  loginEnv: loginEnv, dashboard: dashboard, statusPage: statusPage, identify: identify,
                  fetch: { FetchResult(try await usage($0)) })
    }
}

// MARK: - Errors

public enum ProviderError: LocalizedError, Equatable, Sendable {
    case missingCredential(String)
    case unauthorized(String)
    case rateLimited(String)
    case unavailable(String)
    case http(Int, String)
    case parse(String)
    case network(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let text), .unauthorized(let text), .rateLimited(let text),
             .unavailable(let text), .parse(let text), .network(let text), .unsupported(let text):
            text.printable
        case .http(let code, let text):
            text.isEmpty ? "The provider returned HTTP \(code)." : text.printable
        }
    }

    /// True when the account needs a new sign-in or key.
    public var needsSignIn: Bool {
        switch self {
        case .unauthorized, .missingCredential: true
        default: false
        }
    }
}

// MARK: - HTTP

public struct HTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public let headers: [String: String]

    public var text: String { String(decoding: data, as: UTF8.self) }
    public func json() throws -> JSON {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ProviderError.parse("The provider returned data that is not JSON.")
        }
        return JSON(value)
    }
}

public enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: SameHostRedirects(), delegateQueue: nil)
    }()

    /// Follows redirects only within the original host, so keys and cookies never leave it.
    private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            let from = task.originalRequest?.url
            let to = request.url
            let same = to?.host == from?.host && (to?.scheme == "https" || to?.scheme == from?.scheme)
            completionHandler(same ? request : nil)
        }
    }

    public static let userAgent = "Switch/3 (macOS)"

    /// Sends one request and returns any status. Network failures throw `ProviderError.network`.
    public static func send(_ url: String, method: String = "GET", headers: [String: String] = [:],
                            body: Data? = nil) async throws -> HTTPResponse {
        guard let target = URL(string: url),
              target.scheme == "https" || (target.scheme == "http" && isPrivate(target.host)) else {
            throw ProviderError.unsupported("Refusing a non-HTTPS provider URL.")
        }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            var fields: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                fields[String(describing: key).lowercased()] = String(describing: value)
            }
            return .init(status: http?.statusCode ?? 0, data: data, headers: fields)
        } catch {
            throw ProviderError.network("The provider could not be reached. Check the network and try again.")
        }
    }

    /// Sends one request and requires 2xx. Maps 401/403 to `unauthorized` and 429 to `rateLimited`.
    public static func json(_ url: String, method: String = "GET", headers: [String: String] = [:],
                            body: Data? = nil) async throws -> JSON {
        let response = try await send(url, method: method, headers: headers, body: body)
        try check(response)
        return try response.json()
    }

    public static func json(_ url: String, method: String = "POST", headers: [String: String] = [:],
                            object: Any) async throws -> JSON {
        let body = try JSONSerialization.data(withJSONObject: object)
        return try await json(url, method: method, headers: headers, body: body)
    }

    public static func check(_ response: HTTPResponse) throws {
        switch response.status {
        case 200..<300: return
        case 401, 403:
            throw ProviderError.unauthorized("The provider rejected this credential. Sign in again or replace it.")
        case 429:
            throw ProviderError.rateLimited("The provider is rate limiting usage checks. Switch will retry later.")
        case 500...:
            throw ProviderError.unavailable("The provider is unavailable (HTTP \(response.status)).")
        default:
            throw ProviderError.http(response.status, "")
        }
    }

    /// Loopback, RFC 1918 and `.local` hosts, where self-hosted gateways may use plain HTTP.
    static func isPrivate(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    public static func bearer(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)"]
    }

    public static func form(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return values.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}

// MARK: - JSON

/// Small dynamic JSON reader. Missing keys and wrong types read as nil.
public struct JSON: @unchecked Sendable {
    public let raw: Any?

    public init(_ raw: Any?) { self.raw = raw is NSNull ? nil : raw }

    public init(data: Data) throws {
        self.init(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public subscript(_ key: String) -> JSON { JSON((raw as? [String: Any])?[key]) }
    public subscript(_ index: Int) -> JSON {
        guard let array = raw as? [Any], array.indices.contains(index) else { return JSON(nil) }
        return JSON(array[index])
    }

    /// Dotted path lookup, such as "data.quota.used".
    public func at(_ path: String) -> JSON {
        path.split(separator: ".").reduce(self) { $0[String($1)] }
    }

    public var exists: Bool { raw != nil }
    public var string: String? {
        switch raw {
        case let value as String: value.isEmpty ? nil : value
        case let value as NSNumber where !(raw is Bool): value.stringValue
        default: nil
        }
    }
    public var double: Double? {
        switch raw {
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID(): value.doubleValue
        case let value as String: Double(value.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
    public var int: Int? { double.flatMap { $0.isFinite ? Int($0) : nil } }
    public var bool: Bool? {
        switch raw {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: ["true", "1", "yes"].contains(value.lowercased())
        default: nil
        }
    }
    public var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
    public var object: [String: JSON] { (raw as? [String: Any])?.mapValues(JSON.init) ?? [:] }
    /// ISO-8601 text or Unix seconds/milliseconds.
    public var date: Date? { Fmt.date(raw) }
}

// MARK: - Formatting and parsing helpers

public enum Fmt {
    public static func number(_ value: Double, digits: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : max(digits, 2)
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func money(_ value: Double, currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? "\(currency) \(value)"
    }

    public static func percent(_ used: Double, of limit: Double) -> Double? {
        guard limit > 0 else { return nil }
        return used / limit * 100
    }

    public static func date(_ raw: Any?) -> Date? {
        switch raw {
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID():
            return epoch(value.doubleValue)
        case let value as String:
            if let number = Double(value) { return epoch(number) }
            return iso(value)
        default:
            return nil
        }
    }

    public static func epoch(_ value: Double) -> Date? {
        guard value > 0, value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    public static func iso(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // Trim sub-millisecond precision such as 2026-01-01T00:00:00.123456789Z.
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { "Z+-".contains($0) }) {
            let trimmed = String(text[..<dot]) + "." + text[text.index(after: dot)..<zone].prefix(3) + text[zone...]
            return fractional.date(from: trimmed)
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            day.dateFormat = format
            if let date = day.date(from: text) { return date }
        }
        return nil
    }

    /// Decodes the claims of a JWT without verifying it.
    public static func jwtClaims(_ token: String) -> JSON? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSON(object)
    }

    /// Value of one cookie in a Cookie header.
    public static func cookie(_ name: String, in header: String) -> String? {
        header.split(separator: ";").lazy.compactMap { part -> String? in
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return pair.count == 2 && pair[0] == name ? pair[1] : nil
        }.first
    }
}
