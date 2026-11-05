import AppKit
import XCTest
@testable import WallpaperMachine

/// The inactivity rule's watch on input: one deadline while the Mac is in use, the timeout less the
/// time already gone without input; inactive from the timeout on; back in use at the first pointer
/// event, typing seen by the two-second read, or a wake, unlock or return to the session. That read
/// waits while the displays sleep or another session has the screens, as the system says when it
/// is asked, not as the last notice said; a notice arms one read whatever the system says then,
/// and that read asks again. Nothing is armed or observed while no timeout is chosen.
@MainActor
final class UserInactivityMonitorTests: XCTestCase {
    private var input: ManualInactivityInput!
    private var monitor: UserInactivityMonitor!
    private var changes = 0

    override func setUp() {
        super.setUp()
        input = ManualInactivityInput()
        monitor = input.makeMonitor()
        changes = 0
        monitor.onChange = { [unowned self] in changes += 1 }
    }

    override func tearDown() {
        monitor.setTimeout(nil)
        monitor = nil
        input = nil
        super.tearDown()
    }

    /// Reaches the timeout of a monitor watching for ten minutes.
    private func becomeInactive() {
        input.secondsSinceInput = 0
        monitor.setTimeout(600)
        input.secondsSinceInput = 600
        input.fireTimer()
        XCTAssertTrue(monitor.isInactive)
    }

