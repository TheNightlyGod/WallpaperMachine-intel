import XCTest

@testable import WallpaperMachine

/// What Settings › Library & Steam offers for each state of SteamCMD, the shared scene resources,
/// the Workshop update check and the Steam account.
@MainActor
final class LibrarySettingsPresentationTests: SettingsBTestCase {
  private func steamCMD(
    busy: Bool = false, ready: Bool = false, canCancel: Bool = true, canApprove: Bool = false,
    candidate: Bool = false, downloads: Bool = false, storeBusy: Bool = false
  ) -> LibrarySteamCMDPresentation {
    .make(
      isBusy: busy, isReady: ready, canCancel: canCancel, canApprove: canApprove, hasCandidate: candidate,
      hasPendingDownload: downloads, isStoreBusy: storeBusy)
  }

  // MARK: SteamCMD

  func testWithoutSteamCMDInstallIsTheFilledButtonAndLocateStandsBesideIt() {
    let state = steamCMD()
    XCTAssertEqual(state.primary, .install)
    XCTAssertTrue(state.primaryIsProminent)
    XCTAssertFalse(state.primaryIsDisabled)
    XCTAssertTrue(state.showsLocate)
    XCTAssertFalse(state.locateIsDisabled)
    XCTAssertFalse(state.showsCancel)
    XCTAssertFalse(state.showsApprove)
    XCTAssertFalse(state.showsCandidate)
    XCTAssertFalse(state.showsDownloadsNote)
  }

  func testReinstallIsQuietAndAKeptCopyOffersToContinueWithIt() {
    let ready = steamCMD(ready: true)
    XCTAssertEqual(ready.primary, .reinstall)
    XCTAssertFalse(ready.primaryIsProminent)
    let kept = steamCMD(candidate: true)
    XCTAssertEqual(kept.primary, .continueInstallation, "a kept copy comes before reinstalling")
    XCTAssertTrue(kept.showsCandidate)
    XCTAssertEqual(steamCMD(ready: true, candidate: true).primary, .continueInstallation)
  }

  func testWhileSetupWorksOnlyCancelIsOfferedAndSavingTheInstallationCannotBeCancelled() {
    let working = steamCMD(busy: true)
    XCTAssertTrue(working.showsCancel)
    XCTAssertFalse(working.cancelIsDisabled)
    XCTAssertNil(working.primary)
    XCTAssertFalse(working.showsLocate)
    XCTAssertFalse(working.showsDownloadsNote, "setup is the reason, not the downloads")
    let saving = steamCMD(busy: true, canCancel: false)
    XCTAssertTrue(saving.cancelIsDisabled)
    XCTAssertTrue(steamCMD(busy: true, storeBusy: true).cancelIsDisabled, "nor while a wallpaper switches")
  }

  func testRunningDownloadsAndWallpaperCommandsLockEveryChangeToTheInstallation() {
    let downloading = steamCMD(canApprove: true, candidate: true, downloads: true)
    XCTAssertTrue(downloading.primaryIsDisabled)
    XCTAssertTrue(downloading.locateIsDisabled)
    XCTAssertTrue(downloading.approveIsDisabled)
    XCTAssertTrue(downloading.discardIsDisabled)
    XCTAssertFalse(downloading.revealIsDisabled, "showing a folder changes nothing")
    XCTAssertTrue(downloading.showsDownloadsNote)
    let switching = steamCMD(candidate: true, storeBusy: true)
    XCTAssertTrue(switching.primaryIsDisabled)
    XCTAssertTrue(switching.revealIsDisabled)
    XCTAssertFalse(switching.showsDownloadsNote)
  }

  func testAllowingACopyAppearsOnlyWhenTheSetupSaysItMay() {
    XCTAssertFalse(steamCMD().showsApprove)
    XCTAssertTrue(steamCMD(canApprove: true, candidate: true).showsApprove)
  }

  // MARK: Shared scene resources

