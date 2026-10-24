import XCTest

@testable import WallpaperMachine

/// What the monitor reports about memory pressure. The system's events are fed to the
/// handler directly and the footprint, the scene count, the clock and the report are
/// injected: no pressure is provoked and nothing is written to the real log. The reports
/// are checked as facts (the level, the footprint, the scene count, the length of the
/// stretch); one test pins the wording of the two log lines the diagnostics doc shows.
@MainActor
final class MemoryPressureMonitorTests: XCTestCase {
    private typealias Report = MemoryPressureMonitor.Report

    private let gigabyte: UInt64 = 1_073_741_824
    private let defaultFootprint: UInt64 = 3_435_973_837  // 3.2 GB

    @MainActor
    private final class Harness {
        var footprint: UInt64? = 3_435_973_837  // 3.2 GB
        var scenes = 2
        var reports: [Report] = []
        let origin = ContinuousClock.now
        var seconds = 0.0
        var monitor: MemoryPressureMonitor!

        init() {
            monitor = MemoryPressureMonitor(
                footprint: { [unowned self] in self.footprint },
                presentingScenes: { [unowned self] in self.scenes },
                report: { [unowned self] in self.reports.append($0) },
                now: { [unowned self] in self.origin.advanced(by: .seconds(self.seconds)) })
        }

        /// Delivers `event` `seconds` after the harness started.
        func deliver(_ event: DispatchSource.MemoryPressureEvent, at seconds: Double) {
            self.seconds = seconds
            monitor.handle(event)
        }
    }

    func testWarningIsReportedWithFootprintAndSceneCount() {
        let harness = Harness()
        harness.deliver(.warning, at: 0)
        XCTAssertEqual(harness.reports, [.pressure(.warning, footprint: defaultFootprint, scenes: 2)])
        XCTAssertEqual(harness.reports.first?.isWarning, true)
    }

    func testListenerHearsWhenPressureBeginsAndEndsOnce() {
        let harness = Harness()
        var changes: [Bool] = []
        harness.monitor.onPressureChanged = { changes.append($0) }
        harness.deliver(.normal, at: 0)
        harness.deliver(.warning, at: 1)
        harness.deliver(.critical, at: 2)
        harness.deliver(.warning, at: 30)
        XCTAssertTrue(harness.monitor.underPressure)
        harness.deliver(.normal, at: 40)
        harness.deliver(.normal, at: 41)
        XCTAssertEqual(changes, [true, false], "only the start and the end of a stretch")
        XCTAssertFalse(harness.monitor.underPressure)
    }

    func testNormalAfterPressureReportsDuration() {
        let harness = Harness()
        harness.deliver(.warning, at: 10)
        harness.footprint = 2 * gigabyte
        harness.deliver(.normal, at: 52)
        XCTAssertEqual(
            harness.reports,
            [
                .pressure(.warning, footprint: defaultFootprint, scenes: 2),
                .recovered(afterSeconds: 42, footprint: 2 * gigabyte),
            ])
        // The end of pressure is information, not a warning.
        XCTAssertEqual(harness.reports.last?.isWarning, false)
    }

    func testNormalWithoutPressureBeforeItIsSilent() {
        let harness = Harness()
        harness.deliver(.normal, at: 0)
        harness.deliver(.normal, at: 30)
        XCTAssertTrue(harness.reports.isEmpty)
        // And a second normal after a reported one adds nothing.
        harness.deliver(.warning, at: 40)
        harness.deliver(.normal, at: 50)
        harness.deliver(.normal, at: 51)
        XCTAssertEqual(harness.reports.count, 2)
    }

    func testRepeatedIdenticalEventsInsideFiveSecondsAreCollapsed() {
        let harness = Harness()
        harness.deliver(.warning, at: 0)
        harness.deliver(.warning, at: 1)
        harness.deliver(.warning, at: 4.9)
        XCTAssertEqual(harness.reports.count, 1)
        // Measured from the line that was written, so a steady stream still logs.
        harness.deliver(.warning, at: 5)
        XCTAssertEqual(harness.reports.count, 2)
        harness.deliver(.warning, at: 9.9)
        XCTAssertEqual(harness.reports.count, 2)
    }

