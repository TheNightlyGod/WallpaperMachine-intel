import XCTest

@testable import WallpaperMachine

/// A scripted clock stands in for real time, so every duration is exact and no test sleeps.
@MainActor
final class QuitTimingsTests: XCTestCase {
    private final class ScriptedClock {
        private let base = ContinuousClock.now
        private var elapsed = Duration.zero
        var instant: ContinuousClock.Instant { base.advanced(by: elapsed) }
        func pass(_ amount: Duration) { elapsed += amount }
    }

    private let clock = ScriptedClock()
    private var lines: [String] = []

    private func makeTimings() -> QuitTimings {
        QuitTimings(now: { [clock] in clock.instant }, log: { [unowned self] in self.lines.append($0) })
    }

    /// A stage that takes `amount`, recorded the way the supervisor records it.
    private func stage(_ name: String, _ amount: Duration, in timings: QuitTimings, failed: Bool = false) {
        let start = clock.instant
        clock.pass(amount)
        timings.record(name, since: start, failed: failed)
    }

    func testEachStageKeepsItsOwnDurationInTheOrderItWasSettled() {
        let timings = makeTimings()

        stage("restore", .milliseconds(1_250), in: timings)
        stage("bridge", .milliseconds(40), in: timings)

        XCTAssertEqual(timings.stages, [
            .init(name: "restore", duration: .milliseconds(1_250), failed: false),
            .init(name: "bridge", duration: .milliseconds(40), failed: false),
        ])
    }

    func testAStageThatFailedIsStillTimedAndSaysWhyInTheLog() {
        let timings = makeTimings()
        let start = clock.instant
        clock.pass(.milliseconds(5_003))

        timings.record("restore", since: start, failed: true, detail: "still restoring")

        XCTAssertEqual(timings.stages, [.init(name: "restore", duration: .milliseconds(5_003), failed: true)])
        XCTAssertTrue(lines[0].contains("5003 ms") && lines[0].contains("failed") && lines[0].contains("still restoring"),
                      "the line names the duration and the reason: \(lines[0])")
    }

    func testAStageThatWasLeftBehindIsMarkedAndKeepsHowLongItWasWaitedFor() {
        let timings = makeTimings()
        let start = clock.instant
        clock.pass(.milliseconds(10_000))

        timings.recordStalled("steamcmd", since: start)
        timings.finish("finished without steamcmd")

        XCTAssertEqual(timings.stages, [.init(name: "steamcmd", duration: .milliseconds(10_000), failed: false, stalled: true)])
        XCTAssertTrue(lines.last?.contains("steamcmd 10000 ms (stalled)") == true, "the summary marks it: \(lines.last ?? "")")
    }

    func testTheWholeQuitIsTimedFromTheStartNotAsTheSumOfItsStages() {
        let timings = makeTimings()
        clock.pass(.milliseconds(10))
        stage("imports", .milliseconds(30), in: timings)
        clock.pass(.milliseconds(5))
        stage("bridge", .milliseconds(20), in: timings)

        timings.finish("finished")

        let summary = lines.last ?? ""
        XCTAssertTrue(summary.contains("65 ms"), "10 + 30 + 5 + 20: \(summary)")
        XCTAssertTrue(summary.contains("imports") && summary.contains("bridge"),
                      "the summary names every stage that ran")
    }

    func testEveryStageAndTheSummaryAreLoggedOnce() {
        let timings = makeTimings()
        stage("a", .zero, in: timings)
        stage("b", .zero, in: timings)
        timings.finish("finished")

        XCTAssertEqual(lines.count, 3)
    }

    func testAQuitWithNoStagesStillSummarises() {
        let timings = makeTimings()
        clock.pass(.milliseconds(7))

        timings.finish("cancelled")

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("7 ms"))
    }

    func testDurationsAreWholeMilliseconds() {
        XCTAssertEqual(Duration.zero.wholeMilliseconds, 0)
        XCTAssertEqual(Duration.milliseconds(1_999).wholeMilliseconds, 1_999)
        XCTAssertEqual(Duration.seconds(3).wholeMilliseconds, 3_000)
        XCTAssertEqual(Duration.microseconds(1_900).wholeMilliseconds, 1, "a fraction of a millisecond is dropped")
    }

    func testDurationsConvertToSecondsForThreadSleep() {
        XCTAssertEqual(Duration.milliseconds(1_500).timeInterval, 1.5, accuracy: 1e-9)
        XCTAssertEqual(Duration.zero.timeInterval, 0)
    }
}
