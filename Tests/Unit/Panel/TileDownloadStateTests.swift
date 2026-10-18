import XCTest

@testable import WallpaperMachine

/// The ring a tile wears over its picture, rule by rule in the order they are tried: a retained
/// request, a queued job, a job waiting for Steam, a running one, a paused one and a failed one.
@MainActor
final class TileDownloadStateTests: MediaPanelTestCase {
  private func job(
    progress: Double? = 0.42, pending: Bool = true, queued: Bool = false, speed: Double? = 600_000
  ) -> DownloadRow {
    DownloadRow(
      id: "ring-fixture", wallpaperID: "ring-fixture", title: "Ring fixture",
      status: "Downloading Workshop files…", account: "fixture", progress: progress,
      isPending: pending, isQueued: queued, bytesPerSecond: speed)
  }

  private func ring(
    request: DownloadRequestRow? = nil, job: DownloadRow?, setupReady: Bool = true
  ) -> TileDownloadState? {
    TileDownloadState.workshop(
      title: "Ring fixture", request: request, job: job, setupIsReady: setupReady, locale: english)
  }

  func testAnUntouchedTileAndAFinishedDownloadWearNoRing() {
    XCTAssertNil(ring(job: nil))
    XCTAssertNil(ring(job: job(progress: 1, pending: false)), "a finished job is the installed check's business")
  }

  func testARunningTransferShowsItsPercentSpeedAndOneClickToCancel() throws {
    let state = try XCTUnwrap(ring(job: job()))
    XCTAssertEqual(state.kind, .progress)
    XCTAssertEqual(state.text, "42%")
    XCTAssertFalse(state.isStepWord)
    XCTAssertEqual(state.speed, "600 KB/s")
    XCTAssertEqual(state.progress, 0.42)
    XCTAssertEqual(state.action, .cancel)
    XCTAssertTrue(state.showsCloseOnHover)
    XCTAssertEqual(state.label, "Downloading 42% at 600 KB/s: Ring fixture. Click to cancel")
  }

  func testSigningInSpinsTheRingAndKeepsTheSpeedAndBeforeBytesMoveNamesTheStep() throws {
    var authenticating = job(progress: nil)
    let spinning = try XCTUnwrap(ring(job: authenticating))
    XCTAssertEqual(spinning.kind, .busy)
    XCTAssertEqual(spinning.text, "", "no percentage and no step word yet")
    XCTAssertEqual(spinning.speed, "600 KB/s", "without a percentage the ring still carries the speed")
    XCTAssertNil(spinning.progress)

    authenticating = DownloadRow(
      id: "ring-fixture", title: "Ring fixture", status: "Waiting for Steam authentication…",
      phase: .signingIn, progress: nil, isPending: true, isAuthenticating: true)
    let phased = try XCTUnwrap(ring(job: authenticating))
    XCTAssertEqual(phased.kind, .busy)
    XCTAssertEqual(phased.text, "Signing in", "before bytes move the ring names the SteamCMD step")
    XCTAssertTrue(phased.isStepWord)
    XCTAssertEqual(phased.phase, .signingIn)
    XCTAssertEqual(phased.speed, "")
    XCTAssertEqual(phased.label, "Waiting for Steam authentication…: Ring fixture. Click to cancel")
  }

  func testATransferMeasuringItsSpeedShowsTheSpeedNotAStepWordUntilThereIsAPercentage() throws {
    let measuring = DownloadRow(
      id: "a", title: "A", phase: .transferring, progress: nil, isPending: true, bytesPerSecond: 1_000)
    XCTAssertEqual(try XCTUnwrap(ring(job: measuring)).text, "")
    let unmeasured = DownloadRow(
      id: "a", title: "A", phase: .transferring, progress: nil, isPending: true)
    let word = try XCTUnwrap(ring(job: unmeasured))
    XCTAssertEqual(word.text, "Downloading")
    XCTAssertTrue(word.isStepWord)
  }

