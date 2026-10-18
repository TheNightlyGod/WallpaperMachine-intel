import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor
private final class PolicyProbe {
    /// Global decisions delivered to the bridge.
    var applied: [Bool] = []
    /// Per-display decisions, in delivery order.
    var appliedDisplays: [(display: UInt32, suspended: Bool)] = []
    var surfaces: [WallpaperSurfaceVisibility] = [
        WallpaperSurfaceVisibility(displayID: 1, isVisible: true)
    ]
    var sessionLocked = false
    /// Window-server round trips spent asking for `sessionLocked`.
    var lockReads = 0
    /// Displays whose working area other windows cover.
    var covered: Set<UInt32> = []
    var coveredAction: DesktopCoveredAction = .pause
    /// Displays the user is not using, as the policy is told when it asks about the displays it knows.
    var inactive: Set<UInt32> = []
    /// The displays the policy asked about, each time.
    var inactiveQueries: [Set<UInt32>] = []
    /// Each screen's frame and working area.
    var screenLayout = [NSRect(x: 0, y: 0, width: 1728, height: 1117), NSRect(x: 0, y: 0, width: 1728, height: 1084)]

    func setVisible(_ visible: Bool, display: UInt32 = 1) {
        if let index = surfaces.firstIndex(where: { $0.displayID == display }) {
            surfaces[index] = WallpaperSurfaceVisibility(displayID: display, isVisible: visible)
        } else {
            surfaces.append(WallpaperSurfaceVisibility(displayID: display, isVisible: visible))
        }
    }

    func displayDecisions(for display: UInt32) -> [Bool] {
        appliedDisplays.filter { $0.display == display }.map(\.suspended)
    }
}

@MainActor
final class WallpaperPresentationPolicyTests: XCTestCase {
    private let workspaceCenter = NotificationCenter()
    private let lockCenter = NotificationCenter()
    private let windowCenter = NotificationCenter()

