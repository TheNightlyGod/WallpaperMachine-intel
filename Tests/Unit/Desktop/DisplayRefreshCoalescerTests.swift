import CoreGraphics
import XCTest
@testable import WallpaperMachine

@MainActor
final class DisplayRefreshCoalescerTests: XCTestCase {
    /// A display waking can post dozens of screen changes in a second. Each
    /// refresh used to queue behind the last in the bridge, and the resume
    /// after an unlock waited behind all of them.
    func testABurstDuringARefreshIsAnsweredByOneMoreRefresh() async throws {
        var displays = Self.configuration(width: 1728)
        var runs = 0
        var held: [CheckedContinuation<Void, Never>] = []
        let coalescer = DisplayRefreshCoalescer(configuration: { displays }) {
            runs += 1
            await withCheckedContinuation { held.append($0) }
            return true
        }

        coalescer.request()
        try await waitUntil { held.count == 1 }
        displays = Self.configuration(width: 1512)
        for _ in 0..<50 { coalescer.request() }
        XCTAssertEqual(runs, 1, "a change during a refresh must not start another one alongside it")

        held.removeFirst().resume()
        try await waitUntil { held.count == 1 }
        XCTAssertEqual(runs, 2, "the burst is answered by exactly one more refresh")

        held.removeFirst().resume()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runs, 2, "nothing arrived during the second refresh, so there is no third")
    }

    func testAChangeAfterTheLastRefreshFinishedRefreshesAgain() async throws {
        var displays = Self.configuration(width: 1728)
        var runs = 0
        let coalescer = DisplayRefreshCoalescer(configuration: { displays }) {
            runs += 1
            return true
        }

        coalescer.request()
        try await waitUntil { runs == 1 }
        displays = Self.configuration(width: 1728, refreshRate: 60)
        coalescer.request()
        try await waitUntil { runs == 2 }
    }

    /// An XDR display posts a screen change for every frame of an EDR headroom
    /// ramp, about 240 in two seconds, with every display exactly as it was.
    /// Refreshing for each held the app and the control panel near a full core
    /// for the whole ramp.
    func testScreenChangesThatLeaveTheDisplaysAsTheyWereDoNotRefresh() async throws {
        let displays = Self.configuration(width: 1728)
        var runs = 0
        let coalescer = DisplayRefreshCoalescer(configuration: { displays }) {
            runs += 1
            return true
        }

        coalescer.request()
        try await waitUntil { runs == 1 }
        for _ in 0..<240 {
            coalescer.request()
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runs, 1)
    }

    func testAnUnchangedBurstDuringARefreshEndsWithIt() async throws {
        var runs = 0
        var held: [CheckedContinuation<Void, Never>] = []
        let coalescer = DisplayRefreshCoalescer(configuration: { Self.configuration(width: 1728) }) {
            runs += 1
            await withCheckedContinuation { held.append($0) }
            return true
        }

        coalescer.request()
        try await waitUntil { held.count == 1 }
        for _ in 0..<50 { coalescer.request() }
        held.removeFirst().resume()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runs, 1, "the displays the burst left are the ones the running refresh read")
    }

    func testAFailedRefreshIsRetriedOnTheNextChangeWithTheSameDisplays() async throws {
        var runs = 0
        var succeeds = false
        let coalescer = DisplayRefreshCoalescer(configuration: { Self.configuration(width: 1728) }) {
            runs += 1
            return succeeds
        }

        coalescer.request()
        try await waitUntil { runs == 1 }
        succeeds = true
        coalescer.request()
        try await waitUntil { runs == 2 }
        coalescer.request()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runs, 2, "once one succeeds, the same displays are left alone")
    }

    /// The filter is only as good as the reading: anything in it that moves
    /// without the displays changing, as EDR headroom does, brings every
    /// refresh back.
    func testTwoReadingsOfTheSameDisplaysAreEqual() {
        XCTAssertEqual(DisplayConfiguration.current(), DisplayConfiguration.current())
    }

    // MARK: A display that vanishes

    /// A link renegotiating or a monitor waking drops a display from the screen
    /// list for a moment. The bridge closes the wallpaper of a display that is
    /// not listed, so refreshing at once turned that blip into a full scene
    /// load or decoder rebuild when the display came back.
    func testADisplayThatComesBackBeforeTheSettleCausesNoRefresh() async throws {
        let coalescer = await refreshedWithBothDisplays()

        displays = Self.configuration(ids: [1])
        coalescer.request()
        try await waitForTheSettle()
        XCTAssertEqual(sleeper.requested, [.milliseconds(800)])
        XCTAssertEqual(refreshes.count, 1, "a display that is gone is given time to come back first")

        displays = Self.configuration(ids: [1, 2])
        coalescer.request()
        XCTAssertEqual(sleeper.cancelledCount, 1, "the display is as the last refresh read it, so the wait is over")
        XCTAssertEqual(sleeper.pendingCount, 0)
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.count, 1, "no bridge work for a display that was never really gone")
        XCTAssertEqual(returns, 1, "but whoever closed its window for the gap is told it is back")

        coalescer.request()
        XCTAssertEqual(sleeper.requested.count, 1, "an unchanged reading starts no wait")
        XCTAssertEqual(returns, 1, "and a display that never left is not announced")
    }

    /// The settle can end in the same turn the display comes back. The refresh it starts then
    /// finds the displays as the last one read them, which is a return like any other.
    func testADisplayThatComesBackAsTheSettleEndsIsAnnouncedToo() async throws {
        let coalescer = await refreshedWithBothDisplays()
        displays = Self.configuration(ids: [1])
        coalescer.request()
        try await waitForTheSettle()

        XCTAssertTrue(sleeper.fireNext())
        displays = Self.configuration(ids: [1, 2])
        try await waitUntil { returns == 1 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.count, 1, "the display is back, so the refresh the wait led to has nothing to read")
        XCTAssertEqual(returns, 1)
    }

    func testADisplayThatStaysAwayRefreshesOnceWhenTheSettleEnds() async throws {
        let coalescer = await refreshedWithBothDisplays()

        displays = Self.configuration(ids: [1])
        coalescer.request()
        try await waitForTheSettle()
        for _ in 0..<20 { coalescer.request() }
        XCTAssertEqual(refreshes.count, 1)
        XCTAssertEqual(sleeper.requested.count, 1, "later readings of the same absence do not start another wait")

        XCTAssertTrue(sleeper.fireNext())
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes, [[1, 2], [1]], "the refresh reads the displays as they are when the wait ends")

        coalescer.request()
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.count, 2, "the displays that are left are now the ones the bridge knows")
        XCTAssertEqual(sleeper.requested.count, 1)
        XCTAssertEqual(returns, 0, "a display that stayed away has not returned")
    }

    /// When the main display leaves, or any display that stays is moved,
    /// rescaled or re-rated, the renderer's picture of the displays that remain
    /// is stale, and waiting would leave their wallpapers where the screens no
    /// longer are.
    func testAChangeToADisplayThatRemainsRefreshesAtOnce() async throws {
        let coalescer = await refreshedWithBothDisplays()
        displays = Self.configuration(ids: [1])
        coalescer.request()
        try await waitForTheSettle()

        displays = Self.configuration(ids: [1], width: 1512)
        coalescer.request()
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(sleeper.cancelledCount, 1, "the refresh that went ahead ends the wait")
        XCTAssertFalse(sleeper.fireNext())
        XCTAssertEqual(refreshes, [[1, 2], [1]])
    }

    func testADisplayThatLeavesWhileAnotherMovesDoesNotWait() async throws {
        let coalescer = await refreshedWithBothDisplays()

        displays = Self.configuration(ids: [1], width: 1512)
        coalescer.request()
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertTrue(sleeper.requested.isEmpty)
    }

    func testAnArrivalDuringTheSettleRefreshesAtOnce() async throws {
        let coalescer = await refreshedWithBothDisplays()
        displays = Self.configuration(ids: [1])
        coalescer.request()
        try await waitForTheSettle()

        displays = Self.configuration(ids: [1, 3])
        coalescer.request()
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes, [[1, 2], [1, 3]], "one display swapped for another is not a display that is merely missing")
        XCTAssertEqual(sleeper.cancelledCount, 1)
        XCTAssertFalse(sleeper.fireNext())
        XCTAssertEqual(returns, 0, "the refresh that went ahead already reopens everything")
    }

    func testTheFirstReadingNeverWaits() async throws {
        displays = Self.configuration(ids: [1])
        let coalescer = makeCoalescer()
        coalescer.request()
        try await waitUntil { refreshes.count == 1 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertTrue(sleeper.requested.isEmpty)
    }

    func testAFailedRefreshIsStillRetriedAtOnceWhenADisplayIsMissing() async throws {
        refreshSucceeds = false
        let coalescer = makeCoalescer()
        coalescer.request()
        try await waitUntil { refreshes.count == 1 }
        await coalescer.waitUntilIdleForTest()

        displays = Self.configuration(ids: [1])
        refreshSucceeds = true
        coalescer.request()
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes, [[1, 2], [1]], "with nothing known to be wrong with it, the retry does not wait")
        XCTAssertTrue(sleeper.requested.isEmpty)
    }

    /// A display that keeps coming and going holds at most one wait at a time,
    /// and the wait it finally leaves running is not stretched by the readings
    /// that arrive while it runs.
    func testAFlappingDisplayHoldsOneWaitAndTheSettleIsNeverExtended() async throws {
        let coalescer = await refreshedWithBothDisplays()

        for _ in 0..<3 {
            displays = Self.configuration(ids: [1])
            coalescer.request()
            try await waitForTheSettle()
            XCTAssertEqual(sleeper.pendingCount, 1)
            displays = Self.configuration(ids: [1, 2])
            coalescer.request()
            XCTAssertEqual(sleeper.pendingCount, 0)
        }
        XCTAssertEqual(sleeper.cancelledCount, 3)
        XCTAssertEqual(refreshes.count, 1, "every return from the dead is a reading the bridge already knows")
        XCTAssertEqual(returns, 3, "and each one is announced, since a snapshot in between may have closed the window")

        displays = Self.configuration(ids: [1])
        coalescer.request()
        try await waitForTheSettle()
        displays = Self.configuration(ids: [])
        coalescer.request()
        displays = Self.configuration(ids: [1])
        coalescer.request()
        XCTAssertEqual(sleeper.requested.count, 4, "three waits that were answered and one that was not")
        XCTAssertEqual(sleeper.pendingCount, 1)

        XCTAssertTrue(sleeper.fireNext())
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.last, [1])
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertEqual(returns, 3, "the absence that outlasted the wait is not a return")
    }

    func testEveryDisplayMissingWaitsToo() async throws {
        let coalescer = await refreshedWithBothDisplays()

        displays = Self.configuration(ids: [])
        coalescer.request()
        try await waitForTheSettle()
        displays = Self.configuration(ids: [1, 2])
        coalescer.request()
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.count, 1, "displays asleep for a moment are not displays gone")

        displays = Self.configuration(ids: [])
        coalescer.request()
        try await waitForTheSettle()
        XCTAssertTrue(sleeper.fireNext())
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.last, [])
    }

    /// A screen with no display ID cannot be matched to anything the bridge
    /// holds, so it going missing is an ordinary change.
    func testAScreenWithoutADisplayIDLeavingDoesNotWait() async throws {
        displays = Self.configuration(ids: [1, 0])
        let coalescer = makeCoalescer()
        coalescer.request()
        try await waitUntil { refreshes.count == 1 }
        await coalescer.waitUntilIdleForTest()

        displays = Self.configuration(ids: [1])
        coalescer.request()
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertTrue(sleeper.requested.isEmpty)
    }

    /// The reading that finds a display missing can be the one a running
    /// refresh left behind, not only one that arrives while nothing runs.
    func testADepartureSeenWhileARefreshRunsWaitsToo() async throws {
        let coalescer = await refreshedWithBothDisplays()

        holdRefreshes = true
        displays = Self.configuration(ids: [1, 2], width: 1512)
        coalescer.request()
        try await waitUntil { held.count == 1 }
        displays = Self.configuration(ids: [1], width: 1512)
        coalescer.request()

        holdRefreshes = false
        held.removeFirst().resume()
        try await waitForTheSettle()
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.count, 2, "the burst's last reading lacks a display the refresh just read")

        XCTAssertTrue(sleeper.fireNext())
        try await waitUntil { refreshes.count == 3 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.last, [1])
    }

    func testCancellingEndsAWaitWithoutRefreshingAndALaterRequestStartsOver() async throws {
        let coalescer = await refreshedWithBothDisplays()
        displays = Self.configuration(ids: [1])
        coalescer.request()
        try await waitForTheSettle()

        coalescer.cancel()
        XCTAssertEqual(sleeper.cancelledCount, 1)
        XCTAssertEqual(sleeper.pendingCount, 0)
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.count, 1)

        coalescer.request()
        try await waitForTheSettle()
        XCTAssertEqual(sleeper.requested.count, 2)

        coalescer.cancel()
        displays = Self.configuration(ids: [1, 2])
        coalescer.request()
        XCTAssertEqual(returns, 0, "a coalescer that was stopped announces nothing")
    }

    // MARK: Mirror sets, a closed lid and a screen without an ID

    /// AppKit lists a hardware mirror set as one screen, a closed lid takes the
    /// built-in display out of the list, and a screen can come without a display
    /// number. The coalescer reads these as any other change in the list: one
    /// refresh for the shape, and none for the same reading again.
    private static let builtIn = DisplayConfiguration.Display(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), scale: 2, refreshRate: 120)
    private static let external = DisplayConfiguration.Display(
        id: 2, frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080), scale: 1, refreshRate: 60)

    /// A mirror set whose surviving screen is unchanged is the other screen
    /// leaving, which waits for it to come back and then refreshes once.
    func testAMirrorSetCollapsingTwoScreensRefreshesOnce() async throws {
        displays = DisplayConfiguration(displays: [Self.builtIn, Self.external])
        let coalescer = makeCoalescer()
        coalescer.request()
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes, [[1, 2]])

        displays = DisplayConfiguration(displays: [Self.builtIn])
        coalescer.request()
        try await waitForTheSettle()
        for _ in 0..<20 { coalescer.request() }
        XCTAssertEqual(refreshes.count, 1, "the second screen may only be blinking")
        XCTAssertTrue(sleeper.fireNext())
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes, [[1, 2], [1]])

        for _ in 0..<20 { coalescer.request() }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.count, 2, "the same mirror set again is not a change")
        XCTAssertEqual(sleeper.requested.count, 1)
    }

    /// When the screen that survives is the one that was not first, it takes the
    /// first place and the origin, which is a change to a display that remains.
    func testAMirrorSetWhoseOtherMemberSurvivesRefreshesAtOnceAndOnlyOnce() async throws {
        displays = DisplayConfiguration(displays: [Self.builtIn, Self.external])
        let coalescer = makeCoalescer()
        coalescer.request()
        await coalescer.waitUntilIdleForTest()

        var survivor = Self.external
        survivor.frame.origin = .zero
        displays = DisplayConfiguration(displays: [survivor])
        coalescer.request()
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes, [[1, 2], [2]])
        XCTAssertTrue(sleeper.requested.isEmpty, "the screen that stayed moved, so there is nothing to wait for")

        for _ in 0..<20 { coalescer.request() }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.count, 2)
    }

    func testClamshellWithTheBuiltInLeavingRefreshesOnceAndThenSettles() async throws {
        displays = DisplayConfiguration(displays: [Self.builtIn, Self.external])
        let coalescer = makeCoalescer()
        coalescer.request()
        await coalescer.waitUntilIdleForTest()

        // The lid closes: the external display is first in the list and at the origin.
        var main = Self.external
        main.frame.origin = .zero
        displays = DisplayConfiguration(displays: [main])
        coalescer.request()
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.last, [2])
        XCTAssertTrue(sleeper.requested.isEmpty, "the main display changed, so its wallpaper cannot wait")

        for _ in 0..<20 {
            coalescer.request()
            await Task.yield()
        }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.count, 2, "the lid staying closed is not another change")

        // The lid opens again.
        displays = DisplayConfiguration(displays: [Self.builtIn, Self.external])
        coalescer.request()
        try await waitUntil { refreshes.count == 3 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.last, [1, 2])
    }

    func testAScreenWithoutAnIDIsNotMistakenForADisplayThatLeft() async throws {
        // Two screens without a number are two screens, not one display 0.
        var unnumbered = Self.external
        unnumbered.id = 0
        var another = unnumbered
        another.frame.origin.x += 1920
        displays = DisplayConfiguration(displays: [Self.builtIn, unnumbered, another])
        let coalescer = makeCoalescer()
        coalescer.request()
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.count, 1)

        for _ in 0..<20 { coalescer.request() }
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes.count, 1, "the same screens again are not a change")

        // One of them leaving cannot be matched to any display the bridge holds,
        // so it is an ordinary change and the displays are refreshed at once.
        displays = DisplayConfiguration(displays: [Self.builtIn, unnumbered])
        coalescer.request()
        try await waitUntil { refreshes.count == 2 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertTrue(sleeper.requested.isEmpty)

        // One arriving is a change too.
        displays = DisplayConfiguration(displays: [Self.builtIn, unnumbered, another])
        coalescer.request()
        try await waitUntil { refreshes.count == 3 }
        await coalescer.waitUntilIdleForTest()
        XCTAssertTrue(sleeper.requested.isEmpty)
    }

    private var displays = DisplayRefreshCoalescerTests.configuration(ids: [1, 2])
    private var refreshes: [[UInt32]] = []
    private var refreshSucceeds = true
    private var holdRefreshes = false
    /// How many times the coalescer said a missing display was back without refreshing for it.
    private var returns = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private let sleeper = ManualSleeper()

    /// A coalescer whose displays are `displays`, whose settle wait is `sleeper`, and whose
    /// refreshes are recorded as the display IDs each one read.
    private func makeCoalescer() -> DisplayRefreshCoalescer {
        let coalescer = DisplayRefreshCoalescer(
            configuration: { [unowned self] in self.displays }, sleep: sleeper.closure,
            displayReturned: { [unowned self] in self.returns += 1 }
        ) { [unowned self] in
            self.refreshes.append(self.displays.displays.map(\.id))
            if self.holdRefreshes { await withCheckedContinuation { self.held.append($0) } }
            return self.refreshSucceeds
        }
        addTeardownBlock { @MainActor in coalescer.cancel() }
        return coalescer
    }

    /// A coalescer that has refreshed for displays 1 and 2.
    private func refreshedWithBothDisplays() async -> DisplayRefreshCoalescer {
        displays = Self.configuration(ids: [1, 2])
        let coalescer = makeCoalescer()
        coalescer.request()
        await coalescer.waitUntilIdleForTest()
        XCTAssertEqual(refreshes, [[1, 2]])
        return coalescer
    }

    /// Waits, within the usual limit, for the settle to be sleeping, so a coalescer that never
    /// starts one fails the test instead of leaving it waiting.
    private func waitForTheSettle() async throws {
        try await waitUntil { sleeper.pendingCount == 1 }
    }

    private static func configuration(ids: [UInt32], width: CGFloat = 1728) -> DisplayConfiguration {
        DisplayConfiguration(displays: ids.map { id in
            .init(id: id, frame: CGRect(x: CGFloat(id) * 4000, y: 0, width: width, height: 1117), scale: 2, refreshRate: 120)
        })
    }

    private static func configuration(width: CGFloat, refreshRate: Int = 120) -> DisplayConfiguration {
        DisplayConfiguration(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: width, height: 1117), scale: 2, refreshRate: refreshRate)
        ])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum TestFailure: Error { case timeout }
}
