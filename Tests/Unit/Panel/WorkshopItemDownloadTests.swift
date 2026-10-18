import XCTest

@testable import WallpaperMachine

/// What Discover's inspector offers for an item's download: the primary action by precedence,
/// **Download and apply** only where it can apply, what is pending and why an arrived wallpaper was
/// left alone.
@MainActor
final class WorkshopItemDownloadTests: MediaPanelTestCase {
  private func item(_ id: String = "111", kind: String = "Video", collection: Int? = nil) -> WorkshopItem {
    WorkshopItem(
      id: id, title: "W\(id)", creator: "Test", summary: "", previewURL: nil, tags: [kind], size: 2_048,
      subscriptions: 0, collectionSize: collection)
  }

  private func download(
    _ item: WorkshopItem, request: DownloadRequestRow? = nil, job: DownloadRow? = nil,
    installed: Bool = false, canApply: Bool = true, note: String? = nil
  ) -> WorkshopItemDownload {
    WorkshopItemDownload.make(
      item: item, request: request, job: job, isInstalled: installed, canApplyToTarget: canApply,
      applyNote: note, locale: english)
  }

  private func job(
    _ id: String = "111", pending: Bool = true, queued: Bool = false, progress: Double? = nil,
    paused: Bool = false, error: String? = nil, prompt: WorkshopDownloader.Prompt? = nil,
    applies: Bool = false
  ) -> DownloadRow {
    DownloadRow(
      id: id, wallpaperID: id, title: "W\(id)", status: "Downloading Workshop files…",
      progress: progress, isPending: pending, isQueued: queued, isPaused: paused,
      bytesReceived: progress == nil ? nil : 860, bytesExpected: progress == nil ? nil : 2_048,
      bytesPerSecond: progress == nil ? nil : 600_000, errorMessage: error, prompt: prompt,
      appliesOnArrival: applies)
  }

  /// **Download and apply** sits under Download for a wallpaper that can run and a target display
  /// that can show it, and nowhere else.
  func testDownloadAndApplyIsOfferedOnlyWhereItCanApply() {
    XCTAssertTrue(download(item()).offersDownloadAndApply)
    XCTAssertEqual(download(item()).action, .download(again: false, canApply: true), "plain Download stays beside it")
    XCTAssertFalse(download(item("222", kind: "Application")).offersDownloadAndApply, "an Application cannot run on macOS")
    XCTAssertFalse(download(item("333", collection: 4)).offersDownloadAndApply)
    XCTAssertEqual(download(item("333", collection: 4)).action, .openCollection, "a collection is opened, not downloaded")
    XCTAssertFalse(download(item(), installed: true).offersDownloadAndApply, "an installed wallpaper is applied, not downloaded")
    XCTAssertFalse(download(item(), job: job()).offersDownloadAndApply, "a download under way is where the person looks")
    XCTAssertFalse(
      download(item(), request: DownloadRequestRow(id: "111", title: "W111", stage: .setup)).offersDownloadAndApply)
    XCTAssertFalse(download(item(), canApply: false).offersDownloadAndApply, "a mirror or disabled target shows no wallpaper of its own")
    XCTAssertTrue(download(item("444", kind: "All types")).offersDownloadAndApply, "an item with no type tag is still not an Application")
  }