  private func scene(
    job: DownloadRow? = nil, request: DownloadRequestRow? = nil, installed: Bool = false,
    warning: String? = nil, setupBusy: Bool = false, storeBusy: Bool = false
  ) -> LibrarySceneResourcesPresentation {
    .make(
      scene: job, request: request, isInstalled: installed, assetsWarning: warning,
      setupIsBusy: setupBusy, isStoreBusy: storeBusy)
  }

  private func job(
    pending: Bool = true, queued: Bool = false, prompt: WorkshopDownloader.Prompt? = nil,
    authenticating: Bool = false, progress: Double? = nil, status: String = "Downloading shared resources",
    error: String? = nil, warning: String? = nil
  ) -> DownloadRow {
    DownloadRow(
      id: WorkshopStore.sceneAssetsRequestID, title: "Scene assets", status: status, progress: progress,
      isPending: pending, isQueued: queued, isAuthenticating: authenticating, errorMessage: error,
      prompt: prompt, warning: warning)
  }

  private func request(_ stage: WorkshopDownloadStage) -> DownloadRequestRow {
    DownloadRequestRow(id: WorkshopStore.sceneAssetsRequestID, title: "Scene assets", stage: stage)
  }

  func testWithNothingGoingOnTheStatusSaysWhetherScenesCanPlayAndDownloadIsOffered() {
    let missing = scene()
    XCTAssertEqual(missing.status, "Not installed. Scene wallpapers cannot play yet.")
    XCTAssertEqual(missing.actions, [.download(installed: false), .locate])
    XCTAssertTrue(missing.isProminent(.download(installed: false)), "the way in is the filled button")
    let installed = scene(installed: true)
    XCTAssertEqual(installed.status, "Installed. Scene wallpapers can play.")
    XCTAssertEqual(installed.actions, [.download(installed: true), .locate])
    XCTAssertFalse(installed.isProminent(.download(installed: true)), "Download again is quiet")
    XCTAssertFalse(missing.isPending)
    XCTAssertNil(missing.progress)
  }

  func testARetainedRequestSaysWhatItWaitsForAndOffersToContinueOrRemoveIt() {
    for (stage, words) in [
      (WorkshopDownloadStage.setup, "Waiting for SteamCMD setup."),
      (.account, "Waiting for your Steam sign-in."),
      (.resources, "Waiting for your go-ahead on the download."),
    ] {
      let state = scene(request: request(stage))
      XCTAssertEqual(state.status, words)
      XCTAssertEqual(state.actions, [.continueSetup, .removeRequest, .locate])
      XCTAssertTrue(state.isProminent(.continueSetup))
      XCTAssertFalse(state.isProminent(.removeRequest))
    }
  }

  func testARunningDownloadShowsItsProgressAndCancelsAndQueuedOnesSayQueued() {
    let running = scene(job: job(progress: 0.4))
    XCTAssertTrue(running.isPending)
    XCTAssertEqual(running.progress, 0.4)
    XCTAssertEqual(running.actions, [.cancelDownload], "no Locate while it downloads")
    XCTAssertEqual(running.status, "Downloading shared resources", "the job's own words")
    XCTAssertNil(scene(job: job(progress: nil)).progress, "a bar without a figure is indeterminate")
    XCTAssertEqual(scene(job: job(progress: 4)).progress, 1, "kept within 0 to 1")
    XCTAssertEqual(scene(job: job(queued: true)).actions, [.cancelQueuedDownload])
  }

  func testSteamAskingForAPasswordOrACodeOffersToFinishSigningIn() {
    let asking = scene(job: job(prompt: .password))
    XCTAssertEqual(asking.actions, [.finishSignIn, .cancelDownload])
    XCTAssertTrue(asking.isProminent(.finishSignIn))
    XCTAssertEqual(scene(job: job(authenticating: true)).actions, [.finishSignIn, .cancelDownload])
    XCTAssertEqual(
      scene(job: job(queued: true, prompt: .password)).actions, [.cancelQueuedDownload],
      "a queued job is not the one asking")
  }