    func testCollapsedEventsDoNotRestartTheStretchOfPressure() {
        let harness = Harness()
        harness.deliver(.warning, at: 0)
        harness.deliver(.warning, at: 3)
        harness.deliver(.normal, at: 10)
        XCTAssertEqual(harness.reports.count, 2)
        XCTAssertEqual(harness.reports.last, .recovered(afterSeconds: 10, footprint: defaultFootprint))
    }

    func testAChangeOfLevelInsideTheWindowIsStillReported() {
        let harness = Harness()
        harness.deliver(.warning, at: 0)
        harness.deliver(.critical, at: 1)
        XCTAssertEqual(
            harness.reports.map { report -> MemoryPressureMonitor.Level? in
                if case let .pressure(level, _, _) = report { level } else { nil }
            },
            [.warning, .critical])
        XCTAssertEqual(harness.reports.last?.isWarning, true)
        // The stretch began with the warning, not with the escalation.
        harness.deliver(.normal, at: 20)
        XCTAssertEqual(harness.reports.last, .recovered(afterSeconds: 20, footprint: defaultFootprint))
    }

    func testPressureThatReturnsAfterANormalIsReportedAgainAtOnce() {
        let harness = Harness()
        harness.deliver(.warning, at: 0)
        harness.deliver(.normal, at: 1)
        harness.deliver(.warning, at: 2)
        XCTAssertEqual(harness.reports.count, 3)
    }

    func testUnavailableFootprintIsReportedAsUnknownNotZero() {
        let harness = Harness()
        harness.footprint = nil
        harness.deliver(.warning, at: 0)
        harness.deliver(.normal, at: 5)
        XCTAssertEqual(
            harness.reports,
            [
                .pressure(.warning, footprint: nil, scenes: 2),
                .recovered(afterSeconds: 5, footprint: nil),
            ],
            "an unreadable footprint stays nil, never 0")
    }

    func testAnEventCarryingSeveralLevelsReportsTheMostSevere() {
        let harness = Harness()
        harness.deliver([.warning, .critical], at: 0)
        XCTAssertEqual(harness.reports, [.pressure(.critical, footprint: defaultFootprint, scenes: 2)])
    }

    func testAnEmptyEventIsIgnored() {
        let harness = Harness()
        harness.deliver([], at: 0)
        XCTAssertTrue(harness.reports.isEmpty)
    }

    func testStoppingEndsTheStretchOfPressureSoTheNextStartBeginsClean() {
        let harness = Harness()
        harness.deliver(.warning, at: 0)
        harness.monitor.stop()
        // Starting arms a real source; the test never yields, so no real event is
        // delivered to it before `stop()` cancels it.
        harness.monitor.start()
        defer { harness.monitor.stop() }
        harness.deliver(.normal, at: 30)
        XCTAssertEqual(harness.reports.count, 1, "a normal with no pressure before it is silent")
    }

    /// The shape of the two lines in `docs/features/diagnostics.md#memory-pressure`, which a bug
    /// report is read by. The one place the wording is pinned; the tests above assert the facts.
    func testTheLogLinesAreWordedAsTheDocsShowThem() {
        XCTAssertEqual(
            Report.pressure(.warning, footprint: 3_435_973_837, scenes: 2).message,
            "memory pressure warning: process footprint 3.2 GB, 2 scenes presenting")
        XCTAssertEqual(
            Report.pressure(.critical, footprint: nil, scenes: 1).message,
            "memory pressure critical: process footprint unknown, 1 scene presenting",
            "an unreadable footprint says unknown, and one scene is not pluralised")
        XCTAssertEqual(
            Report.recovered(afterSeconds: 42, footprint: 2 * gigabyte).message,
            "memory pressure normal after 42 s: process footprint 2.0 GB")
    }

    func testOnlyScenesThatAreDrawingOrWaitingToDrawArePresenting() {
        func report(_ mode: String) -> BridgeSceneUpdateModeReport {
            BridgeSceneUpdateModeReport(
                displayId: 1, displayName: "Display", wallpaperId: "w", wallpaperTitle: "W",
                mode: mode, reasons: [])
        }
        let modes = [
            "continuous", "waiting_for_event", "waiting_for_deadline",
            "user_paused", "policy_suspended", "stopped_after_failure", "unknown",
        ]
        XCTAssertEqual(MemoryPressureMonitor.presentingSceneCount(modes.map(report)), 3)
        XCTAssertEqual(MemoryPressureMonitor.presentingSceneCount([]), 0)
    }
}
