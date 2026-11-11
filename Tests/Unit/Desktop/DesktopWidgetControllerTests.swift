import AppKit
import XCTest
@testable import WallpaperMachine

/// The desktop widgets' windows: one per widget and display it belongs on, kept current only while
/// one of them can be seen, moved with the displays, and never mistaken for a wallpaper window.
@MainActor
final class DesktopWidgetControllerTests: XCTestCase {
    typealias Screen = DesktopWidgetController.Screen

    private let laptop = Screen(
        displayID: 1, uuid: "AAAA-1", name: "Built-in Display",
        frame: NSRect(x: 0, y: 0, width: 1512, height: 982), isMain: true)
    private let external = Screen(
        displayID: 2, uuid: "BBBB-2", name: "Studio Display",
        frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440), isMain: false)

    /// A widget window that records what it was asked to show and is never put on screen.
    private final class FakeSurface: DesktopWidgetSurface {
        var frame: NSRect = .zero
        var text = ""
        var isOnScreen = true
        var removed = false

        func show(_ drawing: DesktopWidgetRendering.Drawing, padding: CGFloat, frame: NSRect) {
            self.frame = frame
            if case .text(let text) = drawing { self.text = text.string } else { self.text = "" }
        }

        func remove() { removed = true }
    }

    /// A battery whose reading the test sets, and which says whether anything listens to it.
    private final class FakeBattery: BatteryLevelSource {
        var reading: BatteryReading?
        private(set) var onChange: (@MainActor () -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0

        func start(onChange: @escaping @MainActor () -> Void) {
            starts += 1
            self.onChange = onChange
        }

        func stop() {
            stops += 1
            onChange = nil
        }
    }

    @MainActor
    private final class Fixture {
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        let defaults: UserDefaults
        var screens: [Screen]
        var now = Date(timeIntervalSince1970: 1_794_171_907)  // 21:05:07 UTC
        var surfacesOnScreen = true
        let battery = FakeBattery()
        private(set) var made: [FakeSurface] = []
        private(set) var scheduled: [Date] = []
        private(set) var cancelled = 0
        private var pending: (@MainActor () -> Void)?
        lazy var store = DesktopWidgetStore(defaults: defaults, center: center)
        lazy var controller = DesktopWidgetController(
            defaults: defaults, center: center, workspaceCenter: workspace,
            screens: { [unowned self] in screens },
            makeSurface: { [unowned self] in
                let surface = FakeSurface()
                surface.isOnScreen = surfacesOnScreen
                made.append(surface)
                return surface
            },
            clock: .init(
                now: { [unowned self] in now },
                calendar: {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: "UTC")!
                    return calendar
                },
                locale: { Locale(identifier: "en_GB") }),
            schedule: { [unowned self] date, action in
                scheduled.append(date)
                pending = action
                return { [unowned self] in cancelled += 1 }
            },
            makeBattery: { [unowned self] in battery })

        init(defaults: UserDefaults, screens: [Screen]) {
            self.defaults = defaults
            self.screens = screens
        }

        var live: [FakeSurface] { made.filter { !$0.removed } }

        /// Runs the scheduled redraw as its timer would.
        func fire() {
            let action = pending
            pending = nil
            action?()
        }

        func screensChanged() {
            center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
    }

    private func makeFixture(screens: [Screen]) throws -> Fixture {
        let fixture = Fixture(defaults: try TemporaryDefaults.make(for: self).defaults, screens: screens)
        addTeardownBlock { @MainActor in fixture.controller.stop() }
        return fixture
    }

    func testWithoutWidgetsThereIsNoWindowAndNoTimer() throws {
        let fixture = try makeFixture(screens: [laptop, external])
        fixture.controller.start()
        fixture.screensChanged()
        XCTAssertTrue(fixture.made.isEmpty)
        XCTAssertTrue(fixture.scheduled.isEmpty)
    }

    func testEachWidgetGoesOnTheDisplaysItIsPlacedOn() throws {
        let fixture = try makeFixture(screens: [laptop, external])
        fixture.controller.start()
        let clock = try fixture.store.add(.time)
        XCTAssertEqual(fixture.controller.shown.map(\.displayID), [1], "a new widget is on the main display")
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:05")

        try fixture.store.update(clock.id) { $0.placement = .all }
        XCTAssertEqual(fixture.controller.shown.map(\.displayID), [1, 2])
        XCTAssertEqual(fixture.made.count, 2, "the main display keeps its window")

        try fixture.store.update(clock.id) { $0.placement = .display(uuid: "bbbb-2", name: "Studio Display") }
        XCTAssertEqual(fixture.controller.shown.map(\.displayID), [2], "by the display's own UUID")
        XCTAssertEqual(fixture.live.count, 1)

        fixture.screens = [laptop]
        fixture.screensChanged()
        XCTAssertTrue(fixture.controller.shown.isEmpty, "a disconnected display takes its widget with it")
        fixture.screens = [laptop, external]
        fixture.screensChanged()
        XCTAssertEqual(fixture.controller.shown.map(\.displayID), [2], "and brings it back")

        try fixture.store.update(clock.id) { $0.isShown = false }
        XCTAssertTrue(fixture.live.isEmpty, "a hidden widget keeps no window")
        try fixture.store.update(clock.id) { $0.isShown = true }
        try fixture.store.remove(clock.id)
        XCTAssertTrue(fixture.live.isEmpty)
    }

    func testTheWordsChangeOnTimeAndOnlyAsOftenAsTheyNeed() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.controller.start()
        let clock = try fixture.store.add(.time)
        XCTAssertEqual(fixture.scheduled.last, Date(timeIntervalSince1970: 1_794_171_960), "21:06")

        fixture.now = Date(timeIntervalSince1970: 1_794_171_960)
        fixture.fire()
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:06")
        XCTAssertEqual(fixture.scheduled.last, Date(timeIntervalSince1970: 1_794_172_020), "21:07")

        try fixture.store.update(clock.id) { $0.showsSeconds = true }
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:06:00")
        XCTAssertEqual(fixture.scheduled.last, Date(timeIntervalSince1970: 1_794_171_961), "each second")

        try fixture.store.remove(clock.id)
        _ = try fixture.store.add(.date)
        XCTAssertEqual(fixture.scheduled.last, Date(timeIntervalSince1970: 1_794_182_400), "dates alone wait for midnight")
    }

    func testNothingIsScheduledWhileNoWidgetCanBeSeenUntilOneCanAgain() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.surfacesOnScreen = false
        fixture.controller.start()
        _ = try fixture.store.add(.time)
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:05", "drawn, so it is right when it shows")
        XCTAssertTrue(fixture.scheduled.isEmpty, "covered, asleep or locked: no timer")
        XCTAssertNil(fixture.controller.nextChange)

        fixture.now = Date(timeIntervalSince1970: 1_794_172_200)
        let surface = try XCTUnwrap(fixture.live.first)
        surface.isOnScreen = true
        fixture.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: NSObject())
        XCTAssertTrue(fixture.scheduled.isEmpty, "another window's occlusion changes nothing")
        fixture.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: surface)
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:10", "brought up to date as it shows")
        XCTAssertEqual(fixture.scheduled.count, 1)

        surface.isOnScreen = false
        fixture.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: surface)
        XCTAssertEqual(fixture.cancelled, 1, "covered again, the timer goes")
        XCTAssertEqual(fixture.scheduled.count, 1)
    }

    func testAWakeOrAClockChangeRedrawsAtOnce() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.controller.start()
        _ = try fixture.store.add(.time)
        fixture.now = Date(timeIntervalSince1970: 1_794_200_000)
        fixture.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(fixture.controller.shown.first?.text, "04:53")
        fixture.now = Date(timeIntervalSince1970: 1_794_171_907)
        fixture.center.post(name: .NSSystemClockDidChange, object: nil)
        XCTAssertEqual(fixture.controller.shown.first?.text, "21:05")
    }

    func testAScreenChangeMovesTheWindowsAndOneThatMovesNothingTouchesNone() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.controller.start()
        _ = try fixture.store.add(.time)
        let before = try XCTUnwrap(fixture.controller.shown.first?.frame)
        for _ in 0..<30 { fixture.screensChanged() }
        XCTAssertEqual(fixture.made.count, 1)
        XCTAssertEqual(fixture.controller.shown.first?.frame, before)

        fixture.screens[0].frame.origin = NSPoint(x: -1512, y: 300)
        fixture.screensChanged()
        XCTAssertEqual(fixture.controller.shown.first?.frame, before.offsetBy(dx: -1512, dy: 300))
        XCTAssertEqual(fixture.made.count, 1, "the same window moves")
    }

    func testABatteryWidgetFollowsTheBatterysNotificationAndKeepsItOnlyWhilePlaced() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.battery.reading = BatteryReading(percent: 82, isDischarging: true)
        fixture.controller.start()
        XCTAssertEqual(fixture.battery.starts, 0, "nothing listens without a battery widget")

        let widget = try fixture.store.add(.battery)
        XCTAssertEqual(fixture.battery.starts, 1)
        let percent = (0.82).formatted(.percent.locale(Locale(identifier: "en_GB")))
        XCTAssertEqual(fixture.controller.shown.first?.text, String(localized: "Battery \(percent)"))
        XCTAssertTrue(fixture.scheduled.isEmpty, "the battery needs no timer")

        fixture.battery.reading = BatteryReading(percent: 83, isDischarging: false, isCharging: true)
        fixture.battery.onChange?()
        let charging = (0.83).formatted(.percent.locale(Locale(identifier: "en_GB")))
        XCTAssertEqual(fixture.controller.shown.first?.text, String(localized: "Charging \(charging)"))

        try fixture.store.update(widget.id) { $0.isShown = false }
        XCTAssertEqual(fixture.battery.stops, 1, "a hidden battery widget stops listening")
        try fixture.store.update(widget.id) { $0.isShown = true }
        XCTAssertEqual(fixture.battery.starts, 2)
        fixture.controller.stop()
        XCTAssertEqual(fixture.battery.stops, 2)
    }

    func testTheSunFollowsTheSunriseAndSunsetSettingsAndRedrawsWhenTheyChange() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.controller.start()
        _ = try fixture.store.add(.sun)
        XCTAssertEqual(fixture.controller.shown.first?.text, String(localized: "No location for sunrise and sunset"))
        XCTAssertTrue(fixture.scheduled.isEmpty, "nothing to wait for without a place")

        var solar = WallpaperSolarSettings()
        solar.source = .fixed
        solar.fixedSunriseMinute = 7 * 60 + 15
        fixture.defaults.set(try JSONEncoder().encode(solar), forKey: WallpaperAutomationStore.solarKey)
        fixture.center.post(name: WallpaperAutomationStore.didChangeNotification, object: nil)
        XCTAssertEqual(fixture.controller.shown.first?.text, String(localized: "Sunrise \("07:15")"), "tomorrow's")
        XCTAssertEqual(fixture.scheduled.last, Date(timeIntervalSince1970: 1_794_182_400), "midnight comes first")
    }

    func testStoppingTakesEveryWidgetDownAndListensNoMore() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.controller.start()
        _ = try fixture.store.add(.time)
        fixture.controller.stop()
        XCTAssertTrue(fixture.live.isEmpty)
        XCTAssertTrue(fixture.controller.shown.isEmpty)
        _ = try fixture.store.add(.date)
        XCTAssertEqual(fixture.made.count, 1)
    }

    // MARK: The window

    func testTheWindowSitsBetweenTheWallpaperAndTheDesktopIconsAndIsNoWallpaperWindow() {
        let window = DesktopWidgetWindow.make()
        defer { window.close() }
        XCTAssertGreaterThan(window.level.rawValue, Int(CGWindowLevelForKey(.desktopWindow)), "above the wallpaper")
        XCTAssertLessThan(window.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)), "below Finder's icons")
        XCTAssertTrue(window.ignoresMouseEvents, "a click there reaches the desktop")
        XCTAssertFalse(window.isOpaque, "only the text covers the wallpaper")
        XCTAssertFalse(window.canHide, "hiding the app hides only the panel")
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(
            WallpaperPresentationPolicy.wallpaperWindows().contains(window),
            "occlusion tracking, the window audit and the posters look only at wallpaper windows")

        let widget = DesktopWidget(kind: .time)
        let text = DesktopWidgetRendering.attributedText("21:05", for: widget)
        window.show(.text(text), padding: 4, frame: NSRect(x: 10, y: 20, width: 300, height: 140))
        XCTAssertEqual(window.frame, NSRect(x: 10, y: 20, width: 300, height: 140))
        XCTAssertEqual(window.shownText, "21:05")
    }
}
