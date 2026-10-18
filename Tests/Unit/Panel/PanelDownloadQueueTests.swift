import XCTest

@testable import WallpaperMachine

/// What the title bar's Downloads button and the popover say about the batch: one job's own
/// figures, or the mean progress and summed speed of several, with the slowest job's estimate only
/// when every job has one.
@MainActor
final class PanelDownloadQueueTests: MediaPanelTestCase {
  private func running(
    _ id: String = "one", progress: Double? = 0.4, speed: Double? = 600_000,
    remaining: Int? = nil, status: String = "Downloading Workshop files…"
  ) -> DownloadRow {
    DownloadRow(
      id: id, wallpaperID: id, title: id, status: status, progress: progress, isPending: true,
      bytesReceived: progress == nil ? nil : 400, bytesExpected: progress == nil ? nil : 1_000,
      bytesPerSecond: speed, secondsRemaining: remaining)
  }

  private func queue(
    steam: [DownloadRow] = [], pixiv: [DownloadRow] = [], requests: [DownloadRequestRow] = [],
    slots: Int = 3
  ) -> DownloadQueue {
    DownloadQueue.make(
      requests: requests, steam: steam, pixiv: pixiv, slotLimit: slots, locale: english)
  }

  func testNothingToListHidesTheButtonAndSaysSo() {
    let empty = queue()
    XCTAssertFalse(empty.isVisible)
    XCTAssertEqual(empty.summary, "No downloads")
    XCTAssertEqual(empty.count, 0)
    XCTAssertFalse(empty.showsRing)
    XCTAssertEqual(empty.emptyMessage, "No downloads yet. Pick a Workshop wallpaper and choose Download.")
  }

  func testADownloadWithoutMeasuredBytesRingsWithoutAValueAndShowsTheSpeedAndNoPercent() {
    let state = queue(steam: [running(progress: nil)])
    XCTAssertTrue(state.showsRing)
    XCTAssertNil(state.progress, "an indeterminate ring is drawn while no job has a figure")
    XCTAssertNil(state.percent)
    XCTAssertEqual(state.summary, "Downloading Workshop files… · Network speed: 600 KB/s")
    XCTAssertEqual(
      state.buttonLabel, "Downloads: Downloading Workshop files… · Network speed: 600 KB/s")
  }

  func testAMeasuredIdleRateReadsZeroAndAnUnavailableOneIsOmitted() {
    XCTAssertEqual(
      queue(steam: [running(progress: nil, speed: 0)]).summary,
      "Downloading Workshop files… · Network speed: 0 B/s")
    XCTAssertEqual(
      queue(steam: [running(progress: nil, speed: nil)]).summary, "Downloading Workshop files…")
    XCTAssertEqual(
      queue(steam: [running(progress: nil, speed: nil, status: "Validating and adding to your library…")])
        .summary,
      "Validating and adding to your library…",
      "the validating phase shows its status without a network speed")
  }

  func testBytesThatAreKnownDriveADeterminateRingAndAPercent() {
    let assets = DownloadRow(
      id: "scene-assets", title: "Scene assets", status: "Downloading Wallpaper Engine files…",
      progress: 0.25, isPending: true, bytesReceived: 250, bytesExpected: 1_000)
    let state = queue(steam: [assets])
    XCTAssertEqual(state.progress, 0.25)
    XCTAssertEqual(state.percent, 25)
    XCTAssertEqual(state.summary, "Downloading Wallpaper Engine files… · 25%")
  }