    private func makePolicy(
        _ probe: PolicyProbe,
        settle: Duration = .milliseconds(20),
        counters: RuntimeCounters? = nil
    ) -> WallpaperPresentationPolicy {
        WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { probe.surfaces },
            isSessionLocked: {
                probe.lockReads += 1
                return probe.sessionLocked
            },
            desktopCoveredAction: { probe.coveredAction },
            coveredDisplays: { probe.covered },
            inactiveDisplays: { known in
                probe.inactiveQueries.append(known)
                return probe.inactive
            },
            screenLayout: { probe.screenLayout },
            occlusionSettleDelay: settle,
            counters: counters,
            applyGlobal: { presentation, completion in
                probe.applied.append(presentation != .running)
                completion(.success(()))
            },
            applyDisplay: { display, suspended, completion in
                probe.appliedDisplays.append((display, suspended))
                completion(.success(()))
            }
        )
    }

    func testDisplaySleepSuspendsGloballyAndWakeResumes() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.applied, [], "A visible, unlocked desktop must keep rendering")

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(probe.applied, [true], "Sleeping displays must suspend immediately")
        XCTAssertTrue(
            probe.appliedDisplays.isEmpty,
            "A condition that covers every screen is delivered once, not per display")

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(probe.applied, [true, false], "Waking displays must resume without delay")
    }

    func testSessionLockSuspendsWhileDesktopIsVisible() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.sessionLocked = true
        lockCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        XCTAssertEqual(probe.applied, [true], "The lock screen hides the desktop even when its windows report visible")
    }

    /// Asking is a window-server round trip, and the app evaluates after every snapshot
    /// the engine applies: dragging a property slider must not ask each time.
    func testTheLockStateIsAskedOnlyWhenItCanHaveChanged() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        let readsAtStart = probe.lockReads

        for _ in 0..<100 { policy.evaluate() }
        windowCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        XCTAssertEqual(probe.lockReads, readsAtStart, "snapshots and occlusion changes do not lock the session")

        probe.sessionLocked = true
        lockCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        probe.sessionLocked = false
        lockCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        XCTAssertEqual(probe.applied, [true, false])
        let readsAfterUnlock = probe.lockReads
        for _ in 0..<100 { policy.evaluate() }
        XCTAssertEqual(probe.lockReads, readsAfterUnlock, "an unlocked session is not asked again")
    }

    func testASessionLockedBeforeStartIsSuspendedFromTheStart() {
        let probe = PolicyProbe()
        probe.sessionLocked = true
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.applied, [true], "a lock that posted before start() is still a lock")

        probe.sessionLocked = false
        lockCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        XCTAssertEqual(probe.applied, [true, false])
    }

    /// A lock taken as the displays went to sleep may have posted nothing this process saw.
    func testWakingDisplaysAskForTheLockStateAgain() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        probe.sessionLocked = true
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(probe.applied, [true], "the lock screen after wake keeps the wallpaper suspended")
        XCTAssertTrue(policy.isSuspended)

        probe.sessionLocked = false
        lockCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        XCTAssertEqual(probe.applied, [true, false])
    }

    func testSwitchingUsersAsksForTheLockStateAgain() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.sessionLocked = true
        workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertEqual(probe.applied, [true], "a session switched away from is locked behind the login window")

        probe.sessionLocked = false
        workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(probe.applied, [true, false], "switching back resumes")
    }

    /// While the session counts as locked every evaluation asks again, so an unlock this
    /// process never heard about cannot leave the wallpaper suspended.
    func testAMissedUnlockClearsAtTheNextEvaluation() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.sessionLocked = true
        lockCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        probe.sessionLocked = false
        policy.evaluate()
        XCTAssertEqual(probe.applied, [true, false])
    }

    /// The unlock is reported once, after the decision it causes was made, however many
    /// evaluations follow.
    func testUnlockIsReportedOnceWhenTheLockClears() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        var unlocks: [GlobalPresentation] = []
        policy.onSessionUnlocked = { unlocks.append(policy.globalPresentation) }
        policy.start()
        defer { policy.stop() }

        probe.sessionLocked = true
        lockCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        XCTAssertTrue(unlocks.isEmpty, "locking is not an unlock")
        probe.sessionLocked = false
        lockCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        XCTAssertEqual(unlocks, [.running], "the callback sees the presentation the unlock restored")
        for _ in 0..<5 { policy.evaluate() }
        lockCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        XCTAssertEqual(unlocks.count, 1, "an unlock is reported once, not again by later evaluations or a repeated notification")

        probe.sessionLocked = true
        lockCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        probe.sessionLocked = false
        lockCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        XCTAssertEqual(unlocks.count, 2, "the next unlock is a new one")
    }

    /// The lock state is read from the window server, so an unlock whose notification never
    /// arrived is still reported by the next evaluation.
    func testAMissedUnlockIsStillReportedAtTheNextEvaluation() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        var unlocks = 0
        policy.onSessionUnlocked = { unlocks += 1 }
        policy.start()
        defer { policy.stop() }

        probe.sessionLocked = true
        lockCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        probe.sessionLocked = false
        policy.evaluate()
        XCTAssertEqual(unlocks, 1)
        XCTAssertEqual(probe.applied, [true, false])
    }

    /// A lock the app saw only after wake, and a user switched away and back, end like any other.
    func testUnlockAfterWakeOrAUserSwitchIsReported() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        var unlocks = 0
        policy.onSessionUnlocked = { unlocks += 1 }
        policy.start()
        defer { policy.stop() }

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        probe.sessionLocked = true
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(unlocks, 0)
        probe.sessionLocked = false
        lockCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        XCTAssertEqual(unlocks, 1)

        probe.sessionLocked = true
        workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        probe.sessionLocked = false
        workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(unlocks, 2)
    }

    func testStartingLockedOrStoppingReportsNoUnlock() {
        let probe = PolicyProbe()
        probe.sessionLocked = true
        let policy = makePolicy(probe)
        var unlocks = 0
        policy.onSessionUnlocked = { unlocks += 1 }
        policy.start()
        XCTAssertEqual(unlocks, 0, "a session that was locked before the app looked has not been seen to unlock")

        policy.stop()
        XCTAssertEqual(unlocks, 0, "tearing the policy down while locked is not an unlock")
        probe.sessionLocked = false
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(unlocks, 0, "starting again with the session unlocked is a first look, not an unlock")
    }

    func testFullOcclusionSuspendsOnlyAfterTheSettleDelay() async throws {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false)
        windowCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        XCTAssertEqual(probe.appliedDisplays.count, 0, "A Space switch must not freeze the wallpaper instantly")

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.displayDecisions(for: 1), [true], "A wallpaper hidden past the settle delay must stop rendering")
        XCTAssertEqual(probe.applied, [], "Occlusion is a per-display condition")
    }

    func testRevealingTheDesktopDuringTheSettleDelayNeverSuspends() async throws {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false)
        windowCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        probe.setVisible(true)

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(probe.appliedDisplays.isEmpty, "Mission Control passes must never reach the engine")
        XCTAssertFalse(policy.isSuspended)
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
    }

    // MARK: - Covered working area

    func testACoveredWorkingAreaPausesThatDisplayAfterTheSettleDelay() async throws {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        // The wallpaper window still shows under the menu bar, so AppKit keeps
        // reporting it visible; only the working area is covered.
        probe.covered = [1]
        windowCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        XCTAssertTrue(probe.appliedDisplays.isEmpty, "Covering is subject to the same settle delay as occlusion")

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.displayDecisions(for: 1), [true])
        XCTAssertEqual(probe.displayDecisions(for: 2), [], "An uncovered display keeps running")
        XCTAssertEqual(probe.applied, [], "Covering is a per-display condition")
    }

    /// An XDR display posts a screen change for every frame of an EDR headroom ramp,
    /// about 240 in two seconds, with every screen where it was.
    func testOnlyAScreenChangeThatMovesAWorkingAreaIsEvaluated() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }

        probe.covered = [1]
        for _ in 0..<240 {
            windowCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        XCTAssertTrue(probe.appliedDisplays.isEmpty, "a screen change that moved nothing decides nothing")

        probe.screenLayout[1].size.height = 1020
        windowCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(probe.displayDecisions(for: 1), [true], "the Dock appearing moves the working area")
    }

    func testKeepRunningIgnoresACoveredWorkingArea() {
        let probe = PolicyProbe()
        probe.coveredAction = .keepRunning
        probe.covered = [1]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }

        windowCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        XCTAssertTrue(probe.appliedDisplays.isEmpty, "A visible strip keeps animating when the user chose Keep running")
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
    }

    func testUncoveringResumesAtOnceAndChangingTheChoiceAppliesOnTheNextEvaluation() {
        let probe = PolicyProbe()
        probe.covered = [1]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.displayDecisions(for: 1), [true])

        probe.covered = []
        windowCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        XCTAssertEqual(probe.displayDecisions(for: 1), [true, false], "Exposing the desktop must resume without delay")

        probe.covered = [1]
        probe.coveredAction = .keepRunning
        policy.evaluate()
        XCTAssertEqual(probe.displayDecisions(for: 1), [true, false], "Keep running leaves a covered display alone")

        probe.coveredAction = .pause
        policy.evaluate()
        XCTAssertEqual(probe.displayDecisions(for: 1), [true, false, true])
    }

    // MARK: - Displays the user is not using

    private func twoVisibleDisplays() -> PolicyProbe {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        return probe
    }

    func testAnInactiveDisplayIsSuspendedOnItsOwnAfterTheSettleDelayAndResumesAtOnce() async throws {
        let probe = twoVisibleDisplays()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.inactive = [2]
        policy.evaluate()
        XCTAssertTrue(probe.appliedDisplays.isEmpty, "The usual settle delay applies on top of the pointer's own wait")

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])
        XCTAssertEqual(probe.displayDecisions(for: 1), [], "The display in use is never told to stop")
        XCTAssertEqual(probe.applied, [], "One display not in use is not a global condition")
        XCTAssertFalse(policy.isSuspended)

        probe.inactive = []
        policy.evaluate()
        XCTAssertEqual(probe.displayDecisions(for: 2), [true, false], "Returning to a display resumes it without waiting")
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
    }

    func testAnInactiveDisplayJoinsCoverageAndCoverageCanBeTurnedOffWithoutResumingIt() {
        let probe = twoVisibleDisplays()
        probe.covered = [2]
        probe.inactive = [2]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(policy.suspendedDisplayIDs, [2], "Display 2 has two reasons to be paused")

        probe.coveredAction = .keepRunning
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [2], "Keep running ends the covered reason only")
        XCTAssertEqual(probe.displayDecisions(for: 2), [true], "and display 2 is not resumed and paused again")
        XCTAssertEqual(probe.displayDecisions(for: 1), [], "The display in use is never told to stop")

        probe.inactive = []
        policy.evaluate()
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
    }

    func testHidingTheDisplayInUseLeavesTheOthersPlaying() {
        // A full-screen app or windows over the display the pointer is on pause that
        // display alone: the one beside it still shows its wallpaper, and stopping it
        // too would leave the user looking at nothing but frozen wallpapers.
        let probe = twoVisibleDisplays()
        probe.inactive = [2]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])

        probe.covered = [1]
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [1], "Windows over the display in use pause that display only")
        XCTAssertEqual(probe.displayDecisions(for: 2), [true, false], "and the other one plays again at once")
        XCTAssertFalse(policy.isSuspended)

        probe.covered = []
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [2], "Uncovering it brings the pointer's rule back")
        XCTAssertEqual(probe.displayDecisions(for: 1), [true, false])

        probe.setVisible(false, display: 1)
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [1], "A full-screen app on the display in use pauses only that display")
        XCTAssertEqual(policy.hiddenDisplayIDs, [1])
        XCTAssertFalse(policy.isSuspendedInPlainSight(displayID: 2), "The other display is playing, not paused")

        probe.setVisible(true, display: 1)
        probe.covered = [1]
        probe.coveredAction = .keepRunning
        policy.evaluate()
        XCTAssertEqual(
            policy.suspendedDisplayIDs, [2],
            "A covered display the user keeps running still shows its wallpaper, so the pointer's rule holds")

        probe.setVisible(false, display: 2)
        probe.setVisible(false, display: 1)
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [1, 2], "Each display hidden on its own stays paused")
    }

    func testTheInactiveSetIsAskedAboutTheDisplaysWithWallpaperAndNeverDarkensAllOfThem() {
        let probe = twoVisibleDisplays()
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.inactiveQueries.last, [1, 2], "The policy asks about the displays it has wallpaper on")

        probe.inactive = [1, 2]
        policy.evaluate()
        XCTAssertTrue(
            policy.suspendedDisplayIDs.isEmpty,
            "An answer that would darken every display is a mistake, not a reason to freeze the desktop")
        XCTAssertTrue(probe.appliedDisplays.isEmpty)

        probe.inactive = [2, 9]
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [2], "A display with no wallpaper is not the policy's to pause")
    }

    func testADisplayPausedOnlyBecauseTheUserIsElsewhereIsNotHidden() {
        let probe = twoVisibleDisplays()
        probe.inactive = [2]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertTrue(policy.hiddenDisplayIDs.isEmpty, "An idle second display must not hold back the update alert")

        probe.covered = [1]
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [1], "Covering the display in use lets the other one play")
        XCTAssertEqual(policy.hiddenDisplayIDs, [1], "A display something covers is still hidden")

        probe.inactive = []
        probe.covered = []
        policy.evaluate()
        XCTAssertTrue(policy.hiddenDisplayIDs.isEmpty)
    }

    func testADisplayTheUserIsNotUsingIsStillHiddenWhenSomethingElseHidesIt() {
        // Pausing for the pointer being elsewhere must not hide a second reason: a
        // full-screen video on the display next to the one in use is the thing an
        // unattended modal alert must not take focus from.
        let probe = twoVisibleDisplays()
        probe.inactive = [2]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertTrue(policy.hiddenDisplayIDs.isEmpty)

        probe.setVisible(false, display: 2)
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertEqual(policy.hiddenDisplayIDs, [2], "a full-screen app on it hides it, whoever is using the other display")

        probe.setVisible(true, display: 2)
        policy.evaluate()
        XCTAssertTrue(policy.hiddenDisplayIDs.isEmpty, "and not once that app is gone")

        probe.covered = [2]
        policy.evaluate()
        XCTAssertEqual(policy.hiddenDisplayIDs, [2], "windows over its working area hide it when that pauses")
        probe.coveredAction = .keepRunning
        policy.evaluate()
        XCTAssertTrue(
            policy.hiddenDisplayIDs.isEmpty,
            "unless the user keeps a covered wallpaper running, which leaves the pointer as the only reason")
    }

    func testOnlyADisplayThatIsSuspendedForTheUserBeingElsewhereIsSuspendedInPlainSight() {
        let probe = twoVisibleDisplays()
        probe.inactive = [2]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertTrue(policy.isSuspendedInPlainSight(displayID: 2), "its wallpaper is on screen and only the pointer is elsewhere")
        XCTAssertFalse(policy.isSuspendedInPlainSight(displayID: 1), "the display in use is not suspended")

        probe.covered = [2]
        XCTAssertFalse(policy.isSuspendedInPlainSight(displayID: 2), "a covered working area hides it")
        probe.coveredAction = .keepRunning
        XCTAssertTrue(policy.isSuspendedInPlainSight(displayID: 2), "unless the user keeps a covered wallpaper running")

        probe.setVisible(false, display: 2)
        XCTAssertFalse(policy.isSuspendedInPlainSight(displayID: 2), "a full-screen app on it hides it")

        probe.setVisible(true, display: 2)
        probe.inactive = [1, 2]
        XCTAssertFalse(
            policy.isSuspendedInPlainSight(displayID: 2),
            "an answer that would darken every display suspends none, so none is suspended in plain sight")
        probe.inactive = []
        XCTAssertFalse(policy.isSuspendedInPlainSight(displayID: 2))
    }

    func testAnInactiveDisplayStaysPausedThroughASleepAndWake() {
        let probe = twoVisibleDisplays()
        probe.inactive = [2]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        XCTAssertEqual(probe.applied, [true, false])
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertEqual(probe.displayDecisions(for: 2), [true], "Waking the displays does not restart the one not in use")
    }

    func testTheCoverageProbeCoversTheWorkingAreaInsideItsMargin() {
        let working = NSRect(x: 0, y: 0, width: 2056, height: 1290)
        XCTAssertEqual(
            WallpaperCoverageProbes.probeFrame(for: working),
            NSRect(x: 32, y: 32, width: 1992, height: 1226),
            "The margin leaves room for rounded window corners and screen-edge gaps")
        XCTAssertNil(
            WallpaperCoverageProbes.probeFrame(for: NSRect(x: 0, y: 0, width: 60, height: 900)),
            "A working area narrower than both margins has nothing left to probe")
    }

    // MARK: - P01: per-display granularity

    func testHidingOneDisplayLeavesTheOtherRunning() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false, display: 2)
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])
        XCTAssertEqual(probe.displayDecisions(for: 1), [], "A visible display is never told to stop")
        XCTAssertEqual(probe.applied, [], "One hidden screen is not a global condition")
        XCTAssertFalse(policy.isSuspended)
    }

    func testBothDisplaysHiddenSuspendEachOnItsOwn() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false, display: 1)
        probe.setVisible(false, display: 2)
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [1, 2])
        XCTAssertEqual(probe.displayDecisions(for: 1), [true])
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])
    }

    func testRevealingOneDisplayResumesOnlyThatDisplay() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: false),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: false),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(policy.suspendedDisplayIDs, [1, 2])

        probe.setVisible(true, display: 1)
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertEqual(probe.displayDecisions(for: 1), [true, false])
        XCTAssertEqual(
            probe.displayDecisions(for: 2), [true],
            "A visible consumer on one display must not resume a hidden one")
    }

    func testADisconnectedDisplayStopsCarryingState() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: false),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])

        probe.surfaces = [WallpaperSurfaceVisibility(displayID: 1, isVisible: true)]
        policy.evaluate()
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
        XCTAssertEqual(
            probe.displayDecisions(for: 2), [true],
            "A display that went away needs no resume")
    }

    func testReconnectedDisplayIsReevaluatedRatherThanRememberedAsSuspended() {
        let probe = PolicyProbe()
        probe.surfaces = [WallpaperSurfaceVisibility(displayID: 2, isVisible: false)]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])

        probe.surfaces = []
        policy.evaluate()
        XCTAssertEqual(probe.displayDecisions(for: 2), [true], "A display that is gone gets no decisions")
        probe.surfaces = [WallpaperSurfaceVisibility(displayID: 2, isVisible: true)]
        policy.evaluate()
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
        XCTAssertEqual(
            probe.displayDecisions(for: 2), [true, false],
            "The renderer and hosts still hold the suspension, so a display that comes back visible is resumed")
    }

    func testReconnectedDisplayThatIsStillHiddenStaysSuspendedWithoutAResume() {
        let probe = PolicyProbe()
        probe.surfaces = [WallpaperSurfaceVisibility(displayID: 2, isVisible: false)]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])

        probe.surfaces = []
        policy.evaluate()
        probe.surfaces = [WallpaperSurfaceVisibility(displayID: 2, isVisible: false)]
        policy.evaluate()
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertEqual(probe.displayDecisions(for: 2), [true], "Still suspended: no resume and no second suspend")
    }

    func testRapidHideAndRevealSettlesOnTheLastState() async throws {
        let probe = PolicyProbe()
        let policy = makePolicy(probe, settle: .milliseconds(20))
        policy.start()
        defer { policy.stop() }

        for _ in 0..<5 {
            probe.setVisible(false)
            policy.evaluate()
            probe.setVisible(true)
            policy.evaluate()
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(
            probe.appliedDisplays.isEmpty,
            "occlusion flapping must not produce a burst of transitions")
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
    }

    func testGlobalSuspensionDoesNotClearAPerDisplaySuspension() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: false),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(probe.applied, [true, false])
        XCTAssertEqual(
            policy.suspendedDisplayIDs, [2],
            "waking the displays must not resume a screen that is still covered")
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])
    }

    func testWakingResumesADisplayUncoveredDuringSleep() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: false),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        probe.setVisible(true, display: 2)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        XCTAssertEqual(probe.applied, [true, false])
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
        XCTAssertEqual(
            probe.displayDecisions(for: 2), [true, false],
            "Waking must resume a display uncovered during sleep without another window event")
        XCTAssertEqual(probe.displayDecisions(for: 1), [], "The other display stays running")
    }

    func testUnlockingResumesADisplayUncoveredWhileLocked() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: false),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])

        probe.sessionLocked = true
        lockCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        probe.setVisible(true, display: 2)
        probe.sessionLocked = false
        lockCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        XCTAssertEqual(probe.applied, [true, false])
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
        XCTAssertEqual(
            probe.displayDecisions(for: 2), [true, false],
            "Unlocking must clear the revealed display's own pause as well as the global pause")
        XCTAssertEqual(probe.displayDecisions(for: 1), [], "The other display stays running")
    }

    func testADisplayNewlyHiddenAtWakeStillWaitsForOcclusionToSettle() async throws {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        let policy = makePolicy(probe, settle: .milliseconds(20))
        policy.start()
        defer { policy.stop() }

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        probe.setVisible(false, display: 2)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        XCTAssertEqual(probe.applied, [true, false])
        XCTAssertTrue(probe.appliedDisplays.isEmpty, "Wake does not bypass the occlusion settle delay")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertEqual(probe.displayDecisions(for: 2), [true])
        XCTAssertEqual(probe.displayDecisions(for: 1), [], "The visible display keeps running")
    }

    func testCountersRecordEachDeliveredDecisionForItsOwnSurface() {
        let counters = RuntimeCounters()
        counters.startSession(duration: .seconds(60))
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        let policy = makePolicy(probe, settle: .zero, counters: counters)
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false, display: 2)
        policy.evaluate()
        probe.setVisible(true, display: 2)
        policy.evaluate()

        let hidden = RuntimeSurfaceKey(kind: .desktopScene, displayID: 2)
        let visible = RuntimeSurfaceKey(kind: .desktopScene, displayID: 1)
        let snapshot = counters.snapshot()
        XCTAssertEqual(snapshot.value(.presentationSuspended, for: hidden), 1)
        XCTAssertEqual(snapshot.value(.presentationResumed, for: hidden), 1)
        XCTAssertEqual(snapshot.value(.presentationSuspended, for: visible), 0)
    }

    // MARK: - delivery serialization

    func testReapplyingAfterCanceledShutdownResumesRenderer() {
        let probe = PolicyProbe()
        var acceptingUpdates = true
        var rendererSuspended: [UInt32: Bool] = [:]
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { probe.surfaces },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: .zero,
            applyGlobal: { _, completion in completion(.success(())) },
            applyDisplay: { display, suspended, completion in
                guard acceptingUpdates else {
                    completion(.failure(CancellationError()))
                    return
                }
                rendererSuspended[display] = suspended
                completion(.success(()))
            }
        )
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false)
        policy.evaluate()
        XCTAssertEqual(rendererSuspended[1], true)

        acceptingUpdates = false
        probe.setVisible(true)
        policy.evaluate()
        XCTAssertEqual(rendererSuspended[1], true, "Shutdown temporarily withholds bridge updates")

        acceptingUpdates = true
        policy.evaluate()
        XCTAssertEqual(rendererSuspended[1], false, "Canceling shutdown must deliver the withheld resume")
    }

    /// A failed resume leaves the renderer suspended. If the display disconnects before the retry,
    /// it is still resumed when it comes back visible, like one whose suspension was acknowledged.
    func testFailedResumeIsRetriedWhenTheDisplayReturnsVisible() {
        let probe = PolicyProbe()
        var rendererSuspended = false
        var failResume = true
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { probe.surfaces },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: .zero,
            applyGlobal: { _, completion in completion(.success(())) },
            applyDisplay: { _, suspended, completion in
                if !suspended, failResume {
                    completion(.failure(NSError(domain: "AudioCapture", code: 1)))
                    return
                }
                rendererSuspended = suspended
                completion(.success(()))
            }
        )
        policy.start()
        defer { policy.stop() }
        probe.setVisible(false)
        policy.evaluate()
        probe.setVisible(true)
        policy.evaluate()
        XCTAssertTrue(rendererSuspended, "the resume failed")

        failResume = false
        let connected = probe.surfaces
        probe.surfaces = []
        policy.evaluate()
        probe.surfaces = connected
        policy.evaluate()
        XCTAssertFalse(rendererSuspended, "the display came back visible, so it is resumed")
    }

    /// A failed suspension leaves the renderer running. If the display disconnects before the
    /// retry and comes back still hidden, the suspension is sent again.
    func testFailedSuspensionIsRetriedWhenTheDisplayReturnsHidden() {
        let probe = PolicyProbe()
        var rendererSuspended = false
        var failSuspend = true
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { probe.surfaces },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: .zero,
            applyGlobal: { _, completion in completion(.success(())) },
            applyDisplay: { _, suspended, completion in
                if suspended, failSuspend {
                    completion(.failure(NSError(domain: "Renderer", code: 1)))
                    return
                }
                rendererSuspended = suspended
                completion(.success(()))
            }
        )
        policy.start()
        defer { policy.stop() }
        probe.setVisible(false)
        policy.evaluate()
        XCTAssertFalse(rendererSuspended, "the suspension failed")

        failSuspend = false
        let connected = probe.surfaces
        probe.surfaces = []
        policy.evaluate()
        probe.surfaces = connected
        policy.evaluate()
        XCTAssertTrue(rendererSuspended, "the display came back hidden, so it is suspended")
    }

    func testFailedResumeRetriesWithUnchangedVisibility() {
        let probe = PolicyProbe()
        var rendererSuspended = false
        var failResume = true
        var resumeAttempts = 0
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { probe.surfaces },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: .zero,
            applyGlobal: { _, completion in completion(.success(())) },
            applyDisplay: { _, suspended, completion in
                if !suspended {
                    resumeAttempts += 1
                    if failResume {
                        completion(.failure(NSError(domain: "AudioCapture", code: 1)))
                        return
                    }
                }
                rendererSuspended = suspended
                completion(.success(()))
            }
        )
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false)
        policy.evaluate()
        XCTAssertTrue(rendererSuspended)

        probe.setVisible(true)
        policy.evaluate()
        XCTAssertTrue(rendererSuspended, "A failed audio restart leaves the renderer rolled back")
        XCTAssertEqual(resumeAttempts, 1, "A failed delivery must not retry in a busy loop")

        failResume = false
        policy.evaluate()
        XCTAssertFalse(rendererSuspended, "Unchanged visibility must retry the unacknowledged resume")
        XCTAssertEqual(resumeAttempts, 2)
        policy.evaluate()
        XCTAssertEqual(resumeAttempts, 2, "An acknowledged state must not be sent again")
    }

    func testVisibilityChangesWaitForInFlightAcknowledgement() {
        let probe = PolicyProbe()
        var requests: [Bool] = []
        var completions: [WallpaperPresentationPolicy.ApplyCompletion] = []
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { probe.surfaces },
            isSessionLocked: { probe.sessionLocked },
            occlusionSettleDelay: .zero,
            applyGlobal: { _, completion in completion(.success(())) },
            applyDisplay: { _, suspended, completion in
                requests.append(suspended)
                completions.append(completion)
            }
        )
        policy.start()
        defer { policy.stop() }

        probe.setVisible(false)
        policy.evaluate()
        probe.setVisible(true)
        policy.evaluate()
        policy.evaluate()
        XCTAssertEqual(requests, [true], "Only one transition may be outstanding")

        completions.removeFirst()(.success(()))
        XCTAssertEqual(requests, [true, false], "The newest visibility decision follows the acknowledgement")
        completions.removeFirst()(.success(()))
        policy.evaluate()
        XCTAssertEqual(requests, [true, false])
        XCTAssertTrue(completions.isEmpty)
    }

    func testStopResumesEverySuspendedSurface() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: false),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        let policy = makePolicy(probe, settle: .zero)
        policy.start()
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(probe.applied, [true])
        XCTAssertEqual(policy.suspendedDisplayIDs, [1])

        policy.stop()
        XCTAssertEqual(probe.applied.last, false, "Teardown must never leave the engine suspended")
        XCTAssertFalse(policy.isSuspended)
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)
        XCTAssertEqual(
            probe.displayDecisions(for: 1), [true, false],
            "Teardown must resume a display it had suspended")
    }

    // MARK: Resume announcements

    func testAGlobalResumeIsAnnouncedAndASuspendIsNot() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        var resumes = 0
        policy.onResumed = { resumes += 1 }
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(resumes, 0, "a desktop that was never suspended has nothing to resume")

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(resumes, 0, "suspending is not a resume")

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(resumes, 1)
        XCTAssertEqual(probe.applied, [true, false])
    }

    func testAUnloadedDesktopThatOnlyBecomesSuspendedHasNotResumed() {
        let probe = PolicyProbe()
        var action = DisplaySleepAction.stop
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter, lockCenter: lockCenter, windowCenter: windowCenter,
            surfaces: { probe.surfaces }, isSessionLocked: { probe.sessionLocked },
            displaySleepAction: { action },
            applyGlobal: { _, completion in completion(.success(())) },
            applyDisplay: { _, _, completion in completion(.success(())) })
        var resumes = 0
        policy.onResumed = { resumes += 1 }
        policy.start()
        defer { policy.stop() }

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        action = .pause
        policy.evaluate()
        XCTAssertEqual(resumes, 0, "unloaded to suspended still shows nothing")

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(resumes, 1)
    }

    func testAResumeTheBridgeRefusesIsAnnouncedWhenItLands() {
        let probe = PolicyProbe()
        var accepting = true
        var attempts = 0
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter, lockCenter: lockCenter, windowCenter: windowCenter,
            surfaces: { probe.surfaces }, isSessionLocked: { probe.sessionLocked },
            applyGlobal: { _, completion in
                attempts += 1
                completion(accepting ? .success(()) : .failure(CancellationError()))
            },
            applyDisplay: { _, _, completion in completion(.success(())) })
        var resumes = 0
        policy.onResumed = { resumes += 1 }
        policy.start()
        defer { policy.stop() }

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        accepting = false
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(resumes, 0, "the scenes are still suspended: nothing has resumed")
        XCTAssertEqual(attempts, 2, "A refused resume is not retried inside the same evaluation")

        accepting = true
        policy.evaluate()
        XCTAssertEqual(resumes, 1, "the retried resume is the one that is announced, once")
        XCTAssertEqual(attempts, 3)
        policy.evaluate()
        XCTAssertEqual(resumes, 1)
        XCTAssertEqual(attempts, 3, "An acknowledged resume is not delivered again")
    }

    func testFailedGlobalResumeIsNotRetriedWhenDisplaysExchangeVisibility() async throws {
        for settle in [Duration.zero, .milliseconds(20)] {
            let probe = PolicyProbe()
            probe.surfaces = [
                WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
                WallpaperSurfaceVisibility(displayID: 2, isVisible: false),
            ]
            var accepting = true
            var attempts = 0
            let policy = WallpaperPresentationPolicy(
                workspaceCenter: workspaceCenter, lockCenter: lockCenter, windowCenter: windowCenter,
                surfaces: { probe.surfaces }, isSessionLocked: { probe.sessionLocked },
                occlusionSettleDelay: settle,
                applyGlobal: { _, completion in
                    attempts += 1
                    completion(accepting ? .success(()) : .failure(CancellationError()))
                },
                applyDisplay: { display, suspended, completion in
                    probe.appliedDisplays.append((display, suspended))
                    completion(.success(()))
                })
            policy.start()
            defer { policy.stop() }
            if settle > .zero { try await Task.sleep(for: .milliseconds(80)) }
            XCTAssertEqual(probe.displayDecisions(for: 2), [true])

            workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            probe.setVisible(false, display: 1)
            probe.setVisible(true, display: 2)
            accepting = false
            workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            XCTAssertEqual(attempts, 2, "A reveal and a hide must not retry a refused global resume")

            accepting = true
            policy.evaluate()
            XCTAssertEqual(attempts, 3)
            XCTAssertEqual(
                probe.displayDecisions(for: 2), [true, false],
                "The revealed display resumes immediately, without waiting for the other display's hide")
            if settle > .zero {
                XCTAssertEqual(probe.displayDecisions(for: 1), [], "Only suspension waits to settle")
                try await Task.sleep(for: .milliseconds(80))
            }
            XCTAssertEqual(probe.displayDecisions(for: 1), [true])
        }
    }

    func testResumingOneDisplayIsAnnouncedAndHidingOrNeverHidingIsNot() {
        let probe = PolicyProbe()
        probe.surfaces = [
            WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
            WallpaperSurfaceVisibility(displayID: 2, isVisible: true),
        ]
        let policy = makePolicy(probe, settle: .zero)
        var resumes = 0
        policy.onResumed = { resumes += 1 }
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(resumes, 0, "displays that were never told anything are presenting already")

        probe.setVisible(false, display: 1)
        policy.evaluate()
        XCTAssertEqual(probe.displayDecisions(for: 1), [true])
        XCTAssertEqual(resumes, 0, "hiding a display is not a resume")

        probe.setVisible(true, display: 1)
        policy.evaluate()
        XCTAssertEqual(probe.displayDecisions(for: 1), [true, false])
        XCTAssertEqual(resumes, 1)
        XCTAssertEqual(probe.displayDecisions(for: 2), [], "the other display never changed")
    }

    func testTearingDownDoesNotAnnounceItsOwnResume() {
        let probe = PolicyProbe()
        let policy = makePolicy(probe)
        var resumes = 0
        policy.onResumed = { resumes += 1 }
        policy.start()
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertTrue(policy.isSuspended)

        policy.stop()

        XCTAssertEqual(probe.applied.last, false, "teardown still resumes the engine")
        XCTAssertEqual(resumes, 0, "but it is not the wallpaper presenting again for a wake to be checked")
    }
}
