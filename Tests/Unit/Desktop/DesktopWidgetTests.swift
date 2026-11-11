import AppKit
import XCTest
@testable import WallpaperMachine

/// Desktop widgets: what each kind says or draws, where it sits on a display, when it next changes,
/// and how it is kept.
@MainActor
final class DesktopWidgetTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!
    /// Sunday, November 8 2026, 21:05:07 UTC.
    private let moment = Date(timeIntervalSince1970: 1_794_171_907)

    /// The words, with the narrow and no-break spaces the formats put before AM and PM made plain.
    private func text(_ widget: DesktopWidget, locale: Locale? = nil) -> String {
        DesktopWidgetRendering.text(
            for: widget, at: moment, locale: locale ?? english, timeZone: utc,
            formatters: DesktopWidgetRendering.Formatters())
        .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// The Gregorian calendar of a region, in UTC, with that region's first weekday.
    private func calendar(_ locale: Locale? = nil) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale ?? english
        calendar.timeZone = utc
        return calendar
    }

    private func inputs(
        at date: Date? = nil, locale: Locale? = nil, battery: BatteryReading? = nil,
        solar: WallpaperSolarSettings? = nil
    ) -> DesktopWidgetRendering.Inputs {
        .init(
            date: date ?? moment, calendar: calendar(locale), locale: locale ?? english, battery: battery,
            solar: solar)
    }

    private func say(_ widget: DesktopWidget, _ inputs: DesktopWidgetRendering.Inputs) -> String {
        DesktopWidgetRendering.text(for: widget, inputs: inputs, formatters: DesktopWidgetRendering.Formatters())
    }

    // MARK: Words

    func testAClockFollowsTheChosenHourCycleAndShowsSecondsOnlyWhenAskedTo() {
        var clock = DesktopWidget(kind: .time)
        XCTAssertEqual(text(clock), "9:05 PM", "the system's own cycle for the region")
        XCTAssertEqual(text(clock, locale: Locale(identifier: "en_GB")), "21:05")

        clock.timeFormat = .twentyFourHour
        XCTAssertEqual(text(clock), "21:05")
        clock.timeFormat = .twelveHour
        XCTAssertEqual(text(clock, locale: Locale(identifier: "en_GB")).lowercased(), "9:05 pm")

        clock.showsSeconds = true
        XCTAssertEqual(text(clock), "9:05:07 PM")
    }

    func testADateIsWrittenInTheStyleChosenAndTheRegionsOrder() {
        var date = DesktopWidget(kind: .date)
        let expected: [DesktopWidget.DateStyle: String] = [
            .weekdayMonthDay: "Sunday, November 8", .monthDayYear: "November 8, 2026",
            .abbreviated: "Sun, Nov 8", .numeric: "11/8/2026", .weekday: "Sunday", .monthYear: "November 2026",
        ]
        for style in expected.keys {
            date.dateStyle = style
            XCTAssertEqual(text(date), expected[style], "\(style)")
        }
        date.dateStyle = .numeric
        XCTAssertEqual(text(date, locale: Locale(identifier: "de_DE")), "8.11.2026")
    }

    func testTheNewDateStylesCountWeeksAndDaysAsTheRegionDoes() {
        var date = DesktopWidget(kind: .date)
        date.dateStyle = .monthYear
        XCTAssertEqual(say(date, inputs()), "November 2026")
        date.dateStyle = .weekNumber
        XCTAssertEqual(say(date, inputs()), String(localized: "Week \("46")"), "US weeks start on Sunday")
        XCTAssertEqual(
            say(date, inputs(locale: Locale(identifier: "de_DE"))), String(localized: "Week \("45")"),
            "ISO weeks start on Monday")
        date.dateStyle = .dayOfYear
        XCTAssertEqual(say(date, inputs()), String(localized: "Day \("312")"))
    }

    func testADateCanBeWrittenInAnotherCalendarInThatCalendarsOwnWords() {
        var date = DesktopWidget(kind: .date)
        date.calendarSystem = .chinese
        date.dateStyle = .monthDayYear
        XCTAssertEqual(say(date, inputs(locale: Locale(identifier: "zh_Hans"))), "2026丙午年九月三十")
        date.dateStyle = .weekdayMonthDay
        XCTAssertEqual(say(date, inputs(locale: Locale(identifier: "zh_Hans"))), "九月三十星期日")
        date.calendarSystem = .hebrew
        XCTAssertEqual(say(date, inputs()), "Sunday, 28 Heshvan")
    }

    func testAClockOrADateCanShowAnotherTimeZoneAfterALabel() {
        var clock = DesktopWidget(kind: .time)
        clock.timeZone = "Asia/Tokyo"
        XCTAssertEqual(text(clock, locale: Locale(identifier: "en_GB")), "06:05", "already the next morning")
        clock.text = "  Tokyo \n"
        XCTAssertEqual(text(clock, locale: Locale(identifier: "en_GB")), "Tokyo 06:05", "the label on one line")

        var date = DesktopWidget(kind: .date)
        date.timeZone = "Asia/Tokyo"
        XCTAssertEqual(text(date), "Monday, November 9")
        XCTAssertEqual(
            DesktopWidgetRendering.nextChange(after: inputs(), widgets: [date]),
            Date(timeIntervalSince1970: 1_794_236_400), "midnight in Tokyo, 15:00 UTC")
    }

    func testATextWidgetKeepsItsLinesAndAlignsThemOnItsEdge() {
        var note = DesktopWidget(kind: .text)
        note.text = "Ship it\nthen rest"
        let content = DesktopWidgetRendering.content(
            for: note, inputs: inputs(), formatters: DesktopWidgetRendering.Formatters())
        XCTAssertEqual(content.text, "Ship it\nthen rest")
        var single = note
        single.text = "Ship it"
        let one = DesktopWidgetRendering.content(
            for: single, inputs: inputs(), formatters: DesktopWidgetRendering.Formatters())
        XCTAssertGreaterThan(content.size.height, one.size.height * 1.8, "two lines are twice as tall")
        note.alignment = .trailing
        guard case .text(let attributed) = DesktopWidgetRendering.content(
            for: note, inputs: inputs(), formatters: DesktopWidgetRendering.Formatters()).drawing,
            let paragraph = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else { return XCTFail("text is drawn as text") }
        XCTAssertEqual(paragraph.alignment, .right)
        XCTAssertNil(DesktopWidgetRendering.nextChange(after: inputs(), widgets: [note]), "text never changes")
    }

    func testACountdownCountsWholeDaysToAndSinceItsDay() {
        var countdown = DesktopWidget(kind: .countdown, today: moment, calendar: calendar())
        XCTAssertEqual(countdown.targetDay, "2026-12-08", "a new one counts thirty days")
        countdown.targetDay = "2026-11-20"
        XCTAssertEqual(say(countdown, inputs()), String(localized: "\(12) days until \("November 20")"))
        countdown.targetDay = "2027-01-01"
        XCTAssertEqual(
            say(countdown, inputs()), String(localized: "\(54) days until \("January 1, 2027")"),
            "another year's day says the year")
        countdown.text = "Launch"
        countdown.targetDay = "2026-11-09"
        XCTAssertEqual(say(countdown, inputs()), String(localized: "1 day until \("Launch")"))
        countdown.targetDay = "2026-11-08"
        XCTAssertEqual(say(countdown, inputs()), String(localized: "\("Launch") is today"))
        countdown.targetDay = "2026-11-07"
        XCTAssertEqual(say(countdown, inputs()), String(localized: "1 day since \("Launch")"))
        countdown.targetDay = "2026-10-01"
        XCTAssertEqual(say(countdown, inputs()), String(localized: "\(38) days since \("Launch")"))
        XCTAssertEqual(
            DesktopWidgetRendering.nextChange(after: inputs(), widgets: [countdown]),
            Date(timeIntervalSince1970: 1_794_182_400), "midnight")
    }

    func testAGreetingFollowsThePartOfTheDayAndChangesOnTheHour() {
        var greeting = DesktopWidget(kind: .greeting)
        func at(_ hour: Int) -> DesktopWidgetRendering.Inputs {
            inputs(at: Date(timeIntervalSince1970: 1_794_096_000 + Double(hour) * 3600))  // Nov 8 00:00 UTC
        }
        XCTAssertEqual(say(greeting, at(4)), String(localized: "Good night"))
        XCTAssertEqual(say(greeting, at(5)), String(localized: "Good morning"))
        XCTAssertEqual(say(greeting, at(12)), String(localized: "Good afternoon"))
        XCTAssertEqual(say(greeting, at(21)), String(localized: "Good evening"))
        greeting.text = "Alex"
        XCTAssertEqual(say(greeting, at(22)), String(localized: "Good night, \("Alex")"))
        XCTAssertEqual(
            DesktopWidgetRendering.nextChange(after: inputs(), widgets: [greeting]),
            Date(timeIntervalSince1970: 1_794_175_200), "22:00, when evening turns to night")
    }

    func testTheBatteryWidgetSaysHowFullTheBatteryIsAndWhetherItCharges() {
        let battery = DesktopWidget(kind: .battery)
        let percent = (0.82).formatted(.percent.locale(english))
        XCTAssertEqual(say(battery, inputs()), String(localized: "No battery"))
        XCTAssertEqual(
            say(battery, inputs(battery: .init(percent: 82, isDischarging: true))),
            String(localized: "Battery \(percent)"))
        XCTAssertEqual(
            say(battery, inputs(battery: .init(percent: 82, isDischarging: false))),
            String(localized: "Battery \(percent)"), "on power and held at a level, not charging")
        XCTAssertEqual(
            say(battery, inputs(battery: .init(percent: 82, isDischarging: false, isCharging: true))),
            String(localized: "Charging \(percent)"))
        XCTAssertNil(
            DesktopWidgetRendering.nextChange(after: inputs(), widgets: [battery]),
            "the battery's notification redraws it, not a timer")
    }

    func testTheSunWidgetUsesTheAutomaticWallpapersSunriseAndSunset() throws {
        var sun = DesktopWidget(kind: .sun)
        sun.timeFormat = .twentyFourHour
        XCTAssertEqual(say(sun, inputs()), String(localized: "No location for sunrise and sunset"))
        XCTAssertNil(DesktopWidgetRendering.nextChange(after: inputs(), widgets: [sun]))

        var fixed = WallpaperSolarSettings()
        fixed.source = .fixed
        fixed.fixedSunriseMinute = 6 * 60 + 30
        fixed.fixedSunsetMinute = 22 * 60
        XCTAssertEqual(
            say(sun, inputs(solar: fixed)), String(localized: "Sunset \("22:00")"), "the next one, still today")
        XCTAssertEqual(
            DesktopWidgetRendering.nextChange(after: inputs(solar: fixed), widgets: [sun]),
            Date(timeIntervalSince1970: 1_794_175_200), "at sunset")
        sun.sunStyle = .both
        XCTAssertEqual(
            say(sun, inputs(solar: fixed)),
            String(localized: "Sunrise \("06:30")") + "  ·  " + String(localized: "Sunset \("22:00")"))

        let polar = WallpaperSolarSettings(location: WallpaperSolarLocation(latitude: 89, longitude: 0))
        XCTAssertEqual(say(sun, inputs(solar: polar)), String(localized: "No sunrise or sunset today"), "polar night")
        let london = WallpaperSolarSettings(location: WallpaperSolarLocation(latitude: 51.5, longitude: 0))
        let next = try XCTUnwrap(DesktopWidgetRendering.nextSunEvent(after: moment, solar: london, calendar: calendar()))
        XCTAssertEqual(next.0, .sunrise, "after a London sunset comes the next sunrise")
        XCTAssertEqual(next.1.timeIntervalSince(moment) / 3600, 10, accuracy: 1, "a little after seven")
    }

    func testAnAnalogClockPointsItsHandsAtTheTime() throws {
        var analog = DesktopWidget(kind: .analog)
        let content = DesktopWidgetRendering.content(
            for: analog, inputs: inputs(), formatters: DesktopWidgetRendering.Formatters())
        guard case .analog(let face) = content.drawing else { return XCTFail("a face, not text") }
        XCTAssertEqual(content.text, "21:05")
        XCTAssertEqual(face.hour, (9 + 5.0 / 60) / 12, accuracy: 1e-9)
        XCTAssertEqual(face.minute, 5.0 / 60, accuracy: 1e-9)
        XCTAssertNil(face.second)
        XCTAssertEqual(content.size, NSSize(width: 150, height: 150), "one and a half times its size across")

        analog.showsSeconds = true
        analog.timeZone = "Asia/Kolkata"
        let seconds = DesktopWidgetRendering.analogFace(for: analog, inputs: inputs())
        XCTAssertEqual(seconds.minute, (35 + 7.0 / 60) / 60, accuracy: 1e-9, "02:35:07 in India")
        XCTAssertEqual(try XCTUnwrap(seconds.second), 7.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(
            DesktopWidgetRendering.nextChange(after: inputs(), widgets: [analog]),
            Date(timeIntervalSince1970: 1_794_171_908))
    }

    func testTheMonthCalendarPutsEachDayUnderItsWeekdayAndMarksToday() throws {
        let month = DesktopWidget(kind: .calendar)
        let content = DesktopWidgetRendering.content(
            for: month, inputs: inputs(), formatters: DesktopWidgetRendering.Formatters())
        XCTAssertEqual(content.text, "November 2026")
        guard case .text(let grid) = content.drawing else { return XCTFail("a grid of text") }
        let lines = grid.string.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 7, "the month, the weekdays and five weeks")
        XCTAssertEqual(lines[1], "\tS\tM\tT\tW\tT\tF\tS", "Sunday first in the US")
        XCTAssertEqual(lines[2], "\t1\t2\t3\t4\t5\t6\t7", "November 1 2026 is a Sunday")
        XCTAssertEqual(lines[6], "\t29\t30")
        let today = (grid.string as NSString).range(of: "\t8\t").location + 1
        XCTAssertNotNil(grid.attribute(.underlineStyle, at: today, effectiveRange: nil), "today is marked")
        XCTAssertNil(grid.attribute(.underlineStyle, at: today + 2, effectiveRange: nil))

        let monday = DesktopWidgetRendering.calendarGrid(
            for: month, inputs: inputs(locale: Locale(identifier: "de_DE")),
            formatters: DesktopWidgetRendering.Formatters())
        let weeks = monday.string.components(separatedBy: "\n")
        XCTAssertEqual(weeks[2], "\t\t\t\t\t\t\t1", "a Monday-first week puts Sunday last")
    }

    // MARK: Place

    private let display = NSRect(x: 0, y: 0, width: 1512, height: 982)

    func testThePositionNamesTheChosenEdgeOfTheTextAndItsVerticalCentre() {
        var widget = DesktopWidget(kind: .time)
        widget.x = 0.5
        widget.y = 0.25
        let size = NSSize(width: 200, height: 100)
        XCTAssertEqual(
            DesktopWidgetRendering.frame(textSize: size, padding: 10, widget: widget, display: display),
            NSRect(x: 646, y: 676, width: 220, height: 120), "centred on the point a quarter down the display")

        widget.alignment = .leading
        XCTAssertEqual(
            DesktopWidgetRendering.frame(textSize: size, padding: 10, widget: widget, display: display).minX + 10,
            756, "the text starts at the point")
        widget.alignment = .trailing
        XCTAssertEqual(
            DesktopWidgetRendering.frame(textSize: size, padding: 10, widget: widget, display: display).maxX - 10,
            756, "the text ends at the point")
    }

    func testAWidgetStaysOnItsDisplayWhereverItIsPutAndWhereverTheDisplayIs() {
        var widget = DesktopWidget(kind: .time)
        let size = NSSize(width: 300, height: 120)
        let left = NSRect(x: -1920, y: 200, width: 1920, height: 1080)
        for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, 0.0)] {
            widget.x = x
            widget.y = y
            for screen in [display, left] {
                let frame = DesktopWidgetRendering.frame(textSize: size, padding: 4, widget: widget, display: screen)
                XCTAssertTrue(screen.contains(frame), "\(x),\(y) on \(screen)")
                XCTAssertEqual(frame.size, NSSize(width: 308, height: 128), "moved, never shrunk")
            }
        }
    }

    func testAWidgetIsNeverTallerThanMostOfItsDisplay() {
        let widget = DesktopWidget(kind: .text)
        let frame = DesktopWidgetRendering.frame(
            textSize: NSSize(width: 400, height: 5000), padding: 4, widget: widget, display: display)
        XCTAssertEqual(frame.height, floor(display.height * DesktopWidgetRendering.heightLimit))
        XCTAssertTrue(display.contains(frame))
    }

    func testTheLargestWidgetNeverMakesADisplayCountAsCovered() throws {
        // A small display with a large menu bar and Dock leaves the smallest working area.
        let screen = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let working = NSRect(x: 0, y: 70, width: 1024, height: 660)
        let probe = try XCTUnwrap(WallpaperCoverageProbes.probeFrame(for: working))
        var widget = DesktopWidget(kind: .time)
        widget.size = DesktopWidget.sizeRange.upperBound
        widget.weight = 900
        widget.showsSeconds = true
        widget.timeFormat = .twelveHour
        let text = DesktopWidgetRendering.attributedText("12:00:00 PM", for: widget)
        let frame = DesktopWidgetRendering.frame(
            textSize: text.size(), padding: DesktopWidgetRendering.padding(for: widget), widget: widget,
            display: screen)
        XCTAssertFalse(frame.contains(probe), "some of the probe always shows beside it")

        var analog = DesktopWidget(kind: .analog)
        analog.size = DesktopWidget.sizeRange.upperBound
        let face = DesktopWidgetRendering.analogFace(
            for: analog, inputs: .init(date: moment, calendar: .current, locale: english))
        let faceFrame = DesktopWidgetRendering.frame(
            textSize: NSSize(width: face.diameter, height: face.diameter),
            padding: DesktopWidgetRendering.padding(for: analog), widget: analog, display: screen)
        XCTAssertFalse(faceFrame.contains(probe), "nor beside the largest clock face")
    }

    // MARK: Time

    func testTheWordsNextChangeAtTheNextSecondMinuteOrMidnightTheyNeed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var clock = DesktopWidget(kind: .time)
        let date = DesktopWidget(kind: .date)
        func next(_ widgets: [DesktopWidget]) -> Date? {
            DesktopWidgetRendering.nextChange(after: moment, widgets: widgets, calendar: calendar)
        }
        XCTAssertNil(next([]))
        XCTAssertEqual(next([date]), Date(timeIntervalSince1970: 1_794_182_400), "midnight")
        XCTAssertEqual(next([date, clock]), Date(timeIntervalSince1970: 1_794_171_960), "21:06")
        clock.showsSeconds = true
        XCTAssertEqual(next([date, clock]), Date(timeIntervalSince1970: 1_794_171_908), "21:05:08")
    }

    // MARK: Keeping them

    func testAWidgetSavedWithFewerFieldsKeepsWhatItHasAndDefaultsTheRest() throws {
        let data = Data(#"[{"id":"a","kind":"date","size":40,"placement":{"all":{}}}]"#.utf8)
        let widgets = try DesktopWidgetStore.decode(data)
        XCTAssertEqual(widgets.count, 1)
        XCTAssertEqual(widgets[0].size, 40)
        XCTAssertEqual(widgets[0].placement, .all)
        XCTAssertEqual(widgets[0].weight, DesktopWidget(kind: .date).weight)
        XCTAssertEqual(widgets[0].dateStyle, .weekdayMonthDay)
        XCTAssertNil(widgets[0].timeZone)
        XCTAssertEqual(widgets[0].calendarSystem, .system)
        XCTAssertEqual(widgets[0].text, "")

        let every = try DesktopWidgetStore.decode(JSONEncoder().encode(DesktopWidget.Kind.allCases.map {
            var widget = DesktopWidget(kind: $0)
            widget.timeZone = "Europe/Paris"
            widget.text = "Line one\nline two"
            return widget
        }))
        XCTAssertEqual(every.map(\.kind), DesktopWidget.Kind.allCases, "every kind is kept")
    }

    func testValuesNoControlCouldChooseAreRefused() {
        for json in [
            #"[{"id":"a","kind":"time","size":2000}]"#,
            #"[{"id":"a","kind":"time","x":1.5}]"#,
            #"[{"id":"a","kind":"time","color":"white"}]"#,
            #"[{"id":"a","kind":"time","weight":450}]"#,
            #"[{"id":"a","kind":"time"},{"id":"a","kind":"date"}]"#,
            #"[{"id":"","kind":"time"}]"#,
            #"[{"id":"a","kind":"weather"}]"#,
            #"[{"id":"a","kind":"time","timeZone":"Mars/Olympus_Mons"}]"#,
            #"[{"id":"a","kind":"countdown","targetDay":"2026-02-30"}]"#,
            #"[{"id":"a","kind":"countdown","targetDay":"20261120"}]"#,
            #"[{"id":"a","kind":"text","text":"a\u0000b"}]"#,
            "[{\"id\":\"a\",\"kind\":\"text\",\"text\":\"\(String(repeating: "x", count: 501))\"}]",
        ] {
            XCTAssertThrowsError(try DesktopWidgetStore.decode(Data(json.utf8)), json)
        }
    }

    func testTheStoreKeepsEachChangeAndTellsTheDesktop() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: DesktopWidgetStore.didChangeNotification, object: nil, queue: nil) { _ in
            posts += 1
        }
        defer { center.removeObserver(token) }
        let store = DesktopWidgetStore(defaults: defaults, center: center)

        let clock = try store.add(.time)
        let second = try store.add(.time)
        XCTAssertNotEqual(clock.y, second.y, "a new widget does not land on one already there")
        try store.update(clock.id) {
            $0.size = 5000
            $0.weight = 640
            $0.color = "#12ab9F"
        }
        try store.remove(second.id)
        XCTAssertEqual(posts, 4)

        let reopened = DesktopWidgetStore(defaults: defaults, center: center)
        XCTAssertEqual(reopened.widgets.count, 1)
        XCTAssertEqual(reopened.widgets[0].size, DesktopWidget.sizeRange.upperBound, "a change is kept in range")
        XCTAssertEqual(reopened.widgets[0].weight, 600)
        XCTAssertEqual(reopened.widgets[0].color, "#12ab9F")
        XCTAssertThrowsError(try store.remove(second.id)) { XCTAssertEqual($0 as? DesktopWidgetError, .missing) }

        for _ in 1..<DesktopWidgetStore.limit { try store.add(.date) }
        XCTAssertThrowsError(try store.add(.date)) { XCTAssertEqual($0 as? DesktopWidgetError, .tooMany) }
    }

    func testABackupCarriesTheWidgetsAndRefusesBrokenOnes() throws {
        XCTAssertTrue(WallpaperBackupPreferences.allowedKeys.contains(DesktopWidgetStore.storageKey))
        let valid = try JSONEncoder().encode([DesktopWidget(kind: .time)])
        XCTAssertNoThrow(try WallpaperBackupPreferences.validate(valid, forKey: DesktopWidgetStore.storageKey))
        XCTAssertThrowsError(try WallpaperBackupPreferences.validate(
            Data(#"[{"id":"a","kind":"time","opacity":0}]"#.utf8), forKey: DesktopWidgetStore.storageKey))
    }

    func testTheColourWellsColourIsKeptAsSRGBHex() {
        XCTAssertEqual(DesktopWidget.hex(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)), "#FF8000")
        XCTAssertNotNil(DesktopWidget.rgb("#00ff7F"))
        XCTAssertNil(DesktopWidget.rgb("#00ff7"))
        XCTAssertNil(DesktopWidget.rgb("00ff7F0"))
    }
}