  func testTimeLeftShowsOnlyWhenEveryRunningJobHasAnEstimate() {
    func summary(_ jobs: [DownloadRow]) -> String { queue(steam: jobs).summary }
    XCTAssertFalse(summary([running(remaining: nil)]).contains(" left"), "no estimate, no time left")
    XCTAssertTrue(summary([running(remaining: 45)]).hasSuffix("45 sec left"))
    XCTAssertTrue(summary([running(remaining: 600)]).hasSuffix("10 min left"))
    XCTAssertTrue(summary([running(remaining: 9_000)]).hasSuffix("2.5 hr left"))

    let slowest = queue(steam: [running("one", remaining: 600), running("two", remaining: 120)])
    XCTAssertTrue(slowest.summary.hasPrefix("2 downloading"))
    XCTAssertTrue(slowest.summary.hasSuffix("10 min left"), "several jobs finish when the slowest does")
    XCTAssertEqual(slowest.secondsRemaining, 600)

    let unknown = queue(steam: [running("one", remaining: 600), running("two", remaining: nil)])
    XCTAssertTrue(unknown.summary.hasPrefix("2 downloading"))
    XCTAssertFalse(unknown.summary.contains(" left"), "one job without an estimate hides the batch's")
    XCTAssertNil(unknown.secondsRemaining)
  }

  func testSeveralRunningJobsShowTheirMeanProgressAndSummedSpeed() {
    let state = queue(steam: [
      running("one", progress: 0.2, speed: 600_000), running("two", progress: 0.6, speed: 600_000),
      running("three", progress: nil, speed: nil),
    ])
    XCTAssertEqual(state.progress ?? 0, 0.4, accuracy: 0.0001, "only jobs with a figure count toward the mean")
    XCTAssertEqual(state.bytesPerSecond, 1_200_000)
    XCTAssertEqual(state.summary, "3 downloading · 40% · Network speed: 1.2 MB/s")
  }

  func testWaitingJobsRequestsAndFinishedOnesAreCountedAndSummarisedInThatOrder() {
    let waiting = DownloadRow(id: "w", title: "W", isPending: true, isQueued: true)
    let finished = DownloadRow(id: "f", title: "F")
    let request = DownloadRequestRow(id: "r", title: "R", stage: .setup)
    XCTAssertEqual(queue(steam: [waiting]).summary, "1 waiting to download")
    XCTAssertEqual(queue(steam: [waiting, waiting]).summary, "2 waiting to download")
    XCTAssertEqual(queue(steam: [finished]).summary, "1 download")
    XCTAssertEqual(queue(steam: [finished, finished]).summary, "2 downloads")
    XCTAssertEqual(queue(requests: [request]).summary, "1 download needs setup")
    XCTAssertEqual(queue(requests: [request, request]).summary, "2 downloads need setup")
    let all = queue(steam: [running(), waiting, finished], requests: [request])
    XCTAssertEqual(all.count, 3, "requests, running and waiting jobs make the badge")
    XCTAssertTrue(all.summary.hasPrefix("Downloading Workshop files…"), "a running job leads the summary")
  }

  func testAFinishedSignInIsNotADownloadButARunningOneIs() {
    let signedIn = DownloadRow(id: WorkshopStore.signInRequestID, title: "Steam sign-in", isSignInOnly: true)
    XCTAssertFalse(queue(steam: [signedIn]).isVisible)
    let signingIn = DownloadRow(
      id: WorkshopStore.signInRequestID, title: "Steam sign-in", isPending: true, isSignInOnly: true)
    XCTAssertTrue(queue(steam: [signingIn]).isVisible)
    XCTAssertEqual(queue(steam: [signingIn]).active.count, 1)
  }

  func testAFailureOrAPromptMarksTheButtonAsNeedingAttention() {
    let failed = DownloadRow(id: "a", title: "A", errorMessage: "Steam denied this download.")
    let asking = DownloadRow(id: "b", title: "B", isPending: true, prompt: .password)
    XCTAssertTrue(queue(steam: [failed]).needsAttention)
    XCTAssertTrue(queue(steam: [asking]).needsAttention)
    XCTAssertFalse(queue(steam: [running()]).needsAttention)
    XCTAssertEqual(
      queue(steam: [failed]).buttonLabel, "Downloads: 1 download · needs attention")
  }