  func testAfterTheLastByteFinishingReplacesAFrozenHundredPercent() throws {
    let finishing = DownloadRow(
      id: "a", title: "A", phase: .finishing, progress: 1, isPending: true)
    let state = try XCTUnwrap(ring(job: finishing))
    XCTAssertEqual(state.kind, .progress)
    XCTAssertEqual(state.progress, 1, "the ring stays full while the files are validated")
    XCTAssertEqual(state.text, "Finishing")
    XCTAssertTrue(state.isStepWord)
  }

  func testAWaitingJobIsDimAndOneClickRemovesItFromTheQueue() throws {
    let state = try XCTUnwrap(ring(job: job(progress: nil, queued: true)))
    XCTAssertEqual(state.kind, .queued)
    XCTAssertEqual(state.glyph, .download)
    XCTAssertEqual(state.action, .cancel)
    XCTAssertTrue(state.showsCloseOnHover)
    XCTAssertEqual(
      state.label, "Ring fixture is waiting to download. Click to remove it from the queue")
  }

  func testAJobWaitingForSteamMarksTheTileAndReopensTheDialog() throws {
    for asking in [
      DownloadRow(id: "a", title: "A", isPending: true, prompt: .password),
      DownloadRow(id: "a", title: "A", isPending: true, challenge: .mobileApproval),
    ] {
      let state = try XCTUnwrap(ring(job: asking))
      XCTAssertEqual(state.kind, .attention)
      XCTAssertEqual(state.glyph, .shield)
      XCTAssertEqual(state.action, .continueSetup)
      XCTAssertEqual(state.label, "Finish the Steam sign-in to download Ring fixture")
    }
  }

  func testAQueuedJobBeatsAPromptAndAPausedJobBeatsAFailure() throws {
    let queuedAndAsking = DownloadRow(
      id: "a", title: "A", isPending: true, isQueued: true, prompt: .password)
    XCTAssertEqual(try XCTUnwrap(ring(job: queuedAndAsking)).kind, .queued)
    let pausedWithError = DownloadRow(
      id: "a", title: "A", isPaused: true, errorMessage: "Steam denied this download.")
    let state = try XCTUnwrap(ring(job: pausedWithError))
    XCTAssertEqual(state.action, .resume)
    XCTAssertEqual(state.label, "Resume download")
  }

  func testARetainedRequestComesBeforeAnyJobAndEitherResumesOrContinuesSetup() throws {
    let waiting = DownloadRequestRow(id: "a", title: "A", stage: .account)
    let state = try XCTUnwrap(ring(request: waiting, job: job()))
    XCTAssertEqual(state.kind, .attention)
    XCTAssertEqual(state.action, .continueSetup)
    XCTAssertEqual(state.label, "Continue setup to download Ring fixture")

    let restored = DownloadRequestRow(id: "a", title: "A", stage: .setup, isPaused: true)
    let resume = try XCTUnwrap(ring(request: restored, job: nil))
    XCTAssertEqual(resume.kind, .queued)
    XCTAssertEqual(resume.glyph, .play)
    XCTAssertEqual(resume.action, .resume)
  }

  func testAFailedOrCancelledDownloadOffersRetryOnlyOnceSteamCMDIsReady() throws {
    let failed = DownloadRow(id: "a", title: "A", errorMessage: "Steam denied this download.")
    let state = try XCTUnwrap(ring(job: failed))
    XCTAssertEqual(state.kind, .failed)
    XCTAssertEqual(state.glyph, .refresh)
    XCTAssertEqual(state.action, .retry)
    XCTAssertTrue(state.isEnabled)
    XCTAssertEqual(state.label, "Steam denied this download. Click to try again")
    XCTAssertFalse(try XCTUnwrap(ring(job: failed, setupReady: false)).isEnabled)

    let cancelled = DownloadRow(id: "a", title: "A", isCancelled: true)
    XCTAssertEqual(
      try XCTUnwrap(ring(job: cancelled)).label, "Download cancelled. Click to try again")
  }

