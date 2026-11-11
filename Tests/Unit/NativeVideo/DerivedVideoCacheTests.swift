import AVFoundation
import Darwin
import XCTest

@testable import WallpaperMachine

/// The playable copies of `hev1` clips: made beside nothing in the library, reused while the file
/// is the same, held while something reads them, and removed when the file changes, its wallpaper
/// goes, room is needed or the caches are cleared.
final class DerivedVideoCacheTests: XCTestCase {
    private var root: URL!
    private var folder: URL { root.appendingPathComponent("DerivedVideos", isDirectory: true) }
    private var library: URL { root.appendingPathComponent("Library", isDirectory: true) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("derived-videos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// Counts the copies it was asked to check, and answers `plays`, after `gate` opens when one is
    /// set; throws `failure` instead when one is set, as a read error in the copy would.
    private final class Verifier: @unchecked Sendable {
        private let lock = NSLock()
        private var _checked = 0
        var plays = true
        var failure: Error?
        var gate: AsyncGate?
        var checked: Int { lock.withLock { _checked } }
        func check(_ url: URL) async throws -> Bool {
            lock.withLock { _checked += 1 }
            await gate?.wait()
            if let failure { throw failure }
            return plays
        }
    }

    /// What the startup disk has free, changed by the test as it goes.
    private final class FreeSpace: @unchecked Sendable {
        private let lock = NSLock()
        private var _bytes: Int64
        init(_ bytes: Int64) { _bytes = bytes }
        var bytes: Int64 {
            get { lock.withLock { _bytes } }
            set { lock.withLock { _bytes = newValue } }
        }
    }

    /// A cache in this test's folder, as a new session of the app would have it. AVFoundation is
    /// taken to refuse the clip as it is (`playsAsItIs`), as this macOS does.
    private func makeCache(
        capacity: Int = 8, copyBudget: Int64 = 1 << 30, available: Int64 = 1 << 40,
        freeSpace: FreeSpace? = nil, cloneError: Int32? = nil, verifier: Verifier? = nil,
        playsAsItIs: Bool = false
    ) -> DerivedVideoCache {
        let folder = self.folder
        let verify: @Sendable (URL) async throws -> Bool
        if let verifier {
            verify = { try await verifier.check($0) }
        } else {
            verify = DerivedVideoCache.playsInAVFoundation
        }
        return DerivedVideoCache(
            folder: { folder }, capacity: capacity, copyBudget: copyBudget, freeSpaceReserve: 1 << 20,
            clone: { cloneError ?? DerivedVideoCache.cloneFile($0, $1) },
            availableCapacity: { _ in freeSpace?.bytes ?? available }, verify: verify,
            playsAsItIs: { _ in playsAsItIs })
    }

    /// The embedded `hev1` clip as wallpaper `id`'s file.
    private func clip(_ id: String) throws -> URL {
        let directory = library.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try Hev1Fixture.write(name: "clip", into: directory)
    }

    private func plan(_ url: URL) throws -> HevcSampleEntryRetag.Plan {
        guard case let .retag(plan) = try HevcSampleEntryRetag.inspect(url: url) else {
            throw XCTSkip("the fixture is not an hev1 clip with its parameter sets")
        }
        return plan
    }

    private func copies() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func prepared(_ cache: DerivedVideoCache, _ source: URL) async throws -> URL {
        try await cache.prepare(source: source, plan: plan(source)).get()
    }

    /// The copy a player is handed for `source`, held until the lease goes.
    private func held(_ cache: DerivedVideoCache, _ source: URL) throws -> DerivedVideoCache.Lease {
        let file = cache.playableFile(for: source)
        guard case let .copy(lease) = file else { throw NoCopy(file: "\(file)") }
        return lease
    }

    private struct NoCopy: Error { var file: String }

    private func isOriginal(_ file: DerivedVideoCache.PlayableFile) -> Bool {
        if case .original = file { return true }
        return false
    }

    private func isGone(_ file: DerivedVideoCache.PlayableFile) -> Bool {
        if case .gone = file { return true }
        return false
    }

    /// Changes what the file's stamp says, as a replaced download does.
    private func replace(_ url: URL, modified: Date = Date(timeIntervalSince1970: 1_000_000)) throws {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    // MARK: - Making a copy

    func testTheCopyPlaysAndTheFileInTheLibraryIsUntouched() async throws {
        let source = try clip("w1")
        if try await DerivedVideoCache.playsInAVFoundation(source) {
            throw XCTSkip("this macOS plays hev1 itself, so nothing needs a copy")
        }
        let before = try Data(contentsOf: source)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let copy = try await prepared(makeCache(), source)
        XCTAssertEqual(try Data(contentsOf: source), before, "the library's file is not written")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date,
            attributes[.modificationDate] as? Date)
        XCTAssertEqual(try HevcSampleEntryRetag.inspect(url: source), .retag(try plan(source)))
        XCTAssertEqual(try HevcSampleEntryRetag.inspect(url: copy), .none, "the copy has no hev1 left")
        XCTAssertTrue(copy.path.hasPrefix(folder.path + "/"))
        let playable = try await DerivedVideoCache.playsInAVFoundation(copy)
        XCTAssertTrue(playable, "AVFoundation plays the retagged copy")
    }

    func testTheCopyIsReusedWhileTheFileIsUnchangedAndMadeAgainWhenItChanges() async throws {
        let source = try clip("w1")
        let verifier = Verifier()
        let cache = makeCache(verifier: verifier)
        let first = try await prepared(cache, source)
        let again = try await prepared(cache, source)
        XCTAssertEqual(again, first)
        XCTAssertEqual(verifier.checked, 1, "an existing copy is not checked again")
        XCTAssertEqual(try held(cache, source).url, first)

        try replace(source)
        XCTAssertTrue(isGone(cache.playableFile(for: source)),
                      "a replaced file is played neither from the old copy nor as it is")
        let replaced = try await prepared(cache, source)
        XCTAssertNotEqual(replaced, first)
        XCTAssertEqual(verifier.checked, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the old copy is gone")
        XCTAssertEqual(copies(), [replaced.lastPathComponent])
        XCTAssertEqual(try held(cache, source).url, replaced)
    }

    func testOnlyAFileThisSessionPreparedIsPlayedFromACopy() async throws {
        let source = try clip("w1")
        let copy = try await prepared(makeCache(verifier: Verifier()), source)
        let later = makeCache(verifier: Verifier())
        XCTAssertTrue(isOriginal(later.playableFile(for: source)), "nothing was asked of this session yet")
        let taken = try await prepared(later, source)
        XCTAssertEqual(taken, copy, "the copy on disk is taken")
        XCTAssertEqual(try held(later, source).url, copy)
        let other = try clip("w2")
        XCTAssertTrue(isOriginal(later.playableFile(for: other)), "a file that needed no copy plays as it is")
        later.forget(source)
        XCTAssertTrue(isOriginal(later.playableFile(for: source)), "nor one judged again that needs none")
    }

    func testACopyThatStillDoesNotPlayIsNotKept() async throws {
        let source = try clip("w1")
        let verifier = Verifier()
        verifier.plays = false
        let cache = makeCache(verifier: verifier)
        let result = await cache.prepare(source: source, plan: try plan(source))
        XCTAssertEqual(result, .failure(.notPlayable))
        XCTAssertEqual(copies(), [], "no copy and nothing unfinished is left")
        XCTAssertTrue(isOriginal(cache.playableFile(for: source)))
        let again = await cache.prepare(source: source, plan: try plan(source))
        XCTAssertEqual(again, .failure(.notPlayable))
        XCTAssertEqual(verifier.checked, 1, "the same file is not copied again to find the same")
    }

    func testAFileThatCannotBeClonedIsCopiedInTheBackground() async throws {
        let source = try clip("w1")
        let size = Int64(try Data(contentsOf: source).count)
        let verifier = Verifier()
        let gate = AsyncGate()
        verifier.gate = gate
        let cache = makeCache(cloneError: EXDEV, verifier: verifier)
        let asked = await cache.prepare(source: source, plan: try plan(source), waiting: false)
        XCTAssertEqual(asked, .failure(.copying), "the caller is not kept waiting for a full copy")
        let again = await cache.prepare(source: source, plan: try plan(source), waiting: false)
        XCTAssertEqual(again, .failure(.copying))
        await gate.waitUntilWaiting()
        XCTAssertTrue(isOriginal(cache.playableFile(for: source)), "nothing is handed out before it is done")

        let done = expectation(forNotification: DerivedVideoCache.copiesChanged, object: cache)
        done.assertForOverFulfill = false
        gate.open()
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(verifier.checked, 1, "one copy was made for both requests")
        let copy = try await prepared(cache, source)
        XCTAssertEqual(try HevcSampleEntryRetag.inspect(url: copy), .none)
        XCTAssertEqual(Int64(try Data(contentsOf: copy).count), size)
        // A later session clears it, and its bytes are what that frees.
        XCTAssertEqual(makeCache(verifier: Verifier()).removeUnused(), size)
        XCTAssertEqual(copies(), [])
    }

    func testAWaitForAFullCopyEndsWithItsTaskWhileTheCopyGoesOn() async throws {
        let source = try clip("w1")
        let verifier = Verifier()
        let gate = AsyncGate()
        verifier.gate = gate
        let cache = makeCache(cloneError: EXDEV, verifier: verifier)
        let plan = try plan(source)
        let waiting = Task { await cache.prepare(source: source, plan: plan, waiting: true) }
        await gate.waitUntilWaiting()
        waiting.cancel()
        let cancelled = await waiting.value
        guard case .failure(.unreadable) = cancelled else { return XCTFail("expected the wait to end, got \(cancelled)") }
        gate.open()
        let copy = try await prepared(cache, source)
        XCTAssertEqual(verifier.checked, 1, "the copy that was under way is the one handed out")
        XCTAssertEqual(try HevcSampleEntryRetag.inspect(url: copy), .none)
    }

    func testAFullCopyIsRefusedWhenItWouldNotFit() async throws {
        let source = try clip("w1")
        let size = Int64(try Data(contentsOf: source).count)
        let tooLarge = await makeCache(copyBudget: size - 1, cloneError: EXDEV, verifier: Verifier())
            .prepare(source: source, plan: try plan(source))
        XCTAssertEqual(tooLarge, .failure(.noRoomForCopy(.tooLarge)), "larger than the whole budget")
        let full = await makeCache(available: size, cloneError: ENOTSUP, verifier: Verifier())
            .prepare(source: source, plan: try plan(source))
        XCTAssertEqual(full, .failure(.noRoomForCopy(.notNow)), "the startup disk keeps its reserve")
        XCTAssertEqual(copies(), [])
    }

    func testAFullCopyThatWouldNotFitTakesNoOtherCopyWithIt() async throws {
        let first = try clip("w1")
        let second = try clip("w2")
        let size = Int64(try Data(contentsOf: first).count)
        let freeSpace = FreeSpace(1 << 40)
        let cache = makeCache(copyBudget: size, freeSpace: freeSpace, cloneError: EXDEV, verifier: Verifier())
        let earlier = try await prepared(cache, first)
        // The second copy would take the first one's room, but the startup disk has none to spare
        // even with it, so the first stays.
        freeSpace.bytes = 0
        let refused = await cache.prepare(source: second, plan: try plan(second))
        XCTAssertEqual(refused, .failure(.noRoomForCopy(.notNow)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: earlier.path), "nothing was removed for nothing")
        let lease = try held(cache, first)
        XCTAssertEqual(lease.url, earlier)
        lease.release()
    }

    func testAFullCopyThatFailsIsToldAndNotStartedAgainUntilItIsAskedFor() async throws {
        // A read error on the library's drive: the caller that was told the copy is being made
        // learns that it failed, and nothing starts the same copy again on its own.
        let source = try clip("w1")
        let verifier = Verifier()
        verifier.failure = CocoaError(.fileReadUnknown)
        let gate = AsyncGate()
        verifier.gate = gate
        let cache = makeCache(cloneError: EXDEV, verifier: verifier)
        XCTAssertEqual(cache.progress(ofCopyOf: source), .unknown)
        let asked = await cache.prepare(source: source, plan: try plan(source), waiting: false)
        XCTAssertEqual(asked, .failure(.copying))
        await gate.waitUntilWaiting()
        XCTAssertEqual(cache.progress(ofCopyOf: source), .making)

        let ended = expectation(forNotification: DerivedVideoCache.copiesChanged, object: cache)
        ended.assertForOverFulfill = false
        gate.open()
        await fulfillment(of: [ended], timeout: 10)
        guard case .failed(.unreadable) = cache.progress(ofCopyOf: source) else {
            return XCTFail("the failure is told, got \(cache.progress(ofCopyOf: source))")
        }
        XCTAssertEqual(copies(), [], "nothing is left of it")
        XCTAssertTrue(isOriginal(cache.playableFile(for: source)), "nothing was handed out")
        XCTAssertEqual(verifier.checked, 1, "the copy was made once")

        // Asked for again, it is made again.
        verifier.failure = nil
        let copy = try await prepared(cache, source)
        XCTAssertEqual(verifier.checked, 2)
        XCTAssertEqual(cache.progress(ofCopyOf: source), .made)
        XCTAssertEqual(try held(cache, source).url, copy)
    }

    func testACloneThatFailsForAnotherReasonSaysNothingAboutTheFormat() async throws {
        let source = try clip("w1")
        let denied = await makeCache(cloneError: EACCES, verifier: Verifier())
            .prepare(source: source, plan: try plan(source))
        guard case .failure(.unreadable) = denied else { return XCTFail("expected unreadable, got \(denied)") }
        let missing = await makeCache(verifier: Verifier()).prepare(
            source: library.appendingPathComponent("gone.mp4"), plan: .init(offsets: [0]))
        guard case .failure(.unreadable) = missing else { return XCTFail("expected unreadable, got \(missing)") }
    }

    func testAFullCopyNothingHoldsMakesRoomForAnotherAndAHeldOneDoesNot() async throws {
        let first = try clip("w1")
        let second = try clip("w2")
        let third = try clip("w3")
        let size = Int64(try Data(contentsOf: first).count)
        let cache = makeCache(copyBudget: size, cloneError: EXDEV, verifier: Verifier())
        let earlier = try await prepared(cache, first)
        // The first clip is no longer shown: its copy is not held, so the second takes its room.
        let copy = try await prepared(cache, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: earlier.path), "the budget holds one full copy")
        XCTAssertEqual(copies(), [copy.lastPathComponent])
        XCTAssertTrue(isGone(cache.playableFile(for: first)), "its file is not played without it")

        let playing = try held(cache, second)
        let refused = await cache.prepare(source: third, plan: try plan(third))
        XCTAssertEqual(refused, .failure(.noRoomForCopy(.notNow)), "a copy being read is never taken")
        XCTAssertTrue(FileManager.default.fileExists(atPath: playing.url.path))

        let released = expectation(forNotification: DerivedVideoCache.copiesChanged, object: cache)
        released.assertForOverFulfill = false
        playing.release()
        await fulfillment(of: [released], timeout: 1)
        let made = try await prepared(cache, third)
        XCTAssertEqual(copies(), [made.lastPathComponent], "once let go, it makes room again")
    }

    // MARK: - Bounds and removal

    func testTheCacheKeepsItsCapacityByDroppingTheLeastRecentlyUsed() async throws {
        let sources = try ["w1", "w2", "w3", "w4", "w5"].map(clip)
        let session = makeCache(capacity: 2, verifier: Verifier())
        let older = try await prepared(session, sources[0])
        let oldest = try await prepared(session, sources[1])
        let manager = FileManager.default
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: older.path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: oldest.path)
        let next = makeCache(capacity: 2, verifier: Verifier())
        let third = try await prepared(next, sources[2])
        XCTAssertEqual(copies(), [older.lastPathComponent, third.lastPathComponent].sorted(),
                       "the copy used longest ago went")
        // What is being read stays, even past the capacity.
        let leases = try [held(next, sources[2])]
        let fourth = try await prepared(next, sources[3])
        let more = try leases + [held(next, sources[3])]
        let fifth = try await prepared(next, sources[4])
        XCTAssertEqual(copies(), [third, fourth, fifth].map(\.lastPathComponent).sorted())
        more.forEach { $0.release() }
    }

    func testDeletingAWallpaperRemovesTheCopiesOfItsFilesOnly() async throws {
        let cache = makeCache(verifier: Verifier())
        let deleted = try await prepared(cache, try clip("w1"))
        let kept = try await prepared(cache, try clip("w2"))
        cache.removeCopies(under: library.appendingPathComponent("w1", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        // The folder put back from the Trash: its clip still plays only from a copy, made again.
        let restored = library.appendingPathComponent("w1/clip.mp4")
        XCTAssertTrue(isGone(cache.playableFile(for: restored)), "a restored clip is not played as it is")
        let again = try await prepared(cache, restored)
        XCTAssertEqual(try held(cache, restored).url, again)
    }

    func testClearingRemovesWhatNothingHoldsAndKeepsWhatIsBeingRead() async throws {
        let unused = try await prepared(makeCache(verifier: Verifier()), try clip("w1"))
        let session = makeCache(verifier: Verifier())
        let gone = try clip("w2")
        let orphaned = try await prepared(session, gone)
        let shownBefore = try clip("w3")
        let released = try await prepared(session, shownBefore)
        try held(session, shownBefore).release()
        let playing = try clip("w4")
        let read = try await prepared(session, playing)
        let lease = try held(session, playing)
        try FileManager.default.removeItem(at: gone)
        try Data("leftover".utf8).write(to: folder.appendingPathComponent(".interrupted-copy.mp4"))
        try Data("stray".utf8).write(to: folder.appendingPathComponent("no-record.mp4"))

        let cleared = expectation(forNotification: DerivedVideoCache.copiesChanged, object: session)
        cleared.assertForOverFulfill = false
        XCTAssertEqual(session.removeUnused(), 0, "clones hold no bytes of their own")
        await fulfillment(of: [cleared], timeout: 1)
        for removed in [unused, orphaned, released] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path), removed.lastPathComponent)
        }
        XCTAssertEqual(copies(), [read.lastPathComponent], "only the copy a player is reading stays")
        XCTAssertTrue(isGone(session.playableFile(for: shownBefore)), "a cleared clip is not played as it is")
        let again = try await prepared(session, shownBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.path), "its copy is made again")
        lease.release()
    }

    func testACopyBeingReadStaysWhileItsFileIsAwayForAMoment() async throws {
        // A library drive that was ejected: the file cannot be read, and nothing may take the copy
        // a player is reading.
        let cache = makeCache(verifier: Verifier())
        let source = try clip("w1")
        let copy = try await prepared(cache, source)
        let lease = try held(cache, source)
        let away = root.appendingPathComponent("away.mp4")
        try FileManager.default.moveItem(at: source, to: away)
        XCTAssertEqual(cache.removeUnused(), 0)
        _ = try await prepared(cache, try clip("w2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "neither clearing nor a sweep took it")

        try FileManager.default.moveItem(at: away, to: source)
        let again = try held(cache, source)
        XCTAssertEqual(again.url, copy, "the copy plays again once the file is back")
        lease.release()
        again.release()
    }

    // MARK: - Reading

    func testAReadIsGivenTheCopyOfAnHev1ClipAndAnyOtherFileItself() async throws {
        let cache = makeCache(verifier: Verifier())
        let source = try clip("w1")
        let read = try await cache.reading(source, keepingCopy: false) { url -> URL in
            XCTAssertEqual(try HevcSampleEntryRetag.inspect(url: url), .none, "it reads a retagged copy")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            return url
        }
        XCTAssertTrue(read.path.hasPrefix(folder.path + "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: read.path), "a copy made for the read alone goes")
        XCTAssertTrue(isOriginal(cache.playableFile(for: source)))

        let kept = try await cache.reading(source) { $0 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "kept for the players otherwise")

        let other = library.appendingPathComponent("plain.mov")
        try Data("not a movie".utf8).write(to: other)
        let itself = try await cache.reading(other) { $0 }
        XCTAssertEqual(itself, other)
    }

    func testAReadOfAnHev1ClipAVFoundationPlaysAsItIsTakesTheFileItself() async throws {
        // A macOS that decodes hev1 needs no copy, as the format check decides.
        let verifier = Verifier()
        let cache = makeCache(verifier: verifier, playsAsItIs: true)
        let source = try clip("w1")
        let read = try await cache.reading(source) { $0 }
        XCTAssertEqual(read, source)
        XCTAssertEqual(copies(), [], "no copy was made")
        XCTAssertEqual(verifier.checked, 0)
    }
}
