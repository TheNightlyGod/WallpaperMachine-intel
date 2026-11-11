import AppKit
import Foundation

/// What a desktop widget shows and where: its words or clock face at a moment, its font, its frame
/// on a display, and when what it shows next changes. Pure, so the desktop and the panel's arranging
/// preview draw the same widget the same way.
enum DesktopWidgetRendering {
    /// What the widgets are drawn from: the moment, this Mac's calendar and time zone, the language
    /// and region, and the readings some kinds show.
    struct Inputs {
        var date: Date
        /// This Mac's calendar, in its time zone.
        var calendar: Calendar
        var locale: Locale
        /// The internal battery; nil on a Mac without one.
        var battery: BatteryReading?
        /// Where and how the automatic wallpapers plan sunrise and sunset; nil when nothing is set.
        var solar: WallpaperSolarSettings?

        init(
            date: Date, calendar: Calendar, locale: Locale, battery: BatteryReading? = nil,
            solar: WallpaperSolarSettings? = nil
        ) {
            self.date = date
            self.calendar = calendar
            self.locale = locale
            self.battery = battery
            self.solar = solar
        }
    }

    /// A clock face: its size, its ink, and where its hands point, each as a fraction of a turn
    /// from twelve o'clock.
    struct AnalogFace: Equatable {
        var diameter: CGFloat
        var color: NSColor
        /// The minute hand's width; the others are drawn in proportion.
        var lineWidth: CGFloat
        var hour: Double
        var minute: Double
        /// Nil without a second hand.
        var second: Double?
        /// The shadow's blur and downward offset; nil without one.
        var shadow: Shadow?

        struct Shadow: Equatable {
            var blur: CGFloat
            var offset: CGFloat
        }
    }

    /// How a widget is drawn.
    enum Drawing: Equatable {
        case text(NSAttributedString)
        case analog(AnalogFace)
    }

    /// Everything one widget shows at a moment.
    struct Content: Equatable {
        /// What it says, as plain text: the words, or the time a clock face shows.
        var text: String
        var drawing: Drawing
        /// The size of what is drawn, without the padding.
        var size: NSSize
        /// The room left around it so the shadow is not cut off.
        var padding: CGFloat
    }

    // MARK: Formatters

    /// Date formatters by template, locale, calendar and time zone. Making one costs far more than
    /// using it, and a clock with seconds asks every second.
    @MainActor
    final class Formatters {
        private var cache: [String: DateFormatter] = [:]
        private var symbols: [String: [String]] = [:]

        init() {}

        func string(_ date: Date, template: String, locale: Locale, calendar: Calendar) -> String {
            formatter(template: template, locale: locale, calendar: calendar).string(from: date)
        }

        /// The one-letter weekday names of `locale`, Sunday first.
        func weekdaySymbols(locale: Locale) -> [String] {
            if let found = symbols[locale.identifier] { return found }
            let formatter = DateFormatter()
            formatter.locale = locale
            let found = formatter.veryShortStandaloneWeekdaySymbols ?? []
            symbols[locale.identifier] = found
            return found
        }

        private func formatter(template: String, locale: Locale, calendar: Calendar) -> DateFormatter {
            let key = [
                template, locale.identifier, "\(calendar.identifier)", calendar.timeZone.identifier,
                "\(calendar.firstWeekday)", "\(calendar.minimumDaysInFirstWeek)",
            ].joined(separator: "|")
            if let formatter = cache[key] { return formatter }
            let formatter = DateFormatter()
            // The locale first: setting it gives the formatter the locale's calendar. Another
            // calendar is asked for through the locale, so the date is written in that calendar's
            // own patterns ("九月三十" in the Chinese calendar, not "9月30日"); the region's own
            // calendar keeps the locale as it is, with the person's 12- or 24-hour choice.
            if calendar.identifier == locale.calendar.identifier {
                formatter.locale = locale
            } else {
                var components = Locale.Components(locale: locale)
                components.calendar = calendar.identifier
                formatter.locale = Locale(components: components)
            }
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            if cache.count >= 48 { cache.removeAll() }
            cache[key] = formatter
            return formatter
        }
    }

    // MARK: Words

    /// The calendar a widget counts in: this Mac's, or the one a date is written in, in the
    /// widget's time zone.
    static func calendar(for widget: DesktopWidget, inputs: Inputs) -> Calendar {
        var calendar = inputs.calendar
        if widget.kind == .date, let identifier = widget.calendarSystem.identifier {
            calendar = Calendar(identifier: identifier)
            calendar.locale = inputs.locale
        }
        calendar.timeZone = widget.zone(or: inputs.calendar.timeZone)
        return calendar
    }

