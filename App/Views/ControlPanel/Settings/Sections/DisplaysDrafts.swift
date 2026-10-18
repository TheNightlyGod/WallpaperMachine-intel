import Foundation

// The pure rules of the Displays page that the model layer does not hold: what a number field
// accepts, the choreography of the Custom interval, the time rule editor's draft, the name forms,
// the order editor's rows and the summary line of a saved playlist. Every type here is a plain
// value, so the rules are tested without a window.

// MARK: - Number fields

enum DisplaysNumberInput {
  /// The number a field holds, read the way `locale` writes numbers: digits, an optional sign and at
  /// most one decimal separator, in either character width. Empty text, anything else in the text
  /// (so "1.2.3" and "12px" are nothing, not 1.2 and 12), a figure that is not finite, and for
  /// `integer` a number with a fraction are nil.
  static func parse(_ text: String, integer: Bool = false, locale: Locale = .current) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var normalized = trimmed.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? trimmed
    guard !normalized.isEmpty else { return nil }
    let decimal = locale.decimalSeparator ?? "."
    let grouping = locale.groupingSeparator ?? ","
    if grouping != decimal { normalized = normalized.replacingOccurrences(of: grouping, with: "") }
    normalized = normalized.replacingOccurrences(of: decimal, with: ".")
    guard normalized.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)$"#, options: .regularExpression) != nil,
      let value = Double(normalized), value.isFinite
    else { return nil }
    if integer, value != value.rounded() { return nil }
    return value
  }

  /// How a stored number is written in a field: no grouping, at most `digits` fraction digits.
  static func text(_ value: Double, digits: Int = 2, locale: Locale = .current) -> String {
    value.formatted(
      .number.grouping(.never).precision(.fractionLength(0...digits)).locale(locale))
  }
}

/// What a number field does with its text when it is submitted or left.
enum DisplaysNumberCommit: Equatable {
  /// Nothing was typed, or the typed number is the stored one: nothing is sent, and the field shows
  /// the stored value again.
  case none
  /// The typed number is sent.
  case send(Double)
  /// The text is not a number the field accepts: nothing is sent, and the text stays in the field
  /// beside what the field accepts, to be corrected.
  case refuse

  /// - Parameters:
  ///   - typed: The field's text; nil when nothing was typed since the stored value showed.
  ///   - accepts: The range the field takes, beyond being a number.
  static func outcome(
    typed: String?, stored: Double, integer: Bool = false, locale: Locale = .current,
    accepts: (Double) -> Bool
  ) -> DisplaysNumberCommit {
    guard let typed else { return .none }
    guard let number = DisplaysNumberInput.parse(typed, integer: integer, locale: locale), accepts(number)
    else { return .refuse }
    return abs(number - stored) > 1e-9 ? .send(number) : .none
  }
}

// MARK: - How often

/// What the How often menu shows: one of the times, the unlock, or Custom.
enum DisplaysIntervalOption: Hashable {
  case preset(Int)
  case unlock
  case custom
}

/// The Custom interval's choreography. Choosing Custom sends nothing: the menu shows Custom and
/// the minutes field appears, holding the saved minutes until something else is typed. The draft
/// ends when the field is left without a number to save, or when a number is saved.
struct DisplaysIntervalDraft: Equatable {
  /// The Custom entry was chosen and no number has been saved yet.
  var customChosen = false
  /// What was typed into the minutes field; nil leaves it showing the saved interval.
  var text: String?
  /// Return was pressed on a text that is not a whole number in range: the field keeps it and says
  /// what it accepts, until it is typed in again.
  var isInvalid = false

  /// The menu's selection for `playlist`: the draft's Custom, else what is saved.
  func selection(for playlist: DisplayPlaylist) -> DisplaysIntervalOption {
    if customChosen { return .custom }
    switch IntervalChoice.current(for: playlist) {
    case .unlock: return .unlock
    case .preset(let minutes): return .preset(minutes)
    case .custom: return .custom
    }
  }

