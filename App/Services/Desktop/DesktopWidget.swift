import AppKit
import Foundation

/// One widget the app draws on the desktop (a clock, a date, a note, a countdown and the other
/// kinds), above every wallpaper and below Finder's icons. It belongs to no wallpaper: changing the
/// wallpaper keeps it where it is.
///
/// Every field has a default, so a record written by an older or newer version decodes with what
/// it carries and the rest at their defaults; `DesktopWidgetStore.decode` still refuses values out
/// of range, which is what a backup is checked with.
struct DesktopWidget: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// A digital clock, of this Mac's time zone or another.
        case time
        case date
        /// Words the person wrote, on one line or several.
        case text
        /// The days until, or since, a day the person chose.
        case countdown
        /// "Good morning" and the rest of the day's greetings, with the person's name if given.
        case greeting
        /// How full the Mac's battery is, and whether it is charging.
        case battery
        /// The next sunrise or sunset, or both of today's, where the automatic wallpapers plan them.
        case sun
        /// A clock face with hands.
        case analog
        /// This month's days in a grid, today marked.
        case calendar
    }

    /// Which displays show the widget.
    enum Placement: Codable, Hashable, Sendable {
        /// The display with the menu bar, whichever that is now.
        case main
        case all
        /// One display, by the UUID Core Graphics keeps for it across reboots and reconnections,
        /// with the name it had when chosen, for when it is not connected.
        case display(uuid: String, name: String)
    }

    /// Which side of the text the position names.
    enum Alignment: String, Codable, CaseIterable, Sendable {
        case leading, center, trailing
    }

    enum Typeface: String, Codable, CaseIterable, Sendable {
        case standard, rounded, serif, monospaced
    }

    enum TimeFormat: String, Codable, CaseIterable, Sendable {
        /// What System Settings › General › Date & Time says.
        case system, twelveHour, twentyFourHour
    }

    /// The date's words and order, as Unicode date templates the locale arranges.
    enum DateStyle: String, Codable, CaseIterable, Sendable {
        case weekdayMonthDay, monthDayYear, abbreviated, numeric, weekday, monthYear
        /// "Week 45": the week of the year, numbered as the region numbers weeks.
        case weekNumber
        /// "Day 312": the day of the year.
        case dayOfYear

        var template: String {
            switch self {
            case .weekdayMonthDay: "EEEEMMMMd"
            case .monthDayYear: "yMMMMd"
            case .abbreviated: "EEEMMMd"
            case .numeric: "yMd"
            case .weekday: "EEEE"
            case .monthYear: "yMMMM"
            case .weekNumber: "w"
            case .dayOfYear: "D"
            }
        }
    }

    /// The calendar a date is written in: the region's own, or another one beside it, such as the
    /// Chinese lunar calendar.
    enum CalendarSystem: String, Codable, CaseIterable, Sendable {
        case system, chinese, islamic, hebrew, persian, buddhist, japanese, indian

        /// Nil for the region's own calendar.
        var identifier: Calendar.Identifier? {
            switch self {
            case .system: nil
            case .chinese: .chinese
            case .islamic: .islamicUmmAlQura
            case .hebrew: .hebrew
            case .persian: .persian
            case .buddhist: .buddhist
            case .japanese: .japanese
            case .indian: .indian
            }
        }
    }

    /// What a sunrise and sunset widget says.
    enum SunStyle: String, Codable, CaseIterable, Sendable {
        /// Whichever of the two comes next.
        case next
        /// Today's sunrise and today's sunset.
        case both
    }

    static let sizeRange = 10...320
    static let opacityRange = 10...100
    /// The font weight on the 100 to 900 scale fonts are made in, in steps of 100: 100 is the
    /// thinnest, 400 regular, 700 bold.
    static let weightRange = 100...900
    /// The longest text a widget keeps, in characters.
    static let textLimit = 500

    var id: String
    var kind: Kind
    var isShown = true
    var placement = Placement.main
    /// The point the alignment names, as a fraction of the display's width from its left edge.
    var x = 0.5
    /// The text's vertical centre, as a fraction of the display's height from its top edge.
    var y = 0.25
    var alignment = Alignment.center
    /// The font size, in points.
    var size = 96
    var typeface = Typeface.standard
    var weight = 300
    /// `#RRGGBB`, in sRGB.
    var color = "#FFFFFF"
    /// Percent.
    var opacity = 100
    var hasShadow = true
    var timeFormat = TimeFormat.system
    var showsSeconds = false
    var dateStyle = DateStyle.weekdayMonthDay
    /// The calendar a date is written in.
    var calendarSystem = CalendarSystem.system
    /// The time zone of a clock or a date, by its identifier; nil for this Mac's own.
    var timeZone: String?
    /// The words of a text widget, the label before a clock or a date, the name of a countdown's
    /// day, or the name a greeting adds.
    var text = ""
    /// The day a countdown counts to, as `yyyy-MM-dd` in the Gregorian calendar; empty for today.
    var targetDay = ""
    var sunStyle = SunStyle.next

    /// A new widget of `kind`, laid out for it. `today` and `calendar` choose a countdown's first
    /// day, thirty days ahead.
    init(
        id: String = UUID().uuidString, kind: Kind, today: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.id = id
        self.kind = kind
        switch kind {
        case .time:
            break
        case .date:
            y = 0.34
            size = 28
            weight = 500
        case .text:
            y = 0.5
            size = 32
            weight = 400
            text = String(localized: "Your text")
        case .countdown:
            y = 0.5
            size = 28
            weight = 500
            if let day = calendar.date(byAdding: .day, value: 30, to: today) {
                targetDay = Self.day(of: day, in: calendar)
            }
        case .greeting:
            y = 0.5
            size = 40
        case .battery, .sun:
            y = 0.5
            size = 22
            weight = 500
        case .analog:
            y = 0.3
            size = 100
            weight = 400
        case .calendar:
            y = 0.5
            size = 16
            weight = 500
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, isShown, placement, x, y, alignment, size, typeface, weight, color, opacity
        case hasShadow, timeFormat, showsSeconds, dateStyle, calendarSystem, timeZone, text, targetDay
        case sunStyle
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            kind: try container.decode(Kind.self, forKey: .kind))
        func read<Value: Decodable>(_ key: CodingKeys, into value: inout Value) throws {
            if let decoded = try container.decodeIfPresent(Value.self, forKey: key) { value = decoded }
        }
        try read(.isShown, into: &isShown)
        try read(.placement, into: &placement)
        try read(.x, into: &x)
        try read(.y, into: &y)
        try read(.alignment, into: &alignment)
        try read(.size, into: &size)
        try read(.typeface, into: &typeface)
        try read(.weight, into: &weight)
        try read(.color, into: &color)
        try read(.opacity, into: &opacity)
        try read(.hasShadow, into: &hasShadow)
        try read(.timeFormat, into: &timeFormat)
        try read(.showsSeconds, into: &showsSeconds)
        try read(.dateStyle, into: &dateStyle)
        try read(.calendarSystem, into: &calendarSystem)
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
        try read(.text, into: &text)
        try read(.targetDay, into: &targetDay)
        try read(.sunStyle, into: &sunStyle)
    }

    /// Whether every value is one the panel could have chosen.
    var isValid: Bool {
        let placementIsValid: Bool = switch placement {
        case .main, .all: true
        case .display(let uuid, let name):
            Self.validText(uuid, limit: 64) && name.count <= 256 && !name.contains("\0")
        }
        return Self.validText(id, limit: 128) && placementIsValid
            && (0...1).contains(x) && (0...1).contains(y)
            && Self.sizeRange.contains(size) && Self.opacityRange.contains(opacity)
            && Self.weightRange.contains(weight) && weight % 100 == 0
            && Self.rgb(color) != nil
            && text.count <= Self.textLimit && !text.contains("\0")
            && (timeZone.map(Self.validTimeZone) ?? true)
            && (targetDay.isEmpty || Self.components(ofDay: targetDay) != nil)
    }

    /// The widget with every number pulled into its range and an unreadable colour made white.
    func clamped() -> DesktopWidget {
        var copy = self
        copy.x = x.isFinite ? min(max(x, 0), 1) : 0.5
        copy.y = y.isFinite ? min(max(y, 0), 1) : 0.5
        copy.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        copy.opacity = min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        copy.weight = min(max((weight + 50) / 100 * 100, Self.weightRange.lowerBound), Self.weightRange.upperBound)
        if Self.rgb(color) == nil { copy.color = "#FFFFFF" }
        copy.text = String(text.replacingOccurrences(of: "\0", with: "").prefix(Self.textLimit))
        if let timeZone, !Self.validTimeZone(timeZone) { copy.timeZone = nil }
        if !targetDay.isEmpty, Self.components(ofDay: targetDay) == nil { copy.targetDay = "" }
        return copy
    }

    // MARK: Time zone and day

    /// The time zone the widget tells the time of: its own when it has one, else `system`.
    func zone(or system: TimeZone) -> TimeZone {
        timeZone.flatMap(TimeZone.init(identifier:)) ?? system
    }

    /// Whether `identifier` names a time zone this Mac knows.
    static func validTimeZone(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.count <= 64 && TimeZone(identifier: identifier) != nil
    }

    /// `date`'s day in `calendar`'s time zone, as `yyyy-MM-dd` in the Gregorian calendar.
    static func day(of date: Date, in calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1, parts.month ?? 1, parts.day ?? 1)
    }

    /// The Gregorian year, month and day of a `yyyy-MM-dd` day; nil for anything else or a day
    /// the calendar does not have, such as February 30.
    static func components(ofDay day: String) -> DateComponents? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard day.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let dayNumber = Int(parts[2]),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(dayNumber) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: dayNumber)
        guard let date = gregorian.date(from: components),
              gregorian.component(.day, from: date) == dayNumber else { return nil }
        return components
    }

    /// The start of a `yyyy-MM-dd` day in `calendar`'s time zone; nil for an unreadable day.
    static func start(ofDay day: String, in calendar: Calendar) -> Date? {
        guard var components = components(ofDay: day) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        components.hour = 0
        return gregorian.date(from: components).map { gregorian.startOfDay(for: $0) }
    }

    /// Whether the widget belongs on a display.
    func isPlaced(onDisplayUUID uuid: String?, isMain: Bool) -> Bool {
        switch placement {
        case .main: isMain
        case .all: true
        case .display(let wanted, _): uuid.map { $0.caseInsensitiveCompare(wanted) == .orderedSame } ?? false
        }
    }

    // MARK: Colour

    /// The red, green and blue of `#RRGGBB`, each 0 to 255; nil for anything else.
    static func rgb(_ hex: String) -> (red: Int, green: Int, blue: Int)? {
        guard hex.count == 7, hex.first == "#", let value = Int(hex.dropFirst(), radix: 16),
              hex.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    /// `#RRGGBB` for a colour, converted to sRGB; nil for one that cannot be.
    static func hex(_ color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X", channel(srgb.redComponent), channel(srgb.greenComponent),
            channel(srgb.blueComponent))
    }

    /// The text colour with the widget's opacity.
    var textColor: NSColor {
        let rgb = Self.rgb(color) ?? (255, 255, 255)
        return NSColor(
            srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255,
            alpha: CGFloat(opacity) / 100)
    }

    private static func validText(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.count <= limit && !value.contains(where: { $0.isNewline || $0 == "\0" })
    }
}
