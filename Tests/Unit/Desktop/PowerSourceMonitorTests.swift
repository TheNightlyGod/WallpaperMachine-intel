import XCTest

@testable import WallpaperMachine

@MainActor
final class PowerSourceMonitorTests: XCTestCase {
    private var reading = PowerSourceMonitor.Source.mains

    override func setUp() {
        super.setUp()
        reading = .mains
    }

    private func makeMonitor() -> PowerSourceMonitor {
        PowerSourceMonitor(read: { self.reading })
    }

    func testOnlyAChangeOfSourceIsReported() {
        let monitor = makeMonitor()
        var reported: [PowerSourceMonitor.Source] = []
        monitor.onChange = { reported.append($0) }

        // The system notification also fires as the charge level moves.
        monitor.handleChange()
        XCTAssertEqual(reported, [])

        reading = .battery
        monitor.handleChange()
        monitor.handleChange()
        XCTAssertEqual(reported, [.battery])
        XCTAssertEqual(monitor.source, .battery)

        reading = .mains
        monitor.handleChange()
        XCTAssertEqual(reported, [.battery, .mains])
    }

    func testTheSourceIsReadWhenTheMonitorIsBuilt() {
        reading = .battery
        let monitor = makeMonitor()
        var reported: [PowerSourceMonitor.Source] = []
        monitor.onChange = { reported.append($0) }

        monitor.handleChange()
        XCTAssertEqual(monitor.source, .battery)
        XCTAssertEqual(reported, [], "starting on battery is not a change")
    }

    /// The change that happened between building the monitor and starting it is
    /// not lost, and the system source can be started and stopped repeatedly.
    func testStartingReportsAChangeMadeSinceTheMonitorWasBuilt() {
        let monitor = makeMonitor()
        var reported: [PowerSourceMonitor.Source] = []
        monitor.onChange = { reported.append($0) }

        reading = .battery
        monitor.start()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(reported, [.battery])

        monitor.stop()
        monitor.stop()
        monitor.start()
        XCTAssertEqual(reported, [.battery])
    }

    /// The machine running the tests may be on either power, or a virtual one with
    /// none, so only that two reads agree and that a monitor built on the system
    /// reading reports nothing for a source that has not moved.
    func testTheSystemReadingIsStableAndReportsNoChangeOfItsOwn() {
        let first = PowerSourceMonitor.systemSource()
        XCTAssertEqual(PowerSourceMonitor.systemSource(), first)
        let monitor = PowerSourceMonitor()
        var reported = 0
        monitor.onChange = { _ in reported += 1 }
        monitor.handleChange()
        XCTAssertEqual(reported, 0)
        XCTAssertEqual(monitor.source, first)
    }

    // MARK: - refresh until the snapshot agrees

    /// A script of the answers the renderer gives to successive refreshes.
    private final class Script {
        var onBattery: [Bool]
        var refreshes = 0
        var waits: [Duration] = []
        init(_ onBattery: [Bool]) { self.onBattery = onBattery }
        var current: Bool { onBattery[min(max(refreshes - 1, 0), onBattery.count - 1)] }
    }

    private func run(
        _ script: Script, expectedOnBattery: Bool, delays: [Duration] = PowerSourceRefresh.retryDelays,
        failing: Set<Int> = []
    ) async -> Bool {
        await PowerSourceRefresh.run(
            expectedOnBattery: expectedOnBattery,
            refresh: {
                script.refreshes += 1
                if failing.contains(script.refreshes) { throw CancellationError() }
            },
            bridgeOnBattery: { script.current },
            delays: delays,
            wait: { script.waits.append($0) })
    }

    func testASnapshotThatAlreadyAgreesEndsTheRefreshAtOnce() async {
        let script = Script([true])
        let agreed = await run(script, expectedOnBattery: true)
        XCTAssertTrue(agreed)
        XCTAssertEqual(script.refreshes, 1)
        XCTAssertEqual(script.waits, [], "no pause before the first refresh")
    }

    /// The renderer hears of the change on its own thread; a snapshot taken before
    /// it has applied the policy still describes the old source.
    func testASnapshotFromBeforeTheRendererHeardIsRefreshedAgain() async {
        let script = Script([false, false, true])
        let agreed = await run(script, expectedOnBattery: true)
        XCTAssertTrue(agreed)
        XCTAssertEqual(script.refreshes, 3)
        XCTAssertEqual(script.waits, Array(PowerSourceRefresh.retryDelays.prefix(2)))
    }

    func testARendererThatNeverAgreesEndsAfterTheLastDelay() async {
        let script = Script([false])
        let agreed = await run(script, expectedOnBattery: true)
        XCTAssertFalse(agreed)
        XCTAssertEqual(script.refreshes, 1 + PowerSourceRefresh.retryDelays.count)
        XCTAssertEqual(script.waits, PowerSourceRefresh.retryDelays)
    }

    func testAFailedRefreshIsRetriedLikeADisagreeingOne() async {
        let script = Script([true])
        let agreed = await run(script, expectedOnBattery: true, failing: [1])
        XCTAssertTrue(agreed)
        XCTAssertEqual(script.refreshes, 2)
    }

    func testPluggingInIsFollowedTheSameWay() async {
        let script = Script([true, false])
        let agreed = await run(script, expectedOnBattery: false)
        XCTAssertTrue(agreed)
        XCTAssertEqual(script.refreshes, 2)
    }

    func testCancellationEndsTheRefresh() async {
        let script = Script([false])
        let agreed = await PowerSourceRefresh.run(
            expectedOnBattery: true,
            refresh: { script.refreshes += 1 },
            bridgeOnBattery: { script.current },
            wait: { _ in throw CancellationError() })
        XCTAssertFalse(agreed)
        XCTAssertEqual(script.refreshes, 1, "the wait that was cancelled is the last thing that happens")
    }
}
