import XCTest
@testable import WallpaperMachine

@MainActor
final class SystemConditionMonitorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var preferences: PlaybackPreferences!
    private var focus: FocusFilterState!
    private var systemCenter: NotificationCenter!
    private var lowPower = false
    private var thermal = ProcessInfo.ThermalState.nominal
    private var battery: FakeBatteryLevel!
    private var state: SystemConditionState!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
        preferences = PlaybackPreferences(defaults: defaults)
        focus = FocusFilterState(defaults: defaults)
        systemCenter = NotificationCenter()
        lowPower = false
        thermal = .nominal
        battery = FakeBatteryLevel()
        state = SystemConditionState()
    }

    override func tearDown() {
        defaults = nil
        preferences = nil
        focus = nil
        systemCenter = nil
        battery = nil
        state = nil
        super.tearDown()
    }

    private func makeMonitor() -> SystemConditionMonitor {
        SystemConditionMonitor(
            preferences: preferences, focus: focus, systemCenter: systemCenter,
            isLowPowerModeEnabled: { self.lowPower }, thermalState: { self.thermal }, battery: battery,
            state: state)
    }

    func testLowPowerModeActsOnlyOnceTheUserChoseAnAction() {
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        lowPower = true
        systemCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertTrue(monitor.actions.isEmpty, "Keep running is the default")

        preferences.lowPowerModeAction = .pause
        XCTAssertEqual(monitor.actions, [.pause])

        lowPower = false
        systemCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertTrue(monitor.actions.isEmpty, "Leaving Low Power Mode resumes")
    }

    func testOnlySeriousAndCriticalHeatCount() {
        preferences.thermalAction = .stop
        let monitor = makeMonitor()
        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.start()
        defer { monitor.stop() }
        for state in [ProcessInfo.ThermalState.nominal, .fair] {
            thermal = state
            systemCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            XCTAssertTrue(monitor.actions.isEmpty)
        }
        thermal = .serious
        systemCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(monitor.actions, [.stop])
        thermal = .critical
        systemCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(monitor.actions, [.stop])
        XCTAssertEqual(changes, 1, "Staying hot is not a change")
    }

    private func announceHeat(_ state: ProcessInfo.ThermalState) {
        thermal = state
        systemCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    func testReducedQualityInLowPowerModeAsksForAReductionAndNeverForAPause() {
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        lowPower = true
        systemCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertTrue(monitor.actions.isEmpty)
        XCTAssertTrue(monitor.qualityReductions.isEmpty, "Keep running is the default")

        preferences.lowPowerModeAction = .reduceQuality
        XCTAssertEqual(monitor.qualityReductions, [.lowPowerMode])
        XCTAssertTrue(monitor.actions.isEmpty, "Reducing quality pauses nothing")

        lowPower = false
        systemCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertTrue(monitor.qualityReductions.isEmpty, "Leaving Low Power Mode restores the quality")
        XCTAssertTrue(monitor.actions.isEmpty)
    }

    func testHeatReducesAtSeriousAndPausesAtCritical() {
        preferences.thermalAction = .reduceQuality
        let monitor = makeMonitor()
        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.start()
        defer { monitor.stop() }
        for state in [ProcessInfo.ThermalState.nominal, .fair] {
            announceHeat(state)
            XCTAssertTrue(monitor.actions.isEmpty)
            XCTAssertTrue(monitor.qualityReductions.isEmpty, "Only serious and critical heat counts")
        }
        XCTAssertEqual(changes, 0)

        announceHeat(.serious)
        XCTAssertEqual(monitor.qualityReductions, [.heat])
        XCTAssertTrue(monitor.actions.isEmpty, "Serious heat reduces without pausing")
        XCTAssertEqual(changes, 1)

        announceHeat(.critical)
        XCTAssertEqual(monitor.actions, [.pause], "Critical heat escalates to a pause")
        XCTAssertEqual(monitor.qualityReductions, [.heat], "and stays reduced for the way back")
        XCTAssertEqual(changes, 2)
        announceHeat(.critical)
        XCTAssertEqual(changes, 2, "Staying critical is not a change")

        announceHeat(.serious)
        XCTAssertTrue(monitor.actions.isEmpty, "Cooling to serious resumes, already reduced")
        XCTAssertEqual(monitor.qualityReductions, [.heat])
        XCTAssertEqual(changes, 3)

        announceHeat(.nominal)
        XCTAssertTrue(monitor.actions.isEmpty)
        XCTAssertTrue(monitor.qualityReductions.isEmpty)
        XCTAssertEqual(changes, 4)
    }

    func testPauseAndStopAtHeatStillAskForNoReduction() {
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        for (choice, expected) in [(SystemConditionAction.pause, AppRuleAction.pause), (.stop, .stop)] {
            preferences.thermalAction = choice
            for state in [ProcessInfo.ThermalState.serious, .critical] {
                announceHeat(state)
                XCTAssertEqual(monitor.actions, [expected], "\(choice) at \(state.rawValue)")
                XCTAssertTrue(monitor.qualityReductions.isEmpty, "\(choice) at \(state.rawValue)")
            }
        }
    }

    func testLowBatteryReducesQualityThroughTheSameGate() {
        battery.reading = BatteryReading(percent: 15, isDischarging: true)
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.qualityReductions.isEmpty, "Keep running is the default")
        XCTAssertFalse(battery.isObserving, "Nothing is observed until an action is chosen")
        XCTAssertEqual(battery.reads, 0, "Nothing is read until an action is chosen")

        preferences.lowBatteryAction = .reduceQuality
        XCTAssertEqual(monitor.qualityReductions, [.lowBattery], "Already low when the rule is chosen engages at once")
        XCTAssertTrue(monitor.actions.isEmpty, "Reducing quality pauses nothing")
        XCTAssertTrue(battery.isObserving)

        battery.change(to: BatteryReading(percent: 22, isDischarging: true))
        XCTAssertEqual(monitor.qualityReductions, [.lowBattery], "22% is still inside the margin above the 20% level")
        battery.change(to: BatteryReading(percent: 26, isDischarging: true))
        XCTAssertTrue(monitor.qualityReductions.isEmpty, "Five points above the level restores the quality")
        battery.change(to: BatteryReading(percent: 21, isDischarging: true))
        XCTAssertTrue(monitor.qualityReductions.isEmpty, "Falling back to 21% is not low again")
        battery.change(to: BatteryReading(percent: 8, isDischarging: true))
        XCTAssertEqual(monitor.qualityReductions, [.lowBattery])
        battery.change(to: BatteryReading(percent: 8, isDischarging: false))
        XCTAssertTrue(monitor.qualityReductions.isEmpty, "Plugging in releases however low the charge is")
        battery.change(to: BatteryReading(percent: 8, isDischarging: true))
        XCTAssertEqual(monitor.qualityReductions, [.lowBattery])

        preferences.lowBatteryAction = .keepRunning
        XCTAssertTrue(monitor.qualityReductions.isEmpty, "Choosing Keep running releases")
        XCTAssertFalse(battery.isObserving, "and stops observing")
    }

    func testConditionsAreIndependent() {
        lowPower = true
        thermal = .serious
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }

        preferences.lowPowerModeAction = .reduceQuality
        preferences.thermalAction = .pause
        XCTAssertEqual(monitor.actions, [.pause])
        XCTAssertEqual(monitor.qualityReductions, [.lowPowerMode])

        preferences.lowPowerModeAction = .stop
        preferences.thermalAction = .reduceQuality
        XCTAssertEqual(monitor.actions, [.stop])
        XCTAssertEqual(monitor.qualityReductions, [.heat])

        preferences.lowPowerModeAction = .reduceQuality
        preferences.lowBatteryAction = .reduceQuality
        battery.change(to: BatteryReading(percent: 9, isDischarging: true))
        XCTAssertEqual(monitor.qualityReductions, [.heat, .lowPowerMode, .lowBattery])
        XCTAssertTrue(monitor.actions.isEmpty)

        focus.set(.mute)
        announceHeat(.critical)
        XCTAssertEqual(monitor.actions, [.mute, .pause], "A Focus filter and the critical-heat pause join")
        XCTAssertEqual(monitor.qualityReductions, [.heat, .lowPowerMode, .lowBattery])
    }

    func testStoppingReleasesEveryReduction() {
        preferences.lowPowerModeAction = .reduceQuality
        preferences.thermalAction = .reduceQuality
        preferences.lowBatteryAction = .reduceQuality
        lowPower = true
        thermal = .critical
        battery.reading = BatteryReading(percent: 9, isDischarging: true)
        let monitor = makeMonitor()
        monitor.start()
        XCTAssertEqual(monitor.qualityReductions, [.heat, .lowPowerMode, .lowBattery])
        XCTAssertEqual(monitor.actions, [.pause])

        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.stop()
        XCTAssertTrue(monitor.qualityReductions.isEmpty, "A stopped monitor must never leave wallpapers reduced")
        XCTAssertTrue(monitor.actions.isEmpty)
        XCTAssertEqual(changes, 1, "Releasing everything is one change")
        XCTAssertFalse(battery.isObserving)

        preferences.thermalAction = .pause
        announceHeat(.serious)
        XCTAssertTrue(monitor.qualityReductions.isEmpty, "Nothing is observed after stop")
        XCTAssertTrue(monitor.actions.isEmpty)
        XCTAssertEqual(changes, 1)
    }

    func testFocusFilterJoinsTheOtherConditions() {
        preferences.lowPowerModeAction = .pause
        lowPower = true
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        focus.set(.mute)
        XCTAssertEqual(monitor.actions, [.pause, .mute])
        focus.set(nil)
        XCTAssertEqual(monitor.actions, [.pause])
    }

    func testFocusFilterStateOutlivesTheApp() {
        focus.set(.stop)
        XCTAssertEqual(FocusFilterState(defaults: defaults).action, .stop)
        focus.set(nil)
        XCTAssertNil(FocusFilterState(defaults: defaults).action)
    }

    func testStoppingReleasesEveryAction() {
        preferences.thermalAction = .pause
        thermal = .critical
        let monitor = makeMonitor()
        monitor.start()
        XCTAssertEqual(monitor.actions, [.pause])
        monitor.stop()
        XCTAssertTrue(monitor.actions.isEmpty, "A stopped monitor must never leave wallpapers paused")
        preferences.thermalAction = .stop
        XCTAssertTrue(monitor.actions.isEmpty, "Nothing is observed after stop")
    }

    func testLowBatteryActsOnlyOnceTheUserChoseAnAction() {
        battery.reading = BatteryReading(percent: 15, isDischarging: true)
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty, "Keep running is the default")
        XCTAssertFalse(battery.isObserving, "Nothing is observed until an action is chosen")
        XCTAssertEqual(battery.reads, 0, "Nothing is read until an action is chosen")

        preferences.lowBatteryAction = .pause
        XCTAssertEqual(monitor.actions, [.pause], "Already low when the rule is chosen engages at once")
        XCTAssertTrue(battery.isObserving)

        battery.change(to: BatteryReading(percent: 22, isDischarging: true))
        XCTAssertEqual(monitor.actions, [.pause], "22% is still inside the margin above the 20% level")
        battery.change(to: BatteryReading(percent: 26, isDischarging: true))
        XCTAssertTrue(monitor.actions.isEmpty, "Five points above the level resumes")
        battery.change(to: BatteryReading(percent: 21, isDischarging: true))
        XCTAssertTrue(monitor.actions.isEmpty, "Falling back to 21% is not low again")
        battery.change(to: BatteryReading(percent: 20, isDischarging: true))
        XCTAssertEqual(monitor.actions, [.pause])

        preferences.lowBatteryAction = .keepRunning
        XCTAssertTrue(monitor.actions.isEmpty, "Choosing Keep running releases")
        XCTAssertFalse(battery.isObserving, "and stops observing")
    }

    func testPluggingInReleasesAtAnyChargeAndThresholdChangesApplyAtOnce() {
        preferences.lowBatteryAction = .stop
        battery.reading = BatteryReading(percent: 28, isDischarging: true)
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty, "28% is above the default 20% level")

        preferences.lowBatteryThreshold = 30
        XCTAssertEqual(monitor.actions, [.stop], "Raising the level above the charge engages")
        preferences.lowBatteryThreshold = 20
        XCTAssertTrue(monitor.actions.isEmpty, "Lowering it more than the margin below the charge releases")

        battery.change(to: BatteryReading(percent: 8, isDischarging: true))
        XCTAssertEqual(monitor.actions, [.stop])
        battery.change(to: BatteryReading(percent: 8, isDischarging: false))
        XCTAssertTrue(monitor.actions.isEmpty, "Plugging in releases however low the charge is")
    }

    func testAMacWithoutAnInternalBatteryNeverEngages() {
        preferences.lowBatteryAction = .pause
        battery.reading = nil
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty)
        battery.change(to: nil)
        XCTAssertTrue(monitor.actions.isEmpty)
    }

    func testLowBatteryJoinsTheOtherConditionsAndStopReleasesIt() {
        preferences.lowPowerModeAction = .pause
        preferences.lowBatteryAction = .stop
        lowPower = true
        battery.reading = BatteryReading(percent: 9, isDischarging: true)
        let monitor = makeMonitor()
        monitor.start()
        XCTAssertEqual(monitor.actions, [.pause, .stop], "Each condition contributes its own action")

        monitor.stop()
        XCTAssertTrue(monitor.actions.isEmpty, "A stopped monitor must never leave wallpapers stopped")
        XCTAssertFalse(battery.isObserving, "and observes nothing")
        battery.reading = BatteryReading(percent: 5, isDischarging: true)
        preferences.lowBatteryThreshold = 30
        XCTAssertTrue(monitor.actions.isEmpty, "Nothing is evaluated after stop")

        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.actions, [.pause, .stop], "A restart evaluates the current charge afresh")
    }

    func testRefreshingReadsAChangeNobodyAnnouncedOnlyWhileTheRuleIsOn() {
        battery.reading = BatteryReading(percent: 50, isDischarging: false)
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        battery.reading = BatteryReading(percent: 12, isDischarging: true)
        monitor.refreshBattery()
        XCTAssertEqual(battery.reads, 0, "With Keep running there is nothing to read")
        XCTAssertTrue(monitor.actions.isEmpty)

        preferences.lowBatteryAction = .pause
        XCTAssertEqual(monitor.actions, [.pause])
        battery.reading = BatteryReading(percent: 80, isDischarging: false)
        monitor.refreshBattery()
        XCTAssertTrue(monitor.actions.isEmpty, "A wake that finds the Mac plugged in releases without a notification")
    }

    // MARK: Engaged conditions

    private func engaged(_ pairs: (SystemCondition, EngagedSystemCondition.Effect)...) -> EngagedSystemConditions {
        EngagedSystemConditions(pairs.map { EngagedSystemCondition(condition: $0.0, effect: $0.1) })
    }

    /// The panel names the rule behind a pause from what the monitor publishes, so each condition
    /// is reported with what its own rule does, in naming order, and the state holds the same value.
    func testEngagedNamesEachConditionWithWhatItsOwnRuleDoes() {
        preferences.lowPowerModeAction = .pause
        preferences.thermalAction = .reduceQuality
        preferences.lowBatteryAction = .stop
        lowPower = true
        thermal = .serious
        battery.reading = BatteryReading(percent: 9, isDischarging: true)
        focus.set(.mute)
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        let expected = engaged((.heat, .reducedQuality), (.lowPowerMode, .pause), (.lowBattery, .stop))
        XCTAssertEqual(monitor.engaged, expected, "A Focus filter is not a condition")
        XCTAssertEqual(state.engaged, expected)
        XCTAssertEqual(state.engaged.strongestRuleAction?.condition, .lowBattery, "A stop outweighs a pause")

        announceHeat(.critical)
        XCTAssertEqual(
            state.engaged.effect(of: .heat), .pause,
            "Reduced quality pauses at critical, so the hot Mac reads as a pause")
        XCTAssertEqual(monitor.actions, [.pause, .stop, .mute])

        preferences.lowPowerModeAction = .keepRunning
        XCTAssertNil(state.engaged.effect(of: .lowPowerMode), "Keep running is never listed")
    }

    /// The low-battery rule stays engaged inside its margin; the state follows the gate, never the
    /// charge alone.
    func testEngagedFollowsTheLowBatteryHysteresis() {
        preferences.lowBatteryAction = .pause
        battery.reading = BatteryReading(percent: 15, isDischarging: true)
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(state.engaged, engaged((.lowBattery, .pause)))
        battery.change(to: BatteryReading(percent: 22, isDischarging: true))
        XCTAssertEqual(state.engaged, engaged((.lowBattery, .pause)), "22% is inside the margin above 20%")
        battery.change(to: BatteryReading(percent: 26, isDischarging: true))
        XCTAssertTrue(state.engaged.isEmpty)
        battery.change(to: BatteryReading(percent: 21, isDischarging: true))
        XCTAssertTrue(state.engaged.isEmpty, "Falling back to 21% is not low again")
    }

    /// A second condition that engages with the same action changes nothing the presentation
    /// policy reads, so it is no policy change, but the state still names both.
    func testASecondConditionWithTheSameActionChangesOnlyTheState() {
        preferences.lowPowerModeAction = .pause
        preferences.thermalAction = .pause
        lowPower = true
        let monitor = makeMonitor()
        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(changes, 1)
        let posts = expectation(forNotification: SystemConditionState.didChangeNotification, object: state)
        announceHeat(.serious)
        wait(for: [posts], timeout: 1)
        XCTAssertEqual(changes, 1, "The policy is not asked again for the same pause")
        XCTAssertEqual(state.engaged, engaged((.heat, .pause), (.lowPowerMode, .pause)))
        XCTAssertEqual(state.engaged.strongestRuleAction?.condition, .heat, "Among equals, heat is named first")
    }

    func testStoppingClearsTheState() {
        preferences.thermalAction = .stop
        thermal = .serious
        let monitor = makeMonitor()
        monitor.start()
        XCTAssertEqual(state.engaged, engaged((.heat, .stop)))
        monitor.stop()
        XCTAssertTrue(monitor.engaged.isEmpty)
        XCTAssertTrue(state.engaged.isEmpty, "A stopped monitor never leaves the panel naming a rule")
    }
}

/// A battery the test drives: `reading` is what the monitor sees, `change(to:)` also announces it.
@MainActor
private final class FakeBatteryLevel: BatteryLevelSource {
    var stored: BatteryReading?
    private(set) var reads = 0
    private(set) var isObserving = false
    private var onChange: (@MainActor () -> Void)?

    var reading: BatteryReading? {
        get {
            reads += 1
            return stored
        }
        set { stored = newValue }
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        isObserving = true
        self.onChange = onChange
    }

    func stop() {
        isObserving = false
        onChange = nil
    }

    func change(to reading: BatteryReading?) {
        stored = reading
        onChange?()
    }
}
