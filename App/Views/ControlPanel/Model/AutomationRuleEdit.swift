import Foundation

/// A time rule as its editor hands it over: the rule to add, or with `id` the saved rule to replace.
///
/// A time rule keeps no offset and a sunrise or sunset rule keeps no time, so each is stored with
/// the value the other kind ignores (an offset of 0, the placeholder time of 08:00) however the
/// editor's fields were left.
struct AutomationRuleEdit: Equatable, Sendable {
  /// The saved rule this replaces; nil adds a new one.
  let id: String?
  /// Gregorian weekday numbers, Sunday 1 to Saturday 7. A rule needs at least one.
  let weekdays: Set<Int>
  let event: WallpaperAutomationRule.Event
  /// Minutes after midnight for a time rule; the placeholder 08:00 for a sunrise or sunset rule.
  let minute: Int
  /// Minutes after the sun event, from -180 (before) to 180; 0 for a time rule.
  let offset: Int
  let target: WallpaperAutomationTarget

  static let weekdaysOnly: Set<Int> = Set(2...6)
  static let weekends: Set<Int> = [1, 7]
  static let everyDay: Set<Int> = Set(1...7)
  /// A time rule at `time`, or a sunrise or sunset rule `offset` minutes from the sun, which is
  /// refused on saving when it is outside the range the editor offers.
  init(
    id: String? = nil, weekdays: Set<Int> = Self.everyDay, event: WallpaperAutomationRule.Event = .time,
    time: ClockMinute = .eightAM, offset: Int = 0, target: WallpaperAutomationTarget
  ) {
    self.id = id
    self.weekdays = weekdays
    self.event = event
    minute = event == .time ? time.minutes : ClockMinute.eightAM.minutes
    self.offset = event == .time ? 0 : offset
    self.target = target
  }

  /// The edit that changes the saved `rule` as it stands.
  init(editing rule: WallpaperAutomationRule) {
    id = rule.id
    weekdays = rule.weekdays
    event = rule.event
    minute = rule.minute
    offset = rule.offset
    target = rule.target
  }

  /// The time of a time rule, for the editor's time field.
  var time: ClockMinute { ClockMinute(minutes: minute) ?? .eightAM }
}