  /// The minutes a typed text names: a whole number in the range the store accepts.
  static func minutes(from text: String, locale: Locale = .current) -> Int? {
    guard let value = DisplaysNumberInput.parse(text, integer: true, locale: locale) else {
      return nil
    }
    let minutes = Int(value)
    return IntervalChoice.range.contains(minutes) ? minutes : nil
  }
}

// MARK: - The time rule editor

/// A time rule while it is being edited: the fields as the editor holds them, before they become an
/// `AutomationRuleEdit`.
struct DisplaysRuleDraft: Equatable {
  /// The saved rule being edited; nil for a new one.
  var id: String?
  var weekdays: Set<Int> = AutomationRuleEdit.everyDay
  var event: WallpaperAutomationRule.Event = .time
  var time: ClockMinute = .eightAM
  /// The offset field's text. Only a sunrise or sunset rule reads it.
  var offsetText = "0"
  /// What the rule switches to; a rule needs one.
  var target: WallpaperAutomationTarget?
  /// "Choose at least one weekday." is showing: set by a save without a day, cleared by the next
  /// choice of days.
  var showsDaysError = false

  /// The range the offset field accepts, in minutes before (negative) and after the sun event.
  static let offsetRange = -180...180

  init() {}

  /// The editor for a saved rule: its own values.
  init(editing rule: WallpaperAutomationRule) {
    id = rule.id
    weekdays = rule.weekdays
    event = rule.event
    time = ClockMinute(minutes: rule.minute) ?? .eightAM
    offsetText = String(rule.offset)
    target = rule.target
  }

  enum Failure: Error, Equatable {
    /// No target was chosen: the form's Save stays disabled.
    case noTarget
    /// A sunrise or sunset rule's offset is not a whole number within three hours.
    case invalidOffset
    /// No day is ticked: the editor says so inline and moves to the first day.
    case noWeekday
  }

  /// The offset field's number; nil when it is not a whole number in `offsetRange`.
  func offset(locale: Locale = .current) -> Int? {
    guard let value = DisplaysNumberInput.parse(offsetText, integer: true, locale: locale) else {
      return nil
    }
    return Self.offsetRange.contains(Int(value)) ? Int(value) : nil
  }

  /// Whether the editor's Save is available: the fields the form requires are filled in.
  func canSave(locale: Locale = .current) -> Bool {
    if target == nil { return false }
    return event == .time || offset(locale: locale) != nil
  }

  /// The edit to send, or why there is none. The checks are in the form's order: the required
  /// fields first, then the weekdays.
  func edit(locale: Locale = .current) -> Result<AutomationRuleEdit, Failure> {
    guard let target else { return .failure(.noTarget) }
    let offset = event == .time ? 0 : offset(locale: locale)
    guard let offset else { return .failure(.invalidOffset) }
    guard !weekdays.isEmpty else { return .failure(.noWeekday) }
    return .success(
      AutomationRuleEdit(
        id: id, weekdays: weekdays, event: event, time: time, offset: offset, target: target))
  }

  /// Chooses one of the quick sets, which also ends the weekday alert.
  mutating func choose(_ days: Set<Int>) {
    weekdays = days
    showsDaysError = false
  }

  /// Ticks or unticks a day; ticking one ends the weekday alert.
  mutating func toggle(_ day: Int) {
    if weekdays.contains(day) {
      weekdays.remove(day)
    } else {
      weekdays.insert(day)
      showsDaysError = false
    }
  }
}

// MARK: - Name forms

/// The inline form that names a layout or a saved playlist. The stores accept one line of 1 to 128
/// characters once trimmed; the field keeps within that while it is typed.
struct DisplaysNameForm: Equatable {
  static let maximumLength = 128

  var text: String

  init(_ text: String = "") { self.text = Self.limited(text) }

  var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
  var canSubmit: Bool { !trimmed.isEmpty }

  /// `text` on one line and no longer than the stores allow.
  static func limited(_ text: String) -> String {
    let oneLine = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(
      of: "\r", with: " ")
    return String(oneLine.prefix(maximumLength))
  }
}

