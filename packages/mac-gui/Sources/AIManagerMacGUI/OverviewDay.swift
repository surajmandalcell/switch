import Foundation

/// Helpers for the `yyyy-MM-dd` UTC days of the history. Plain arithmetic, so no time zone applies.
enum OverviewDay {
  private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

  private static func parts(_ day: String) -> [Int] { day.split(separator: "-").compactMap { Int($0) } }

  /// Days since 1970-01-01.
  static func epoch(_ day: String) -> Int? {
    let p = parts(day)
    guard p.count == 3, (1...12).contains(p[1]) else { return nil }
    let year = p[0] - (p[1] <= 2 ? 1 : 0)
    let era = (year >= 0 ? year : year - 399) / 400
    let yearOfEra = year - era * 400
    let dayOfYear = (153 * (p[1] + (p[1] > 2 ? -3 : 9)) + 2) / 5 + p[2] - 1
    return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
  }

  /// 0 is Sunday.
  static func weekday(_ day: String) -> Int { (((epoch(day) ?? 0) + 4) % 7 + 7) % 7 }
  static func dayOfMonth(_ day: String) -> Int { parts(day).last ?? 0 }
  static func month(_ day: String) -> String {
    let p = parts(day)
    return p.count == 3 && (1...12).contains(p[1]) ? months[p[1] - 1] : ""
  }
  /// "Sat"
  static func weekdayName(_ day: String) -> String { weekdays[weekday(day)] }
  /// "Oct 3"
  static func short(_ day: String) -> String { "\(month(day)) \(dayOfMonth(day))" }
  /// "Saturday, October 3"
  static func title(_ day: String) -> String {
    let p = parts(day)
    guard p.count == 3, (1...12).contains(p[1]) else { return day }
    return "\(fullWeekdays[weekday(day)]), \(fullMonths[p[1] - 1]) \(p[2])"
  }
  private static let fullMonths = [
    "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
  ]
  private static let fullWeekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  /// "Sat, Oct 3, 2026"
  static func long(_ day: String) -> String {
    "\(weekdays[weekday(day)]), \(short(day)), \(parts(day).first ?? 0)"
  }
}
