import AppKit
import XCTest
@testable import WallpaperMachine

/// A wallpaper window that only records what is done to it, in one log shared with the mover.
@MainActor
private final class FakeWindow: WallpaperPinnableWindow {
    let number: Int
    var displayID: UInt32?
    var wallpaperID: String?
    var isOrderedIn = true
    var allSpaces = true
    var hidden = false
    var lastFade: TimeInterval?
    let log: Log
    /// Sorted, as the window server's answer is read.
    var spaces: [UInt64]
    var space: UInt64 {
        get { spaces[0] }
        set { spaces = [newValue] }
    }

    init(_ number: Int, display: UInt32, space: UInt64, wallpaper: String?, log: Log) {
        self.number = number
        displayID = display
        spaces = [space]
        wallpaperID = wallpaper
        self.log = log
    }

    var joinsAllSpaces: Bool {
        get { allSpaces }
        set { allSpaces = newValue; log.events.append("\(number) all-spaces \(newValue)") }
    }

    func setConcealed(_ concealed: Bool, fade: TimeInterval) {
        hidden = concealed
        lastFade = fade
        log.events.append("\(number) \(concealed ? "hide" : "show")")
    }
}

@MainActor
private final class Log { var events: [String] = [] }

@MainActor
private final class FakeMover: WallpaperSpaceWindowMoving {
    var windows: [Int: FakeWindow] = [:]
    /// Whether the calls that put a window on several Spaces exist.
    var placesOnSeveralSpaces = true
    let log: Log
    init(log: Log) { self.log = log }

    func spaces(ofWindow number: Int) -> [UInt64]? { windows[number]?.spaces }

    func place(window number: Int, onSpaces spaces: [UInt64]) -> Bool {
        guard placesOnSeveralSpaces, let window = windows[number] else { return false }
        window.spaces = spaces.sorted()
        log.events.append("\(number) place \(spaces.sorted())")
        return true
    }

    func move(windows numbers: [Int], toSpace space: UInt64) {
        for number in numbers {
            windows[number]?.space = space
            log.events.append("\(number) move \(space)")
        }
    }
}

@MainActor
private final class PinRig {
    let log = Log()
    let mover: FakeMover
    var windows: [FakeWindow] = []
    var pins: [UInt32: WallpaperSpacePin] = [:]
    var holding = Set<UInt32>()
    var reduceMotion = false
    /// Every wait the pinning asked for, in order.
    private(set) var sleeps: [Duration] = []
    private(set) var clock = ContinuousClock.now
    private(set) var pinning: WallpaperSpacePinning!
    let center = NotificationCenter()
    /// The window the next `wallpaperLayerInstalled` notification announces.
    var opening: FakeWindow?

    init(available: Bool = true) {
        mover = FakeMover(log: log)
        pinning = WallpaperSpacePinning(
            windows: { [unowned self] in self.windows },
            pins: { [unowned self] in self.pins },
            holding: { [unowned self] in self.holding.contains($0) },
            mover: available ? mover : nil,
            reduceMotion: { [unowned self] in self.reduceMotion },
            now: { [unowned self] in self.clock },
            sleep: { [unowned self] duration in
                await MainActor.run { self.sleeps.append(duration) }
                try await Task.sleep(for: .seconds(3_600))
            },
            center: center,
            windowCenter: center,
            openedWindow: { [unowned self] _ in self.opening })
    }

    @discardableResult
    func window(_ number: Int, display: UInt32 = 1, space: UInt64 = 5, wallpaper: String? = nil) -> FakeWindow {
        let window = FakeWindow(number, display: display, space: space, wallpaper: wallpaper, log: log)
        windows.append(window)
        mover.windows[number] = window
        return window
    }

    /// Announces a window about to be ordered in on `display`, as the renderer does.
    func announceOpening(_ window: FakeWindow, display: UInt32 = 1, reason: String = "open") {
        opening = window
        center.post(name: WallpaperSwitchHoldNotification.layerInstalled, object: nil,
                    userInfo: ["displayID": NSNumber(value: display), "reason": reason])
    }

    func advance(_ duration: Duration) { clock = clock.advanced(by: duration) }
}

