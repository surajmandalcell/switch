import AIManagerCore
import Foundation

// Foundation-only summary of local Claude Code usage (all profiles): Today, Yesterday, and the
// last 30 days, from ClaudeCostScanner. The model checks compile this file.

struct ClaudeActivityRow: Equatable, Sendable {
  var label: String
  var tokens: Int
  /// Estimated API-equivalent cost; nil when nothing in the period could be priced.
  var costUSD: Double?
  /// Exact token buckets for the tooltip and accessibility value.
  var detail: String
}

struct ClaudeActivitySummary: Equatable, Sendable {
  var rows: [ClaudeActivityRow]
  /// Models with usage but no published price. Their cost is not in the totals.
  var unpricedModels: [String]
  var computedAt: Date
}

enum ClaudeActivity {
  /// The scan reruns at most this often, except on manual refresh.
  static let interval: TimeInterval = 15 * 60
  static let days = 30

  static func isDue(computedAt: Date?, force: Bool, now: Date = Date()) -> Bool {
    if force { return true }
    guard let computedAt else { return true }
    return now.timeIntervalSince(computedAt) >= interval
  }

  static func tokens(_ day: ClaudeDailyCost) -> Int {
    day.inputTokens + day.outputTokens + day.cacheReadTokens + day.cacheWriteTokens
  }

  static func summarize(
    _ daily: [ClaudeDailyCost], now: Date, calendar: Calendar = .current
  ) -> ClaudeActivitySummary {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: now)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map(formatter.string(from:))

    func row(_ label: String, _ days: [ClaudeDailyCost]) -> ClaudeActivityRow {
      let priced = days.compactMap(\.costUSD)
      let (input, output) = (days.map(\.inputTokens).reduce(0, +), days.map(\.outputTokens).reduce(0, +))
      let (read, write) = (days.map(\.cacheReadTokens).reduce(0, +), days.map(\.cacheWriteTokens).reduce(0, +))
      return ClaudeActivityRow(
        label: label, tokens: input + output + read + write,
        costUSD: priced.isEmpty ? nil : priced.reduce(0, +),
        detail: "Input \(Fmt.number(Double(input))), output \(Fmt.number(Double(output))), "
          + "cache read \(Fmt.number(Double(read))), cache write \(Fmt.number(Double(write))) tokens.")
    }
    let unpriced = Set(daily.flatMap(\.unpricedModels)).sorted()
    return ClaudeActivitySummary(
      rows: [
        row("Today", daily.filter { $0.date == today }),
        row("Yesterday", daily.filter { $0.date == yesterday }),
        row("Last 30 days", daily),
      ],
      unpricedModels: unpriced, computedAt: now)
  }

  /// Scans every profile's shared `projects/` logs. Heavy on the first run: call it off the main actor.
  static func compute(
    roots: [URL] = ClaudeCostScanner.defaultRoots(), cacheURL: URL, pricing: ClaudePricingSource,
    now: Date = Date()
  ) async throws -> ClaudeActivitySummary {
    let scanner = ClaudeCostScanner(roots: roots, cacheURL: cacheURL, pricing: pricing.loader())
    return summarize(try await scanner.daily(days: days, now: now), now: now)
  }
}
