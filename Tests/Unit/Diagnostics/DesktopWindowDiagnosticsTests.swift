import AppKit
import XCTest

@testable import WallpaperMachine

/// What a diagnostics report says about the wallpaper windows. The windows
/// themselves are injected as observations: reading real ones needs a desktop.
@MainActor
final class DesktopWindowDiagnosticsTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 3456, height: 2234)

    private func entry(
        layer: Int = -2_147_483_623, alpha: Double = 1, isOnScreen: Bool = true,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 3456, height: 2234)
    ) -> DesktopWindowObservation.WindowServerEntry {
        .init(layer: layer, alpha: alpha, isOnScreen: isOnScreen, bounds: bounds)
    }

    /// A wallpaper window that is shown: ordered in, on the active Space,
    /// composited by the window server and covering its display.
    private func healthy(
        _ configure: (inout DesktopWindowObservation) -> Void = { _ in }
    ) -> DesktopWindowObservation {
        var window = DesktopWindowObservation(
            windowNumber: 1234, className: "MWEWallpaperDesktopWindow", displayID: 1,
            frame: display, displayFrame: display, level: -2_147_483_623, alpha: 1,
            isOrderedIn: true, isOnActiveSpace: true, occlusionVisible: true,
            collectionBehaviorRaw: 0x51, server: entry())
        configure(&window)
        return window
    }

    func testClassificationPrecedence() {
        let cases: [(String, DesktopWindowObservation, DesktopWindowState)] = [
            ("healthy", healthy(), .ok),
            ("not ordered in beats every other fault", healthy {
                $0.isOrderedIn = false; $0.server = nil; $0.isOnActiveSpace = false
                $0.frame = CGRect(x: 9000, y: 0, width: 10, height: 10); $0.alpha = 0
            }, .notOrderedIn),
            ("no window server entry beats the Space", healthy {
                $0.server = nil; $0.isOnActiveSpace = false
            }, .absentFromWindowServer),
            ("another Space beats the server's on-screen flag", healthy {
                $0.isOnActiveSpace = false; $0.server = entry(isOnScreen: false)
            }, .notOnActiveSpace),
            ("AppKit visible but the window server lists it off screen", healthy {
                $0.server = entry(isOnScreen: false)
            }, .offScreenInWindowServer),
            ("off screen beats a frame outside the display", healthy {
                $0.server = entry(isOnScreen: false)
                $0.frame = CGRect(x: 9000, y: 0, width: 10, height: 10)
            }, .offScreenInWindowServer),
            ("frame beside the display", healthy {
                $0.frame = CGRect(x: 3500, y: 0, width: 3456, height: 2234)
            }, .outsideItsDisplay),
            ("a window on no display", healthy {
                $0.displayID = nil; $0.displayFrame = nil
            }, .outsideItsDisplay),
            ("outside beats transparent", healthy {
                $0.frame = CGRect(x: 9000, y: 0, width: 10, height: 10); $0.alpha = 0.5
            }, .outsideItsDisplay),
            ("a window that is not opaque", healthy { $0.alpha = 0.99 }, .transparent),
            ("a window server copy that is not opaque", healthy { $0.server = entry(alpha: 0) }, .transparent),
            ("a window inside a larger display", healthy {
                $0.frame = CGRect(x: 100, y: 100, width: 500, height: 400)
            }, .ok),
            ("occlusion alone is not a fault", healthy { $0.occlusionVisible = false }, .ok),
        ]
        for (name, window, expected) in cases {
            XCTAssertEqual(DesktopWindowState.classify(window), expected, name)
            XCTAssertEqual(window.state, expected, name)
        }
    }

    /// The one test that pins a whole line. It is the sample in
    /// `docs/features/diagnostics.md#wallpaper-window-state`, the format a bug report is read and
    /// searched by, so changing it is a change of that documented format and the doc moves with
    /// it. The tests below check that each field is wired to its own property (a swap would pass
    /// here, because every field of a healthy window reads the same way) and how numbers print.
    func testTheDocumentedWindowLineFormat() {
        XCTAssertEqual(
            DesktopWindowDiagnostics.line(healthy()),
            "desktop window MWEWallpaperDesktopWindow #1234 display 1: frame (0,0,3456,2234), "
                + "display frame (0,0,3456,2234), level -2147483623, collection behavior 0x51, alpha 1.0, "
                + "ordered in yes, active Space yes, occlusion visible yes; "
                + "window server: layer -2147483623, alpha 1.0, on screen yes, bounds (0,0,3456,2234); state ok")
        XCTAssertEqual(
            DesktopWindowDiagnostics.lines([healthy()], separateSpaces: true).first,
            "desktop windows: 1 wallpaper window, displays have separate Spaces: yes")
    }

    func testFractionalGeometryAndAlphaKeepTheirDecimals() {
        let line = DesktopWindowDiagnostics.line(healthy {
            $0.frame = CGRect(x: -1512.25, y: 0.04, width: 1512, height: 982.5)
            $0.alpha = 0.333
            $0.server = entry(alpha: 0.5, bounds: CGRect(x: -1512, y: -0.04, width: 1512, height: 982))
        })
        XCTAssertTrue(line.contains("frame (-1512.3,0,1512,982.5),"), line)
        XCTAssertTrue(line.contains("alpha 0.33,"), line)
        XCTAssertTrue(line.contains("alpha 0.5, on screen yes, bounds (-1512,0,1512,982)"), line)
    }

    func testUnreadableGeometryIsPrintedAsUnknown() {
        let line = DesktopWindowDiagnostics.line(healthy {
            $0.frame = .null; $0.displayFrame = .infinite
        })
        XCTAssertTrue(line.contains("frame (?,?,0,0), display frame (?,?,?,?),"), line)
    }

    func testOffSpaceWindowIsReportedWithItsState() {
        // On another Space the server still has the window, but not on screen.
        let offSpace = healthy {
            $0.isOnActiveSpace = false; $0.occlusionVisible = false
            $0.server = entry(isOnScreen: false)
        }
        let separate = DesktopWindowDiagnostics.lines([offSpace], separateSpaces: true)
        XCTAssertEqual(separate.count, 2)
        XCTAssertEqual(separate[0], "desktop windows: 1 wallpaper window, displays have separate Spaces: yes")
        XCTAssertTrue(separate[1].hasSuffix("; state notOnActiveSpace"), separate[1])
        XCTAssertTrue(separate[1].contains("active Space no, occlusion visible no;"), separate[1])
        XCTAssertTrue(separate[1].contains("on screen no,"), separate[1])

        let shared = DesktopWindowDiagnostics.lines([offSpace, healthy { $0.windowNumber = 1300; $0.displayID = 2 }],
                                                    separateSpaces: false)
        XCTAssertEqual(shared[0], "desktop windows: 2 wallpaper windows, displays have separate Spaces: no")
        XCTAssertEqual(shared.count, 3)
    }

    func testNoWindowsSaysSo() {
        XCTAssertEqual(
            DesktopWindowDiagnostics.lines([], separateSpaces: true),
            ["desktop windows: none open, displays have separate Spaces: yes"])
    }

    func testMissingServerEntryIsNotACrash() {
        let line = DesktopWindowDiagnostics.line(healthy {
            $0.server = nil; $0.displayID = nil; $0.displayFrame = nil
        })
        XCTAssertTrue(line.contains(" display ?: "), line)
        XCTAssertTrue(line.contains("display frame ?,"), line)
        XCTAssertTrue(line.contains("window server: absent; state absentFromWindowServer"), line)
    }

    func testWindowServerEntryReadsADescription() throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        var description: [String: Any] = [
            kCGWindowLayer as String: -2_147_483_623,
            kCGWindowAlpha as String: 0.5,
            kCGWindowBounds as String: CGRectCreateDictionaryRepresentation(bounds),
            kCGWindowNumber as String: 77,
        ]
        let offScreen = try XCTUnwrap(DesktopWindowObservation.WindowServerEntry(description: description))
        XCTAssertEqual(offScreen, entry(alpha: 0.5, isOnScreen: false, bounds: bounds),
                       "the window server omits the on-screen key instead of writing false")

        description[kCGWindowIsOnscreen as String] = true
        XCTAssertEqual(DesktopWindowObservation.WindowServerEntry(description: description)?.isOnScreen, true)
        description[kCGWindowIsOnscreen as String] = false
        XCTAssertEqual(DesktopWindowObservation.WindowServerEntry(description: description)?.isOnScreen, false)

        description[kCGWindowLayer as String] = nil
        XCTAssertNil(DesktopWindowObservation.WindowServerEntry(description: description))
        description[kCGWindowLayer as String] = 0
        description[kCGWindowBounds as String] = ["X": 1]
        XCTAssertNil(DesktopWindowObservation.WindowServerEntry(description: description))
    }

    /// The window-server read is the one piece the injected observations skip:
    /// the CFArray of raw window IDs and the keys it returns. Any window the
    /// session lists on screen exercises it; none (a headless runner) skips.
    func testWindowServerReadMatchesTheWindowList() throws {
        let listed = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let sample = listed.compactMap { description -> (Int, Int)? in
            guard let number = (description[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let layer = (description[kCGWindowLayer as String] as? NSNumber)?.intValue else { return nil }
            return (number, layer)
        }.first
        guard let sample else { throw XCTSkip("no on-screen window in this session") }
        let entries = DesktopWindowReader.windowServerEntries(for: [sample.0, -1, 0])
        XCTAssertEqual(Set(entries.keys), [sample.0], "numbers that are not window IDs are not asked about")
        XCTAssertEqual(entries[sample.0]?.layer, sample.1)
        XCTAssertEqual(entries[sample.0]?.isOnScreen, true)
    }

    func testWindowServerReadWithoutValidWindowsIsEmpty() {
        XCTAssertTrue(DesktopWindowReader.windowServerEntries(for: []).isEmpty)
        XCTAssertTrue(DesktopWindowReader.windowServerEntries(for: [-1, 0]).isEmpty)
        XCTAssertTrue(DesktopWindowReader.windowServerEntries(for: [Int(Int32.max)]).isEmpty,
                      "a window that does not exist has no entry")
    }

    private final class UnshownWindow: NSWindow {}

    /// A window that was never ordered in reports that, whatever the window
    /// server says; AppKit's own values are read as they are.
    func testObservationReadsAppKitStateOfAWindowThatWasNeverShown() {
        let window = UnshownWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360), styleMask: .borderless,
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: -2_147_483_623)
        window.alphaValue = 0.5
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let observed = DesktopWindowReader.observation(of: window, server: nil)
        XCTAssertEqual(observed.className, NSStringFromClass(UnshownWindow.self))
        XCTAssertEqual(observed.frame.size, CGSize(width: 640, height: 360))
        XCTAssertEqual(observed.level, -2_147_483_623)
        XCTAssertEqual(observed.alpha, 0.5)
        XCTAssertEqual(observed.collectionBehaviorRaw, NSWindow.CollectionBehavior([.canJoinAllSpaces, .stationary]).rawValue)
        XCTAssertFalse(observed.isOrderedIn)
        XCTAssertEqual(observed.state, .notOrderedIn)
        XCTAssertTrue(DesktopWindowReader.current(windows: [], windowServer: { _ in
            XCTFail("no windows, no window server call"); return [:]
        }).isEmpty)
    }
}