    /// The hour and minute (and second) of a clock, in the hour cycle chosen.
    static func timeTemplate(_ format: DesktopWidget.TimeFormat, seconds: Bool) -> String {
        let hour = switch format {
        case .system: "j"
        case .twelveHour: "h"
        case .twentyFourHour: "H"
        }
        return hour + (seconds ? "mmss" : "mm")
    }

    /// The Unicode date template of a clock's or a date's words.
    static func template(for widget: DesktopWidget) -> String {
        switch widget.kind {
        case .date: widget.dateStyle.template
        case .analog: timeTemplate(.twentyFourHour, seconds: widget.showsSeconds)
        default: timeTemplate(widget.timeFormat, seconds: widget.showsSeconds)
        }
    }

    /// What the widget says at the moment of `inputs`, as plain text.
    @MainActor
    static func text(for widget: DesktopWidget, inputs: Inputs, formatters: Formatters) -> String {
        let calendar = calendar(for: widget, inputs: inputs)
        let now = inputs.date
        func format(_ template: String, _ date: Date = now) -> String {
            formatters.string(date, template: template, locale: inputs.locale, calendar: calendar)
        }
        switch widget.kind {
        case .time, .analog:
            return labelled(format(template(for: widget)), widget: widget)
        case .date:
            let words = switch widget.dateStyle {
            case .weekNumber: String(localized: "Week \(format("w"))")
            case .dayOfYear: String(localized: "Day \(format("D"))")
            default: format(widget.dateStyle.template)
            }
            return labelled(words, widget: widget)
        case .text:
            return widget.text
        case .countdown:
            return countdown(widget, calendar: calendar, now: now, format: format)
        case .greeting:
            return greeting(hour: calendar.component(.hour, from: now), name: line(widget.text))
        case .battery:
            guard let battery = inputs.battery else { return String(localized: "No battery") }
            let percent = (Double(battery.percent) / 100).formatted(.percent.locale(inputs.locale))
            return battery.isCharging ? String(localized: "Charging \(percent)") : String(localized: "Battery \(percent)")
        case .sun:
            return sun(widget, inputs: inputs, calendar: calendar, format: format)
        case .calendar:
            return format("yMMMM")
        }
    }

    /// The same, for tests and callers that have only a moment, a language and a time zone.
    @MainActor
    static func text(
        for widget: DesktopWidget, at date: Date, locale: Locale, timeZone: TimeZone, formatters: Formatters
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return text(for: widget, inputs: Inputs(date: date, calendar: calendar, locale: locale), formatters: formatters)
    }

    /// `words` after the widget's label, when it has one.
    private static func labelled(_ words: String, widget: DesktopWidget) -> String {
        let label = line(widget.text)
        return label.isEmpty ? words : "\(label) \(words)"
    }

    /// Text on one line, without the spaces around it.
    private static func line(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func countdown(
        _ widget: DesktopWidget, calendar: Calendar, now: Date, format: (String, Date) -> String
    ) -> String {
        let target = DesktopWidget.start(ofDay: widget.targetDay, in: calendar) ?? calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: target).day ?? 0
        let sameYear = calendar.component(.year, from: target) == calendar.component(.year, from: now)
        let name = line(widget.text).isEmpty ? format(sameYear ? "MMMMd" : "yMMMMd", target) : line(widget.text)
        switch days {
        case 0: return String(localized: "\(name) is today")
        case 1: return String(localized: "1 day until \(name)")
        case 2...: return String(localized: "\(days) days until \(name)")
        case -1: return String(localized: "1 day since \(name)")
        default: return String(localized: "\(-days) days since \(name)")
        }
    }

    /// Morning from 5, afternoon from 12, evening from 18, night from 22.
    static let greetingHours = [5, 12, 18, 22]

    private static func greeting(hour: Int, name: String) -> String {
        switch (hour, name.isEmpty) {
        case (5..<12, true): String(localized: "Good morning")
        case (5..<12, false): String(localized: "Good morning, \(name)")
        case (12..<18, true): String(localized: "Good afternoon")
        case (12..<18, false): String(localized: "Good afternoon, \(name)")
        case (18..<22, true): String(localized: "Good evening")
        case (18..<22, false): String(localized: "Good evening, \(name)")
        case (_, true): String(localized: "Good night")
        case (_, false): String(localized: "Good night, \(name)")
        }
    }

