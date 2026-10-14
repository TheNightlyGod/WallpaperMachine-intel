import XCTest

@testable import WallpaperMachine

/// What the inspector reads between clicks: results kept per wallpaper and library revision,
/// one probe at a time, and nothing written by a check that was cancelled.
@MainActor
final class VideoLetterboxStoreTests: XCTestCase {
  private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// The index of this call, counting from zero.
    func next() -> Int {
      lock.lock()
      defer { lock.unlock() }
      value += 1
      return value - 1
    }
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  private var directory: URL!
  private var video: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("video-letterbox-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    video = directory.appendingPathComponent("video.mp4")
    try Data("x".utf8).write(to: video)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
    try super.tearDownWithError()
  }

  private static let letterboxed: VideoLetterboxProbe.FrameSource = { _ in
    LetterboxFixtures.frames(top: 23, bottom: 23)
  }

  private func makeStore(frames: @escaping VideoLetterboxProbe.FrameSource = VideoLetterboxStoreTests.letterboxed,
                         entry: VideoLetterboxStore.EntryResolver? = nil) -> VideoLetterboxStore {
    let url = video!
    return VideoLetterboxStore(probe: VideoLetterboxProbe(frames: frames, timeout: .seconds(600)),
                               entry: entry ?? { _, _ in url })
  }

  /// A frame source whose first call parks until it is cancelled; later calls answer at once.
  private func parkedFirstCall(_ calls: Calls, started: XCTestExpectation) -> VideoLetterboxProbe.FrameSource {
    { _ in
      if calls.next() == 0 {
        started.fulfill()
        try await Task.sleep(for: .seconds(3600))
      }
      return LetterboxFixtures.frames(top: 23, bottom: 23)
    }
  }

