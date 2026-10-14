import AppKit
import XCTest
@testable import WallpaperMachine

/// Two displays side by side, a pointer the test places, a monitor the test feeds, whether this app is
/// the active one, and a dwell and a poll timer the test ends by hand. Nothing here reads a real
/// screen, pointer or event stream.
@MainActor
private final class Rig {
    typealias Screen = ActiveDisplayTracker.Screen

    static let left = Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    static let right = Screen(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
    static let third = Screen(id: 3, frame: CGRect(x: 2000, y: 0, width: 1000, height: 800))
    static let onLeft = CGPoint(x: 500, y: 400)
    static let onRight = CGPoint(x: 1500, y: 400)
    static let onThird = CGPoint(x: 2500, y: 400)

    let center = NotificationCenter()
    let sleeper = ManualSleep()
    let pollSleeper = ManualSleep()
    var screens = [Rig.left, Rig.right]
    var pointer = Rig.onLeft
    var appActive = false
    /// Times the tracker said the active displays changed.
    private(set) var changes = 0
    private(set) var installs = 0
    private(set) var removals = 0
    private var handler: (@MainActor () -> Void)?
    private(set) var tracker: ActiveDisplayTracker!

    init() {
        let sleeper = sleeper, pollSleeper = pollSleeper
        tracker = ActiveDisplayTracker(
            screens: { [unowned self] in screens },
            pointer: { [unowned self] in pointer },
            installMonitor: { [unowned self] handler in
                installs += 1
                self.handler = handler
                return { [unowned self] in
                    removals += 1
                    self.handler = nil
                }
            },
            notificationCenter: center,
            isAppActive: { [unowned self] in appActive },
            dwell: .seconds(3),
            sleep: { await sleeper.sleep(for: $0) },
            pollInterval: .milliseconds(250),
            pollSleep: { await pollSleeper.sleep(for: $0) })
        tracker.onChange = { [unowned self] in changes += 1 }
    }

    /// Ends tracking and lets every wait that is still sleeping finish, so none is left hanging.
    func finish() {
        tracker.stop()
        sleeper.releaseAll()
        pollSleeper.releaseAll()
    }

    /// The pointer moves; the tracker hears of it only while it has a monitor installed.
    func move(to point: CGPoint) {
        pointer = point
        handler?()
    }

    /// This app becomes or stops being the active one, as AppKit says it.
    func setAppActive(_ active: Bool) async {
        appActive = active
        center.post(
            name: active ? NSApplication.didBecomeActiveNotification : NSApplication.didResignActiveNotification,
            object: nil)
        await flushMainQueue()
    }

    func connect(_ screens: [Screen]) async {
        self.screens = screens
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await flushMainQueue()
    }

    func inactive(among known: Set<UInt32> = [1, 2]) -> Set<UInt32> {
        tracker.inactive(among: known)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Notifications and released sleeps reach the tracker through the main queue, so once an
    /// operation added afterwards has run, everything posted before it has been delivered.
    func flushMainQueue() async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                OperationQueue.main.addOperation { continuation.resume() }
            }
        }
    }
}

@MainActor
final class ActiveDisplayTrackerTests: XCTestCase {
    func testPointerDisplayIsActiveAtOnceAndTheOldOneLingersForTheDwell() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.tracker.setEnabled(true)
        XCTAssertEqual(rig.inactive(), [2], "Everything but the display under the pointer is inactive")
        XCTAssertEqual(rig.changes, 1)

        rig.move(to: Rig.onRight)
        XCTAssertEqual(rig.inactive(), [], "The display the pointer entered plays at once, and the one it left still does")
        XCTAssertEqual(rig.changes, 2)
        try await rig.waitUntil { rig.sleeper.waiting == 1 }