    private static func sun(
        _ widget: DesktopWidget, inputs: Inputs, calendar: Calendar, format: (String, Date) -> String
    ) -> String {
        guard let solar = inputs.solar, solar.source == .fixed || solar.location != nil else {
            return String(localized: "No location for sunrise and sunset")
        }
        let template = timeTemplate(widget.timeFormat, seconds: false)
        func words(_ event: WallpaperAutomationRule.Event, _ date: Date) -> String {
            let time = format(template, date)
            return event == .sunrise ? String(localized: "Sunrise \(time)") : String(localized: "Sunset \(time)")
        }
        switch widget.sunStyle {
        case .next:
            guard let (event, date) = nextSunEvent(after: inputs.date, solar: solar, calendar: calendar) else {
                return String(localized: "No sunrise or sunset today")
            }
            return words(event, date)
        case .both:
            let today = [WallpaperAutomationRule.Event.sunrise, .sunset].compactMap { event in
                sunEvent(event, on: inputs.date, solar: solar, calendar: calendar).map { words(event, $0) }
            }
            return today.isEmpty ? String(localized: "No sunrise or sunset today") : today.joined(separator: "  ·  ")
        }
    }

    /// Today's sunrise or sunset as the automatic wallpapers plan it: at the clock time fixed for
    /// it, or worked out from the coordinates. Nil without coordinates, and on a polar day or night.
    static func sunEvent(
        _ event: WallpaperAutomationRule.Event, on day: Date, solar: WallpaperSolarSettings, calendar: Calendar
    ) -> Date? {
        if solar.source == .fixed {
            let minute = event == .sunrise ? solar.fixedSunriseMinute : solar.fixedSunsetMinute
            return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
        }
        guard let location = solar.location else { return nil }
        return WallpaperSolarTimes.event(event, on: day, location: location, calendar: calendar)
    }