// MARK: - The display's own list

/// One wallpaper of a display's own list as the order editor draws it: only the wallpapers the
/// library still holds, numbered by their place among those.
struct DisplaysListRow: Identifiable, Equatable {
  let id: String
  let title: String
  let position: Int
  let isFirst: Bool
  let isLast: Bool
}

enum DisplaysPlaylistList {
  /// The buttons of a row of the list.
  enum Button: Hashable {
    case up, down, remove
  }

  /// The button of `id`'s row that keeps the keyboard after it moved through `pressed`: the same
  /// one while it can still be pressed, else the first one that can (`visible` is the drawn order
  /// after the move).
  static func focusAfterMove(of id: String, pressed: Button, in visible: [String]) -> Button {
    guard let index = visible.firstIndex(of: id) else { return pressed }
    let canMoveUp = index > 0
    let canMoveDown = index < visible.count - 1
    switch pressed {
    case .up where canMoveUp, .down where canMoveDown: return pressed
    default: return canMoveUp ? .up : canMoveDown ? .down : .remove
    }
  }

  /// The rows of `ids`, leaving out the wallpapers `titles` does not know. The stored list keeps
  /// those ids, which is why every move sends the whole list and the order it started from.
  static func rows(of ids: [String], titles: [String: String]) -> [DisplaysListRow] {
    let visible = ids.filter { titles[$0] != nil }
    return visible.enumerated().map { index, id in
      DisplaysListRow(
        id: id, title: titles[id] ?? id, position: index + 1, isFirst: index == 0,
        isLast: index == visible.count - 1)
    }
  }

  /// The order after `moving` takes the place of `target` in a drag: ahead of it when it comes from
  /// below, behind it when it comes from above, so the wallpaper lands where it was dropped. The
  /// list is returned as it was when either is not in it or they are the same.
  static func dropped(_ ids: [String], moving: String, onto target: String) -> [String] {
    guard moving != target, let from = ids.firstIndex(of: moving), let to = ids.firstIndex(of: target)
    else { return ids }
    return PlaylistOrdering.reordered(ids, moving: moving, relativeTo: target, after: from < to)
  }
}

// MARK: - Saved playlists

enum DisplaysPlanSummary {
  /// One line saying what a saved playlist does, as the Saved playlists group lists it.
  ///
  /// - Parameters:
  ///   - collectionName: the name of a collection id, nil for one that no longer exists.
  ///   - wallpaperTitle: the title of a wallpaper id, nil for one the library no longer holds.
  @MainActor
  static func text(
    of playlist: DisplayPlaylist, collectionName: (String) -> String?,
    wallpaperTitle: (String) -> String?
  ) -> String {
    switch playlist.mode {
    case .off:
      return L("Off")
    case .rotate:
      let source: String
      switch playlist.source {
      case .all: source = L("All wallpapers")
      case .favorites: source = L("Favorites")
      case .list: source = L("This display’s list (\(playlist.wallpaperIDs.count))")
      case .collection:
        if let id = playlist.collectionID, let name = collectionName(id) {
          source = L("Collection “\(name)”")
        } else {
          source = L("A collection that no longer exists")
        }
      }
      let order = playlist.order == .shuffle ? L("Shuffle") : L("In order")
      let interval = IntervalChoice.current(for: playlist).title.lowercased(
        with: PanelLocale.shared.locale)
      return L("\(source), \(order), \(interval)")
    case .dayNight:
      func name(_ id: String?) -> String {
        guard let id else { return L("left as it is") }
        return wallpaperTitle(id) ?? L("a removed wallpaper")
      }
      let dayStart = ClockMinute(minutes: playlist.dayStart)?.text ?? ""
      let nightStart = ClockMinute(minutes: playlist.nightStart)?.text ?? ""
      return L(
        "Day: \(name(playlist.dayWallpaperID)) from \(dayStart); night: \(name(playlist.nightWallpaperID)) from \(nightStart)"
      )
    }
  }
}
