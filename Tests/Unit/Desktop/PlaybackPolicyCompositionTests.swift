import XCTest
@testable import WallpaperMachine

@MainActor
private final class CompositionProbe {
    var presentations: [GlobalPresentation] = []
    var audio: [Bool] = []
    var sessionLocked = false
    var sleepAction = DisplaySleepAction.pause
    var rules: Set<AppRuleAction> = []
    var otherAudio = false
    var otherAudioAction = OtherAudioAction.keepRunning
    var userMuted = false
    /// What the conditions ask the quality channel for, and what it was told, in order.
    var reductions: Set<QualityReduction> = []
    var quality: [Set<QualityReduction>] = []
    /// Failures the quality channel returns before it starts acknowledging.
    var qualityFailures = 0
    /// Every delivery in the order it was made, across the channels.
    var order: [Delivery] = []
    /// Holds the global acknowledgement until the test releases it.
    var holdGlobal = false
    var heldGlobal: [WallpaperPresentationPolicy.ApplyCompletion] = []
}

private struct DeliveryRefused: Error {}

/// One request the policy made of the bridge, what it asked for and not how the log words it.
private enum Delivery: Equatable {
    case global(GlobalPresentation)
    case audio(suppressed: Bool)
    case quality(Set<QualityReduction>)
}

/// A Mac with no battery to read: the low-battery rule is left on keep running in these tests.
@MainActor
private final class NoBattery: BatteryLevelSource {
    var reading: BatteryReading? { nil }
    func start(onChange: @escaping @MainActor () -> Void) {}
    func stop() {}
}

@MainActor
final class PlaybackPolicyCompositionTests: XCTestCase {
    private let workspaceCenter = NotificationCenter()
    private let lockCenter = NotificationCenter()
    private let windowCenter = NotificationCenter()