    /// The first sunrise or sunset after `date`, looking two days ahead.
    static func nextSunEvent(
        after date: Date, solar: WallpaperSolarSettings, calendar: Calendar
    ) -> (WallpaperAutomationRule.Event, Date)? {
        for offset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            let events = [WallpaperAutomationRule.Event.sunrise, .sunset].compactMap { event in
                sunEvent(event, on: day, solar: solar, calendar: calendar).map { (event, $0) }
            }
            if let next = events.filter({ $0.1 > date }).min(by: { $0.1 < $1.1 }) { return next }
        }
        return nil
    }

    // MARK: Content

    /// What `widget` shows at the moment of `inputs`, at `scale` times its size.
    @MainActor
    static func content(
        for widget: DesktopWidget, inputs: Inputs, formatters: Formatters, scale: CGFloat = 1
    ) -> Content {
        let text = text(for: widget, inputs: inputs, formatters: formatters)
        let padding = padding(for: widget, scale: scale)
        switch widget.kind {
        case .analog:
            let face = analogFace(for: widget, inputs: inputs, scale: scale)
            return Content(
                text: text, drawing: .analog(face), size: NSSize(width: face.diameter, height: face.diameter),
                padding: padding)
        case .calendar:
            let grid = calendarGrid(for: widget, inputs: inputs, formatters: formatters, scale: scale)
            return Content(text: text, drawing: .text(grid), size: measure(grid), padding: padding)
        default:
            let attributed = attributedText(text, for: widget, scale: scale)
            return Content(text: text, drawing: .text(attributed), size: measure(attributed), padding: padding)
        }
    }

    /// The size text takes, line breaks included.
    static func measure(_ text: NSAttributedString) -> NSSize {
        let bounds = text.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// A clock face's diameter for each point of the widget's size.
    static let analogScale: CGFloat = 1.5

    static func analogFace(for widget: DesktopWidget, inputs: Inputs, scale: CGFloat = 1) -> AnalogFace {
        let calendar = calendar(for: widget, inputs: inputs)
        let parts = calendar.dateComponents([.hour, .minute, .second], from: inputs.date)
        let hour = Double(parts.hour ?? 0)
        let minute = Double(parts.minute ?? 0)
        let second = Double(parts.second ?? 0)
        let diameter = max(CGFloat(widget.size) * analogScale * scale, 1)
        let shadow = shadow(for: widget, scale: scale).map {
            AnalogFace.Shadow(blur: $0.shadowBlurRadius, offset: abs($0.shadowOffset.height))
        }
        return AnalogFace(
            diameter: diameter, color: widget.textColor,
            lineWidth: diameter * (0.012 + 0.03 * CGFloat(widget.weight) / 900),
            hour: (hour.truncatingRemainder(dividingBy: 12) + minute / 60) / 12,
            minute: (minute + (widget.showsSeconds ? second / 60 : 0)) / 60,
            second: widget.showsSeconds ? second / 60 : nil, shadow: shadow)
    }

    /// This month's grid: its name, the weekdays, then a line for each week, the days under their
    /// weekdays and today in bold and underlined. The weeks start on the region's first weekday.
    @MainActor
    static func calendarGrid(
        for widget: DesktopWidget, inputs: Inputs, formatters: Formatters, scale: CGFloat = 1
    ) -> NSAttributedString {
        let calendar = calendar(for: widget, inputs: inputs)
        let now = inputs.date
        let font = font(for: widget, scale: scale)
        var bold = widget
        bold.weight = min(widget.weight + 300, DesktopWidget.weightRange.upperBound)
        let boldFont = self.font(for: bold, scale: scale)
        let column = ceil(font.pointSize * 2.2)
        let grid = NSMutableParagraphStyle()
        grid.tabStops = (1...7).map { NSTextTab(textAlignment: .right, location: column * CGFloat($0)) }
        let header = NSMutableParagraphStyle()
        header.alignment = .center
        header.paragraphSpacing = font.pointSize * 0.3
        var base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: widget.textColor]
        if let shadow = shadow(for: widget, scale: scale) { base[.shadow] = shadow }

        let result = NSMutableAttributedString()
        func append(_ string: String, _ extra: [NSAttributedString.Key: Any]) {
            result.append(NSAttributedString(string: string, attributes: base.merging(extra) { $1 }))
        }
        append(
            formatters.string(now, template: "yMMMM", locale: inputs.locale, calendar: calendar) + "\n",
            [.paragraphStyle: header, .font: boldFont])

        let first = calendar.firstWeekday
        let symbols = formatters.weekdaySymbols(locale: inputs.locale)
        let faded = widget.textColor.withAlphaComponent(widget.textColor.alphaComponent * 0.6)
        if symbols.count == 7 {
            let ordered = (0..<7).map { symbols[(first - 1 + $0) % 7] }
            append(ordered.map { "\t\($0)" }.joined() + "\n", [.paragraphStyle: grid, .foregroundColor: faded])
        }
        guard let month = calendar.dateInterval(of: .month, for: now),
              let days = calendar.range(of: .day, in: .month, for: now) else { return result }
        let today = calendar.component(.day, from: now)
        var column0 = (calendar.component(.weekday, from: month.start) - first + 7) % 7
        append(String(repeating: "\t", count: column0), [.paragraphStyle: grid])
        for day in days {
            guard let date = calendar.date(byAdding: .day, value: day - days.lowerBound, to: month.start) else { continue }
            let number = formatters.string(date, template: "d", locale: inputs.locale, calendar: calendar)
            append("\t", [.paragraphStyle: grid])
            append(
                number,
                day == today
                    ? [.paragraphStyle: grid, .font: boldFont, .underlineStyle: NSUnderlineStyle.single.rawValue]
                    : [.paragraphStyle: grid])
            column0 += 1
            if column0 == 7, day != days.upperBound - 1 {
                append("\n", [.paragraphStyle: grid])
                column0 = 0
            }
        }
        return result
    }

    // MARK: Look

    /// The widget's font at `scale` times its size. Digits keep one width, so a clock does not
    /// shift as its numbers change.
    static func font(for widget: DesktopWidget, scale: CGFloat = 1) -> NSFont {
        let size = max(CGFloat(widget.size) * scale, 1)
        let weight: NSFont.Weight = switch widget.weight {
        case ...100: .ultraLight
        case ...200: .thin
        case ...300: .light
        case ...400: .regular
        case ...500: .medium
        case ...600: .semibold
        case ...700: .bold
        case ...800: .heavy
        default: .black
        }
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        let design: NSFontDescriptor.SystemDesign? = switch widget.typeface {
        case .standard: nil
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        if let design, let designed = descriptor.withDesign(design) { descriptor = designed }
        descriptor = descriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// The soft shadow that keeps light text readable on a light wallpaper; nil without one.
    static func shadow(for widget: DesktopWidget, scale: CGFloat = 1) -> NSShadow? {
        guard widget.hasShadow else { return nil }
        let size = CGFloat(widget.size) * scale
        let shadow = NSShadow()
        shadow.shadowBlurRadius = max(size * 0.06, 1)
        shadow.shadowOffset = NSSize(width: 0, height: -max(size * 0.015, 0.5))
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        return shadow
    }

    /// The room left around the text so the shadow is not cut off.
    static func padding(for widget: DesktopWidget, scale: CGFloat = 1) -> CGFloat {
        guard let shadow = shadow(for: widget, scale: scale) else { return 1 }
        return ceil(shadow.shadowBlurRadius + abs(shadow.shadowOffset.height)) + 1
    }

    /// The text in the widget's font, colour and shadow. Lines of a text widget line up on the
    /// edge the widget is aligned on.
    static func attributedText(_ text: String, for widget: DesktopWidget, scale: CGFloat = 1) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch widget.alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: widget, scale: scale),
            .foregroundColor: widget.textColor,
            .paragraphStyle: paragraph,
        ]
        if let shadow = shadow(for: widget, scale: scale) { attributes[.shadow] = shadow }
        return NSAttributedString(string: text, attributes: attributes)
    }

    // MARK: Place

    /// The tallest a widget's frame gets, as a fraction of its display's height. However large its
    /// text, a widget so never covers the whole working area, which would make the display count
    /// as covered.
    static let heightLimit: CGFloat = 0.6

    /// The widget's frame on a display whose frame is `display`, for content of `textSize` with
    /// `padding` around it. The position names the content's left edge, centre or right edge
    /// (`alignment`) and its vertical centre; the frame is then moved, never shrunk below the
    /// content, to lie on the display, and is cut only when the content is wider than the display
    /// or taller than `heightLimit` of it. Whole points, rounded down so a display that moves moves
    /// its widgets by exactly as much, and the text is not blurred by a fractional origin.
    static func frame(
        textSize: NSSize, padding: CGFloat, widget: DesktopWidget, display: NSRect
    ) -> NSRect {
        let width = min(ceil(textSize.width) + 2 * padding, display.width)
        let height = min(ceil(textSize.height) + 2 * padding, floor(display.height * heightLimit))
        let anchorX = display.minX + widget.x * display.width
        let anchorY = display.maxY - widget.y * display.height
        let x: CGFloat = switch widget.alignment {
        case .leading: anchorX - padding
        case .center: anchorX - width / 2
        case .trailing: anchorX - width + padding
        }
        let y = anchorY - height / 2
        return NSRect(
            x: min(max(x, display.minX), display.maxX - width).rounded(.down),
            y: min(max(y, display.minY), display.maxY - height).rounded(.down),
            width: width, height: height)
    }

    // MARK: Time

    /// When what any of `widgets` shows next changes after the moment of `inputs`: the next second
    /// for a clock with seconds, the next minute for any other clock, the next hour a greeting
    /// changes at, the next sunrise or sunset (or midnight) for the sun, the next midnight for
    /// dates, countdowns and the month, each in the widget's own time zone. Text and the battery
    /// never change on a timer. Nil when none of them does.
    static func nextChange(after inputs: Inputs, widgets: [DesktopWidget]) -> Date? {
        let now = inputs.date
        return widgets.compactMap { widget -> Date? in
            let calendar = calendar(for: widget, inputs: inputs)
            func end(of component: Calendar.Component) -> Date? {
                calendar.dateInterval(of: component, for: now)?.end
            }
            switch widget.kind {
            case .time, .analog:
                return end(of: widget.showsSeconds ? .second : .minute)
            case .date, .countdown, .calendar:
                return end(of: .day)
            case .greeting:
                return greetingHours.compactMap {
                    calendar.nextDate(
                        after: now, matching: DateComponents(hour: $0, minute: 0, second: 0),
                        matchingPolicy: .nextTime)
                }.min()
            case .sun:
                guard let solar = inputs.solar else { return nil }
                let event = nextSunEvent(after: now, solar: solar, calendar: calendar)?.1
                return [event, end(of: .day)].compactMap { $0 }.min()
            case .text, .battery:
                return nil
            }
        }.min()
    }

    /// The same, for widgets drawn in this Mac's own language.
    static func nextChange(after date: Date, widgets: [DesktopWidget], calendar: Calendar) -> Date? {
        nextChange(after: Inputs(date: date, calendar: calendar, locale: .autoupdatingCurrent), widgets: widgets)
    }
}
