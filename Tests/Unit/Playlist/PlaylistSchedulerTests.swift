import XCTest
@testable import WallpaperMachine

@MainActor
final class PlaylistSchedulerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: PlaylistStore!
    private var collections: WallpaperCollectionStore!
    private var shown: [String: String] = [:]
    private var running = true
    /// Playing, but paused only because nobody can see the display (covered, full screen).
    private var unseen = false
    private var displayIDs = ["primary"]
    private var clock = Date()
    private var applied: [String] = []
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
        store = PlaylistStore(defaults: defaults)
        collections = WallpaperCollectionStore(defaults: defaults)
        shown = ["primary": "a"]
        running = true
        unseen = false
        displayIDs = ["primary"]
        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12))!
        applied = []
        watcher = ClipWatcher()
    }

    override func tearDown() {
        defaults = nil
        store = nil
        collections = nil
        super.tearDown()
    }

    private func makeScheduler(
        library: [String] = ["a", "b", "c"], favorites: Set<String> = [],
        commandRevision: @escaping @MainActor (String) -> UInt64 = { _ in 0 },
        watchClipEnd: @escaping PlaylistScheduler.WatchClipEnd = { _, _, _ in nil },
        activate: PlaylistScheduler.Activate? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
    ) -> PlaylistScheduler {
        PlaylistScheduler(
            store: store, collections: collections, displays: { self.displayIDs }, library: { library }, favorites: { favorites },
            current: { self.shown[$0] }, isRunning: { _ in self.running }, isUnseen: { _ in self.unseen },
            watchClipEnd: watchClipEnd,
            activate: activate ?? { display, choose in
                guard let id = choose() else { return nil }
                self.shown[display] = id
                self.applied.append(id)
                return id
            },
            commandRevision: commandRevision, now: { self.clock }, calendar: calendar, center: .default,
            sleep: sleep)
    }

    /// Lets the switch a scheduler started on the main actor run to its end.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    func testFailedWallpaperIsSkippedImmediatelyAndRetriedAfterCooldown() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 5 }
        var attempts: [String] = []
        var broken = true
        let scheduler = makeScheduler(activate: { display, choose in
            guard let id = choose() else { return nil }
            attempts.append(id)
            if id == "b", broken { throw WallpaperActionError(message: "Fixture failed") }
            self.shown[display] = id
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        XCTAssertTrue(scheduler.skip("primary"))
        await settle()
        XCTAssertEqual(attempts, ["b", "c"])
        XCTAssertEqual(shown["primary"], "c")
        XCTAssertNotNil(store.skipped["primary"]?["b"])
        shown["primary"] = "a"
        scheduler.skip("primary")
        await settle()
        XCTAssertEqual(attempts, ["b", "c", "c"], "a failed item is not immediately retried")
        clock.addTimeInterval(PlaylistScheduler.failureCooldown)
        shown["primary"] = "a"
        broken = false
        scheduler.skip("primary")
        await settle()
        XCTAssertEqual(attempts.last, "b")
        XCTAssertEqual(shown["primary"], "b")
        XCTAssertNil(store.skipped["primary"]?["b"])
    }

    func testBrokenLibraryHasBoundedAttemptsAndKeepsTheCurrentWallpaper() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 5 }
        var attempts: [String] = []
        let scheduler = makeScheduler(library: ["a"] + (1...20).map { "broken-\($0)" }, activate: { _, choose in
            guard let id = choose() else { return nil }
            attempts.append(id)
            throw WallpaperActionError(message: "Fixture failed")
        })
        scheduler.start()
        defer { scheduler.stop() }
        scheduler.skip("primary")
        await settle()
        XCTAssertEqual(attempts.count, PlaylistScheduler.maximumAttempts)
        XCTAssertEqual(Set(attempts).count, attempts.count)
        XCTAssertEqual(shown["primary"], "a")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(5 * 60))
    }

    func testCancellationDoesNotBlacklistOrTryAnotherWallpaper() async {
        store.update("primary") { $0.mode = .rotate }
        var attempts: [String] = []
        let scheduler = makeScheduler(activate: { _, choose in
            guard let id = choose() else { return nil }
            attempts.append(id)
            throw CancellationError()
        })
        scheduler.start()
        defer { scheduler.stop() }
        scheduler.skip("primary")
        await settle()
        XCTAssertEqual(attempts, ["b"])
        XCTAssertTrue(store.skipped.isEmpty)
    }

    func testFailedAutomaticSwitchYieldsToANewerManualCommand() async throws {
        store.update("primary") { $0.mode = .rotate }
        let queue = UserCommandQueue()
        let slot = BridgeStore.activationSlot(displayId: "primary")
        var release: CheckedContinuation<Void, Never>?
        var attempts: [String] = []
        let scheduler = makeScheduler(commandRevision: { _ in queue.revision(for: slot) }, activate: { _, choose in
            try await queue.run(slot: slot, origin: .playlist) {
                guard let id = choose() else { return }
                attempts.append(id)
                await withCheckedContinuation { release = $0 }
                throw WallpaperActionError(message: "Fixture failed")
            }
            return nil
        })
        scheduler.start()
        defer { scheduler.stop() }
        scheduler.skip("primary")
        await settle()
        let continuation = try XCTUnwrap(release)
        let manual = Task {
            await queue.run(slot: slot) { self.shown["primary"] = "manual" }
        }
        await settle()
        XCTAssertTrue(queue.hasWaiting(slot: slot))
        continuation.resume()
        await manual.value
        await settle()
        XCTAssertEqual(attempts, ["b"], "an automatic retry must not supersede the manual switch")
        XCTAssertEqual(shown["primary"], "manual")
    }

    func testRotationThatYieldsToAWaitingUserChoiceIsRescheduled() async throws {
        store.update("primary") { $0.mode = .rotate; $0.interval = 5 }
        let queue = UserCommandQueue()
        let slot = BridgeStore.activationSlot(displayId: "primary")
        var attempts: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { await queue.run { await withCheckedContinuation { release = $0 } } }
        await settle()
        let chosen = Task { await queue.run(slot: slot, subject: "chosen") { self.shown["primary"] = "chosen" } }
        await settle()
        XCTAssertTrue(queue.hasWaiting(slot: slot))
        let scheduler = makeScheduler(commandRevision: { _ in queue.revision(for: slot) }, activate: { display, choose in
            var applied: String?
            try await queue.run(slot: slot, origin: .playlist) {
                guard let id = choose() else { return }
                attempts.append(id)
                self.shown[display] = id
                applied = id
            }
            return applied
        })
        scheduler.start()
        defer { scheduler.stop() }

        clock.addTimeInterval(2 * 60)

        scheduler.skip("primary")
        await settle()
        XCTAssertTrue(attempts.isEmpty, "The rotation gives way without choosing a wallpaper")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(5 * 60),
                       "A rotation that yielded waits a full interval from now instead of retrying")

        try XCTUnwrap(release).resume()
        await blocker.value
        await chosen.value
        await settle()
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertEqual(shown["primary"], "chosen", "The wallpaper the user chose stays")
    }

    /// The rotation falls due while the user's Apply is already running, not waiting. It must not
    /// join the line behind it: it would run right after and replace the wallpaper just chosen.
    func testRotationThatFindsAUserChoiceRunningGivesWayAndDoesNotReplaceIt() async throws {
        store.update("primary") { $0.mode = .rotate; $0.interval = 5 }
        let queue = UserCommandQueue()
        let slot = BridgeStore.activationSlot(displayId: "primary")
        var attempts: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let chosen = Task {
            await queue.run(slot: slot, subject: "chosen") {
                await withCheckedContinuation { release = $0 }
                self.shown["primary"] = "chosen"
            }
        }
        await settle()
        XCTAssertTrue(queue.isBusy)
        XCTAssertFalse(queue.hasWaiting(slot: slot), "the choice is running, not waiting")
        let scheduler = makeScheduler(commandRevision: { _ in queue.revision(for: slot) }, activate: { display, choose in
            var applied: String?
            try await queue.run(slot: slot, origin: .playlist) {
                guard let id = choose() else { return }
                attempts.append(id)
                self.shown[display] = id
                applied = id
            }
            return applied
        })
        scheduler.start()
        defer { scheduler.stop() }

        clock.addTimeInterval(6 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(queue.waiting.isEmpty, "The rotation does not queue up behind the choice")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(5 * 60),
                       "A rotation that yielded waits a full interval from now instead of retrying")

        try XCTUnwrap(release).resume()
        await chosen.value
        await settle()
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertEqual(shown["primary"], "chosen", "The wallpaper the user chose stays")
    }

    func testChangingPlaylistDuringFailureDoesNotContinueTheOldRotation() async {
        store.update("primary") { $0.mode = .rotate }
        var attempts: [String] = []
        let scheduler = makeScheduler(activate: { _, choose in
            guard let id = choose() else { return nil }
            attempts.append(id)
            self.store.update("primary") { $0.mode = .off }
            throw WallpaperActionError(message: "Fixture failed")
        })
        scheduler.start()
        defer { scheduler.stop() }
        scheduler.skip("primary")
        await settle()
        XCTAssertEqual(attempts, ["b"])
        XCTAssertEqual(shown["primary"], "a")
        XCTAssertNil(store.nextChange["primary"])
    }

    func testRotationWaitsItsIntervalThenAdvancesInOrder() async {
        store.update("primary") {
            $0.mode = .rotate
            $0.interval = 30
        }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        XCTAssertTrue(applied.isEmpty, "turning rotation on does not change the wallpaper at once")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60))

        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"])
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60))
    }

    func testAChangeThatFellDueWhilePausedHappensOnceOnResume() async {
        store.update("primary") {
            $0.mode = .rotate
            $0.interval = 5
        }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        running = false
        clock.addTimeInterval(3 * 60 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "nothing changes while wallpapers are paused or hidden")

        running = true
        scheduler.evaluate()
        await settle()
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "missed intervals are not caught up one by one")
    }

    /// Issue #160: a rotation that falls due while windows or a full-screen app cover the desktop
    /// changes behind them, so the desktop shows the new wallpaper instead of switching the moment
    /// the user returns to it. It changes once while out of sight, and showing again starts a whole
    /// interval.
    func testARotationOutOfSightChangesBehindTheWindowsOnceAndShowingStartsAnInterval() async {
        store.update("primary") {
            $0.mode = .rotate
            $0.interval = 5
        }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        running = false
        unseen = true
        clock.addTimeInterval(5 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "a covered display changes when its interval ends")

        clock.addTimeInterval(3 * 60 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "one change while out of sight, not one per interval")

        running = true
        unseen = false
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "the desktop does not switch the moment it shows")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(5 * 60))

        clock.addTimeInterval(5 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "c"])
    }

    func testACoveredRotationInterruptedBeforeSelectionRetriesWhenPlaybackResumes() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 5 }
        var interrupt = true
        let scheduler = makeScheduler(activate: { display, choose in
            if interrupt {
                // Sleep or a global playback pause can arrive after the timer fired but
                // before the command gets to choose a wallpaper.
                interrupt = false
                self.unseen = false
            }
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        running = false
        unseen = true
        clock.addTimeInterval(5 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty)

        unseen = true
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "an unmade change must not count as the covered display's change")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(5 * 60))
    }

    func testACoveredRotationThatFinishesDuringAPauseStillCountsAsItsHiddenChange() async throws {
        store.update("primary") { $0.mode = .rotate; $0.interval = 5 }
        let activation = AsyncGate()
        let scheduler = makeScheduler(activate: { display, choose in
            guard let id = choose() else { return nil }
            await activation.wait()
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { activation.open(); scheduler.stop() }
        running = false
        unseen = true
        clock.addTimeInterval(5 * 60)
        scheduler.evaluate()
        try await waitUntil { activation.waitingCount == 1 }

        // A global pause or lock makes both eligibility queries false without
        // revealing the desktop. The already-selected switch still succeeds.
        unseen = false
        scheduler.evaluate()
        activation.open()
        try await waitUntil { applied == ["b"] }

        unseen = true
        clock.addTimeInterval(5 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "resuming behind the same windows must not rotate again")
        clock.addTimeInterval(3 * 60 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "the successful hidden change lasts until the desktop shows")

        running = true
        unseen = false
        scheduler.evaluate()
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(5 * 60))
        clock.addTimeInterval(5 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "c"])
    }

    func testACoveredRotationWithoutAnotherCandidateRetriesAtTheNextInterval() async throws {
        let collection = try collections.create(name: "Rotation", wallpaperIDs: ["a"])
        store.update("primary") {
            $0.mode = .rotate; $0.interval = 5
            $0.source = .collection; $0.collectionID = collection.id
        }
        let timer = ManualSleeper()
        let scheduler = makeScheduler(sleep: { try await timer.sleep(.seconds($0)) })
        scheduler.start()
        defer { scheduler.stop() }
        try await waitUntil { timer.pendingCount == 1 }
        running = false
        unseen = true
        clock.addTimeInterval(5 * 60)
        XCTAssertTrue(timer.fireNext())
        try await waitUntil { timer.pendingCount == 1 }
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(5 * 60))

        try collections.add(["b"], to: collection.id)
        clock.addTimeInterval(5 * 60)
        XCTAssertTrue(timer.fireNext())
        try await waitUntil { applied == ["b"] }
        XCTAssertEqual(applied, ["b"], "new candidates can recover a rotation that has not changed yet")
    }

    func testShowingACoveredRotationBeforeItsDeadlineStartsAFullInterval() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 5 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        running = false
        unseen = true
        clock.addTimeInterval(5 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"])

        clock.addTimeInterval(4 * 60)
        running = true
        unseen = false
        scheduler.evaluate()
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(5 * 60))
        clock.addTimeInterval(60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "the old deadline must not shorten the visible interval")
        clock.addTimeInterval(4 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "c"])
    }

    func testAPlanAppliedToADisplayOutOfSightAppliesAtOnce() async throws {
        store.update("source") { $0.mode = .rotate; $0.interval = 5; $0.wallpaperIDs = ["c"]; $0.source = .list }
        let plan = try store.savePlan(from: "source", name: "Only c")
        store.update("primary") { $0.mode = .rotate; $0.interval = 5 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        running = false
        unseen = true
        clock.addTimeInterval(5 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"])

        try store.applyPlan(plan.id, to: "primary")
        await settle()
        XCTAssertEqual(applied, ["b", "c"], "a playlist chosen meanwhile is not held back")
    }

    func testDayAndNightSwitchesADisplayOutOfSight() async {
        store.update("primary") {
            $0.mode = .dayNight
            $0.dayWallpaperID = "b"
        }
        running = false
        unseen = true
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        XCTAssertEqual(applied, ["b"])
    }

    func testNothingChangesOutOfSightWhileTheUserPausedOrForAnUnlock() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 5 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        running = false
        clock.addTimeInterval(5 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "paused, not merely out of sight")

        store.update("primary") { $0.trigger = .unlock }
        unseen = true
        scheduler.noteUnlock()
        await settle()
        XCTAssertTrue(applied.isEmpty, "an unlock change waits until the display shows")
    }

    func testDayAndNightFollowTheClockButLeaveAManualChoiceAlone() async {
        store.update("primary") {
            $0.mode = .dayNight
            $0.dayWallpaperID = "b"
            $0.nightWallpaperID = "c"
        }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        XCTAssertEqual(applied, ["b"], "at noon the day wallpaper takes over")
        XCTAssertEqual(store.nextChange["primary"], calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 19)))

        shown["primary"] = "a"
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "a wallpaper applied by hand stays until the next half of the day")

        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 20))!
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "c"])
        XCTAssertEqual(store.nextChange["primary"], calendar.date(from: DateComponents(year: 2027, month: 1, day: 16, hour: 7)))
    }

    /// A relaunch inside the same half of the day (an app update, the library's drive coming
    /// back) is not a new period: the wallpaper applied by hand before it stays until the next.
    func testAManualChoiceOnADayAndNightDisplaySurvivesARelaunchUntilTheNextPeriod() async {
        store.update("primary") {
            $0.mode = .dayNight
            $0.dayWallpaperID = "b"
            $0.nightWallpaperID = "c"
        }
        let first = makeScheduler()
        first.start()
        await settle()
        XCTAssertEqual(applied, ["b"])
        shown["primary"] = "a"
        first.stop()

        store = PlaylistStore(defaults: defaults)
        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 13))!
        let second = makeScheduler()
        second.start()
        defer { second.stop() }
        await settle()
        XCTAssertEqual(applied, ["b"], "the day wallpaper is not put back over the manual choice")
        XCTAssertEqual(shown["primary"], "a")

        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 20))!
        second.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "c"], "the night still takes over at its time")
    }

    /// What a relaunch keeps is the period settled under the day and night settings as they
    /// were: a day wallpaper chosen just before quitting is applied when the app starts again.
    func testADayWallpaperChosenBeforeARelaunchIsAppliedAfterIt() async {
        store.update("primary") {
            $0.mode = .dayNight
            $0.dayWallpaperID = "b"
        }
        let first = makeScheduler()
        first.start()
        await settle()
        XCTAssertEqual(applied, ["b"])
        first.stop()
        store.update("primary") { $0.dayWallpaperID = "c" }

        store = PlaylistStore(defaults: defaults)
        let second = makeScheduler()
        second.start()
        defer { second.stop() }
        await settle()
        XCTAssertEqual(applied, ["b", "c"])
    }

    /// A wallpaper that keeps failing is left out of the shuffle while it cools down, and the
    /// round is over once every wallpaper that can be shown has been: the next round shows each
    /// of them again before any repeats.
    func testAShuffleRoundEndsWithoutTheWallpaperThatKeepsFailing() async {
        store.update("primary") { $0.mode = .rotate; $0.order = .shuffle; $0.interval = 60 }
        let scheduler = makeScheduler(library: ["a", "b", "c", "x"])
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        store.recordFailure(
            "x", on: "primary", message: "Fixture failed",
            retryAfter: clock.addingTimeInterval(PlaylistScheduler.failureCooldown))

        for _ in 0..<3 {
            scheduler.skip("primary")
            await settle()
        }
        XCTAssertEqual(Set(applied), ["a", "b", "c"], "the first round shows every wallpaper that works")
        XCTAssertEqual(store.recent["primary"], [], "and is over without the one that does not")

        applied = []
        for _ in 0..<3 {
            scheduler.skip("primary")
            await settle()
        }
        XCTAssertEqual(Set(applied), ["a", "b", "c"], "so the next round shows each again before one repeats")
    }

    func testChoosingADifferentDayWallpaperAppliesAtOnce() async {
        store.update("primary") {
            $0.mode = .dayNight
            $0.dayWallpaperID = "b"
        }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        store.update("primary") { $0.dayWallpaperID = "c" }
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "c"])
    }

    /// A relaunch carries on with the shuffle round it was halfway through: the wallpapers the
    /// round already showed do not come round again before the others have.
    func testARelaunchDoesNotRepeatWhatTheRoundAlreadyShowed() async {
        let library = ["a", "b", "c", "d", "e", "f", "g", "h"]
        store.update("primary") { $0.mode = .rotate; $0.order = .shuffle; $0.interval = 5 }
        var scheduler = makeScheduler(library: library)
        scheduler.start()
        for _ in 0..<3 {
            XCTAssertTrue(scheduler.skip("primary"))
            await settle()
        }
        scheduler.stop()
        let shownBefore = Set(applied)
        XCTAssertEqual(applied.count, 3)
        XCTAssertEqual(shownBefore.count, 3, "a round does not repeat a wallpaper")

        // The app quits and starts again with the same wallpaper on screen.
        store = PlaylistStore(defaults: defaults)
        applied = []
        scheduler = makeScheduler(library: library)
        scheduler.start()
        defer { scheduler.stop() }
        for _ in 0..<5 {
            XCTAssertTrue(scheduler.skip("primary"))
            await settle()
        }
        XCTAssertEqual(applied.count, 5)
        XCTAssertEqual(Set(applied), Set(library).subtracting(shownBefore),
                       "the rest of the round shows exactly the wallpapers it had not shown yet")
        XCTAssertEqual(store.recent["primary"], [], "the round is complete and the next starts fresh")
        XCTAssertNil(PlaylistStore(defaults: defaults).recent["primary"])
    }

    func testSkipChangesARotatingDisplayNowAndRestartsItsInterval() async {
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        XCTAssertFalse(scheduler.skip("primary"), "a display without a rotation leaves Next to the library order")

        store.update("primary") {
            $0.mode = .rotate
            $0.source = .list
            $0.wallpaperIDs = ["c", "a"]
            $0.interval = 60
        }
        XCTAssertTrue(scheduler.canSkip("primary"))
        XCTAssertTrue(scheduler.skip("primary"))
        await settle()
        XCTAssertEqual(applied, ["c"])
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(60 * 60))
        store.update("primary") { $0.wallpaperIDs = ["c"] }
        XCTAssertFalse(scheduler.canSkip("primary"), "the only wallpaper on the list is already showing")
        XCTAssertFalse(scheduler.skip("primary"), "with nothing else to change to, Next must not report success")
        await settle()
        XCTAssertEqual(applied, ["c"])
    }

    /// Change now and Next Wallpaper are asked for, so they move a paused or covered display
    /// along at once, while a change that falls due on its own still waits for it to play.
    func testRequestedSkipChangesAPausedDisplayButItsTimerWaits() async {
        running = false
        store.update("primary") {
            $0.mode = .rotate
            $0.source = .list
            $0.wallpaperIDs = ["a", "b", "c"]
            $0.interval = 30
        }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        XCTAssertTrue(scheduler.skip("primary"))
        await settle()
        XCTAssertEqual(applied, ["b"])
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60))

        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "the timer's own change waits while the display is paused")
    }

    /// Change now asked for while the timer's own change still waits its turn, with the display
    /// paused meanwhile, is not lost: that change runs as asked for.
    func testRequestedSkipDuringATimerChangeStillMovesAPausedDisplay() async {
        store.update("primary") {
            $0.mode = .rotate
            $0.source = .list
            $0.wallpaperIDs = ["a", "b", "c"]
            $0.interval = 30
        }
        var release: CheckedContinuation<Void, Never>?
        let scheduler = makeScheduler(activate: { display, choose in
            await withCheckedContinuation { release = $0 }
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertNotNil(release, "the timer's change is waiting its turn")
        running = false
        XCTAssertTrue(scheduler.skip("primary"))
        release?.resume()
        await settle()
        XCTAssertEqual(applied, ["b"])
    }

    /// When the playlist changes while the timer's change waits its turn, that change is dropped
    /// as stale; Change now asked for meanwhile is then made on its own, paused display or not.
    func testRequestedSkipBehindAStaleTimerChangeIsMadeOnItsOwn() async {
        store.update("primary") {
            $0.mode = .rotate
            $0.source = .list
            $0.wallpaperIDs = ["a", "b", "c"]
            $0.interval = 30
        }
        var release: CheckedContinuation<Void, Never>?
        var holdsFirst = true
        let scheduler = makeScheduler(activate: { display, choose in
            if holdsFirst {
                holdsFirst = false
                await withCheckedContinuation { release = $0 }
            }
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertNotNil(release, "the timer's change is waiting its turn")
        store.update("primary") { $0.wallpaperIDs = ["a", "c"] }
        running = false
        XCTAssertTrue(scheduler.skip("primary"))
        release?.resume()
        await settle()
        XCTAssertEqual(applied, ["c"], "the stale change is dropped and the asked-for one is made")
    }

    func testNothingPlayableLeavesTheDisplayAsItIs() async {
        store.update("primary") {
            $0.mode = .rotate
            $0.source = .favorites
        }
        let scheduler = makeScheduler(favorites: ["gone"])
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(60 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60), "it tries again an interval later")
    }

    func testApplyingPlanWhilePausedWaitsThenRotatesOnceUsingLiveCollection() async throws {
        let collection = try collections.create(name: "Live", wallpaperIDs: ["a", "gone", "b"])
        store.update("source") { $0.mode = .rotate; $0.source = .collection; $0.collectionID = collection.id }
        let plan = try store.savePlan(from: "source", name: "Collection rotation")
        running = false
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        try store.applyPlan(plan.id, to: "primary")
        await settle()
        XCTAssertEqual(applied, [])
        try collections.remove(["b"], from: collection.id)
        try collections.add(["c"], to: collection.id)
        running = true
        scheduler.evaluate()
        await settle()
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["c"], "membership is resolved when the display actually resumes")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60))
    }

    func testReapplyingDayNightPlanSettlesOnceButDeletingPlanKeepsManualOverride() async throws {
        store.update("source") { $0.mode = .dayNight; $0.dayWallpaperID = "b"; $0.nightWallpaperID = "c" }
        let plan = try store.savePlan(from: "source", name: "Day and night")
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        try store.applyPlan(plan.id, to: "primary")
        await settle()
        shown["primary"] = "a"
        try store.applyPlan(plan.id, to: "primary")
        await settle()
        XCTAssertEqual(applied, ["b", "b"], "explicit reactivation reconciles the current phase")
        shown["primary"] = "a"
        try store.deletePlan(plan.id)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "b"], "deleting metadata must not override a manual wallpaper")
    }

    func testQueuedPlanReplacementCannotApplyOldPlanOrOverwriteNewDeadline() async throws {
        store.update("source") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b"] }
        let oldPlan = try store.savePlan(from: "source", name: "Old")
        store.update("source") { $0.wallpaperIDs = ["a", "c"]; $0.interval = 60 }
        let newPlan = try store.savePlan(from: "source", name: "New")
        var resume: CheckedContinuation<Void, Never>?
        var first = true
        let scheduler = makeScheduler(activate: { display, choose in
            if first {
                first = false
                await withCheckedContinuation { resume = $0 }
            }
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        try store.applyPlan(oldPlan.id, to: "primary")
        await settle()
        let gate = try XCTUnwrap(resume)
        try store.applyPlan(newPlan.id, to: "primary")
        gate.resume()
        await settle()
        XCTAssertEqual(applied, ["c"])
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(60 * 60))
    }

    func testPauseAfterEnqueuePreservesDuePlanUntilResume() async throws {
        store.update("source") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b"] }
        let plan = try store.savePlan(from: "source", name: "Rotation")
        var resume: CheckedContinuation<Void, Never>?
        var first = true
        let scheduler = makeScheduler(activate: { display, choose in
            if first {
                first = false
                await withCheckedContinuation { resume = $0 }
            }
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        try store.applyPlan(plan.id, to: "primary")
        await settle()
        let gate = try XCTUnwrap(resume)
        running = false
        gate.resume()
        await settle()
        XCTAssertEqual(applied, [])
        XCTAssertEqual(store.nextChange["primary"], .distantPast)
        running = true
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"])
    }
    func testPlanActivationOnOneDisplayDoesNotLiftAnotherDisplaysPause() async throws {
        shown["second"] = "a"
        running = false
        store.update("source") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b"] }
        let plan = try store.savePlan(from: "source", name: "Shared configuration")
        let scheduler = PlaylistScheduler(
            store: store, collections: collections, displays: { ["primary", "second"] },
            library: { ["a", "b"] }, favorites: { [] }, current: { self.shown[$0] },
            isRunning: { $0 == "primary" || self.running },
            activate: { display, choose in
                guard let id = choose() else { return nil }
                self.shown[display] = id
                self.applied.append(display)
                return id
            },
            now: { self.clock }, center: .default,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        scheduler.start()
        defer { scheduler.stop() }
        try store.applyPlan(plan.id, to: "primary")
        try store.applyPlan(plan.id, to: "second")
        await settle()
        XCTAssertEqual(applied, ["primary"])
        XCTAssertEqual(shown["second"], "a")
        running = true
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["primary", "second"])
        XCTAssertEqual(shown["second"], "b")
    }

    /// A wallpaper the user applies a minute before a rotation falls due is not replaced by
    /// it: the rotation waits the grace from the choice, then happens once.
    func testAManualChoiceHoldsADueRotationForTheGrace() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 30 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        let started = clock
        clock.addTimeInterval(29 * 60)
        scheduler.noteManualChoice("primary")
        await settle()
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(PlaylistScheduler.manualGrace))

        clock = started.addingTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "the old deadline no longer replaces the wallpaper just chosen")
        clock = started.addingTimeInterval(33 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty)

        clock = started.addingTimeInterval(34 * 60)
        scheduler.evaluate()
        await settle()
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "the rotation resumes once the grace has passed")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60))
    }

    func testAManualChoiceNeverShortensALaterDeadline() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 30 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        let deadline = clock.addingTimeInterval(30 * 60)
        clock.addTimeInterval(10 * 60)
        XCTAssertEqual(store.nextChange["primary"], deadline)
        scheduler.noteManualChoice("primary")
        await settle()
        XCTAssertEqual(store.nextChange["primary"], deadline, "twenty minutes out is already past the grace")

        store.update("primary") { $0.interval = 60 }
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(60 * 60))
        scheduler.noteManualChoice("primary")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(60 * 60), "a long interval keeps its rhythm")
    }

    func testTheGraceIsNeverLongerThanTheInterval() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 1 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        clock.addTimeInterval(50)
        scheduler.noteManualChoice("primary")
        await settle()
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(60),
                       "a one-minute rotation is held for one minute, not five")
        XCTAssertTrue(applied.isEmpty)
    }

    /// A paused display keeps the deadline it missed. A choice made meanwhile must not leave it
    /// to swap the wallpaper the moment playback resumes.
    func testAManualChoiceOnAPausedDisplayStillHoldsTheRotationAfterResume() async throws {
        store.update("source") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b"] }
        let plan = try store.savePlan(from: "source", name: "Rotation")
        running = false
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        try store.applyPlan(plan.id, to: "primary")
        await settle()
        XCTAssertEqual(store.nextChange["primary"], .distantPast)
        scheduler.noteManualChoice("primary")
        await settle()
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(PlaylistScheduler.manualGrace))

        running = true
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "resuming within the grace leaves the chosen wallpaper alone")
        clock.addTimeInterval(PlaylistScheduler.manualGrace)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"])
    }

    func testManualChoiceIgnoresOffAndDayNightPlaylists() async {
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        scheduler.noteManualChoice("primary")
        await settle()
        XCTAssertNil(store.nextChange["primary"], "an Off display gets no deadline from a manual choice")

        store.update("primary") { $0.mode = .dayNight; $0.dayWallpaperID = "b"; $0.nightWallpaperID = "c" }
        await settle()
        let boundary = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 19))
        XCTAssertEqual(store.nextChange["primary"], boundary)
        shown["primary"] = "a"
        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 18, minute: 58))!
        scheduler.noteManualChoice("primary")
        await settle()
        XCTAssertEqual(store.nextChange["primary"], boundary, "day and night keeps its own boundary")
        XCTAssertEqual(applied, ["b"], "the manual choice itself changes nothing")
    }

    // MARK: A display the user cleared

    /// The playlist does not undo a removal: a display the user emptied stays empty when the
    /// timer falls due, and nothing is armed for it.
    func testAClearedDisplayIsNotRefilledWhenTheTimerFallsDue() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 30 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        XCTAssertNotNil(store.nextChange["primary"])

        shown["primary"] = nil
        store.setHold(.removedWallpaper, on: "primary")
        clock.addTimeInterval(3 * 60 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "a removed wallpaper is not put back by the rotation")
        XCTAssertNil(store.nextChange["primary"], "a waiting display has no deadline to keep")
        XCTAssertEqual(store.holds["primary"], .removedWallpaper)

        clock.addTimeInterval(24 * 60 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "it keeps waiting, however long")
    }

    /// Whoever puts a wallpaper on the display again ends the wait, and the rotation then counts
    /// a whole interval from there instead of a deadline it kept while the display was empty.
    func testTheHoldEndsWhenAnyWallpaperIsOnTheDisplayAgain() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 30 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        shown["primary"] = nil
        store.setHold(.removedWallpaper, on: "primary")
        clock.addTimeInterval(2 * 60 * 60)
        scheduler.evaluate()
        await settle()

        shown["primary"] = "b"
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(store.holds.isEmpty)
        XCTAssertTrue(applied.isEmpty, "the wallpaper put there is not replaced on the spot")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60))

        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["c"], "the rotation carries on from the wallpaper that is there")
    }

    func testChangeNowFillsAClearedDisplayAndLiftsTheHold() async {
        store.update("primary") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["b", "c"]; $0.interval = 60 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        shown["primary"] = nil
        store.setHold(.removedWallpaper, on: "primary")
        await settle()

        XCTAssertTrue(scheduler.canSkip("primary"))
        XCTAssertTrue(scheduler.skip("primary"))
        await settle()
        XCTAssertEqual(applied, ["b"])
        XCTAssertTrue(store.holds.isEmpty)
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(60 * 60))
    }

    func testResumeFillsAClearedRotationNowAndDoesNothingOtherwise() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 60 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        scheduler.resume("primary")
        await settle()
        XCTAssertTrue(applied.isEmpty, "a display that is not waiting has nothing to resume")

        shown["primary"] = nil
        store.setHold(.removedWallpaper, on: "primary")
        await settle()
        scheduler.resume("primary")
        await settle()
        XCTAssertEqual(applied, ["a"], "the first wallpaper of the rotation fills the empty display")
        XCTAssertTrue(store.holds.isEmpty)
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(60 * 60))
    }

    func testResumePutsTheCurrentDayOrNightWallpaperBack() async {
        store.update("primary") { $0.mode = .dayNight; $0.dayWallpaperID = "b"; $0.nightWallpaperID = "c" }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        XCTAssertEqual(applied, ["b"])

        shown["primary"] = nil
        store.setHold(.removedWallpaper, on: "primary")
        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 20))!
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "the night boundary does not refill a display the user emptied")
        XCTAssertNil(store.nextChange["primary"])

        scheduler.resume("primary")
        await settle()
        XCTAssertEqual(applied, ["b", "c"], "resuming applies the wallpaper for this half of the day")
        XCTAssertTrue(store.holds.isEmpty)
        XCTAssertEqual(store.nextChange["primary"], calendar.date(from: DateComponents(year: 2027, month: 1, day: 16, hour: 7)))
    }

    /// A wallpaper the user puts on a held day and night display stays until the next boundary,
    /// even though a boundary passed while the display was empty.
    func testAWallpaperChosenOnAHeldDayNightDisplayStaysUntilTheNextBoundary() async {
        store.update("primary") { $0.mode = .dayNight; $0.dayWallpaperID = "b"; $0.nightWallpaperID = "c" }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        shown["primary"] = nil
        store.setHold(.removedWallpaper, on: "primary")
        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 20))!
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"])

        shown["primary"] = "a"
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "the choice is not replaced by the night wallpaper")
        XCTAssertTrue(store.holds.isEmpty)

        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 16, hour: 8))!
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "b"], "the next boundary applies the day wallpaper as usual")
    }

    func testTurningThePlaylistOffEndsTheWait() async {
        store.update("primary") { $0.mode = .rotate }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        store.setHold(.removedWallpaper, on: "primary")
        store.update("primary") { $0.mode = .off }
        await settle()
        XCTAssertTrue(store.holds.isEmpty)
        store.update("primary") { $0.mode = .rotate }
        shown["primary"] = nil
        await settle()
        clock.addTimeInterval(PlaylistScheduler.seconds(30))
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["a"], "a playlist turned back on runs like any other")
    }

    /// The user can empty the display while the timer's change waits its turn in the command
    /// queue; the change then leaves the display empty instead of undoing the removal.
    func testAChangeWaitingBehindARemovalLeavesTheDisplayEmpty() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 30 }
        var waited = false
        let scheduler = makeScheduler(activate: { display, choose in
            waited = true
            self.shown[display] = nil
            self.store.setHold(.removedWallpaper, on: display)
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(waited)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertNil(shown["primary"])
        XCTAssertNil(store.nextChange["primary"], "the finished change does not date a display that waits")
        XCTAssertEqual(store.holds["primary"], .removedWallpaper)
    }

    /// Change now asked for while the timer's own change is still in the queue is a request to
    /// fill the display: it ends the wait and is made.
    func testChangeNowBehindATimerChangeEndsTheWait() async {
        store.update("primary") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b", "c"]; $0.interval = 30 }
        var release: CheckedContinuation<Void, Never>?
        let scheduler = makeScheduler(activate: { display, choose in
            await withCheckedContinuation { release = $0 }
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertNotNil(release, "the timer's change is waiting its turn")
        shown["primary"] = nil
        store.setHold(.removedWallpaper, on: "primary")
        XCTAssertTrue(scheduler.skip("primary"))
        XCTAssertTrue(store.holds.isEmpty)
        release?.resume()
        await settle()
        XCTAssertEqual(applied, ["a"])
    }

    // MARK: Changing when the Mac is unlocked

    /// An unlock changes an unlock playlist once. A second report within the debounce is the same
    /// unlock, a later one is a new unlock, and no date is ever put on the display.
    func testUnlockRotatesAnUnlockPlaylistOnceAndIgnoresADoubleEvent() async {
        store.update("primary") { $0.mode = .rotate; $0.trigger = .unlock }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        XCTAssertNil(store.nextChange["primary"], "an unlock playlist has no timer")
        XCTAssertTrue(applied.isEmpty, "nothing changes until the Mac is unlocked")

        scheduler.noteUnlock()
        await settle()
        XCTAssertEqual(applied, ["b"])
        clock.addTimeInterval(PlaylistScheduler.unlockDebounce - 1)
        scheduler.noteUnlock()
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "a double report is one unlock, and evaluating again does not repeat it")

        clock.addTimeInterval(PlaylistScheduler.unlockDebounce + 1)
        scheduler.noteUnlock()
        await settle()
        XCTAssertEqual(applied, ["b", "c"], "the next unlock changes the wallpaper again")
        XCTAssertNil(store.nextChange["primary"])
    }

    /// A display that cannot play when the Mac unlocks changes as soon as it can, but only while
    /// the unlock is recent: it is not changed minutes later.
    func testUnlockWaitsForTheDisplayToPlayButNotLongerThanTheGrace() async {
        store.update("primary") { $0.mode = .rotate; $0.trigger = .unlock }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        running = false
        scheduler.noteUnlock()
        await settle()
        XCTAssertTrue(applied.isEmpty)

        clock.addTimeInterval(PlaylistScheduler.unlockGrace - 1)
        running = true
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "playing again within the grace answers the unlock")
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "once per unlock")

        clock.addTimeInterval(60)
        running = false
        scheduler.noteUnlock()
        clock.addTimeInterval(PlaylistScheduler.unlockGrace + 1)
        running = true
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "an unlock that is over changes nothing")
    }

    /// The timer and the unlock are separate triggers: an interval playlist ignores the unlock,
    /// and an unlock playlist ignores the clock.
    func testIntervalPlaylistsIgnoreUnlockAndUnlockPlaylistsIgnoreTheClock() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 30 }
        shown["second"] = "a"
        displayIDs = ["primary", "second"]
        store.update("second") { $0.mode = .rotate; $0.trigger = .unlock }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        XCTAssertNotNil(store.nextChange["primary"])
        XCTAssertNil(store.nextChange["second"])

        scheduler.noteUnlock()
        await settle()
        XCTAssertEqual(shown["primary"], "a", "a timed rotation does not answer an unlock")
        XCTAssertEqual(shown["second"], "b")

        clock.addTimeInterval(10 * 60 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(shown["primary"], "b", "the timed rotation still follows the clock")
        XCTAssertEqual(shown["second"], "b", "an unlock rotation does not")
        XCTAssertNil(store.nextChange["second"])
    }

    /// An unlock nobody waits for is dropped, so choosing the setting afterwards cannot act on it.
    func testAnUnlockIsNotKeptForAPlaylistChosenAfterwards() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 30 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        scheduler.noteUnlock()
        clock.addTimeInterval(5)
        store.update("primary") { $0.trigger = .unlock }
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "the unlock was over before anything waited for it")
    }

    /// Every display that waits for the unlock changes once, including one that shows up while
    /// the displays are still being enumerated after wake.
    func testADisplayThatAppearsWithinTheGraceChangesOnceToo() async {
        store.update("primary") { $0.mode = .rotate; $0.trigger = .unlock }
        store.update("second") { $0.mode = .rotate; $0.trigger = .unlock }
        shown["second"] = "a"
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        scheduler.noteUnlock()
        await settle()
        XCTAssertEqual(shown["primary"], "b")
        XCTAssertEqual(shown["second"], "a", "a display that is not there is not changed")

        clock.addTimeInterval(10)
        displayIDs = ["primary", "second"]
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(shown["second"], "b")
        XCTAssertEqual(shown["primary"], "b", "the display that already changed is left alone")
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "b"])
    }

    /// A display the user emptied stays empty, and Change now still works on an unlock playlist
    /// without giving it a timer.
    func testUnlockSkipsAHeldDisplayAndChangeNowStillWorks() async {
        store.update("primary") { $0.mode = .rotate; $0.trigger = .unlock }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        shown["primary"] = nil
        store.setHold(.removedWallpaper, on: "primary")
        scheduler.noteUnlock()
        await settle()
        XCTAssertTrue(applied.isEmpty, "an unlock does not refill a display the user cleared")
        XCTAssertEqual(store.holds["primary"], .removedWallpaper)

        XCTAssertTrue(scheduler.skip("primary"))
        await settle()
        XCTAssertEqual(applied, ["a"], "Change now fills it")
        XCTAssertTrue(store.holds.isEmpty)
        XCTAssertNil(store.nextChange["primary"], "the change does not start a timer")
    }

    /// A wallpaper the user chooses while an unlock is still waiting for the display answers it.
    func testAManualChoiceWhileAnUnlockWaitsIsLeftAlone() async {
        store.update("primary") { $0.mode = .rotate; $0.trigger = .unlock }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        running = false
        scheduler.noteUnlock()
        shown["primary"] = "chosen"
        scheduler.noteManualChoice("primary")
        running = true
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(shown["primary"], "chosen")
    }

    /// Change now asked for while the display cannot play yet answers the unlock: the display is
    /// not changed a second time when it plays.
    func testChangeNowWhileAnUnlockWaitsAnswersIt() async {
        store.update("primary") { $0.mode = .rotate; $0.trigger = .unlock }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        running = false
        scheduler.noteUnlock()
        XCTAssertTrue(scheduler.skip("primary"))
        await settle()
        XCTAssertEqual(applied, ["b"], "Change now is made even though the display cannot play")
        running = true
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "the unlock has been answered")
    }

    /// A change that lost its turn because the display stopped playing meanwhile is made when it
    /// plays again, while the unlock is recent.
    func testAnUnlockChangeThatLostItsTurnToAPauseIsMadeOncePlayingResumes() async {
        store.update("primary") { $0.mode = .rotate; $0.trigger = .unlock }
        var release: CheckedContinuation<Void, Never>?
        var blocking = true
        let scheduler = makeScheduler(activate: { display, choose in
            if blocking { await withCheckedContinuation { release = $0 } }
            guard let id = choose() else { return nil }
            self.shown[display] = id
            self.applied.append(id)
            return id
        })
        scheduler.start()
        defer { scheduler.stop() }
        scheduler.noteUnlock()
        await settle()
        XCTAssertNotNil(release, "the change is waiting for its turn")
        running = false
        blocking = false
        release?.resume()
        await settle()
        XCTAssertTrue(applied.isEmpty, "the display was paused when the change got its turn")

        clock.addTimeInterval(5)
        running = true
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"])
    }

    /// A rotation that waits for the unlock has no date, so a playlist moved to it forgets the
    /// one it had, and a plan with that trigger starts nothing on its own.
    func testMovingAPlaylistToTheUnlockTriggerDropsItsTimer() async throws {
        store.update("primary") { $0.mode = .rotate; $0.interval = 30 }
        let scheduler = makeScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        await settle()
        XCTAssertNotNil(store.nextChange["primary"])
        store.update("primary") { $0.trigger = .unlock }
        await settle()
        XCTAssertNil(store.nextChange["primary"])

        let plan = try store.savePlan(from: "primary", name: "On unlock")
        displayIDs = ["primary", "second"]
        shown["second"] = "a"
        try store.applyPlan(plan.id, to: "second")
        await settle()
        XCTAssertNil(store.nextChange["second"], "an unlock plan is not due the moment it is applied")
        XCTAssertTrue(applied.isEmpty)
    }

    // MARK: Waiting for the video to finish

    /// Stands in for the video host: the wallpapers in `videos` are clips with an end, and each
    /// watch stays until the test says its clip started over.
    @MainActor
    private final class ClipWatcher {
        var videos: Set<String> = []
        private(set) var watches: [String: (wallpaper: String, ended: @MainActor () -> Void)] = [:]
        private(set) var started = 0
        private(set) var cancelled = 0

        func watch(
            _ display: String, _ wallpaper: String, _ ended: @escaping @MainActor () -> Void
        ) -> (@MainActor () -> Void)? {
            guard videos.contains(wallpaper) else { return nil }
            started += 1
            watches[display] = (wallpaper, ended)
            return { [weak self] in
                self?.cancelled += 1
                self?.watches[display] = nil
            }
        }

        /// The clip on `display` starts over.
        func finish(_ display: String) {
            watches.removeValue(forKey: display)?.ended()
        }
    }

    private var watcher: ClipWatcher!

    /// A rotation every 30 minutes that waits for videos, on a display playing the video "a".
    private func makeWaitingScheduler(
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
    ) -> PlaylistScheduler {
        store.update("primary") {
            $0.mode = .rotate
            $0.interval = 30
            $0.waitsForClipEnd = true
        }
        watcher.videos = ["a"]
        return makeScheduler(watchClipEnd: watcher.watch, sleep: sleep)
    }

    /// Waits, five seconds at most, for `condition`: the scheduler's timer sleeps off the main
    /// actor, so yielding alone does not let it run.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testADueChangeWaitsForTheVideoToStartOverAndTheNextIntervalCountsFromThen() async {
        let scheduler = makeWaitingScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "the clip playing is not cut")
        XCTAssertEqual(watcher.watches["primary"]?.wallpaper, "a")
        let limit = clock.addingTimeInterval(PlaylistScheduler.clipEndLimit(minutes: 30))
        XCTAssertEqual(store.clipWaits["primary"], limit, "the panel is told the change waits, and until when")

        clock.addTimeInterval(40)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(watcher.started, 1, "one watch for the wait, not one per evaluation")
        XCTAssertEqual(store.clipWaits["primary"], limit)

        watcher.finish("primary")
        await settle()
        XCTAssertEqual(applied, ["b"], "the change happens as the clip ends")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(30 * 60))
        XCTAssertNil(store.clipWaits["primary"])

        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b", "c"], "a wallpaper that is not a video changes on time")
        XCTAssertEqual(watcher.started, 1)
    }

    func testWithoutTheOptionAVideoChangesOnTime() async {
        store.update("primary") { $0.mode = .rotate; $0.interval = 30 }
        watcher.videos = ["a"]
        let scheduler = makeScheduler(watchClipEnd: watcher.watch)
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"])
        XCTAssertEqual(watcher.started, 0, "nothing is watched while the option is off")
    }

    /// The deadline and the limit both arrive through the scheduler's own timer, which the test
    /// fires by hand, so the change at the limit is one the scheduler woke itself for.
    func testAClipThatDoesNotFinishIsChangedOnceTheWaitReachesItsLimit() async throws {
        XCTAssertEqual(PlaylistScheduler.clipEndLimit(minutes: 5), 10 * 60, "a short interval still waits ten minutes")
        XCTAssertEqual(PlaylistScheduler.clipEndLimit(minutes: 30), 30 * 60)
        XCTAssertEqual(PlaylistScheduler.clipEndLimit(minutes: 1440), 60 * 60, "never longer than an hour")
        let timer = ManualSleeper()
        let scheduler = makeWaitingScheduler(sleep: { try await timer.sleep(.seconds($0)) })
        store.update("primary") { $0.interval = 5 }
        scheduler.start()
        defer { scheduler.stop() }
        try await waitUntil { timer.pendingCount == 1 }
        clock.addTimeInterval(5 * 60)
        XCTAssertTrue(timer.fireNext())
        try await waitUntil { timer.pendingCount == 1 }
        XCTAssertTrue(applied.isEmpty, "the clip playing is not cut")
        XCTAssertEqual(timer.requested, [.seconds(5 * 60), .seconds(10 * 60)], "the timer is armed for the wait's limit")

        clock.addTimeInterval(10 * 60 - 1)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "up to the limit the clip may still finish")
        clock.addTimeInterval(1)
        XCTAssertTrue(timer.fireNext())
        try await waitUntil { applied == ["b"] }
        XCTAssertEqual(applied, ["b"], "a long or stalled clip cannot hold the rotation")
        XCTAssertEqual(watcher.cancelled, 1, "and is no longer watched")
        XCTAssertNil(store.clipWaits["primary"])
    }

    func testAPauseEndsTheWaitAndPlayingAgainWaitsForTheClipOnceMore() async {
        let scheduler = makeWaitingScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        running = false
        clock.addTimeInterval(2 * 60 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "nothing changes while wallpapers are paused, as before")
        XCTAssertNil(watcher.watches["primary"], "a paused clip is not watched")
        XCTAssertNil(store.clipWaits["primary"], "nor said to be waited for")

        running = true
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(applied.isEmpty, "playing again does not cut the clip either")
        XCTAssertEqual(watcher.started, 2)
        watcher.finish("primary")
        await settle()
        XCTAssertEqual(applied, ["b"])
    }

    func testAVideoOutOfSightChangesBehindTheWindowsWithoutWaiting() async {
        let scheduler = makeWaitingScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        running = false
        unseen = true
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"], "nobody sees the clip cut")
        XCTAssertEqual(watcher.started, 0)
    }

    func testAWallpaperChosenByHandEndsTheWait() async throws {
        let scheduler = makeWaitingScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        let ended = try XCTUnwrap(watcher.watches["primary"]?.ended)
        shown["primary"] = "c"
        scheduler.noteManualChoice("primary")
        await settle()
        XCTAssertEqual(watcher.cancelled, 1)
        ended()
        await settle()
        XCTAssertTrue(applied.isEmpty, "the end of a clip that is gone changes nothing")
        XCTAssertEqual(store.nextChange["primary"], clock.addingTimeInterval(PlaylistScheduler.manualGrace))
    }

    func testChangeNowWhileTheChangeWaitsChangesAtOnce() async {
        let scheduler = makeWaitingScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        XCTAssertTrue(scheduler.skip("primary"))
        await settle()
        XCTAssertEqual(applied, ["b"])
        XCTAssertEqual(watcher.cancelled, 1)
    }

    func testTurningTheOptionOffWhileTheChangeWaitsChangesAtOnce() async {
        let scheduler = makeWaitingScheduler()
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        store.update("primary") { $0.waitsForClipEnd = false }
        scheduler.evaluate()
        await settle()
        XCTAssertEqual(applied, ["b"])
        XCTAssertNil(watcher.watches["primary"])
    }

    /// The video host reports the end of one display's own clip; a second report of it, or the end
    /// of another display's clip, changes nothing more.
    func testEachDisplayChangesOnceForTheEndOfItsOwnClip() async throws {
        displayIDs = ["primary", "second"]
        shown["second"] = "a"
        let scheduler = makeWaitingScheduler()
        store.update("second") {
            $0.mode = .rotate
            $0.interval = 30
            $0.waitsForClipEnd = true
        }
        scheduler.start()
        defer { scheduler.stop() }
        clock.addTimeInterval(30 * 60)
        scheduler.evaluate()
        await settle()
        let ended = try XCTUnwrap(watcher.watches["primary"]?.ended)
        ended()
        ended()
        await settle()
        XCTAssertEqual(applied, ["b"], "one change for one end")
        XCTAssertEqual(shown["second"], "a", "the other display still waits for its clip")
        XCTAssertNotNil(watcher.watches["second"])
    }
}