  func testAFinishedJobStillOffersADownloadAndFailuresShowAsBoxes() {
    let failed = scene(
      job: job(pending: false, status: "Failed", error: "No space left", warning: "Slow disk"),
      warning: "Shared scene assets are still missing")
    XCTAssertEqual(failed.error, "No space left")
    XCTAssertEqual(failed.warnings, ["Slow disk", "Shared scene assets are still missing"])
    XCTAssertEqual(failed.actions, [.download(installed: false), .locate])
    XCTAssertNil(scene().error)
    XCTAssertTrue(scene(job: job(pending: false, error: "")).warnings.isEmpty)
    XCTAssertNil(scene(job: job(pending: false, error: "")).error, "an empty message is no message")
  }

  func testLocatingWaitsForSetupAndForWallpaperCommands() {
    XCTAssertFalse(scene().locateIsDisabled)
    XCTAssertTrue(scene(setupBusy: true).locateIsDisabled)
    XCTAssertTrue(scene(storeBusy: true).locateIsDisabled)
  }

  // MARK: Workshop updates and the account

  func testTheLastCheckLineSaysWhenAndWhatWithTheRightNumber() throws {
    let noon = try XCTUnwrap(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
    func line(count: Int, checked: Date?) -> String {
      LibraryUpdatesNote.text(lastChecked: checked, count: count, now: noon, locale: english)
    }
    XCTAssertEqual(line(count: 0, checked: nil), "Not checked yet.")
    let time = PlaylistState.changeTime(noon, now: noon, locale: english)
    XCTAssertEqual(line(count: 0, checked: noon), "\(time): everything is up to date.")
    XCTAssertEqual(line(count: 1, checked: noon), "\(time): 1 wallpaper has an update. Update it from Installed.", "no \"1 wallpapers\"")
    XCTAssertEqual(line(count: 3, checked: noon), "\(time): 3 wallpapers have updates. Update them from Installed.")
  }

  func testTheAccountRowSaysWhoIsSignedInAndWhyLogOutWaits() {
    XCTAssertEqual(LibraryAccountNote.text(account: nil, hasPendingDownload: false), "You sign in when a download starts.")
    XCTAssertEqual(LibraryAccountNote.text(account: "bobby", hasPendingDownload: false), "Signed in as bobby")
    XCTAssertEqual(
      LibraryAccountNote.text(account: "bobby", hasPendingDownload: true),
      "Signed in as bobby · log out once downloads finish")
    XCTAssertEqual(LibraryAccountNote.text(account: nil, hasPendingDownload: true), "You sign in when a download starts.")
  }

  // MARK: Through the controller

  func testTheControllerGivesTheStatesTheRulesAreWrittenOver() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let setup = LibrarySteamCMDPresentation.make(
        setup: controller.steamSetup, hasPendingDownload: controller.steamDownloadRows.contains(where: \.isPending),
        isStoreBusy: controller.isStoreBusy)
      XCTAssertNil(controller.steamAccount.saved)
      XCTAssertFalse(setup.showsDownloadsNote)
      XCTAssertEqual(
        controller.librarySteamSettings.concurrentDownloadsRange, WorkshopDownloadManager.concurrentDownloadRange)
      XCTAssertEqual(controller.librarySteamSettings.libraryPath, ClientPaths.libraryURL.path)
    }
  }

  /// The menu offers the queue's whole range, and a count above it that a setting still holds so
  /// the menu can show it. What a choice does to the queue is `PanelSettingsValuesTests`'.
  func testDownloadsAtOnceOffersTheQueuesRangeAndACountAboveItThatIsInUse() async throws {
    try await withPanel { panel in
      let settings = panel.controller.librarySteamSettings
      XCTAssertEqual(LibraryDownloadsMenu.choices(settings), [1, 2, 3, 4, 5, 6])
      var above = settings
      above.concurrentDownloads = 8
      XCTAssertEqual(LibraryDownloadsMenu.choices(above), [1, 2, 3, 4, 5, 6, 7, 8])
    }
  }
}