    func testNothingIsArmedOrObservedUntilATimeoutIsChosen() {
        input.secondsSinceInput = 3600
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            input.post(name)
        }
        input.postUnlock()
        XCTAssertTrue(input.timers.isEmpty)
        XCTAssertEqual(input.monitorInstalls, 0)
        XCTAssertFalse(monitor.isInactive)
        XCTAssertEqual(changes, 0)
    }

    func testTheDeadlineIsTheTimeoutLessTheTimeAlreadyWithoutInput() {
        input.secondsSinceInput = 120
        monitor.setTimeout(600)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(480)])
        XCTAssertFalse(monitor.isInactive)
        XCTAssertFalse(input.isWatchingThePointer, "Before the timeout only the deadline runs")
    }

    func testInputBeforeTheDeadlineArmsItAgainForTheTimeLeft() {
        monitor.setTimeout(600)
        // The last input was five minutes ago when the deadline comes.
        input.secondsSinceInput = 300
        input.fireTimer()
        XCTAssertFalse(monitor.isInactive)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(300)])
        XCTAssertEqual(input.monitorInstalls, 0)
    }

    func testACountAHairShortOfTheTimeoutWaitsASecondRatherThanSpinning() {
        input.secondsSinceInput = 599.9
        monitor.setTimeout(600)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(1)])
    }

    func testReachingTheTimeoutMakesTheMacInactiveAndWatchesForInput() {
        becomeInactive()
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(input.isWatchingThePointer)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(2)], "The tolerant read for typing")
    }

    func testThePointerEndsInactivityAndLeavesOnlyTheDeadline() {
        becomeInactive()
        input.movePointer()
        XCTAssertFalse(monitor.isInactive)
        XCTAssertEqual(changes, 2)
        XCTAssertFalse(input.isWatchingThePointer)
        XCTAssertEqual(input.monitorRemovals, 1)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(600)], "The read for typing is gone")

        input.movePointer()
        XCTAssertEqual(changes, 2, "Input while in use is no change")
    }

    func testTypingAloneIsNoticedByTheTwoSecondRead() {
        becomeInactive()
        input.secondsSinceInput = 602
        input.fireTimer()
        XCTAssertTrue(monitor.isInactive, "Still no input")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(2)])

        // A key pressed a second ago, which no pointer monitor sees.
        input.secondsSinceInput = 1
        input.fireTimer()
        XCTAssertFalse(monitor.isInactive)
        XCTAssertEqual(changes, 2)
        XCTAssertFalse(input.isWatchingThePointer)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(599)])
    }

    func testAWakeAnUnlockOrAReturnToTheSessionReadsAtOnce() {
        let triggers: [(String, @MainActor (ManualInactivityInput) -> Void)] = [
            ("wake", { $0.post(NSWorkspace.didWakeNotification) }),
            ("screens wake", { $0.post(NSWorkspace.screensDidWakeNotification) }),
            ("session returns", { $0.post(NSWorkspace.sessionDidBecomeActiveNotification) }),
            ("unlock", { $0.postUnlock() }),
        ]
        for (name, trigger) in triggers {
            becomeInactive()
            input.secondsSinceInput = 3
            trigger(input)
            XCTAssertFalse(monitor.isInactive, name)
            XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(597)], name)
            monitor.setTimeout(nil)
        }
    }

    func testTheReadWaitsWhileTheDisplaysSleepOrAnotherSessionHasTheScreens() {
        becomeInactive()
        input.displaysAsleep = true
        input.post(NSWorkspace.screensDidSleepNotification)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(2)], "A notice arms one read to ask again")
        input.secondsSinceInput = 602
        input.fireTimer()
        XCTAssertTrue(input.liveTimers.isEmpty, "No input can arrive while the displays sleep")
        XCTAssertTrue(monitor.isInactive)

        input.secondsSinceInput = 900
        input.displaysAsleep = false
        input.post(NSWorkspace.screensDidWakeNotification)
        XCTAssertTrue(monitor.isInactive, "The displays woke without input")
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(2)])

        input.sessionOnConsole = false
        input.post(NSWorkspace.sessionDidResignActiveNotification)
        input.fireTimer()
        XCTAssertTrue(input.liveTimers.isEmpty, "No input can arrive while another session has the screens")
        input.secondsSinceInput = 1
        input.sessionOnConsole = true
        input.post(NSWorkspace.sessionDidBecomeActiveNotification)
        XCTAssertFalse(monitor.isInactive)
        XCTAssertEqual(changes, 2)
    }

    func testADeadlineReachedWhileTheDisplaysSleepArmsNoRead() {
        monitor.setTimeout(600)
        input.displaysAsleep = true
        input.post(NSWorkspace.screensDidSleepNotification)
        XCTAssertEqual(input.liveTimers.count, 1, "The deadline of a Mac in use still runs")
        input.secondsSinceInput = 600
        input.fireTimer()
        XCTAssertTrue(monitor.isInactive)
        XCTAssertTrue(input.liveTimers.isEmpty)
        XCTAssertTrue(input.isWatchingThePointer)
    }

    /// The app relaunched by an automatic update while the displays sleep starts watching long
    /// past the timeout, and no sleep notice will come for displays that are already asleep.
    func testWatchingThatStartsWhileTheDisplaysSleepOrTheSessionIsAwayArmsNoRead() {
        input.secondsSinceInput = 3600
        input.displaysAsleep = true
        monitor.setTimeout(600)
        XCTAssertTrue(monitor.isInactive)
        XCTAssertTrue(input.liveTimers.isEmpty, "Nothing reads the count while the displays sleep")
        XCTAssertTrue(input.isWatchingThePointer)

        input.displaysAsleep = false
        input.post(NSWorkspace.screensDidWakeNotification)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(2)], "Awake, the read for typing runs")
        monitor.setTimeout(nil)

        input.sessionOnConsole = false
        monitor.setTimeout(600)
        XCTAssertTrue(monitor.isInactive)
        XCTAssertTrue(input.liveTimers.isEmpty, "Nothing reads the count while another session has the screens")
    }

    func testTheSystemIsAskedRatherThanTheLastNotice() {
        // Displays that fell asleep with no notice stop the read at its next turn.
        becomeInactive()
        input.displaysAsleep = true
        input.secondsSinceInput = 602
        input.fireTimer()
        XCTAssertTrue(monitor.isInactive)
        XCTAssertTrue(input.liveTimers.isEmpty)

        // They wake with no notice either: the pointer still ends the pause, and the next
        // inactivity reads for typing again instead of waiting for a wake notice that never came.
        input.displaysAsleep = false
        input.movePointer()
        XCTAssertFalse(monitor.isInactive)
        input.secondsSinceInput = 600
        input.fireTimer()
        XCTAssertTrue(monitor.isInactive)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(2)])

        // A sleep notice that comes before the displays have gone to sleep arms the read again,
        // and that read asks once more.
        input.post(NSWorkspace.screensDidSleepNotification)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(2)])
        input.displaysAsleep = true
        input.fireTimer()
        XCTAssertTrue(input.liveTimers.isEmpty)
        XCTAssertEqual(changes, 3)
    }

    /// The displays, backlight and session dictionary can return after the notice that announces
    /// them, so the notice cannot be the last word: typing must still end the inactivity once they
    /// have settled, and a real sleep must still stop the read.
    func testAWakeTheSystemHasNotYetShownStillLetsTypingEndInactivity() {
        let wakes: [(String, @MainActor (ManualInactivityInput) -> Void)] = [
            ("screens wake", { $0.post(NSWorkspace.screensDidWakeNotification) }),
            ("wake", { $0.post(NSWorkspace.didWakeNotification) }),
            ("unlock", { $0.postUnlock() }),
        ]
        for (name, wake) in wakes {
            becomeInactive()
            input.displaysAsleep = true
            input.secondsSinceInput = 900
            input.post(NSWorkspace.screensDidSleepNotification)
            input.fireTimer()
            XCTAssertTrue(input.liveTimers.isEmpty, name)

            // The notice comes while the system still says the displays sleep.
            wake(input)
            XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(2)], name)
            // They settle with no further notice, and a key is pressed.
            input.displaysAsleep = false
            input.secondsSinceInput = 1
            input.fireTimer()
            XCTAssertFalse(monitor.isInactive, name)
            XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(599)], name)
            monitor.setTimeout(nil)
        }

        // A wake notice for displays that really sleep on costs one read.
        becomeInactive()
        input.displaysAsleep = true
        input.secondsSinceInput = 900
        input.post(NSWorkspace.screensDidWakeNotification)
        input.fireTimer()
        XCTAssertTrue(monitor.isInactive)
        XCTAssertTrue(input.liveTimers.isEmpty)
    }

    /// Fast user switching back to this session: its console key can still read as away when the
    /// session's return is announced, and the typing at the login window need not count here.
    func testAReturnTheSessionHasNotYetShownStillLetsTypingEndInactivity() {
        becomeInactive()
        input.sessionOnConsole = false
        input.secondsSinceInput = 900
        input.post(NSWorkspace.sessionDidResignActiveNotification)
        input.fireTimer()
        XCTAssertTrue(input.liveTimers.isEmpty)

        input.post(NSWorkspace.sessionDidBecomeActiveNotification)
        XCTAssertTrue(monitor.isInactive)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(2)])
        // The key settles with no further notice; the read after the notice asks it again.
        input.sessionOnConsole = true
        input.secondsSinceInput = 902
        input.fireTimer()
        XCTAssertTrue(monitor.isInactive, "Still no input in this session")
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(2)], "The read for typing runs on")

        input.secondsSinceInput = 1
        input.fireTimer()
        XCTAssertFalse(monitor.isInactive)
        XCTAssertEqual(changes, 2)
    }

    /// The read for typing can run for hours on an inactive Mac whose displays stay awake, so it
    /// asks the displays each turn but leaves the session's window-server round trip to the moments
    /// the session can have changed.
    func testTheReadForTypingAsksTheSessionOnlyWhenItCanHaveChanged() {
        becomeInactive()
        XCTAssertEqual(input.sessionReads, 1, "The deadline that made the Mac inactive asks")
        let displayReads = input.displayReads
        for second in [602.0, 604, 606] {
            input.secondsSinceInput = second
            input.fireTimer()
        }
        XCTAssertTrue(monitor.isInactive)
        XCTAssertEqual(input.displayReads, displayReads + 3, "Each turn asks the displays")
        XCTAssertEqual(input.sessionReads, 1, "No turn asks the session")

        // Leaving posts a notice, and the read after it asks the session.
        input.sessionOnConsole = false
        input.post(NSWorkspace.sessionDidResignActiveNotification)
        input.fireTimer()
        XCTAssertEqual(input.sessionReads, 2)
        XCTAssertTrue(input.liveTimers.isEmpty)
    }

    func testSwitchingOffLeavesNothingArmedOrObserved() {
        becomeInactive()
        monitor.setTimeout(nil)
        XCTAssertFalse(monitor.isInactive)
        XCTAssertEqual(changes, 1, "The caller that switched it off reads the state itself")
        XCTAssertTrue(input.liveTimers.isEmpty)
        XCTAssertFalse(input.isWatchingThePointer)

        let armed = input.timers.count
        input.secondsSinceInput = 3600
        input.post(NSWorkspace.screensDidWakeNotification)
        input.postUnlock()
        input.movePointer()
        XCTAssertEqual(input.timers.count, armed, "Nothing is observed any more")
        XCTAssertFalse(monitor.isInactive)
    }

    func testANewTimeoutStartsOverAndSettlesWithoutAnnouncing() {
        input.secondsSinceInput = 100
        monitor.setTimeout(600)
        monitor.setTimeout(300)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(200)], "The old deadline is gone")

        input.secondsSinceInput = 400
        monitor.setTimeout(300)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(200)], "The same timeout changes nothing")

        monitor.setTimeout(60)
        XCTAssertTrue(monitor.isInactive, "Already past a shorter timeout")
        XCTAssertTrue(input.isWatchingThePointer)
        monitor.setTimeout(1800)
        XCTAssertFalse(monitor.isInactive, "Not yet at a longer one")
        XCTAssertFalse(input.isWatchingThePointer)
        XCTAssertEqual(input.liveTimers.map(\.delay), [.seconds(1400)])
        XCTAssertEqual(changes, 0, "Whoever set the timeout reads the state")
    }
}
