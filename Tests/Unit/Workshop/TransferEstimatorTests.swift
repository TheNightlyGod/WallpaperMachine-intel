import XCTest

@testable import WallpaperMachine

final class TransferEstimatorTests: XCTestCase {
    private let megabyte: Int64 = 1_000_000

    /// Feeds one sample a second at `rate` bytes a second for `seconds` seconds, starting at `start`.
    private func feed(_ estimator: inout TransferEstimator, rate: Int64, seconds: Int, start: Int = 0, from bytes: Int64 = 0) -> Int64 {
        var total = bytes
        for second in start...(start + seconds) {
            estimator.add(bytes: total, at: TimeInterval(second))
            total += rate
        }
        return total - rate
    }

    func testSteadyTransferGivesTheTimeThatRemainsAtThatPace() {
        var estimator = TransferEstimator()
        let received = feed(&estimator, rate: megabyte, seconds: 10)
        XCTAssertEqual(received, 10 * megabyte)
        XCTAssertEqual(estimator.secondsRemaining(remaining: 50 * megabyte), 50)
        XCTAssertEqual(estimator.secondsRemaining(remaining: 90 * megabyte), 90)
        // A fraction of a second still counts as a whole second to wait.
        XCTAssertEqual(estimator.secondsRemaining(remaining: megabyte / 2), 1)
    }

    func testABurstIsSmoothedRatherThanFollowed() {
        var estimator = TransferEstimator()
        var total = feed(&estimator, rate: megabyte, seconds: 10)
        // One second at ten times the pace, then back to normal.
        total += 10 * megabyte
        estimator.add(bytes: total, at: 11)
        let afterBurst = estimator.secondsRemaining(remaining: 100 * megabyte)
        // Following the burst would promise 10 s; ignoring it would say 100 s.
        XCTAssertNotNil(afterBurst)
        XCTAssertGreaterThan(afterBurst ?? 0, 40)
        XCTAssertLessThan(afterBurst ?? 0, 95)
        total += megabyte
        estimator.add(bytes: total, at: 12)
        let nextSecond = estimator.secondsRemaining(remaining: 100 * megabyte) ?? 0
        XCTAssertLessThan(abs(nextSecond - (afterBurst ?? 0)), 25, "The estimate drifts instead of jumping")
    }

    func testNothingIsEstimatedUntilFourSecondsOfHistory() {
        var estimator = TransferEstimator()
        estimator.add(bytes: 0, at: 0)
        estimator.add(bytes: megabyte, at: 1)
        estimator.add(bytes: 2 * megabyte, at: 2)
        estimator.add(bytes: 3 * megabyte, at: 3.9)
        XCTAssertNil(estimator.secondsRemaining(remaining: 50 * megabyte))
        estimator.add(bytes: 4 * megabyte, at: 4)
        XCTAssertNotNil(estimator.secondsRemaining(remaining: 50 * megabyte))
    }

    func testACrawlOrAFinishedTransferHasNoEstimate() {
        var estimator = TransferEstimator()
        _ = feed(&estimator, rate: 500, seconds: 10)
        XCTAssertNil(estimator.secondsRemaining(remaining: 50 * megabyte), "Under 1 KB/s is a stall, not a pace")

        var steady = TransferEstimator()
        _ = feed(&steady, rate: megabyte, seconds: 10)
        XCTAssertNotNil(steady.secondsRemaining(remaining: 1))
        XCTAssertNil(steady.secondsRemaining(remaining: 0))
        XCTAssertNil(steady.secondsRemaining(remaining: -5))
    }

    func testAStalledTransferLosesItsEstimateOnceTheWindowHasNothingNew() {
        var estimator = TransferEstimator()
        let received = feed(&estimator, rate: megabyte, seconds: 10)
        XCTAssertNotNil(estimator.secondsRemaining(remaining: 50 * megabyte))
        // Bytes stop arriving while the samples keep coming: the pace decays below the floor.
        for second in 11...120 { estimator.add(bytes: received, at: TimeInterval(second)) }
        XCTAssertNil(estimator.secondsRemaining(remaining: 50 * megabyte))
    }

    func testEstimateIsCappedAtNinetyNineHours() {
        var estimator = TransferEstimator()
        _ = feed(&estimator, rate: 10_000, seconds: 10)
        XCTAssertEqual(estimator.secondsRemaining(remaining: Int64.max / 2), 99 * 3_600)
    }

    func testResetForgetsHistory() {
        var estimator = TransferEstimator()
        _ = feed(&estimator, rate: megabyte, seconds: 10)
        XCTAssertNotNil(estimator.secondsRemaining(remaining: 50 * megabyte))
        estimator.reset()
        XCTAssertNil(estimator.secondsRemaining(remaining: 50 * megabyte))
        // A fresh run needs its own four seconds before it says anything.
        estimator.add(bytes: 0, at: 100)
        estimator.add(bytes: megabyte, at: 101)
        XCTAssertNil(estimator.secondsRemaining(remaining: 50 * megabyte))
    }

    func testACounterThatStartsOverDoesNotInheritThePaceBeforeIt() {
        var estimator = TransferEstimator()
        let received = feed(&estimator, rate: 10 * megabyte, seconds: 10)
        XCTAssertEqual(estimator.secondsRemaining(remaining: 100 * megabyte), 10)
        // A relaunched process counts from zero; the old, faster pace must not carry over.
        estimator.add(bytes: received / 100, at: 11)
        XCTAssertNil(estimator.secondsRemaining(remaining: 100 * megabyte))
        var total = received / 100
        for second in 12...20 {
            total += megabyte
            estimator.add(bytes: total, at: TimeInterval(second))
        }
        XCTAssertEqual(estimator.secondsRemaining(remaining: 100 * megabyte), 100)
    }

    func testOnlyTheLastTwentySecondsShapeThePace() {
        var estimator = TransferEstimator()
        // A quick start, then a long steady crawl at 100 KB/s.
        var total = feed(&estimator, rate: 50 * megabyte, seconds: 5)
        for second in 6...120 {
            total += 100_000
            estimator.add(bytes: total, at: TimeInterval(second))
        }
        let seconds = estimator.secondsRemaining(remaining: 10 * megabyte)
        XCTAssertEqual(Double(seconds ?? 0), 100, accuracy: 5)
    }

    func testASampleThatDoesNotAdvanceTheClockIsIgnored() {
        var estimator = TransferEstimator()
        _ = feed(&estimator, rate: megabyte, seconds: 10)
        let before = estimator.secondsRemaining(remaining: 50 * megabyte)
        estimator.add(bytes: 500 * megabyte, at: 10)
        XCTAssertEqual(estimator.secondsRemaining(remaining: 50 * megabyte), before)
    }
}