  func testThePrimaryActionFollowsTheRequestThenTheJob() {
    let waiting = DownloadRequestRow(id: "111", title: "W111", stage: .account)
    XCTAssertEqual(download(item(), request: waiting).action, .continueSetup)
    XCTAssertEqual(download(item(), request: waiting).stageHint, "Waiting for your Steam sign-in.")
    let restored = DownloadRequestRow(id: "111", title: "W111", stage: .setup, isPaused: true)
    XCTAssertEqual(download(item(), request: restored).action, .resume)
    XCTAssertEqual(download(item(), request: waiting, job: job()).action, .continueSetup, "a request comes before a job")

    XCTAssertEqual(download(item(), job: job(pending: false, paused: true)).action, .resume)
    XCTAssertEqual(download(item(), job: job(prompt: .password)).action, .finishSignIn)
    XCTAssertEqual(
      download(item(), job: job(queued: true)).action, .inProgress(label: "Waiting to download", isQueued: true))
    XCTAssertEqual(
      download(item(), job: job()).action, .inProgress(label: "Downloading", isQueued: false),
      "an unknown percentage is not 0%")
    XCTAssertEqual(
      download(item(), job: job(progress: 0.42)).action,
      .inProgress(label: "Downloading 42%", isQueued: false))
    XCTAssertEqual(
      download(item(), job: job(pending: false, error: "Steam denied this download.")).action,
      .download(again: true, canApply: true))
  }

  func testARunningJobShowsItsProgressAndTheLineBeneathIt() {
    let shown = download(item(), job: job(progress: 0.42))
    XCTAssertTrue(shown.showsProgress)
    XCTAssertEqual(shown.progress, 0.42)
    XCTAssertEqual(shown.statusLine, "Downloading Workshop files… · 860 B of 2 KB · Network speed: 600 KB/s")
    let unknown = download(item(), job: job())
    XCTAssertTrue(unknown.showsProgress)
    XCTAssertNil(unknown.progress, "a bar without a value is indeterminate")
    XCTAssertEqual(unknown.statusLine, "Downloading Workshop files…")
    XCTAssertFalse(download(item(), job: job(queued: true)).showsProgress, "a waiting job has no bar")
    XCTAssertFalse(download(item(), job: job(progress: 0.4), installed: true).showsProgress)
    XCTAssertFalse(download(item()).showsProgress)
  }

  func testWhatIsPendingIsSaidOnlyForADownloadThatWillApplyOrARequestThatDoes() {
    XCTAssertFalse(download(item(), job: job()).appliesOnArrival, "a plain download promises no apply")
    XCTAssertTrue(download(item(), job: job(applies: true)).appliesOnArrival)
    let toApply = DownloadRequestRow(id: "111", title: "W111", stage: .setup, appliesOnArrival: true)
    XCTAssertTrue(download(item(), request: toApply).appliesOnArrival, "so does a request waiting for setup")
    XCTAssertFalse(
      download(item(), job: job(pending: false, applies: true)).appliesOnArrival,
      "a job that is over promises nothing")
  }

  func testAFailureShowsForAnUninstalledItemWhoseJobIsOverAndAFinishedJobMovesShowInLibraryUp() {
    let failed = job(pending: false, error: "Steam denied this download.")
    XCTAssertEqual(download(item(), job: failed).failure, "Steam denied this download.")
    XCTAssertNil(download(item(), job: failed, installed: true).failure)
    XCTAssertNil(download(item(), job: job(error: "Retrying")).failure, "a job still under way is not reported as failed")
    XCTAssertTrue(download(item(), job: job(pending: false)).hasFinishedDownload)
    XCTAssertFalse(download(item(), job: failed).hasFinishedDownload)
    XCTAssertFalse(download(item(), job: job()).hasFinishedDownload)
    XCTAssertTrue(download(item(), job: failed).showsInDownloads)
    XCTAssertFalse(download(item()).showsInDownloads)
  }
}

/// What the inspector says about an installed wallpaper's Workshop update.
@MainActor
final class WorkshopUpdateNoticeTests: MediaPanelTestCase {
  private func update(changed: Date? = Date(timeIntervalSince1970: 1_790_000_000)) -> WorkshopItem {
    WorkshopItem(
      id: "123", title: "Changed", creator: "C", summary: "", previewURL: nil, tags: ["Video"], size: 1,
      subscriptions: 0, timeUpdated: changed)
  }

  private func job(queued: Bool = false, progress: Double? = nil) -> DownloadRow {
    DownloadRow(id: "123", title: "Changed", progress: progress, isPending: true, isQueued: queued)
  }

