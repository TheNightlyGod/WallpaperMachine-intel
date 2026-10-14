import CoreMedia
import XCTest

@testable import WallpaperMachine

/// The rule that tells a pipeline delivering pictures from one that only has a
/// running clock. Pure: no player, no media, no timing.
final class NativeVideoLivenessTests: XCTestCase {
    private typealias Sample = NativeVideoLivenessEvaluator.Sample

    /// Two stand-ins for the loop's two copies of the playing item.
    private let first = NSObject()
    private let second = NSObject()
    private var firstID: ObjectIdentifier { ObjectIdentifier(first) }
    private var secondID: ObjectIdentifier { ObjectIdentifier(second) }

    private func sample(
        _ seconds: Double, item: ObjectIdentifier? = nil, frame: Bool = false, waiting: Bool = false
    ) -> Sample {
        Sample(
            time: CMTime(seconds: seconds, preferredTimescale: 600), item: item ?? firstID,
            producedFrame: frame, waiting: waiting)
    }

    private func evaluate(_ samples: [Sample]) -> NativeVideoLivenessEvaluator {
        var evaluator = NativeVideoLivenessEvaluator()
        samples.forEach { evaluator.record($0) }
        return evaluator
    }

    private func isStalled(_ liveness: NativeVideoLiveness) -> Bool {
        if case .stalled = liveness { return true }
        return false
    }

    private func isWaiting(_ liveness: NativeVideoLiveness) -> Bool {
        if case .waiting = liveness { return true }
        return false
    }

    func testAFrameAndAClockThatMovedAFrameAreAdvancing() {
        let evaluator = evaluate([
            sample(1.00, frame: false),
            sample(1.04, frame: true),
        ])

        XCTAssertEqual(evaluator.verdict, .advancing)
        XCTAssertEqual(evaluator.timedOut(), .advancing)
    }

    func testTheProofCanArriveInDifferentSamples() {
        var evaluator = NativeVideoLivenessEvaluator()
        evaluator.record(sample(1.00, frame: true))
        XCTAssertNil(evaluator.verdict, "a frame alone does not say the clock moves")
        evaluator.record(sample(1.01))
        XCTAssertNil(evaluator.verdict, "a tenth of a frame is not movement")
        evaluator.record(sample(1.20))
        XCTAssertEqual(evaluator.verdict, .advancing)
    }

    func testARunningClockWithoutAFrameIsStalledWhichIsWhatAnHev1PipelineLooksLike() {
        // timeControlStatus is playing and currentTime advances, but the
        // decoder produces nothing. Judging by the clock would call it healthy.
        let evaluator = evaluate((0..<20).map { sample(1.0 + Double($0) * 0.1) })

        XCTAssertNil(evaluator.verdict, "nothing short of a frame settles early")
        XCTAssertTrue(isStalled(evaluator.timedOut()), "\(evaluator.timedOut())")
    }

    func testFramesWithAFrozenClockAreStalled() {
        let evaluator = evaluate([
            sample(4.0, frame: true), sample(4.0, frame: true), sample(4.0, frame: true),
        ])

        XCTAssertNil(evaluator.verdict)
        XCTAssertTrue(isStalled(evaluator.timedOut()), "\(evaluator.timedOut())")
    }

    func testNeitherAFrameNorAClockIsStalled() {
        let evaluator = evaluate((0..<5).map { _ in sample(4.0) })

        XCTAssertTrue(isStalled(evaluator.timedOut()), "\(evaluator.timedOut())")
    }

    func testTheThreeKindsOfStallAreToldApart() {
        let clockOnly = evaluate([sample(1.0), sample(2.0)]).timedOut()
        let framesOnly = evaluate([sample(1.0, frame: true), sample(1.0, frame: true)]).timedOut()
        let neither = evaluate([sample(1.0), sample(1.0)]).timedOut()

        XCTAssertNotEqual(clockOnly, framesOnly, "each says what was seen")
        XCTAssertNotEqual(clockOnly, neither)
        XCTAssertNotEqual(framesOnly, neither)
    }

