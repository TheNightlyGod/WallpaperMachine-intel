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
    /// The share of its own volume a wallpaper keeps under Reduce volume, and what the bridge was told.
    var otherAudioVolume: Float = 0.3
    var gains: [Float] = []
    /// Failures the gain channel returns before it starts acknowledging.
    var gainFailures = 0
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
    case gain(Float)
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
            sessionState: { .init(locked: probe.sessionLocked) },
            displaySleepAction: { probe.sleepAction },
            appRuleActions: { probe.rules.union(conditions?.actions ?? []) },
            otherAudioActive: { probe.otherAudio },
            otherAudioAction: { probe.otherAudioAction },
            otherAudioVolume: { probe.otherAudioVolume },
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
            applyAudioGain: { gain, completion in
                probe.gains.append(gain)
                probe.order.append(.gain(gain))
                if probe.gainFailures > 0 {
                    probe.gainFailures -= 1
                    completion(.failure(DeliveryRefused()))
                } else {
                    completion(.success(()))
                }
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

    // MARK: Reduced volume

    func testReduceVolumeTurnsWallpapersDownOnlyWhileAnotherAppPlaysSound() {
        let probe = CompositionProbe()
        probe.otherAudioAction = .reduceVolume
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertTrue(probe.gains.isEmpty, "Nothing else is playing, so wallpapers keep their own volume")
        XCTAssertEqual(policy.audioGain, 1)

        probe.otherAudio = true
        policy.evaluate()
        XCTAssertEqual(probe.gains, [0.3])
        XCTAssertEqual(policy.audioGain, 0.3)
        XCTAssertTrue(probe.audio.isEmpty, "Turning down is not muting")
        XCTAssertFalse(policy.isAudioSuppressed)
        XCTAssertTrue(probe.presentations.isEmpty, "And it never pauses anything")
        XCTAssertFalse(policy.isSuspended)

        policy.evaluate()
        XCTAssertEqual(probe.gains, [0.3], "Already turned down: no second delivery")

        probe.otherAudio = false
        policy.evaluate()
        XCTAssertEqual(probe.gains, [0.3, 1], "The other sound ended, so each wallpaper is back at its own volume")
    }

    /// Dragging the slider while another app is already playing: the level is a number, so a new
    /// one is a new decision even though the rule was holding all along.
    func testANewLevelIsDeliveredWhileTheRuleAlreadyHolds() {
        let probe = CompositionProbe()
        probe.otherAudio = true
        probe.otherAudioAction = .reduceVolume
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.gains, [0.3])

        probe.otherAudioVolume = 0.65
        policy.evaluate()
        XCTAssertEqual(probe.gains, [0.3, 0.65])

        // A level outside 0 to 1 never reaches the bridge as it is.
        probe.otherAudioVolume = 1.8
        policy.evaluate()
        XCTAssertEqual(probe.gains.last, 1)
        probe.otherAudioVolume = -0.2
        policy.evaluate()
        XCTAssertEqual(probe.gains.last, 0)
    }

    func testOnlyReduceVolumeChangesTheGainAndTheOtherChoicesLiftIt() {
        let probe = CompositionProbe()
        probe.otherAudio = true
        probe.otherAudioAction = .reduceVolume
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.gains, [0.3])

        probe.otherAudioAction = .mute
        policy.evaluate()
        XCTAssertEqual(probe.gains, [0.3, 1], "Mute silences through its own channel, at the saved volume")
        XCTAssertEqual(probe.audio, [true])

        probe.otherAudioAction = .pause
        policy.evaluate()
        XCTAssertEqual(probe.gains, [0.3, 1])
        XCTAssertEqual(probe.presentations, [.suspended])

        probe.otherAudioAction = .keepRunning
        policy.evaluate()
        XCTAssertEqual(probe.gains, [0.3, 1])
        XCTAssertEqual(policy.audioGain, 1)
    }

    /// A mute from anywhere else still silences: the user's Mute All or a mute rule holds on its
    /// own channel while the wallpapers are also turned down, and lifting it leaves them turned
    /// down, not at full volume.
    func testAMuteStillSilencesWallpapersThatAreTurnedDown() {
        let probe = CompositionProbe()
        probe.otherAudio = true
        probe.otherAudioAction = .reduceVolume
        probe.userMuted = true
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.audio, [true])
        XCTAssertEqual(probe.gains, [0.3])
        XCTAssertEqual(probe.order, [.audio(suppressed: true), .gain(0.3)], "Silence first, then the level")

        probe.userMuted = false
        probe.rules = [.mute]
        policy.evaluate()
        XCTAssertEqual(probe.audio, [true], "The rule still mutes")

        probe.rules = []
        policy.evaluate()
        XCTAssertEqual(probe.audio, [true, false])
        XCTAssertEqual(probe.gains, [0.3], "Unmuted into the reduced volume, which never left")
        XCTAssertEqual(policy.audioGain, 0.3)
    }

    func testARefusedLevelIsSentAgainAtTheNextEvaluation() {
        let probe = CompositionProbe()
        probe.otherAudio = true
        probe.otherAudioAction = .reduceVolume
        probe.gainFailures = 1
        let policy = makePolicy(probe)
        policy.start()
        defer { policy.stop() }
        XCTAssertEqual(probe.gains, [0.3], "Refused once, and not retried in a loop")

        policy.evaluate()
        XCTAssertEqual(probe.gains, [0.3, 0.3], "The level the bridge never took is sent again")
        policy.evaluate()
        XCTAssertEqual(probe.gains, [0.3, 0.3], "Once taken it is not sent a third time")
    }

    func testTeardownRestoresEveryWallpapersOwnVolume() {
        let probe = CompositionProbe()
        probe.otherAudio = true
        probe.otherAudioAction = .reduceVolume
        let policy = makePolicy(probe)
        policy.start()
        XCTAssertEqual(probe.gains, [0.3])

        policy.stop()
        XCTAssertEqual(probe.gains.last, 1, "Teardown must never leave a surface turned down")
        XCTAssertEqual(policy.audioGain, 1)
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

    /// "When another app is in front" on Pause on battery reaches the policy as the pause rule it
    /// is: another app in front on battery suspends every display, plugging in presents again at
    /// once, and it composes with the user's mute and a mute rule without touching sound.
    func testPauseOnBatterySuspendsOnlyOnBatteryWithAnotherAppInFront() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.otherAppInFrontAction = .pauseOnBattery
        var frontmost: String? = "com.apple.finder"
        var onBattery = false
        let monitor = AppRuleMonitor(
            preferences: preferences, workspaceCenter: workspaceCenter, runningBundleIDs: { [] },
            frontmostBundleID: { frontmost }, onBattery: { onBattery },
            desktopBundleIDs: ["com.apple.finder", "com.example.Self"])
        let probe = CompositionProbe()
        probe.userMuted = true
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter,
            lockCenter: lockCenter,
            windowCenter: windowCenter,
            surfaces: { [WallpaperSurfaceVisibility(displayID: 1, isVisible: true)] },
            sessionState: { .init(locked: false) },
            displaySleepAction: { .pause },
            appRuleActions: { monitor.actions },
            otherAudioActive: { false },
            otherAudioAction: { .keepRunning },
            userMuted: { probe.userMuted },
            qualityReductions: { [] },
            occlusionSettleDelay: .zero,
            applyGlobal: { presentation, completion in
                probe.presentations.append(presentation)
                completion(.success(()))
            },
            applyAudio: { suppressed, completion in
                probe.audio.append(suppressed)
                completion(.success(()))
            },
            applyQuality: { _, completion in completion(.success(())) },
            applyDisplay: { _, _, completion in completion(.success(())) })
        monitor.onChange = { policy.evaluate() }
        monitor.start()
        policy.start()
        defer {
            monitor.onChange = nil
            monitor.stop()
            policy.stop()
        }
        func activate(_ bundleID: String?) {
            frontmost = bundleID
            workspaceCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        }

        activate("com.example.Editor")
        XCTAssertTrue(probe.presentations.isEmpty, "Plugged in, another app in front changes nothing")
        XCTAssertEqual(policy.globalPresentation, .running)

        onBattery = true
        monitor.refresh()
        XCTAssertEqual(probe.presentations, [.suspended], "Unplugged with another app in front: paused")
        XCTAssertEqual(probe.audio, [true], "The user's mute is delivered once and never lifted by the pause")

        activate("com.apple.finder")
        XCTAssertEqual(probe.presentations, [.suspended, .running], "Clicking the desktop plays again")
        activate("com.example.Editor")
        XCTAssertEqual(probe.presentations, [.suspended, .running, .suspended])

        onBattery = false
        monitor.refresh()
        XCTAssertEqual(probe.presentations, [.suspended, .running, .suspended, .running],
                       "Plugging in plays again without the desktop in front")
        XCTAssertEqual(probe.audio, [true], "Pausing and playing never touched the sound")
        XCTAssertEqual(policy.globalPresentation, .running)
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

    // MARK: An inactive Mac

    /// The inactivity rule pauses every display the way an app rule does, beside a display that is
    /// paused on its own because it is covered, and gives each display back to its own visibility
    /// at the next input. Stop goes through the unload that frees memory.
    func testInactivitySuspendsEveryDisplayAndACoveredOneKeepsItsOwnPause() throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.inactivityAction = .pause
        let input = ManualInactivityInput()
        let monitor = SystemConditionMonitor(
            preferences: preferences, focus: FocusFilterState(defaults: defaults),
            systemCenter: NotificationCenter(), isLowPowerModeEnabled: { false },
            thermalState: { .nominal }, battery: NoBattery(), inactivity: input.makeMonitor())
        var presentations: [GlobalPresentation] = []
        let policy = WallpaperPresentationPolicy(
            workspaceCenter: workspaceCenter, lockCenter: lockCenter, windowCenter: windowCenter,
            surfaces: {
                [WallpaperSurfaceVisibility(displayID: 1, isVisible: true),
                 WallpaperSurfaceVisibility(displayID: 2, isVisible: false)]
            },
            sessionState: { .init(locked: false) },
            appRuleActions: { monitor.actions },
            occlusionSettleDelay: .zero,
            applyGlobal: { presentation, completion in
                presentations.append(presentation)
                completion(.success(()))
            },
            applyDisplay: { _, _, completion in completion(.success(())) })
        monitor.onChange = { policy.evaluate() }
        monitor.start()
        policy.start()
        defer {
            monitor.onChange = nil
            monitor.stop()
            policy.stop()
        }
        XCTAssertEqual(policy.suspendedDisplayIDs, [2], "The covered display pauses on its own")
        XCTAssertTrue(presentations.isEmpty)

        input.secondsSinceInput = 600
        input.fireTimer()
        XCTAssertEqual(presentations, [.suspended], "Ten minutes without input pause every display")
        XCTAssertEqual(policy.suspendedDisplayIDs, [2])
        XCTAssertFalse(policy.isUnattended, "Only sleeping displays or a lock count as nobody at the Mac")

        input.movePointer()
        XCTAssertEqual(presentations, [.suspended, .running])
        XCTAssertEqual(policy.suspendedDisplayIDs, [2], "The covered display is still paused")

        preferences.inactivityAction = .stop
        input.secondsSinceInput = 600
        input.fireTimer()
        XCTAssertEqual(presentations.last, .unloaded)
    }
}