  func testAnUpdateThatHasNotBeenAskedForOffersToUpdateAndNamesTheDate() throws {
    let notice = try XCTUnwrap(WorkshopUpdateNotice.make(update: update(), request: nil, job: nil))
    XCTAssertEqual(notice.action, .update)
    XCTAssertNil(notice.progress)
    XCTAssertEqual(notice.message(locale: english), "Its author updated it on the Workshop on 9/21/2026.")
    let undated = try XCTUnwrap(WorkshopUpdateNotice.make(update: update(changed: nil), request: nil, job: nil))
    XCTAssertEqual(undated.message(locale: english), "Its author updated it on the Workshop.")
  }

  func testARequestWaitingForSetupContinuesAndADownloadUnderWayShowsItsProgress() throws {
    let request = DownloadRequestRow(id: "123", title: "Changed", stage: .setup)
    XCTAssertEqual(
      try XCTUnwrap(WorkshopUpdateNotice.make(update: update(), request: request, job: nil)).action,
      .continueSetup)

    let waiting = try XCTUnwrap(WorkshopUpdateNotice.make(update: update(), request: nil, job: job(queued: true)))
    XCTAssertEqual(waiting.action, .showInDownloads)
    XCTAssertEqual(waiting.progress, .waiting)
    XCTAssertEqual(waiting.message(), "The update is waiting to download.")
    let unknown = try XCTUnwrap(WorkshopUpdateNotice.make(update: update(), request: nil, job: job()))
    XCTAssertEqual(unknown.message(), "Downloading the update…")
    let measured = try XCTUnwrap(WorkshopUpdateNotice.make(update: update(), request: nil, job: job(progress: 0.42)))
    XCTAssertEqual(measured.progress, .downloading(percent: 42))
    XCTAssertEqual(measured.message(), "Downloading the update… 42%")
  }

  func testAnUpdateThatIsDownloadingNeedsNoUpdateRecordAndNothingToSayMeansNoNotice() {
    XCTAssertNotNil(WorkshopUpdateNotice.make(update: nil, request: nil, job: job()), "an update the store forgot is still on its way")
    XCTAssertNil(WorkshopUpdateNotice.make(update: nil, request: nil, job: nil))
    let finished = DownloadRow(id: "123", title: "Changed")
    XCTAssertNil(WorkshopUpdateNotice.make(update: nil, request: nil, job: finished))
  }

  func testTheControllerAnswersFromTheUpdateStoreAndTheDownloadState() async throws {
    // Installed two hours ago; its author changed it an hour ago.
    let changed = update(changed: Date().addingTimeInterval(-3600))
    let updates = WorkshopUpdateStore(
      defaults: try TemporaryDefaults.make(for: self).defaults, fetch: { _ in [changed] })
    let panel = try makeBrowsingPanel(service: WorkshopDetailsStub().service, updates: updates)
    let controller = panel.controller
    XCTAssertNil(controller.workshopUpdateNotice(for: "123"))
    XCTAssertNil(controller.workshopUpdate(for: "123"))

    let folder = panel.root.appendingPathComponent("Library/123")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manifest = folder.appendingPathComponent("project.json")
    try Data("{}".utf8).write(to: manifest)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: manifest.path)
    panel.store.librarySnapshot = BridgeLibrarySnapshot(
      wallpapers: [
        BridgeWallpaperEntry(
          id: "123", title: "123", kind: .video, supported: true, active: false, selected: false, previewPath: nil)
      ],
      scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 0,
      videoCount: 1, webpageCount: 0, unknownCount: 0)
    updates.check(installed: ["123"], library: panel.root.appendingPathComponent("Library"))
    try await waitFor { !updates.isChecking }
    XCTAssertEqual(controller.workshopUpdate(for: "123")?.title, "Changed")
    XCTAssertEqual(controller.workshopUpdateNotice(for: "123")?.action, .update)

    try await controller.updateWorkshopItem(id: "123")
    XCTAssertEqual(controller.workshopUpdateNotice(for: "123")?.action, .continueSetup)
  }
}