/// The pinning of wallpaper windows to a display's current desktop. Nothing here opens a window
/// or calls the window server.
@MainActor
final class WallpaperSpacePinningTests: XCTestCase {
    func testADisplayThatFollowsSpacesKeepsItsWindowsOnItsCurrentDesktopOnly() {
        let rig = PinRig()
        let pinned = rig.window(10, display: 1)
        let other = rig.window(20, display: 2)
        rig.pins = [1: .init(space: 5, content: .ready)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        XCTAssertFalse(pinned.allSpaces)
        XCTAssertEqual(pinned.space, 5)
        XCTAssertTrue(other.allSpaces, "a display that does not follow Spaces is left on every desktop")
        XCTAssertFalse(rig.log.events.contains { $0.hasPrefix("20") })

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.pinning.update()
        XCTAssertEqual(pinned.space, 9, "the window follows the person to the desktop they went to")
        XCTAssertFalse(pinned.hidden, "nothing changes there, so the wallpaper stays visible")

        rig.pins = [:]
        rig.pinning.update()
        XCTAssertTrue(pinned.allSpaces, "leaving the mode puts the window back on every desktop")
    }

    func testAWindowIsHiddenBeforeItMovesAndShownWithAFadeOnceItsWallpaperIsReady() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.pins = [1: .init(space: 5, content: .ready)]
        rig.pinning.start()
        defer { rig.pinning.stop() }
        rig.log.events.removeAll()

        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.update()

        XCTAssertEqual(rig.log.events, ["10 hide", "10 move 9"], "the old picture never reaches the new desktop")
        XCTAssertTrue(rig.pinning.isConcealed(1))

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.pinning.update()
        XCTAssertFalse(window.hidden)
        XCTAssertEqual(window.lastFade, WallpaperSpacePinning.Configuration().fade)
        XCTAssertFalse(rig.pinning.isConcealed(1))
    }

    func testReduceMotionShowsTheWindowWithoutAFade() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.reduceMotion = true
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.pinning.update()