    func testAnAdvanceSmallerThanAFrameIsNotMovement() {
        let evaluator = evaluate([
            sample(1.0, frame: true), sample(1.0 + 1.0 / 60.0, frame: true),
        ])

        XCTAssertNil(evaluator.verdict)
        XCTAssertTrue(isStalled(evaluator.timedOut()))
    }

    func testAnAdvanceBuildsUpAcrossSamples() {
        // Each step is far below a frame; together they are not.
        let evaluator = evaluate((0..<8).map { sample(1.0 + Double($0) * 0.006, frame: true) })

        XCTAssertEqual(evaluator.verdict, .advancing)
    }

    func testTimeGoingBackwardsIsALoopWrap() {
        let evaluator = evaluate([
            sample(0.90, frame: true),
            sample(0.02, frame: true),
        ])

        XCTAssertEqual(evaluator.verdict, .advancing, "the clip wrapped, so the clock ran")
    }

    func testANewItemIsTheLoopsNextCopy() {
        // The clock reads the same in both copies; only the item changed.
        let evaluator = evaluate([
            sample(0.50, item: firstID, frame: true),
            sample(0.50, item: secondID, frame: true),
        ])

        XCTAssertEqual(evaluator.verdict, .advancing)
    }

    func testANewItemWithoutAFrameIsStillStalled() {
        // The loop moves on even when the decoder is dead, so a changed item
        // is clock evidence and never frame evidence.
        let evaluator = evaluate([
            sample(0.50, item: firstID), sample(0.50, item: secondID),
        ])

        XCTAssertNil(evaluator.verdict)
        XCTAssertTrue(isStalled(evaluator.timedOut()))
    }

    func testTimesThatAreNotFiniteAnchorNothing() {
        var evaluator = NativeVideoLivenessEvaluator()
        for time in [CMTime.invalid, CMTime.indefinite, CMTime.positiveInfinity, CMTime.negativeInfinity] {
            evaluator.record(Sample(time: time, item: firstID, producedFrame: true, waiting: false))
        }
        XCTAssertNil(evaluator.verdict, "frames alone, and no clock yet")

        // The first usable time is where the clock is anchored; it is not
        // movement from the unusable ones before it.
        evaluator.record(sample(500.0))
        XCTAssertNil(evaluator.verdict)
        XCTAssertTrue(isStalled(evaluator.timedOut()))

        evaluator.record(sample(500.2))
        XCTAssertEqual(evaluator.verdict, .advancing)
    }

    func testAPlayerThatWasWaitingForDataThroughoutIsNotJudged() {
        // A slow disk is not a dead decoder, and kicking it interrupts the load.
        let evaluator = evaluate((0..<5).map { _ in sample(4.0, waiting: true) })

        XCTAssertTrue(isWaiting(evaluator.timedOut()), "\(evaluator.timedOut())")
    }

    func testWaitingForPartOfTheWindowIsStillAStallIfNothingMoved() {
        let evaluator = evaluate([
            sample(4.0, waiting: true), sample(4.0, waiting: true), sample(4.0),
        ])

        XCTAssertTrue(isStalled(evaluator.timedOut()), "\(evaluator.timedOut())")
    }

    func testWaitingDoesNotHideProofThatArrivedAnyway() {
        let evaluator = evaluate([
            sample(4.0, waiting: true), sample(4.1, frame: true, waiting: true),
        ])

        XCTAssertEqual(evaluator.timedOut(), .advancing)
    }

    func testAWindowWithNoSamplesIsWaitingNotStalled() {
        // Nothing to look at is not evidence that anything is broken.
        let evaluator = NativeVideoLivenessEvaluator()

        XCTAssertNil(evaluator.verdict)
        XCTAssertTrue(isWaiting(evaluator.timedOut()), "\(evaluator.timedOut())")
    }
}
