import XCTest

@testable import WallpaperMachine

/// The order in which a stalled pipeline is repaired, and when the repairs run
/// out. Pure: verdicts go in, steps come out.
final class NativeVideoHealthLadderTests: XCTestCase {
    /// What a look saw, as the liveness check phrased it. The give-up carries it on, so the
    /// tests below look for these exact strings and for nothing the ladder itself words.
    private static let stalledText = "the clock advances but no frame is produced"
    private static let waitingText = "the player was waiting for data throughout"
    private let stalled = NativeVideoLiveness.stalled(NativeVideoHealthLadderTests.stalledText)
    private let waiting = NativeVideoLiveness.waiting(NativeVideoHealthLadderTests.waitingText)

    private func isGiveUp(_ action: NativeVideoHealthLadder.Action) -> String? {
        if case let .giveUp(detail) = action { return detail }
        return nil
    }

    func testAPipelineThatDeliversNeedsNothing() {
        var ladder = NativeVideoHealthLadder()

        XCTAssertEqual(ladder.next(.advancing, canRebuild: true), .done)
        XCTAssertFalse(ladder.hasRepaired)
    }

    func testAStallIsKickedFirstAndAKickThatWorksEndsIt() {
        var ladder = NativeVideoHealthLadder()

        XCTAssertEqual(ladder.next(stalled, canRebuild: true), .kick)
        XCTAssertTrue(ladder.hasRepaired)
        XCTAssertEqual(ladder.next(.advancing, canRebuild: true), .done)
    }

    func testAStallThatSurvivesTheKickIsRebuilt() {
        var ladder = NativeVideoHealthLadder()

        XCTAssertEqual(ladder.next(stalled, canRebuild: true), .kick)
        XCTAssertEqual(ladder.next(stalled, canRebuild: true), .rebuild)
        XCTAssertEqual(ladder.next(.advancing, canRebuild: true), .done, "a rebuild that works ends it")
    }

    func testAStallThatSurvivesTheRebuildIsGivenUpWithWhatWasSeenAndTried() throws {
        var ladder = NativeVideoHealthLadder()
        _ = ladder.next(stalled, canRebuild: true)
        _ = ladder.next(stalled, canRebuild: true)

        let detail = try XCTUnwrap(isGiveUp(ladder.next(stalled, canRebuild: true)))

        XCTAssertTrue(detail.contains(Self.stalledText), "what the last look saw is carried on")
        XCTAssertTrue(ladder.kicked && ladder.rebuilt, "and both repairs had been tried")
    }

    func testNothingMoreIsTriedAfterTheGiveUp() {
        var ladder = NativeVideoHealthLadder()
        _ = ladder.next(stalled, canRebuild: true)
        _ = ladder.next(stalled, canRebuild: true)
        _ = ladder.next(stalled, canRebuild: true)

        XCTAssertNotNil(isGiveUp(ladder.next(stalled, canRebuild: true)), "never a second rebuild")
    }

    func testARebuildThatTheBudgetRefusesIsGivenUpAtOnceAfterTheKick() throws {
        // The kick is free, so it is still tried; the rebuild is the step the
        // allowance guards, and a pipeline that is out of allowance is not
        // looked at once more for nothing.
        var ladder = NativeVideoHealthLadder()

        XCTAssertEqual(ladder.next(stalled, canRebuild: false), .kick)
        let detail = try XCTUnwrap(isGiveUp(ladder.next(stalled, canRebuild: false)))

        XCTAssertTrue(detail.contains(Self.stalledText), "what the last look saw is carried on")
        XCTAssertTrue(ladder.kicked)
        XCTAssertFalse(ladder.rebuilt, "the rebuild the allowance refuses is never issued")
    }

    func testAPipelineThatIsOnlyWaitingIsLookedAtAgainBeforeItIsJudged() {
        var ladder = NativeVideoHealthLadder()

        XCTAssertEqual(ladder.next(waiting, canRebuild: true), .recheck)
        XCTAssertEqual(ladder.next(waiting, canRebuild: true), .recheck)
        XCTAssertFalse(ladder.hasRepaired, "a slow source is not nudged")
        XCTAssertEqual(ladder.next(.advancing, canRebuild: true), .done, "and it may come right by itself")
    }

    func testWaitingTwiceThenStalledEscalates() {
        var ladder = NativeVideoHealthLadder()

        XCTAssertEqual(ladder.next(waiting, canRebuild: true), .recheck)
        XCTAssertEqual(ladder.next(waiting, canRebuild: true), .recheck)
        XCTAssertEqual(ladder.next(stalled, canRebuild: true), .kick)
    }

    func testAPlayerThatKeepsWaitingIsEventuallyTreatedAsStuck() {
        var ladder = NativeVideoHealthLadder()
        _ = ladder.next(waiting, canRebuild: true)
        _ = ladder.next(waiting, canRebuild: true)

        XCTAssertEqual(ladder.next(waiting, canRebuild: true), .kick)
    }

    func testTheWaitingAllowanceIsNotRenewedByARepair() throws {
        // Two looks that only waited were all the slow source got; after a
        // repair a player that still only waits has had its patience.
        var ladder = NativeVideoHealthLadder()
        _ = ladder.next(waiting, canRebuild: true)
        _ = ladder.next(waiting, canRebuild: true)
        XCTAssertEqual(ladder.next(stalled, canRebuild: true), .kick)

        XCTAssertEqual(ladder.next(waiting, canRebuild: true), .rebuild)
        let detail = try XCTUnwrap(isGiveUp(ladder.next(waiting, canRebuild: true)))
        XCTAssertTrue(detail.contains(Self.waitingText), "a player that only waited is reported as that")
    }

    func testAWaitingPlayerAfterAKickIsGivenTheLooksAStallWouldNotGet() {
        // A stall that was kicked and then only waits (the load restarting)
        // is looked at again, as a slow source would be.
        var ladder = NativeVideoHealthLadder()
        XCTAssertEqual(ladder.next(stalled, canRebuild: true), .kick)

        XCTAssertEqual(ladder.next(waiting, canRebuild: true), .recheck)
        XCTAssertEqual(ladder.next(waiting, canRebuild: true), .recheck)
        XCTAssertEqual(ladder.next(waiting, canRebuild: true), .rebuild)
    }
}