  func testResultIsKeptForTheStartingRevisionAndReadsIdleAfterARefresh() async throws {
    let store = makeStore()
    var seen: [VideoLetterboxStore.Phase] = []
    store.onChange = { seen.append(store.phase(for: "a", revision: 3)) }
    await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 3)
    guard case .done(let report) = store.phase(for: "a", revision: 3) else {
      return XCTFail("Expected a finished check, got \(store.phase(for: "a", revision: 3))")
    }
    guard case .bars(let bars) = report.verdict else { return XCTFail("Expected bars, got \(report.verdict)") }
    XCTAssertEqual(bars.top, 23.0 / 180, accuracy: 1.0 / 180)
    XCTAssertEqual(seen.first, .checking, "the panel is told the moment a check starts")
    XCTAssertEqual(seen.last, store.phase(for: "a", revision: 3), "and again when it finishes")
    XCTAssertEqual(store.phase(for: "a", revision: 4), .idle, "the files may have been replaced by the refresh")
    XCTAssertEqual(store.phase(for: "b", revision: 3), .idle)
  }

  func testStartingAnotherWallpapersCheckCancelsTheRunningOneAndStoresOnlyTheNewResult() async throws {
    let started = expectation(description: "first frame source started")
    let store = makeStore(frames: parkedFirstCall(Calls(), started: started))
    let first = Task { await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 1) }
    await fulfillment(of: [started], timeout: 10)
    XCTAssertEqual(store.phase(for: "a", revision: 1), .checking)

    await store.check(wallpaperID: "b", displayID: "7", libraryRevision: 1)
    await first.value
    XCTAssertEqual(store.phase(for: "a", revision: 1), .idle, "the cancelled check writes nothing")
    guard case .done = store.phase(for: "b", revision: 1) else {
      return XCTFail("Expected the second check to finish, got \(store.phase(for: "b", revision: 1))")
    }
  }

  func testSelectingAnotherWallpaperCancelsTheRunningCheckButReselectingKeepsIt() async throws {
    let started = expectation(description: "frame source started")
    let calls = Calls()
    let store = makeStore(frames: parkedFirstCall(calls, started: started))
    let running = Task { await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 1) }
    await fulfillment(of: [started], timeout: 10)

    store.select("a")
    XCTAssertEqual(store.phase(for: "a", revision: 1), .checking, "the same selection leaves the check alone")
    store.select("b")
    XCTAssertEqual(store.phase(for: "a", revision: 1), .idle)
    await running.value
    XCTAssertEqual(store.phase(for: "a", revision: 1), .idle, "nothing is written once cancelled")
    XCTAssertEqual(calls.count, 1)
  }

  func testAskingAgainWhileTheSameCheckRunsDoesNotStartASecondProbe() async throws {
    let started = expectation(description: "frame source started")
    let calls = Calls()
    let store = makeStore(frames: parkedFirstCall(calls, started: started))
    let running = Task { await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 1) }
    await fulfillment(of: [started], timeout: 10)

    await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 1)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(store.phase(for: "a", revision: 1), .checking)
    store.cancelAll()
    await running.value
    XCTAssertEqual(store.phase(for: "a", revision: 1), .idle)
  }

  func testFailureIsStoredAndClearedByASuccessfulRetry() async throws {
    let calls = Calls()
    let store = makeStore(frames: { _ in
      if calls.next() == 0 { throw VideoLetterboxProbe.Failure.noVideoTrack }
      return LetterboxFixtures.frames(top: 23, bottom: 23)
    })
    await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 1)
    XCTAssertEqual(store.phase(for: "a", revision: 1), .failed(.noVideoTrack))
    await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 1)
    guard case .done = store.phase(for: "a", revision: 1) else {
      return XCTFail("Expected the retry to replace the failure, got \(store.phase(for: "a", revision: 1))")
    }
  }

  func testEntryThatCannotBeResolvedFailsTheCheckAndACancelledResolutionWritesNothing() async throws {
    struct Refused: LocalizedError { var errorDescription: String? { "refused" } }
    let refusing = makeStore(entry: { _, _ in throw Refused() })
    await refusing.check(wallpaperID: "a", displayID: "7", libraryRevision: 1)
    XCTAssertEqual(refusing.phase(for: "a", revision: 1), .failed(.unreadable("refused")))

    let cancelled = makeStore(entry: { _, _ in throw CancellationError() })
    await cancelled.check(wallpaperID: "a", displayID: "7", libraryRevision: 1)
    XCTAssertEqual(cancelled.phase(for: "a", revision: 1), .idle)
  }

  func testStoreHoldsAtMostSixteenResultsAndDropsTheOldest() async throws {
    let store = makeStore()
    for index in 0..<17 { await store.check(wallpaperID: "w\(index)", displayID: "7", libraryRevision: 1) }
    XCTAssertEqual(store.phase(for: "w0", revision: 1), .idle)
    for index in 1..<17 {
      guard case .done = store.phase(for: "w\(index)", revision: 1) else { return XCTFail("w\(index) should still be held") }
    }
    // Checking an older wallpaper again makes it the newest, so the next one dropped is w2.
    await store.check(wallpaperID: "w1", displayID: "7", libraryRevision: 1)
    await store.check(wallpaperID: "w17", displayID: "7", libraryRevision: 1)
    XCTAssertEqual(store.phase(for: "w2", revision: 1), .idle)
    guard case .done = store.phase(for: "w1", revision: 1) else { return XCTFail("w1 was checked again and stays") }
  }

  func testConfirmedReportHandsBackTheResultOnlyWhileTheFileIsTheOneThatWasMeasured() async throws {
    let store = makeStore()
    await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 1)
    guard case .done(let measured) = store.phase(for: "a", revision: 1) else { return XCTFail("Expected a finished check") }
    let confirmed = try await store.confirmedReport(wallpaperID: "a", displayID: "7", libraryRevision: 1)
    XCTAssertEqual(confirmed, measured)
    XCTAssertEqual(store.phase(for: "a", revision: 1), .done(measured), "confirming does not consume it")

    try Data("a different, longer video file".utf8).write(to: video)
    do {
      _ = try await store.confirmedReport(wallpaperID: "a", displayID: "7", libraryRevision: 1)
      XCTFail("A replaced file must not be confirmed")
    } catch let error as VideoLetterboxStore.Confirmation {
      XCTAssertEqual(error, .fileChanged)
    }
    XCTAssertEqual(store.phase(for: "a", revision: 1), .idle, "the old measurement is dropped")
  }

  func testConfirmedReportRefusesWhatWasNeverMeasuredAtThisRevision() async throws {
    let calls = Calls()
    let store = makeStore(frames: { _ in
      if calls.next() == 0 { throw VideoLetterboxProbe.Failure.noVideoTrack }
      return LetterboxFixtures.frames(top: 23, bottom: 23)
    })
    func assertNotChecked(_ id: String, revision: UInt64, _ why: String, line: UInt = #line) async {
      do {
        _ = try await store.confirmedReport(wallpaperID: id, displayID: "7", libraryRevision: revision)
        XCTFail("Must refuse: \(why)", line: line)
      } catch let error as VideoLetterboxStore.Confirmation {
        XCTAssertEqual(error, .notChecked, why, line: line)
      } catch {
        XCTFail("Unexpected \(error): \(why)", line: line)
      }
    }
    await assertNotChecked("a", revision: 1, "nothing was checked")
    await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 1)
    await assertNotChecked("a", revision: 1, "the check failed")
    await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 1)
    await assertNotChecked("a", revision: 2, "a result from an older library revision describes files that may be gone")
    await assertNotChecked("b", revision: 1, "another wallpaper")
    _ = try await store.confirmedReport(wallpaperID: "a", displayID: "7", libraryRevision: 1)
  }

  func testConfirmedReportRefusesWhenANewCheckLandsWhileTheFileIsBeingFound() async throws {
    let frames = Calls()
    let entries = Calls()
    let url = video!
    var store: VideoLetterboxStore!
    store = makeStore(
      frames: { _ in
        // The first measurement finds side bars, the one made during the confirmation top and bottom.
        frames.next() == 0 ? LetterboxFixtures.frames(left: 40, right: 40) : LetterboxFixtures.frames(top: 23, bottom: 23)
      },
      entry: { _, _ in
        // The second resolution is the confirmation's own.
        if entries.next() == 1 { await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 1) }
        return url
      })
    await store.check(wallpaperID: "a", displayID: "7", libraryRevision: 1)
    do {
      _ = try await store.confirmedReport(wallpaperID: "a", displayID: "7", libraryRevision: 1)
      XCTFail("The result that was asked for has been replaced")
    } catch let error as VideoLetterboxStore.Confirmation {
      XCTAssertEqual(error, .notChecked)
    }
    guard case .done(let report) = store.phase(for: "a", revision: 1), case .bars(let bars) = report.verdict else {
      return XCTFail("The newer check keeps its result")
    }
    XCTAssertGreaterThan(bars.top, 0)
    XCTAssertEqual(bars.left, 0)
    store.onChange = nil
    store = nil
  }
}