        XCTAssertFalse(window.hidden)
        XCTAssertEqual(window.lastFade, 0)
    }

    func testAHiddenDisplayWaitsForTheSwitchHoldToLetGo() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()
        defer { rig.pinning.stop() }
        rig.holding = [1]

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.pinning.update()
        XCTAssertTrue(window.hidden, "a web page or clip is not ready until the hold lets go")

        rig.holding = []
        rig.pinning.update()
        XCTAssertFalse(window.hidden)
    }

    func testASwitchHoldOnAVisibleDisplayHidesNothing() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.holding = [1]
        rig.pins = [1: .init(space: 5, content: .ready)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        XCTAssertFalse(window.hidden, "a manual switch keeps its veil on a visible window")
        XCTAssertFalse(rig.pinning.isConcealed(1))
    }

    func testALoadThatNeverEndsIsShownAfterTheCeilingButAWaitingOneStaysHidden() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()
        defer { rig.pinning.stop() }
        let ceiling = WallpaperSpacePinning.Configuration().loadingCeiling

        rig.advance(ceiling)
        rig.pinning.update()
        XCTAssertFalse(window.hidden, "a wallpaper that never loads does not leave the desktop on a still")

        rig.pinning.update()
        XCTAssertFalse(window.hidden, "and it is not hidden again until it is ready")

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.pinning.update()
        rig.pins = [1: .init(space: 5, content: .waiting)]
        rig.pinning.update()
        rig.advance(ceiling * 2)
        rig.pinning.update()
        XCTAssertTrue(window.hidden, "paused playback keeps the desktop's own still on screen")
    }

    func testADisplayWaitingForPlaybackPastTheCeilingArmsNoZeroWait() async {
        let rig = PinRig()
        let window = rig.window(10)
        rig.pins = [1: .init(space: 9, content: .waiting)]
        rig.pinning.start()
        defer { rig.pinning.stop() }
        rig.advance(WallpaperSpacePinning.Configuration().loadingCeiling * 2)
        rig.pinning.update()
        rig.pinning.update()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(window.hidden, "paused playback keeps the desktop's own still on screen")
        XCTAssertTrue(rig.sleeps.isEmpty, "nothing can end a wait for playback, so no ceiling is armed: \(rig.sleeps)")
    }

    func testADisplayThatLoadsArmsItsCeilingOnce() async {
        let rig = PinRig()
        rig.window(10)
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()
        defer { rig.pinning.stop() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(rig.sleeps, [WallpaperSpacePinning.Configuration().loadingCeiling])
    }

    func testAFullScreenSpaceLeavesTheWindowWhereItIs() {
        let rig = PinRig()
        let window = rig.window(10, space: 5)
        rig.pins = [1: .init(space: nil, content: .ready)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        XCTAssertFalse(window.allSpaces)
        XCTAssertEqual(window.space, 5)
        XCTAssertFalse(rig.log.events.contains { $0.contains("move") })
    }

    func testAWindowThatAppearsLaterIsPinnedAndHiddenLikeTheOthers() {
        let rig = PinRig()
        rig.window(10)
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        let late = rig.window(11, space: 5)
        rig.pinning.update()

        XCTAssertTrue(late.hidden)
        XCTAssertFalse(late.allSpaces)
        XCTAssertEqual(late.space, 9)
    }

    func testWithoutTheWindowServerCallsEveryWindowStaysOnEveryDesktop() {
        let rig = PinRig(available: false)
        let window = rig.window(10)
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        XCTAssertTrue(window.allSpaces)
        XCTAssertFalse(window.hidden)
        XCTAssertTrue(rig.log.events.isEmpty)
    }

    func testStopPutsEveryWindowBackOnEveryDesktopAndShowsIt() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()

        rig.pinning.stop()

        XCTAssertTrue(window.allSpaces)
        XCTAssertFalse(window.hidden)
        XCTAssertFalse(rig.pinning.isConcealed(1))
    }

    func testAWindowStaysOnTheDesktopsChosenForItsWallpaper() {
        let rig = PinRig()
        let shared = rig.window(10, space: 5, wallpaper: "aurora")
        let kept = rig.window(11, space: 5, wallpaper: "basalt")
        rig.pins = [1: .init(space: 5, content: .ready, desktops: ["aurora": [5, 7], "basalt": [6]])]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        XCTAssertEqual(shared.spaces, [5, 7], "a wallpaper two desktops share stays still between them")
        XCTAssertEqual(kept.space, 6, "a wallpaper kept for another desktop waits there")

        rig.pins = [1: .init(space: 6, content: .ready, desktops: ["aurora": [5, 7], "basalt": [6]])]
        rig.pinning.update()
        XCTAssertEqual(shared.spaces, [5, 7], "neither follows the person")
        XCTAssertEqual(kept.space, 6)
        XCTAssertFalse(shared.hidden || kept.hidden)
    }

    func testOnlyAWindowThatBelongsOnTheLoadingDesktopIsHidden() {
        let rig = PinRig()
        let left = rig.window(10, space: 5, wallpaper: "aurora")
        rig.pins = [1: .init(space: 5, content: .ready, desktops: ["aurora": [5], "basalt": [6]])]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        // The person arrives on desktop 6, whose wallpaper is not loaded yet.
        rig.pins = [1: .init(space: 6, content: .loading, desktops: ["aurora": [5], "basalt": [6]], incoming: "basalt")]
        rig.pinning.update()
        XCTAssertFalse(left.hidden, "the wallpaper left behind waits on its own desktop")
        XCTAssertEqual(left.space, 5)
        XCTAssertTrue(rig.pinning.isConcealed(1))

        let arriving = rig.window(11, space: 5)
        rig.pinning.update()
        XCTAssertTrue(arriving.hidden, "a window not known yet is the one that loads")
        XCTAssertEqual(arriving.space, 6)

        arriving.wallpaperID = "basalt"
        rig.pins = [1: .init(space: 6, content: .ready, desktops: ["aurora": [5], "basalt": [6]])]
        rig.pinning.update()
        XCTAssertFalse(arriving.hidden)
        XCTAssertEqual(arriving.space, 6)
    }

    func testAKeptWallpaperThatRunsOnIsNeverHiddenWhileTheSwitchFinishes() {
        let rig = PinRig()
        let left = rig.window(10, space: 5, wallpaper: "aurora")
        let kept = rig.window(11, space: 6, wallpaper: "basalt")
        let desktops: [String: Set<UInt64>] = ["aurora": [5], "basalt": [6]]
        rig.pins = [1: .init(space: 5, content: .ready, desktops: desktops)]
        rig.pinning.start()
        defer { rig.pinning.stop() }
        rig.log.events.removeAll()

        // The renderer already runs the kept wallpaper; the app still counts the switch as loading.
        rig.pins = [1: .init(space: 6, content: .loading, desktops: desktops, incoming: "basalt")]
        rig.pinning.update()
        XCTAssertFalse(kept.hidden, "the desktop picture never flashes through")
        XCTAssertFalse(left.hidden)
        XCTAssertFalse(rig.pinning.isConcealed(1))
        XCTAssertTrue(rig.log.events.isEmpty, "nothing is hidden, shown or moved: \(rig.log.events)")
    }

    func testAWindowNotOrderedInYetIsNotTakenForTheWallpaperAlreadyShowing() {
        let rig = PinRig()
        rig.window(10, space: 5, wallpaper: "aurora")
        let desktops: [String: Set<UInt64>] = ["aurora": [5], "basalt": [6]]
        rig.pins = [1: .init(space: 5, content: .ready, desktops: desktops)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        // A host has listed the new page's window, which is still loading and not ordered in.
        let staged = rig.window(11, space: 6, wallpaper: "basalt")
        staged.isOrderedIn = false
        rig.pins = [1: .init(space: 6, content: .loading, desktops: desktops, incoming: "basalt")]
        rig.pinning.update()
        XCTAssertTrue(rig.pinning.isConcealed(1), "the desktop waits for its wallpaper to be ready")
        XCTAssertTrue(staged.hidden, "so the window cannot flash in before its first frame")
    }

    func testAWallpaperNoDesktopIsChosenForStaysWhereItIsWhileAnotherIsOnItsWay() {
        let rig = PinRig()
        let playing = rig.window(10, space: 5, wallpaper: "from-a-playlist")
        rig.pins = [1: .init(space: 5, content: .ready, desktops: ["basalt": [6]])]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        rig.pins = [1: .init(space: 6, content: .ready, desktops: ["basalt": [6]], incoming: "basalt")]
        rig.pinning.update()
        XCTAssertEqual(playing.space, 5, "it never reaches the desktop it is leaving for")
        XCTAssertFalse(playing.hidden)

        rig.pins = [1: .init(space: 6, content: .ready, desktops: ["basalt": [6]])]
        rig.pinning.update()
        XCTAssertEqual(playing.space, 6, "with nothing on its way it follows the person, as before")
    }

    func testWithoutTheCallsForSeveralSpacesAWindowGoesToOneOfItsDesktops() {
        let rig = PinRig()
        rig.mover.placesOnSeveralSpaces = false
        let shared = rig.window(10, space: 3, wallpaper: "aurora")
        rig.pins = [1: .init(space: 7, content: .ready, desktops: ["aurora": [5, 7]])]
        rig.pinning.start()
        defer { rig.pinning.stop() }
        XCTAssertEqual(shared.space, 7, "the desktop the person is on, when it is one of them")

        rig.pins = [1: .init(space: 6, content: .ready, desktops: ["aurora": [5, 7]])]
        rig.pinning.update()
        XCTAssertEqual(shared.space, 5, "else the first of them")
    }

    func testAWindowAboutToOpenWhileItsDesktopLoadsIsHiddenBeforeItIsOrderedIn() {
        let rig = PinRig()
        rig.window(10, space: 5, wallpaper: "aurora")
        rig.pins = [1: .init(space: 6, content: .loading, desktops: ["aurora": [5]], incoming: "basalt")]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        let opening = FakeWindow(11, display: 1, space: 6, wallpaper: nil, log: rig.log)
        rig.announceOpening(opening)
        XCTAssertTrue(opening.hidden, "its first picture never reaches the screen")
        XCTAssertFalse(opening.allSpaces, "and it does not join the other desktops")

        let elsewhere = FakeWindow(12, display: 2, space: 6, wallpaper: nil, log: rig.log)
        rig.announceOpening(elsewhere, display: 2)
        XCTAssertTrue(elsewhere.allSpaces, "a display that does not follow Spaces is left alone")
        XCTAssertFalse(elsewhere.hidden)

        let replaced = FakeWindow(13, display: 1, space: 6, wallpaper: nil, log: rig.log)
        rig.announceOpening(replaced, reason: "replace")
        XCTAssertTrue(replaced.allSpaces, "only a window that opens is handled here")
    }

    func testAWindowOpeningOnAVisibleDesktopIsKeptOffTheOthersButShown() {
        let rig = PinRig()
        rig.pins = [1: .init(space: 5, content: .ready)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        let opening = FakeWindow(11, display: 1, space: 5, wallpaper: nil, log: rig.log)
        rig.announceOpening(opening)
        XCTAssertFalse(opening.allSpaces)
        XCTAssertFalse(opening.hidden, "a manual switch keeps its veil on a visible window")
    }

    func testADesktopChangeAnnouncedByTheSpaceMonitorUpdatesThePins() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.pins = [1: .init(space: 5, content: .ready)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.center.post(name: WallpaperSpaceMonitor.didChangeNotification, object: nil)

        XCTAssertEqual(window.space, 9)
    }
}