  // MARK: pixiv

  private func work(_ id: String = "301", title: String = "Sky") -> PixivWork {
    PixivWork(
      id: id, title: title, authorID: "1", authorName: "Artist", thumbnailURL: nil, width: 1920,
      height: 1080, pageCount: 3, rating: .everyone, aiGenerated: nil, tags: [], rank: nil)
  }

  private func pixivRing(_ jobs: [PixivDownloadRow], saved: [Int] = []) -> (state: TileDownloadState, jobID: String)? {
    TileDownloadState.pixiv(title: "Sky", jobs: jobs, savedPages: saved)
  }

  func testAPixivTileWearsTheRingOfThePageThatIsUnderWay() throws {
    let downloading = PixivDownloadRow(
      work: work(), pageIndex: 1, status: .downloading, bytesReceived: 250, bytesExpected: 1_000)
    let result = try XCTUnwrap(pixivRing([downloading]))
    XCTAssertEqual(result.jobID, "pixiv-301-p1")
    XCTAssertEqual(result.state.kind, .progress)
    XCTAssertEqual(result.state.text, "25%")
    XCTAssertEqual(result.state.progress, 0.25)
    XCTAssertEqual(result.state.label, "Downloading 25%: Sky. Click to cancel")

    let unknown = PixivDownloadRow(work: work(), pageIndex: 0, status: .downloading)
    let busy = try XCTUnwrap(pixivRing([unknown])).state
    XCTAssertEqual(busy.kind, .busy)
    XCTAssertEqual(busy.label, "Downloading: Sky. Click to cancel")

    let installing = try XCTUnwrap(pixivRing([.init(work: work(), pageIndex: 0, status: .installing)])).state
    XCTAssertEqual(installing.kind, .busy)
    XCTAssertEqual(installing.text, "Finishing")
    XCTAssertEqual(installing.label, "Saving to your library…: Sky. Click to cancel")

    let waiting = try XCTUnwrap(pixivRing([.init(work: work(), pageIndex: 0, status: .waiting)])).state
    XCTAssertEqual(waiting.kind, .queued)
    XCTAssertEqual(waiting.action, .cancel)
  }

  func testAPausedPixivSaveResumesFromItsTileAndAFailedOneOffersRetryUntilThePageIsSaved() throws {
    let paused = PixivDownloadRow(work: work(), pageIndex: 1, status: .paused)
    let resume = try XCTUnwrap(pixivRing([paused])).state
    XCTAssertEqual(resume.action, .resume)
    XCTAssertEqual(resume.label, "Resume download")

    let failed = PixivDownloadRow(work: work(), pageIndex: 0, status: .failed("pixiv is limiting requests."))
    let retry = try XCTUnwrap(pixivRing([failed])).state
    XCTAssertEqual(retry.action, .retry)
    XCTAssertEqual(retry.label, "pixiv is limiting requests. Click to try again")
    XCTAssertNil(pixivRing([failed], saved: [0]), "a retry mark never outlives the page it was for")

    let cancelled = PixivDownloadRow(work: work(), pageIndex: 2, status: .cancelled)
    XCTAssertEqual(
      try XCTUnwrap(pixivRing([cancelled])).state.label, "Download cancelled. Click to try again")
    XCTAssertNil(pixivRing([.init(work: work(), pageIndex: 0, status: .finished)]))
  }

  func testAPendingPixivJobComesBeforeAnEarlierFailedOne() throws {
    let failed = PixivDownloadRow(work: work(), pageIndex: 0, status: .failed("no"))
    let waiting = PixivDownloadRow(work: work(), pageIndex: 1, status: .waiting)
    XCTAssertEqual(try XCTUnwrap(pixivRing([failed, waiting])).jobID, "pixiv-301-p1")
  }
}
