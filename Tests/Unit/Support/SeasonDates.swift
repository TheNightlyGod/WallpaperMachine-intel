import Foundation

extension Date {
  /// Noon on a day no seasonal look covers, for a test of the everyday look that must not depend
  /// on the day it runs (`AppThemeStore` wears the Halloween look by itself in Halloween week).
  static let outsideAnySeason = Calendar.current.date(
    from: DateComponents(year: 2026, month: 3, day: 15, hour: 12))!

  /// Noon on `month`/`day` of 2026, local time.
  static func noon(month: Int, day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
  }
}