        rig.sleeper.releaseAll()
        try await rig.waitUntil { rig.inactive() == [1] }
        XCTAssertEqual(rig.changes, 3, "The dwell ending is the second change")
    }

    func testReturningWithinTheDwellKeepsTheDisplayPlaying() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.tracker.setEnabled(true)

        rig.move(to: Rig.onRight)
        // Each wait registers on its own task, so let display 1's begin before display 2's can.
        try await rig.waitUntil { rig.sleeper.started == 1 }
        rig.move(to: Rig.onLeft)
        XCTAssertEqual(rig.changes, 2, "Both displays were active before and after, so nothing changed")
        XCTAssertEqual(rig.inactive(), [], "The display it just left lingers; the one it is back on never stopped")

        // The wait on display 1 was cancelled by the return; it ends late and must change nothing.
        try await rig.waitUntil { rig.sleeper.waiting == 2 }
        rig.sleeper.releaseOldest()
        await rig.flushMainQueue()
        XCTAssertEqual(rig.inactive(), [])
        XCTAssertEqual(rig.changes, 2)

        rig.sleeper.releaseAll()
        try await rig.waitUntil { rig.inactive() == [2] }
        XCTAssertEqual(rig.changes, 3, "Only display 2's own wait ended")
    }

    func testAnEarlierWaitThatEndsLateDoesNotCutALaterOneShort() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.tracker.setEnabled(true)

        // Each wait registers on its own task, so each begins before the next move can start another.
        rig.move(to: Rig.onRight)  // display 1 starts waiting
        try await rig.waitUntil { rig.sleeper.started == 1 }
        rig.move(to: Rig.onLeft)   // back on it: that wait is cancelled; display 2 starts waiting
        try await rig.waitUntil { rig.sleeper.started == 2 }
        rig.move(to: Rig.onRight)  // leaves again: display 1 waits afresh
        try await rig.waitUntil { rig.sleeper.waiting == 3 }

        rig.sleeper.releaseOldest()
        await rig.flushMainQueue()
        XCTAssertEqual(rig.inactive(), [], "The cancelled first wait ending must not end the fresh one")

        rig.sleeper.releaseAll()
        try await rig.waitUntil { rig.inactive() == [1] }
    }

    func testEventsThatDoNotCrossABoundaryAreIgnored() async {
        let rig = Rig()
        defer { rig.finish() }
        rig.tracker.setEnabled(true)
        let changesAtStart = rig.changes

        for x in stride(from: 10.0, to: 990.0, by: 7.0) {
            rig.move(to: CGPoint(x: x, y: 20 + x / 2))
        }
        rig.move(to: Rig.onLeft)

        XCTAssertEqual(rig.changes, changesAtStart, "Skimming one display tells nobody anything")
        XCTAssertEqual(rig.sleeper.started, 0, "and starts no wait")
        XCTAssertEqual(rig.inactive(), [2])
    }

    func testAPointerOnAnUnmanagedScreenPausesNothing() {
        let rig = Rig()
        rig.screens = [Rig.left, Rig.right, Rig.third]
        rig.pointer = Rig.onThird
        defer { rig.finish() }
        rig.tracker.setEnabled(true)

        XCTAssertEqual(rig.inactive(among: [1, 2]), [], "The app manages displays 1 and 2; the pointer is elsewhere")
        XCTAssertEqual(rig.inactive(among: [1, 2, 3]), [1, 2], "Once display 3 is managed, it is the one in use")

        rig.move(to: Rig.onLeft)
        XCTAssertEqual(rig.inactive(among: [1, 2]), [2])
    }

    func testThePointerBetweenScreensKeepsTheLastDisplay() {
        let rig = Rig()
        rig.screens = [Rig.left, Rig.third]
        defer { rig.finish() }
        rig.tracker.setEnabled(true)
        XCTAssertEqual(rig.inactive(among: [1, 3]), [3])
        let changes = rig.changes

        rig.move(to: CGPoint(x: 1500, y: 400))

        XCTAssertEqual(rig.inactive(among: [1, 3]), [3], "A gap in the arrangement is no display")
        XCTAssertEqual(rig.changes, changes)
    }

    func testSingleDisplayInstallsNoMonitor() async {
        let rig = Rig()
        rig.screens = [Rig.left]
        defer { rig.finish() }
        rig.tracker.setEnabled(true)

        XCTAssertEqual(rig.installs, 0)
        XCTAssertFalse(rig.tracker.isTracking)
        XCTAssertEqual(rig.inactive(among: [1]), [])
        XCTAssertEqual(rig.changes, 0)

        await rig.connect([Rig.left, Rig.right])
        XCTAssertEqual(rig.installs, 1, "A second display is the reason to listen")
        XCTAssertEqual(rig.inactive(), [2])
        XCTAssertEqual(rig.changes, 1)

        await rig.connect([Rig.left])
        XCTAssertEqual(rig.removals, 1, "Back to one display, the monitor goes")
        XCTAssertFalse(rig.tracker.isTracking)
        XCTAssertEqual(rig.inactive(), [], "and nothing stays paused")
        XCTAssertEqual(rig.changes, 2, "The policy is told, so the paused display resumes")
    }

    func testDisablingClearsStateAndNotifiesSoDisplaysResume() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.tracker.setEnabled(true)
        rig.move(to: Rig.onRight)
        try await rig.waitUntil { rig.sleeper.waiting == 1 }
        let changes = rig.changes

        rig.tracker.setEnabled(false)

        XCTAssertEqual(rig.removals, 1)
        XCTAssertEqual(rig.inactive(), [])
        XCTAssertEqual(rig.changes, changes + 1, "Turning the option off resumes the displays through the policy")

        rig.move(to: Rig.onLeft)
        rig.sleeper.releaseAll()
        await rig.flushMainQueue()
        XCTAssertEqual(rig.changes, changes + 1, "A pointer event or a finished wait after that changes nothing")

        rig.tracker.setEnabled(false)
        XCTAssertEqual(rig.changes, changes + 1, "Turning it off again says nothing")
        rig.pointer = Rig.onRight
        rig.tracker.setEnabled(true)
        XCTAssertEqual(rig.installs, 2)
        XCTAssertEqual(rig.inactive(), [1], "Turned back on, it starts from where the pointer is")
    }

    func testStoppingForShutdownLeavesTheCallbackSilent() {
        let rig = Rig()
        rig.tracker.setEnabled(true)
        let changes = rig.changes

        rig.tracker.stop()

        XCTAssertEqual(rig.removals, 1)
        XCTAssertEqual(rig.changes, changes, "Whoever is shutting down resumes the displays itself")
        XCTAssertEqual(rig.inactive(), [])
    }

    func testAScreenChangeIsNotObservedWhileTheOptionIsOff() async {
        let rig = Rig()
        rig.screens = [Rig.left]

        await rig.connect([Rig.left, Rig.right])

        XCTAssertEqual(rig.installs, 0, "Nothing listens for screens until the option is on")
        XCTAssertEqual(rig.changes, 0)
    }

    func testADisplayUnpluggedDuringTheDwellIsForgotten() async throws {
        let rig = Rig()
        rig.screens = [Rig.left, Rig.right, Rig.third]
        defer { rig.finish() }
        rig.tracker.setEnabled(true)
        rig.move(to: Rig.onRight)  // display 1 lingers
        try await rig.waitUntil { rig.sleeper.waiting == 1 }
        XCTAssertEqual(rig.inactive(among: [1, 2, 3]), [3])

        await rig.connect([Rig.right, Rig.third])
        XCTAssertEqual(rig.inactive(among: [2, 3]), [3])
        let changes = rig.changes
        rig.sleeper.releaseAll()
        await rig.flushMainQueue()
        XCTAssertEqual(rig.changes, changes, "The wait of a display that is gone ends quietly")

        await rig.connect([Rig.left, Rig.right, Rig.third])
        XCTAssertEqual(
            rig.inactive(among: [1, 2, 3]), [1, 3],
            "Plugged back in, display 1 is not remembered as still lingering")
    }

    func testAnArrangementChangeFindsTheDisplayUnderTheStillPointer() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.tracker.setEnabled(true)
        XCTAssertEqual(rig.inactive(), [2])

        // The displays swap places under a pointer that has not moved.
        await rig.connect([
            Rig.Screen(id: 1, frame: Rig.right.frame),
            Rig.Screen(id: 2, frame: Rig.left.frame),
        ])

        XCTAssertEqual(rig.tracker.pointerDisplay, 2)
        XCTAssertEqual(rig.inactive(), [], "Display 1 lingers for the dwell, as after a move")
        try await rig.waitUntil { rig.sleeper.waiting == 1 }
        rig.sleeper.releaseAll()
        try await rig.waitUntil { rig.inactive() == [1] }
    }

    func testThePolicyFollowsThePointerAcrossDisplays() async throws {
        let rig = Rig()
        var suspended: [(display: UInt32, suspended: Bool)] = []
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: NotificationCenter(), lockCenter: NotificationCenter(),
            windowCenter: NotificationCenter(),
            surfaces: { [WallpaperSurfaceVisibility(displayID: 1, isVisible: true), WallpaperSurfaceVisibility(displayID: 2, isVisible: true)] },
            isSessionLocked: { false },
            inactiveDisplays: { known in rig.tracker.inactive(among: known) },
            screenLayout: { [] },
            occlusionSettleDelay: .zero,
            applyGlobal: { _, completion in completion(.success(())) },
            applyDisplay: { display, isSuspended, completion in
                suspended.append((display, isSuspended))
                completion(.success(()))
            })
        rig.tracker.onChange = { policy.evaluate() }
        policy.start()
        defer {
            rig.finish()
            policy.stop()
        }

        rig.tracker.setEnabled(true)
        XCTAssertEqual(policy.suspendedDisplayIDs, [2], "The display the pointer is not on pauses")

        rig.move(to: Rig.onRight)
        XCTAssertEqual(policy.suspendedDisplayIDs, [], "Entering a display resumes it at once")
        XCTAssertEqual(suspended.filter { $0.display == 1 }.count, 0, "and the one just left keeps playing for the dwell")
        try await rig.waitUntil { rig.sleeper.waiting == 1 }

        rig.sleeper.releaseAll()
        try await rig.waitUntil { policy.suspendedDisplayIDs == [1] }

        rig.move(to: Rig.onLeft)
        XCTAssertEqual(policy.suspendedDisplayIDs, [], "Coming back resumes display 1 at once; display 2 plays out its own dwell")
        XCTAssertEqual(suspended.filter { $0.display == 1 }.map(\.suspended), [true, false])
    }

    // MARK: - The gap while this app is in front

    func testThePointerIsReadOnATimerWhileTheAppIsActiveAndNoEventArrives() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.tracker.setEnabled(true)
        XCTAssertEqual(rig.pollSleeper.started, 0, "Nothing is read on a timer while another app is in front")

        await rig.setAppActive(true)
        try await rig.waitUntil { rig.pollSleeper.waiting == 1 }
        let changes = rig.changes

        // AppKit sends the pointer to this app, so no monitor hears of the move to display 2.
        rig.pointer = Rig.onRight
        XCTAssertEqual(rig.inactive(), [2], "With no event and no tick yet, nothing is known")

        rig.pollSleeper.releaseAll()
        try await rig.waitUntil { rig.tracker.pointerDisplay == 2 }
        XCTAssertEqual(rig.inactive(), [], "Display 2 plays at once, and display 1 lingers for the dwell")
        XCTAssertEqual(rig.changes, changes + 1)
        try await rig.waitUntil { rig.pollSleeper.waiting == 1 }
        XCTAssertEqual(rig.pollSleeper.started, 2, "The timer keeps going while the app is active")

        // A tick that finds the pointer where it was changes nothing.
        rig.pollSleeper.releaseAll()
        try await rig.waitUntil { rig.pollSleeper.started == 3 }
        XCTAssertEqual(rig.changes, changes + 1)
    }

    func testBecomingActiveReadsThePointerAtOnce() async {
        let rig = Rig()
        defer { rig.finish() }
        rig.tracker.setEnabled(true)

        rig.pointer = Rig.onRight  // moved as the app came to the front, before any monitor could say so
        await rig.setAppActive(true)

        XCTAssertEqual(rig.tracker.pointerDisplay, 2, "No timer tick is needed to find where the pointer is")
    }

    func testResigningActiveReadsThePointerOnceAndEndsTheTimer() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.tracker.setEnabled(true)
        await rig.setAppActive(true)
        try await rig.waitUntil { rig.pollSleeper.waiting == 1 }

        rig.pointer = Rig.onRight  // unseen: the app was in front
        await rig.setAppActive(false)
        XCTAssertEqual(rig.tracker.pointerDisplay, 2, "The pointer is read once more as the app hands events back")

        // The tick that was waiting ends late, after the pointer moved again, and must read nothing.
        rig.pointer = Rig.onLeft
        rig.pollSleeper.releaseAll()
        await rig.flushMainQueue()
        XCTAssertEqual(rig.tracker.pointerDisplay, 2, "The timer ended with the activity")
        XCTAssertEqual(rig.pollSleeper.started, 1, "and starts no further wait")
    }

    func testTrackingStartedWhileTheAppIsActiveReadsOnATimerFromTheStart() async throws {
        let rig = Rig()
        rig.appActive = true
        defer { rig.finish() }

        rig.tracker.setEnabled(true)
        try await rig.waitUntil { rig.pollSleeper.waiting == 1 }

        rig.pointer = Rig.onRight
        rig.pollSleeper.releaseAll()
        try await rig.waitUntil { rig.tracker.pointerDisplay == 2 }
    }

    func testThePointerTimerAndActivityObserversEndWithTracking() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.tracker.setEnabled(true)
        await rig.setAppActive(true)
        try await rig.waitUntil { rig.pollSleeper.waiting == 1 }

        // Back to one display: nothing is tracked, so nothing is read.
        await rig.connect([Rig.left])
        XCTAssertFalse(rig.tracker.isTracking)
        rig.pollSleeper.releaseAll()
        await rig.flushMainQueue()
        XCTAssertEqual(rig.pollSleeper.started, 1, "The timer ended with the monitor")
        await rig.setAppActive(false)
        await rig.setAppActive(true)
        XCTAssertEqual(rig.pollSleeper.started, 1, "and activity changes are no longer observed")
        XCTAssertEqual(rig.changes, 2, "Only the start of tracking and its end were reported")

        // A second display brings it all back, with the app still in front.
        await rig.connect([Rig.left, Rig.right])
        try await rig.waitUntil { rig.pollSleeper.waiting == 1 }

        rig.tracker.setEnabled(false)
        rig.pollSleeper.releaseAll()
        await rig.flushMainQueue()
        let started = rig.pollSleeper.started
        await rig.setAppActive(false)
        await rig.setAppActive(true)
        XCTAssertEqual(rig.pollSleeper.started, started, "Turning the option off ends the timer and the observers")
    }

    func testActivityChangesAreNotObservedUntilTwoDisplaysAreConnected() async {
        let rig = Rig()
        rig.screens = [Rig.left]
        defer { rig.finish() }
        rig.tracker.setEnabled(true)

        await rig.setAppActive(true)

        XCTAssertEqual(rig.pollSleeper.started, 0, "One display has nothing to follow")
        XCTAssertEqual(rig.changes, 0)
    }
}
