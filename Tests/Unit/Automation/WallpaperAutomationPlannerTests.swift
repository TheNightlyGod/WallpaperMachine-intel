import XCTest
@testable import WallpaperMachine

final class WallpaperAutomationPlannerTests: XCTestCase {
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: .init(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    private func target(_ id: String) -> WallpaperAutomationTarget { .init(kind: .wallpaper, id: id) }

    func testWeekdayWeekendScheduleCatchesUpOnceAndFindsNextBoundary() {
        let calendar = calendar()
        let monday = WallpaperAutomationRule(weekdays: Set(2...6), minute: 8 * 60, target: target("work"))
        let weekend = WallpaperAutomationRule(weekdays: [1, 7], minute: 9 * 60, target: target("weekend"))
        var configuration = DisplayWallpaperAutomation()
        configuration.mode = .schedule
        configuration.rules = [monday, weekend]
        let result = WallpaperAutomationPlanner.resolve(configuration, now: date(2026, 10, 10, 12, in: calendar), dark: false, solar: nil, calendar: calendar)
        XCTAssertEqual(result.current?.target.id, "weekend")
        XCTAssertEqual(result.current?.date, date(2026, 10, 10, 9, in: calendar))
        XCTAssertEqual(result.next?.date, date(2026, 10, 11, 9, in: calendar))
    }

    func testSameTimeUsesTheLastRuleAndAppearanceDoesNotDependOnTheClock() {
        let calendar = calendar()
        var value = DisplayWallpaperAutomation()
        value.mode = .schedule
        value.rules = [.init(minute: 480, target: target("first")), .init(minute: 480, target: target("last"))]
        let now = date(2026, 10, 8, 9, in: calendar)
        XCTAssertEqual(WallpaperAutomationPlanner.resolve(value, now: now, dark: false, solar: nil, calendar: calendar).current?.target.id, "last")
        value.mode = .appearance; value.light = target("light"); value.dark = target("dark")
        let morning = WallpaperAutomationPlanner.resolve(value, now: now, dark: true, solar: nil, calendar: calendar)
        let evening = WallpaperAutomationPlanner.resolve(value, now: now.addingTimeInterval(3600), dark: true, solar: nil, calendar: calendar)
        XCTAssertEqual(morning.current?.target.id, "dark")
        XCTAssertEqual(morning.current?.key, evening.current?.key)
    }

    func testDSTMissingTimeMovesForwardAndRepeatedTimeRunsOnlyOnce() {
        let calendar = calendar("America/New_York")
        var value = DisplayWallpaperAutomation()
        value.mode = .schedule
        value.rules = [.init(minute: 150, target: target("spring"))]
        let spring = WallpaperAutomationPlanner.resolve(value, now: date(2026, 3, 8, 4, in: calendar), dark: false, solar: nil, calendar: calendar)
        XCTAssertEqual(spring.current?.date, date(2026, 3, 8, 3, in: calendar))
        value.rules = [.init(minute: 90, target: target("fall"))]
        let fall = WallpaperAutomationPlanner.resolve(value, now: date(2026, 11, 1, 3, in: calendar), dark: false, solar: nil, calendar: calendar)
        XCTAssertEqual(fall.current?.date, date(2026, 11, 1, 1, 30, in: calendar))
        XCTAssertEqual(fall.next?.date, date(2026, 11, 2, 1, 30, in: calendar))
    }

    func testEquatorialEquinoxAndPolarDayHaveUsefulSolarResults() throws {
        let calendar = calendar()
        let day = date(2026, 3, 20, 12, in: calendar)
        let place = WallpaperSolarLocation(latitude: 0, longitude: 0)
        let sunrise = try XCTUnwrap(WallpaperSolarTimes.event(.sunrise, on: day, location: place, calendar: calendar))
        let sunset = try XCTUnwrap(WallpaperSolarTimes.event(.sunset, on: day, location: place, calendar: calendar))
        XCTAssertLessThan(abs(sunrise.timeIntervalSince(date(2026, 3, 20, 6, in: calendar))), 20 * 60)
        XCTAssertLessThan(abs(sunset.timeIntervalSince(date(2026, 3, 20, 18, in: calendar))), 20 * 60)
        let polar = WallpaperSolarLocation(latitude: 80, longitude: 0)
        XCTAssertNil(WallpaperSolarTimes.event(.sunrise, on: date(2026, 6, 21, 12, in: calendar), location: polar, calendar: calendar))
        XCTAssertNil(WallpaperSolarTimes.event(.sunset, on: date(2026, 6, 21, 12, in: calendar), location: polar, calendar: calendar))
    }

    func testSolarOffsetsCanCrossMidnightAndMissingLocationDoesNotInventTimes() throws {
        let calendar = calendar("Asia/Singapore")
        let day = date(2026, 3, 20, 12, in: calendar)
        let location = WallpaperSolarLocation(latitude: 0, longitude: 179)
        let sunrise = try XCTUnwrap(WallpaperSolarTimes.event(.sunrise, on: day, location: location, calendar: calendar))
        XCTAssertTrue(calendar.isDate(sunrise, inSameDayAs: day))
        var value = DisplayWallpaperAutomation()
        value.mode = .schedule
        value.rules = [.init(weekdays: [calendar.component(.weekday, from: day)], event: .sunrise, offset: -180, target: target("dawn"))]
        let shifted = sunrise.addingTimeInterval(-3 * 3600)
        XCTAssertFalse(calendar.isDate(shifted, inSameDayAs: day))
        let result = WallpaperAutomationPlanner.resolve(value, now: shifted.addingTimeInterval(1800), dark: false, solar: WallpaperSolarSettings(location: location), calendar: calendar)
        XCTAssertEqual(result.current?.date, shifted)
        XCTAssertNil(WallpaperAutomationPlanner.resolve(value, now: day, dark: false, solar: nil, calendar: calendar).current)
    }

    func testFixedTimesUseTheClockRatherThanTheSun() {
        let calendar = calendar("Asia/Shanghai")
        var value = DisplayWallpaperAutomation()
        value.mode = .schedule
        value.rules = [.init(event: .sunrise, target: target("morning"))]
        let solar = WallpaperSolarSettings(
            source: .fixed,
            location: WallpaperSolarLocation(latitude: 30.08, longitude: 103.87),
            fixedSunriseMinute: 6 * 60 + 30,
            fixedSunsetMinute: 18 * 60 + 20)

        let before = WallpaperAutomationPlanner.resolve(
            value, now: date(2026, 10, 18, 6, 0, in: calendar), dark: false,
            solar: solar, calendar: calendar)
        XCTAssertEqual(before.current?.date, date(2026, 10, 17, 6, 30, in: calendar))
        XCTAssertEqual(before.next?.date, date(2026, 10, 18, 6, 30, in: calendar))

        let after = WallpaperAutomationPlanner.resolve(
            value, now: date(2026, 10, 18, 7, 0, in: calendar), dark: false,
            solar: solar, calendar: calendar)
        XCTAssertEqual(after.current?.date, date(2026, 10, 18, 6, 30, in: calendar))
    }

    func testFixedTimesApplyTheRuleOffsetAndNeedNoCoordinates() {
        let calendar = calendar("Asia/Shanghai")
        var value = DisplayWallpaperAutomation()
        value.mode = .schedule
        value.rules = [.init(event: .sunset, offset: -15, target: target("evening"))]
        // No location: the fixed source plans from the clock alone.
        let solar = WallpaperSolarSettings(
            source: .fixed, location: nil,
            fixedSunriseMinute: 6 * 60, fixedSunsetMinute: 18 * 60 + 20)
        let result = WallpaperAutomationPlanner.resolve(
            value, now: date(2026, 10, 18, 19, 0, in: calendar), dark: false,
            solar: solar, calendar: calendar)
        XCTAssertEqual(result.current?.date, date(2026, 10, 18, 18, 5, in: calendar))
    }

    func testCoordinatesSourceStillUsesTheSunEvenWithFixedTimesSet() throws {
        let calendar = calendar("Asia/Shanghai")
        var value = DisplayWallpaperAutomation()
        value.mode = .schedule
        value.rules = [.init(event: .sunrise, target: target("morning"))]
        let location = WallpaperSolarLocation(latitude: 30.08, longitude: 103.87)
        let solar = WallpaperSolarSettings(
            source: .coordinates, location: location,
            fixedSunriseMinute: 1, fixedSunsetMinute: 23 * 60)
        let day = date(2026, 10, 18, 12, in: calendar)
        let expected = try XCTUnwrap(
            WallpaperSolarTimes.event(.sunrise, on: day, location: location, calendar: calendar))
        let result = WallpaperAutomationPlanner.resolve(
            value, now: day, dark: false, solar: solar, calendar: calendar)
        XCTAssertEqual(result.current?.date, expected)
    }

    func testAutomaticSourcePlansFromTheTrackedLocation() throws {
        let calendar = calendar("Asia/Shanghai")
        var value = DisplayWallpaperAutomation()
        value.mode = .schedule
        value.rules = [.init(event: .sunrise, target: target("morning"))]
        let location = WallpaperSolarLocation(latitude: 30.08, longitude: 103.87)
        let solar = WallpaperSolarSettings(
            source: .automatic, location: location,
            fixedSunriseMinute: 1, fixedSunsetMinute: 23 * 60)
        let day = date(2026, 10, 18, 12, in: calendar)
        let expected = try XCTUnwrap(
            WallpaperSolarTimes.event(.sunrise, on: day, location: location, calendar: calendar))
        let result = WallpaperAutomationPlanner.resolve(
            value, now: day, dark: false, solar: solar, calendar: calendar)
        XCTAssertEqual(result.current?.date, expected)

        // Automatic without a fix yet has no event to plan with, like coordinates.
        let missing = WallpaperAutomationPlanner.resolve(
            value, now: day, dark: false,
            solar: WallpaperSolarSettings(source: .automatic, location: nil),
            calendar: calendar)
        XCTAssertNil(missing.current)
    }
}
