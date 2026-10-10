import Foundation

// How reset times read. Foundation only, so the scroll check can compile it with the design file.

enum HourFormat: String, CaseIterable, Sendable {
  case auto
  case twelve = "12h"
  case twentyFour = "24h"

  var label: String {
    switch self {
    case .auto: "Auto"
    case .twelve: "12-hour"
    case .twentyFour: "24-hour"
    }
  }
}

/// "Resets in 2h 5m" (countdown, the default) or "Resets 5:30 PM" (exact time).
enum ResetDisplay {
  static let exactKey = "resetTimesExact"
  static let hourFormatKey = "timeFormat"

  static func isExact(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: exactKey) }

  static func hourFormat(defaults: UserDefaults = .standard) -> HourFormat {
    defaults.string(forKey: hourFormatKey).flatMap(HourFormat.init(rawValue:)) ?? .auto
  }

  /// "Resets 5:30 PM" today, "Resets tomorrow 5:30 PM", "Resets Thu 5:30 PM" inside a week,
  /// otherwise "Resets Oct 14, 5:30 PM". "Resets now" once the time has passed.
  static func exactText(
    _ reset: Date, now: Date = Date(), hourFormat: HourFormat = .auto,
    timeZone: TimeZone = .current
  ) -> String {
    guard reset > now else { return "Resets now" }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let posix = Locale(identifier: "en_US_POSIX")
    func format(_ pattern: String, locale: Locale = posix) -> String {
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.timeZone = timeZone
      formatter.dateFormat = pattern
      return formatter.string(from: reset)
    }
    let clock: String
    switch hourFormat {
    case .twelve: clock = format("h:mm a")
    case .twentyFour: clock = format("HH:mm")
    case .auto:
      let pattern = DateFormatter.dateFormat(fromTemplate: "j:mm", options: 0, locale: .current) ?? "h:mm a"
      clock = format(pattern, locale: .current)
    }
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: reset)).day ?? 0
    switch days {
    case ..<1: return "Resets \(clock)"
    case 1: return "Resets tomorrow \(clock)"
    case 2..<7: return "Resets \(format("EEE")) \(clock)"
    default: return "Resets \(format("MMM d")), \(clock)"
    }
  }
}