  func testPixivSavesJoinTheSharedQueueAndHaveNoSpeedOrEstimate() throws {
    let work = PixivWork(
      id: "301", title: "Sky", authorID: "1", authorName: "Artist", thumbnailURL: nil, width: 1, height: 1,
      pageCount: 2, rating: .everyone, aiGenerated: nil, tags: [], rank: nil)
    let saving = DownloadRow(
      PixivDownloadRow(work: work, pageIndex: 1, status: .downloading, bytesReceived: 200, bytesExpected: 400))
    XCTAssertEqual(saving.source, .pixiv)
    XCTAssertEqual(saving.status, "Downloading")
    XCTAssertEqual(saving.wallpaperID, "pixiv-301-p1")
    XCTAssertNil(saving.bytesPerSecond)
    let state = queue(pixiv: [saving])
    XCTAssertEqual(state.percent, 50)
    XCTAssertEqual(state.summary, "Downloading · 50%")
    XCTAssertEqual(
      state.note, "pixiv downloads run two at a time; paused downloads stay in the queue.")
  }

  func testEveryPixivStatusHasItsSentence() {
    let work = PixivWork(
      id: "1", title: "T", authorID: "1", authorName: "A", thumbnailURL: nil, width: 1, height: 1,
      pageCount: 1, rating: .everyone, aiGenerated: nil, tags: [], rank: nil)
    func sentence(_ status: PixivDownload.Status) -> String {
      DownloadRow(PixivDownloadRow(work: work, pageIndex: 0, status: status)).status
    }
    XCTAssertEqual(sentence(.paused), "Download paused")
    XCTAssertEqual(sentence(.waiting), "Waiting to download")
    XCTAssertEqual(sentence(.installing), "Saving to your library…")
    XCTAssertEqual(sentence(.finished), "In your library")
    XCTAssertEqual(sentence(.failed("pixiv is limiting requests.")), "pixiv is limiting requests.")
    XCTAssertEqual(sentence(.cancelled), "Download cancelled.")
    XCTAssertEqual(sentence(.downloading), "Downloading")
  }

  func testThePopoverKeepsUnresolvedWorkInSightAndCollapsesWhatSucceeded() {
    let paused = DownloadRow(id: "p", title: "P", isPaused: true)
    let failed = DownloadRow(id: "x", title: "X", errorMessage: "Steam denied this download.")
    let cancelled = DownloadRow(id: "c", title: "C", isCancelled: true)
    let done = DownloadRow(id: "d", title: "D")
    let state = queue(steam: [done, paused, running(), failed, cancelled])
    XCTAssertEqual(state.pending.map(\.id), ["one"])
    XCTAssertEqual(state.unresolved.map(\.id), ["p", "x", "c"])
    XCTAssertEqual(state.succeeded.map(\.id), ["d"])
    XCTAssertTrue(state.canClearFinished)
    XCTAssertFalse(queue(steam: [running()]).canClearFinished)
    XCTAssertEqual(queue(steam: [done]).emptyMessage, "All downloads are complete.")
  }

  func testTheFooterNoteSaysHowManyRunAtOnce() {
    let job = running()
    XCTAssertEqual(
      queue(steam: [job], slots: 3).note,
      "Up to 3 downloads run at once and share your saved sign-in; the rest wait in order. Steam may still ask you to approve a sign-in."
    )
    XCTAssertEqual(
      queue(steam: [job], slots: 1).note,
      "Downloads run one at a time; the rest wait in order. Steam may still ask you to approve a sign-in."
    )
    let signIn = DownloadRow(id: WorkshopStore.signInRequestID, title: "S", isSignInOnly: true)
    let work = PixivWork(
      id: "1", title: "T", authorID: "1", authorName: "A", thumbnailURL: nil, width: 1, height: 1,
      pageCount: 1, rating: .everyone, aiGenerated: nil, tags: [], rank: nil)
    let pixiv = DownloadRow(PixivDownloadRow(work: work, pageIndex: 0, status: .paused))
    XCTAssertTrue(
      queue(steam: [signIn], pixiv: [pixiv]).note.hasPrefix("pixiv downloads run two at a time"),
      "a finished sign-in is not a Steam download")
    XCTAssertTrue(queue(steam: [job], pixiv: [pixiv]).note.hasPrefix("Up to 3"))
  }
}
