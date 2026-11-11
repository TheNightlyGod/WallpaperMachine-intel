import AppKit
import XCTest
@testable import WallpaperMachine

/// Hide the notch: a black strip behind the menu bar of each notched display, kept only while the
/// switch is on and moved with the displays, and never mistaken for a wallpaper window.
@MainActor
final class NotchMaskControllerTests: XCTestCase {
    typealias Screen = NotchMaskController.Screen

    /// A 14-inch MacBook Pro at its default scale: a 38-point menu bar beside the notch.
    private let laptop = Screen(
        displayID: 1, frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: NSRect(x: 0, y: 64, width: 1512, height: 880), hasNotch: true)
    /// An external display above and to the right of it, with a 25-point menu bar and no notch.
    private let external = Screen(
        displayID: 2, frame: NSRect(x: 1512, y: 400, width: 2560, height: 1440),
        visibleFrame: NSRect(x: 1512, y: 400, width: 2560, height: 1415), hasNotch: false)

    // MARK: Geometry

    func testTheStripCoversTheMenuBarOfANotchedDisplayFromEdgeToEdge() {
        XCTAssertEqual(
            NotchMaskController.maskFrame(for: laptop), NSRect(x: 0, y: 944, width: 1512, height: 38))

        var arranged = laptop
        arranged.frame.origin = NSPoint(x: -1512, y: 300)
        arranged.visibleFrame.origin = NSPoint(x: -1512, y: 364)
        XCTAssertEqual(
            NotchMaskController.maskFrame(for: arranged), NSRect(x: -1512, y: 1244, width: 1512, height: 38),
            "a display placed left of and above the main one keeps its strip at its own top edge")
    }

    func testADisplayWithoutANotchGetsNoStrip() {
        XCTAssertNil(NotchMaskController.maskFrame(for: external), "its menu bar keeps its own look")
    }

    func testAMenuBarThatHidesItselfLeavesNoStrip() {
        var hidden = laptop
        hidden.visibleFrame = NSRect(x: 0, y: 64, width: 1512, height: 918)
        XCTAssertNil(NotchMaskController.maskFrame(for: hidden), "nothing separates the working area from the top")
    }

    func testTheStripStaysOutOfTheWorkingAreaTheCoverageProbesWatch() throws {
        for screen in [laptop, Screen(
            displayID: 3, frame: NSRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: NSRect(x: 72, y: 0, width: 1398, height: 924), hasNotch: true)
        ] {
            let strip = try XCTUnwrap(NotchMaskController.maskFrame(for: screen))
            let probe = try XCTUnwrap(WallpaperCoverageProbes.probeFrame(for: screen.visibleFrame))
            XCTAssertFalse(strip.intersects(probe), "the strip must never make a display count as covered")
            XCTAssertFalse(strip.intersects(screen.visibleFrame), "nor draw over the wallpaper's working area")
        }
    }

    // MARK: The controller

    @MainActor
    private final class Fixture {
        let center = NotificationCenter()
        let defaults: UserDefaults
        var screens: [Screen]
        private(set) var made: [NSWindow] = []
        lazy var controller = NotchMaskController(
            defaults: defaults, center: center, screens: { [unowned self] in screens },
            makeMask: { [unowned self] frame in
                // Never ordered in: a test puts nothing on the developer's screen.
                let mask = NotchMaskController.makeMaskWindow(frame: frame)
                made.append(mask)
                return mask
            })

        init(defaults: UserDefaults, screens: [Screen]) {
            self.defaults = defaults
            self.screens = screens
        }

        func setEnabled(_ enabled: Bool) {
            NotchMaskController.setEnabled(enabled, defaults: defaults, center: center)
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

    func testItIsOffUntilTurnedOnAndThenStripsOnlyTheNotchedDisplays() throws {
        let fixture = try makeFixture(screens: [laptop, external])
        fixture.controller.start()
        fixture.screensChanged()
        XCTAssertTrue(fixture.made.isEmpty, "off by default, and a screen change while off makes nothing")

        fixture.setEnabled(true)
        XCTAssertEqual(fixture.controller.placedFrames, [1: NSRect(x: 0, y: 944, width: 1512, height: 38)])
        XCTAssertTrue(NotchMaskController.isEnabled(defaults: fixture.defaults), "the choice is kept")

        fixture.setEnabled(false)
        XCTAssertTrue(fixture.controller.placedFrames.isEmpty)
        fixture.screensChanged()
        XCTAssertEqual(fixture.made.count, 1, "turned off, it no longer follows the screens")
    }

    func testAChoiceMadeBeforeLaunchIsShownAtStart() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.defaults.set(true, forKey: NotchMaskController.defaultsKey)
        fixture.controller.start()
        XCTAssertEqual(Array(fixture.controller.placedFrames.keys), [1])
    }

    func testTheStripsFollowTheDisplaysAndTheMenuBar() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.setEnabled(true)
        fixture.controller.start()
        XCTAssertEqual(fixture.made.count, 1)

        for _ in 0..<60 { fixture.screensChanged() }
        XCTAssertEqual(fixture.made.count, 1, "a screen change that moves nothing makes no window")

        // A larger text size gives the laptop's menu bar a few more points.
        fixture.screens[0].visibleFrame.size.height = 874
        fixture.screensChanged()
        XCTAssertEqual(fixture.controller.placedFrames[1], NSRect(x: 0, y: 938, width: 1512, height: 44))
        XCTAssertEqual(fixture.made.count, 1, "the same strip moves")

        // A second notched laptop display is connected while the menu bar of the first hides itself.
        var second = laptop
        second.displayID = 4
        second.frame.origin.x = 1512
        second.visibleFrame.origin.x = 1512
        fixture.screens = [
            Screen(displayID: 1, frame: laptop.frame, visibleFrame: laptop.frame, hasNotch: true), second,
        ]
        fixture.screensChanged()
        XCTAssertEqual(fixture.controller.placedFrames, [4: NSRect(x: 1512, y: 944, width: 1512, height: 38)])

        fixture.screens = []
        fixture.screensChanged()
        XCTAssertTrue(fixture.controller.placedFrames.isEmpty, "a disconnected display takes its strip with it")
    }

    func testStoppingTakesEveryStripDown() throws {
        let fixture = try makeFixture(screens: [laptop])
        fixture.setEnabled(true)
        fixture.controller.start()
        fixture.controller.stop()
        XCTAssertTrue(fixture.controller.placedFrames.isEmpty)
        fixture.setEnabled(true)
        fixture.screensChanged()
        XCTAssertEqual(fixture.made.count, 1, "a stopped controller follows neither the switch nor the screens")
    }

    // MARK: The window

    func testTheStripSitsBetweenTheWallpaperAndTheDesktopIconsAndIsNoWallpaperWindow() {
        let mask = NotchMaskController.makeMaskWindow(frame: NSRect(x: 0, y: 944, width: 1512, height: 38))
        defer { mask.close() }
        XCTAssertGreaterThan(mask.level.rawValue, Int(CGWindowLevelForKey(.desktopWindow)), "above the wallpaper")
        XCTAssertLessThan(mask.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)), "below Finder's icons")
        XCTAssertTrue(mask.ignoresMouseEvents, "a click there reaches the menu bar")
        XCTAssertTrue(mask.isOpaque)
        XCTAssertFalse(mask.canHide, "hiding the app hides only the panel")
        XCTAssertTrue(mask.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(
            WallpaperPresentationPolicy.wallpaperWindows().contains(mask),
            "occlusion tracking, the window audit and the posters look only at wallpaper windows")
    }
}
