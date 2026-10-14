import XCTest
@testable import WallpaperMachine

/// The charge-level decision and the parse of IOKit's description, both pure. The live read is
/// never asserted: it depends on the Mac that runs the tests.
final class LowBatteryTests: XCTestCase {
    private func discharging(_ percent: Int) -> BatteryReading {
        BatteryReading(percent: percent, isDischarging: true)
    }

    private func pluggedIn(_ percent: Int) -> BatteryReading {
        BatteryReading(percent: percent, isDischarging: false)
    }

    func testGateEngagesAtTheThresholdAndReleasesFiveAbove() {
        var gate = LowBatteryGate()
        XCTAssertFalse(gate.update(discharging(30), threshold: 20))
        XCTAssertTrue(gate.update(discharging(20), threshold: 20), "At the level counts as low")
        XCTAssertTrue(gate.update(discharging(24), threshold: 20), "Four points above is still inside the margin")
        XCTAssertFalse(gate.update(discharging(25), threshold: 20), "Five points above releases")
        XCTAssertFalse(gate.update(discharging(21), threshold: 20), "A charge back above the level is not low again")
        XCTAssertTrue(gate.update(discharging(20), threshold: 20))
    }

    func testChargingOrACReleasesAtAnyPercent() {
        var gate = LowBatteryGate()
        XCTAssertTrue(gate.update(discharging(5), threshold: 20))
        XCTAssertFalse(gate.update(pluggedIn(5), threshold: 20), "Plugging in ends it however empty the battery is")
        XCTAssertFalse(gate.update(pluggedIn(3), threshold: 20), "A Mac on AC is never low")
        XCTAssertTrue(gate.update(discharging(3), threshold: 20), "Unplugging below the level engages again")
    }

    func testNoBatteryNeverEngages() {
        var gate = LowBatteryGate()
        XCTAssertFalse(gate.update(nil, threshold: 30))
        XCTAssertTrue(gate.update(discharging(1), threshold: 30))
        XCTAssertFalse(gate.update(nil, threshold: 30), "A reading that fails reads as not low")
    }

    func testChangingTheThresholdWhileTheChargeStaysPutMovesTheDecision() {
        var gate = LowBatteryGate()
        XCTAssertFalse(gate.update(discharging(28), threshold: 20))
        XCTAssertTrue(gate.update(discharging(28), threshold: 30), "Raising the level above the charge engages")
        XCTAssertTrue(gate.update(discharging(28), threshold: 30))
        XCTAssertFalse(gate.update(discharging(28), threshold: 20), "Lowering it more than the margin below the charge releases")
        XCTAssertTrue(gate.update(discharging(15), threshold: 20))
        XCTAssertTrue(gate.update(discharging(15), threshold: 11), "Lowering it to within the margin keeps it engaged")
        XCTAssertFalse(gate.update(discharging(15), threshold: 10))
    }

    func testResetForgetsAnEngagedGate() {
        var gate = LowBatteryGate()
        XCTAssertTrue(gate.update(discharging(10), threshold: 20))
        gate.reset()
        XCTAssertFalse(gate.isEngaged)
        XCTAssertFalse(gate.update(discharging(22), threshold: 20), "Left engaged, 22% would still sit inside the margin; after a reset it is simply above the level")
    }

    func testReadingParsesOnlyTheInternalBattery() {
        let onBattery: [String: Any] = [
            "Name": "InternalBattery-0", "Type": "InternalBattery", "Is Charging": false,
            "Power Source State": "Battery Power", "Current Capacity": 17, "Max Capacity": 100,
        ]
        XCTAssertEqual(BatteryReading(description: onBattery), BatteryReading(percent: 17, isDischarging: true))

        var onAC = onBattery
        onAC["Power Source State"] = "AC Power"
        onAC["Is Charging"] = true
        XCTAssertEqual(BatteryReading(description: onAC), BatteryReading(percent: 17, isDischarging: false))

        var inMilliampHours = onBattery
        inMilliampHours["Current Capacity"] = 1_250
        inMilliampHours["Max Capacity"] = 5_000
        XCTAssertEqual(BatteryReading(description: inMilliampHours)?.percent, 25, "A capacity that is not a percentage is scaled")

        var overfull = onBattery
        overfull["Current Capacity"] = 120
        XCTAssertEqual(BatteryReading(description: overfull)?.percent, 100)

        var ups = onBattery
        ups["Type"] = "UPS"
        XCTAssertNil(BatteryReading(description: ups), "A UPS is not the Mac's battery")

        var unusable = onBattery
        unusable["Max Capacity"] = 0
        XCTAssertNil(BatteryReading(description: unusable), "A zero maximum cannot be turned into a percentage")
        unusable.removeValue(forKey: "Max Capacity")
        XCTAssertNil(BatteryReading(description: unusable))
        unusable["Max Capacity"] = 100
        unusable.removeValue(forKey: "Current Capacity")
        XCTAssertNil(BatteryReading(description: unusable))
        XCTAssertNil(BatteryReading(description: [:]))
    }

    @MainActor
    func testTheRealSourceReleasesItselfWhenStopped() {
        weak var observed: SystemBatteryLevel?
        autoreleasepool {
            let level = SystemBatteryLevel()
            observed = level
            level.start {}
            level.start {}
            level.stop()
        }
        XCTAssertNil(observed, "Starting twice and stopping once must leave nothing retaining the source")
    }
}