    private func makePolicy(
        _ probe: CompositionProbe, conditions: SystemConditionMonitor? = nil
    ) -> WallpaperPresentationPolicy {
        WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { [WallpaperSurfaceVisibility(displayID: 1, isVisible: true)] },
            isSessionLocked: { probe.sessionLocked },
            displaySleepAction: { probe.sleepAction },
            appRuleActions: { probe.rules.union(conditions?.actions ?? []) },
            otherAudioActive: { probe.otherAudio },
            otherAudioAction: { probe.otherAudioAction },
            userMuted: { probe.userMuted },
            qualityReductions: { probe.reductions.union(conditions?.qualityReductions ?? []) },
            occlusionSettleDelay: .zero,
            applyGlobal: { presentation, completion in
                probe.presentations.append(presentation)
                probe.order.append(.global(presentation))
                if probe.holdGlobal {
                    probe.heldGlobal.append(completion)
                } else {
                    completion(.success(()))
                }
            },
            applyAudio: { suppressed, completion in
                probe.audio.append(suppressed)
                probe.order.append(.audio(suppressed: suppressed))
                completion(.success(()))
            },
            applyQuality: { reductions, completion in
                probe.quality.append(reductions)
                probe.order.append(.quality(reductions))
                if probe.qualityFailures > 0 {
                    probe.qualityFailures -= 1
                    completion(.failure(DeliveryRefused()))
                } else {
                    completion(.success(()))
                }
            },
            applyDisplay: { _, _, completion in completion(.success(())) })
    }

    func testDisplaySleepStopUnloadsAndPauseOnlySuspends() {
        let probe = CompositionProbe()
        probe.sleepAction = .stop
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(probe.presentations, [.unloaded])
        XCTAssertEqual(policy.globalPresentation, .unloaded)
        XCTAssertTrue(policy.isSuspended)

        probe.sleepAction = .pause
        policy.evaluate()
        XCTAssertEqual(policy.globalPresentation, .suspended)
        XCTAssertEqual(probe.presentations.last, .suspended)
    }

    func testLockPlusPauseRuleSuspendsAndStopBeatsPause() {
        let probe = CompositionProbe()
        probe.sessionLocked = true
        probe.rules = [.pause]
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.presentations, [.suspended])
        XCTAssertTrue(probe.audio.isEmpty, "Pause does not mute")

        probe.rules = [.pause, .stop]
        policy.evaluate()
        XCTAssertEqual(policy.globalPresentation, .unloaded)
        XCTAssertEqual(probe.presentations.last, .unloaded)
    }

    func testMuteComesFromARuleOrFromOtherAudio() {
        let probe = CompositionProbe()
        probe.rules = [.mute]
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.audio, [true])
        XCTAssertTrue(probe.presentations.isEmpty, "Mute leaves presentation running")
        XCTAssertFalse(policy.isSuspended)

        probe.rules = []
        policy.evaluate()
        XCTAssertEqual(probe.audio.last, false)

        probe.otherAudio = true
        probe.otherAudioAction = .mute
        policy.evaluate()
        XCTAssertEqual(probe.audio.last, true)
        XCTAssertTrue(probe.presentations.isEmpty)

        probe.otherAudioAction = .pause
        policy.evaluate()
        XCTAssertEqual(probe.audio.last, false)
        XCTAssertEqual(probe.presentations, [.suspended])
    }

    /// The user's own mute of every wallpaper is one more reason for the bridge's single
    /// audio-suppression flag, not a replacement for the others: it silences without touching
    /// presentation, and what else is muting keeps holding when it is lifted.
    func testUserMuteComposesWithRulesAndOtherAudio() {
        let probe = CompositionProbe()
        probe.userMuted = true
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.audio, [true], "A mute that was already on at launch reaches the bridge")
        XCTAssertTrue(policy.isAudioSuppressed)
        XCTAssertTrue(probe.presentations.isEmpty, "Muting never pauses or unloads anything")
        XCTAssertFalse(policy.isSuspended)

        // A mute rule and other-app audio hold as well, so lifting the user's mute changes nothing.
        probe.rules = [.mute]
        probe.otherAudio = true
        probe.otherAudioAction = .mute
        policy.evaluate()
        XCTAssertEqual(probe.audio, [true], "Already suppressed: no second delivery")
        probe.userMuted = false
        policy.evaluate()
        XCTAssertEqual(probe.audio, [true], "The rule and the other audio still mute")
        XCTAssertTrue(policy.isAudioSuppressed)

        probe.rules = []
        policy.evaluate()
        XCTAssertTrue(policy.isAudioSuppressed, "Other-app audio alone still mutes")
        probe.otherAudio = false
        policy.evaluate()
        XCTAssertEqual(probe.audio, [true, false], "Nothing mutes any more")
        XCTAssertFalse(policy.isAudioSuppressed)

        // And back on from silence, with no rule involved.
        probe.userMuted = true
        policy.evaluate()
        XCTAssertEqual(probe.audio, [true, false, true])
        XCTAssertTrue(probe.presentations.isEmpty)
    }

    func testTeardownRestoresSoundWhateverTheUserChose() {
        let probe = CompositionProbe()
        probe.userMuted = true
        let policy = makePolicy(probe)
        policy.start()
        XCTAssertEqual(probe.audio, [true])

        policy.stop()
        XCTAssertEqual(probe.audio.last, false, "Teardown must never leave a surface muted")
        XCTAssertFalse(policy.isAudioSuppressed)
    }

    func testKeepRunningIgnoresOtherAudio() {
        let probe = CompositionProbe()
        probe.otherAudio = true
        probe.otherAudioAction = .keepRunning
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertTrue(probe.presentations.isEmpty)
        XCTAssertTrue(probe.audio.isEmpty)
        XCTAssertEqual(policy.globalPresentation, .running)
        XCTAssertFalse(policy.isAudioSuppressed)
    }

    func testStopRestoresRunningAndUnmuted() {
        let probe = CompositionProbe()
        probe.rules = [.stop, .mute]
        let policy = makePolicy(probe)
        policy.start()
        XCTAssertEqual(probe.presentations, [.unloaded])
        XCTAssertEqual(probe.audio, [true])

        policy.stop()
        XCTAssertEqual(probe.presentations.last, .running)
        XCTAssertEqual(probe.audio.last, false)
        XCTAssertEqual(policy.globalPresentation, .running)
        XCTAssertFalse(policy.isAudioSuppressed)
        XCTAssertFalse(policy.isSuspended)
    }

    // MARK: Quality channel

    func testQualityReductionIsDeliveredOnItsOwnAndNeverSuspends() {
        let probe = CompositionProbe()
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertTrue(probe.quality.isEmpty, "The bridge starts unthrottled: nothing to say yet")

        probe.reductions = [.heat]
        policy.evaluate()
        XCTAssertEqual(probe.quality, [[.heat]])
        XCTAssertEqual(policy.qualityReductions, [.heat])
        XCTAssertTrue(probe.presentations.isEmpty, "Reduced quality is not a presentation change")
        XCTAssertTrue(probe.audio.isEmpty)
        XCTAssertFalse(policy.isSuspended)
        XCTAssertTrue(policy.suspendedDisplayIDs.isEmpty)

        policy.evaluate()
        XCTAssertEqual(probe.quality, [[.heat]], "An unchanged set is not sent again")

        probe.reductions = [.heat, .lowBattery]
        policy.evaluate()
        XCTAssertEqual(probe.quality.last, [.heat, .lowBattery], "Another cause joining is a new request")

        probe.reductions = []
        policy.evaluate()
        XCTAssertEqual(probe.quality.last, [], "Nothing asks for it any more")
        XCTAssertEqual(probe.quality.count, 3)
        XCTAssertTrue(policy.qualityReductions.isEmpty)
        XCTAssertTrue(probe.presentations.isEmpty)
    }

    func testAFailedQualityDeliveryIsRetriedByTheNextEvaluation() {
        let probe = CompositionProbe()
        probe.qualityFailures = 1
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.reductions = [.heat]
        policy.evaluate()
        XCTAssertEqual(probe.quality, [[.heat]], "A refusal is not retried inside the same evaluation")

        policy.evaluate()
        XCTAssertEqual(probe.quality, [[.heat], [.heat]], "The next evaluation sends the same request again")

        policy.evaluate()
        XCTAssertEqual(probe.quality.count, 2, "Once acknowledged it stays delivered")
    }

    func testAFailedReleaseIsSentAgainToo() {
        let probe = CompositionProbe()
        probe.reductions = [.lowPowerMode]
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.quality, [[.lowPowerMode]])

        probe.reductions = []
        probe.qualityFailures = 1
        policy.evaluate()
        policy.evaluate()
        XCTAssertEqual(probe.quality, [[.lowPowerMode], [], []],
                       "A wallpaper must not stay reduced because the release was refused once")
    }

    func testStoppingThePolicyRestoresFullQuality() {
        let probe = CompositionProbe()
        probe.reductions = [.heat]
        let policy = makePolicy(probe)
        policy.start()
        XCTAssertEqual(probe.quality, [[.heat]])

        policy.stop()
        XCTAssertEqual(probe.quality.last, [], "Teardown must never leave a wallpaper reduced")
        XCTAssertTrue(policy.qualityReductions.isEmpty)
    }

    func testQualityIsDeliveredAfterGlobalPresentationAndIndependentOfIt() {
        let probe = CompositionProbe()
        probe.holdGlobal = true
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }

        probe.reductions = [.lowPowerMode]
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(probe.order, [.global(.suspended)], "One acknowledgement at a time: quality waits")
        XCTAssertTrue(probe.quality.isEmpty)

        probe.holdGlobal = false
        probe.heldGlobal.removeFirst()(.success(()))
        XCTAssertEqual(probe.order, [.global(.suspended), .quality([.lowPowerMode])])
        XCTAssertEqual(policy.globalPresentation, .suspended)
        XCTAssertEqual(policy.qualityReductions, [.lowPowerMode])

        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(policy.globalPresentation, .running)
        XCTAssertEqual(probe.presentations, [.suspended, .running])
        XCTAssertEqual(probe.quality.count, 1, "Waking does not send the unchanged request again")
    }

    func testHeatThrottlesAtSeriousAndEscalatesToAPauseAtCritical() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.thermalAction = .reduceQuality
        var thermal = ProcessInfo.ThermalState.nominal
        let systemCenter = NotificationCenter()
        let monitor = SystemConditionMonitor(
            preferences: preferences, focus: FocusFilterState(defaults: defaults),
            systemCenter: systemCenter, isLowPowerModeEnabled: { false }, thermalState: { thermal },
            battery: NoBattery())
        let probe = CompositionProbe()
        let policy = makePolicy(probe, conditions: monitor)
        monitor.onChange = { policy.evaluate() }
        monitor.start()
        policy.start()
        defer {
            monitor.onChange = nil
            monitor.stop()
            policy.stop()
        }
        func announce(_ state: ProcessInfo.ThermalState) {
            thermal = state
            systemCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        }

        announce(.fair)
        XCTAssertTrue(probe.quality.isEmpty, "Fair heat asks for nothing")

        announce(.serious)
        XCTAssertEqual(probe.quality, [[.heat]])
        XCTAssertTrue(probe.presentations.isEmpty, "Serious heat reduces and keeps presenting")
        XCTAssertFalse(policy.isSuspended)

        announce(.critical)
        XCTAssertEqual(probe.presentations, [.suspended], "Critical heat is past what reducing can do")
        XCTAssertEqual(probe.quality.count, 1, "The reduction is already in force and is not sent again")

        announce(.serious)
        XCTAssertEqual(probe.presentations, [.suspended, .running], "Cooling to serious presents again")
        XCTAssertEqual(probe.quality.count, 1, "Cooling to serious does not release the reduction")

        announce(.nominal)
        XCTAssertEqual(probe.quality, [[.heat], []])
        XCTAssertEqual(probe.presentations, [.suspended, .running])
    }
}
