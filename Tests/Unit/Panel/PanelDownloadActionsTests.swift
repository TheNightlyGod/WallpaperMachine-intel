import XCTest

@testable import WallpaperMachine

/// The download pipeline through the typed actions: requests and their prerequisites, Download and
/// apply, a rejected account, the secrets, controlling jobs, and the SteamCMD setup. A fake
/// `steamcmd` script stands in for Valve's tool, so nothing reaches Steam.
@MainActor
final class PanelDownloadActionsTests: MediaPanelTestCase {
  private func item(_ id: String = "222", kind: String = "Video", collection: Int? = nil) -> WorkshopItem {
    WorkshopItem(
      id: id, title: "Local video", creator: "Fixture", summary: "", previewURL: nil, tags: [kind],
      size: 0, subscriptions: 0, collectionSize: collection)
  }

  /// A display row with the same shape as the fixture's.
  private func display(mode: BridgeDisplayMode = .standalone, enabled: Bool = true) -> BridgeDisplaySettingsRow {
    BridgeDisplaySettingsRow(
      displayId: "primary", title: "Primary", enabled: enabled, mode: mode, mirrorTargets: [],
      selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60,
      muted: false, volume: 1)
  }

  /// Selects the fake SteamCMD, as Locate a copy does, and waits for it to be ready.
  private func useFakeSteamCMD(_ panel: PanelFixture) async throws {
    panel.workshop.steamCMDSetup.selectExisting(at: panel.executable)
    try await panel.waitUntil { panel.workshop.steamCMDSetup.selectedRuntime != nil }
  }

  // MARK: Download and apply

  func testDownloadAndApplyAsksForTheTargetDisplayAndTheStateSaysSo() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let wanted = item()
      panel.workshop.selectedItem = wanted
      XCTAssertFalse(controller.workshopItemDownload(for: wanted).appliesOnArrival)
      try await controller.requestDownload(item: wanted, apply: true)

      XCTAssertTrue(panel.workshop.appliesOnArrival("222"))
      XCTAssertEqual(controller.downloadRequestRows.first { $0.id == "222" }?.appliesOnArrival, true)
      XCTAssertTrue(controller.workshopItemDownload(for: wanted).appliesOnArrival)
    }
  }

  func testAPlainRequestAsksForNoApply() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let wanted = item()
      panel.workshop.selectedItem = wanted
      try await controller.requestDownload(item: wanted)
      XCTAssertFalse(panel.workshop.appliesOnArrival("222"))
      try await controller.requestDownload(item: wanted, apply: false)
      XCTAssertFalse(panel.workshop.appliesOnArrival("222"))
      XCTAssertEqual(controller.downloadRequestRows.first?.appliesOnArrival, false)
    }
  }

  func testATargetThatCannotShowAWallpaperOfItsOwnRefusesBeforeAnythingIsQueued() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let wanted = item()
      panel.workshop.selectedItem = wanted
      for target in [display(mode: .mirror), display(enabled: false)] {
        panel.store.settingsSnapshot.displays = [target]
        XCTAssertFalse(controller.mediaApplyTarget.canShowWallpaper)
        XCTAssertEqual(
          controller.workshopItemDownload(for: wanted).action, .download(again: false, canApply: false),
          "Download and apply is not offered where it cannot apply")
        do {
          try await controller.requestDownload(item: wanted, apply: true)
          XCTFail("a display that shows no wallpaper of its own has nothing to apply to")
        } catch let error as WallpaperActionError {
          XCTAssertEqual(
            error.message,
            "The selected display is unavailable, disabled, or mirroring another display. Choose an enabled independent display in Settings."
          )
        }
        XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)
        XCTAssertFalse(panel.workshop.appliesOnArrival("222"))
      }
      try await controller.requestDownload(item: wanted)
      XCTAssertEqual(panel.workshop.downloadRequests.map(\.id), ["222"], "a plain download needs no display")
    }
  }

  func testTheTargetIsTheDisplayChosenWhenTheDownloadWasAskedFor() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      let wanted = item()
      panel.workshop.selectedItem = wanted
      panel.navigation.targetDisplayID = "secondary"
      try await panel.controller.requestDownload(item: wanted, apply: true)
      XCTAssertEqual(panel.workshop.applyIntents["222"]?.displayID, "secondary")
    }
  }

  func testOnlyAnItemTheStoreKnowsCanBeRequested() async throws {
    try await withPanel { panel in
      do {
        try await panel.controller.requestDownload(item: item("404"))
        XCTFail("an item the store has never seen is a stale control")
      } catch is InvalidControlValue {}
      XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)
    }
  }

  // MARK: The ladder of prerequisites

  func testARequestThatNeedsSetupIsRetainedAndOnlyRemovedWhenTheUserSaysSo() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await controller.requestSceneAssets()

      XCTAssertEqual(controller.downloadRequestRows.map(\.id), [WorkshopStore.sceneAssetsRequestID])
      XCTAssertEqual(controller.downloadRequestRows.first?.stage, .setup)
      XCTAssertEqual(controller.downloadRequestRows.first?.title, "Scene assets")
      XCTAssertEqual(controller.downloadQueue.summary, "1 download needs setup")
      XCTAssertEqual(
        controller.downloadDialogTarget(afterRequesting: nil), WorkshopStore.sceneAssetsRequestID,
        "a request that waits on a prerequisite opens the dialog on it")

      let dialog = controller.resolveDownloadDialog(
        target: WorkshopStore.sceneAssetsRequestID, currentStage: nil, handoffTarget: nil)
      XCTAssertEqual(dialog?.stage, .setup)
      // Closing the dialog is not removing the request: a later look resolves to the same stage.
      XCTAssertEqual(
        controller.resolveDownloadDialog(
          target: WorkshopStore.sceneAssetsRequestID, currentStage: .setup, handoffTarget: nil)?.stage,
        .setup)

      try await controller.removeDownloadRequest(id: WorkshopStore.sceneAssetsRequestID)
      XCTAssertTrue(controller.downloadRequestRows.isEmpty)
      XCTAssertNil(
        controller.resolveDownloadDialog(
          target: WorkshopStore.sceneAssetsRequestID, currentStage: .setup, handoffTarget: nil),
        "with the request gone the dialog has nothing to say")
      try await controller.removeDownloadRequest(id: WorkshopStore.sceneAssetsRequestID)
    }
  }

  func testARequestWithSetupDoneWaitsForTheAccountAndSeedsItsFormFromTheRequest() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await useFakeSteamCMD(panel)
      let wanted = item()
      panel.workshop.selectedItem = wanted
      try await controller.requestDownload(item: wanted)

      XCTAssertEqual(controller.downloadRequestRows.first?.stage, .account)
      XCTAssertEqual(controller.downloadDialogTarget(afterRequesting: "222"), "222")
      XCTAssertEqual(controller.downloadAccountSeed(for: "222"), DownloadAccountSeed(account: "", remembersSession: true))
      XCTAssertEqual(
        controller.resolveDownloadDialog(target: "222", currentStage: nil, handoffTarget: nil)?.stage,
        .account)
    }
  }

  /// A name the downloader refuses is shown beside the form it was typed into: the request stays
  /// where it was, with the typed account and the choice not to keep the session.
  func testARejectedAccountKeepsTheRequestAtTheAccountStageWithTheReason() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await useFakeSteamCMD(panel)
      let wanted = item()
      panel.workshop.selectedItem = wanted
      try await controller.requestDownload(item: wanted)

      await controller.launch("continue:222") {
        try await controller.continueDownload(
          id: "222", account: "  anonymous ", remembersSession: false, includeResources: false)
      }.value

      XCTAssertNotNil(controller.errors.message, "the refusal reaches the banner")
      let request = try XCTUnwrap(panel.workshop.downloadRequests.first)
      XCTAssertEqual(request.id, "222")
      XCTAssertEqual(request.account, "anonymous", "the dialog's field is trimmed as it always was")
      XCTAssertFalse(request.rememberSession)
      XCTAssertTrue(request.refused)
      XCTAssertTrue(panel.workshop.downloader.downloads.isEmpty, "anonymous is refused before starting even the local tool")
      XCTAssertFalse(controller.remembersSession, "the choice is kept even though the request was refused")
      let row = try XCTUnwrap(controller.downloadRequestRows.first)
      XCTAssertEqual(row.stage, .account, "a refused request returns to the account stage")
      XCTAssertEqual(
        controller.downloadAccountSeed(for: "222"),
        DownloadAccountSeed(account: "anonymous", remembersSession: false),
        "a reopened dialog keeps what was typed")
      XCTAssertEqual(
        controller.resolveDownloadDialog(target: "222", currentStage: .account, handoffTarget: nil)?.stage,
        .account)
    }
  }

  func testContinuingAnIdentifierThatIsNeitherARequestNorAKnownItemIsRefused() async throws {
    try await withPanel { panel in
      do {
        try await panel.controller.continueDownload(
          id: "404", account: "fixture", remembersSession: true, includeResources: false)
        XCTFail("nothing is waiting on 404")
      } catch is InvalidControlValue {}
    }
  }

  // MARK: A hidden panel

  /// A hidden panel keeps the work going: a request becomes a job the moment SteamCMD is selected,
  /// and the state a visible panel reads still follows every nested change of the job.
  func testAHiddenPanelContinuesSetupAndObservesNestedDownloadChanges() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      panel.hide()
      // What a view that reads the queue would hold: the rows as of the last change it heard of.
      let heard = Heard()
      let observation = ObservationLoop(
        track: { _ = controller.downloadQueue; _ = controller.steamDownloadRows },
        onChange: { heard.rows = controller.steamDownloadRows })
      observation.start()
      defer { observation.stop() }

      let wanted = item()
      panel.workshop.selectedItem = wanted
      panel.workshop.username = "localtest"
      controller.remembersSession = false
      try await controller.requestDownload(item: wanted)
      XCTAssertEqual(panel.workshop.downloadRequests.map(\.id), ["222"])
      try await useFakeSteamCMD(panel)
      try await panel.waitUntil { panel.workshop.downloader.download(for: "222")?.worker.prompt == .password }
      XCTAssertTrue(panel.workshop.downloadRequests.isEmpty, "the request became a job with no panel on screen")

      var row = try XCTUnwrap(controller.steamDownloadRow(for: "222"))
      XCTAssertTrue(row.needsAuthentication)
      XCTAssertTrue(row.promptIsSecret)
      XCTAssertEqual(
        controller.steamAuthRequestToSurface(dismissed: [], welcomeIsOpen: false)?.id, "222",
        "a password request is what opens the dialog by itself")
      XCTAssertTrue(controller.downloadQueue.needsAttention)
      XCTAssertEqual(controller.downloadDialogTarget(afterRequesting: "222"), "222")
      try await waitFor { heard.rows.first?.prompt == .password }

      try Data().write(to: panel.root.appendingPathComponent("advance"))
      try await panel.waitUntil { panel.workshop.downloader.download(for: "222")?.worker.prompt == nil }
      row = try XCTUnwrap(controller.steamDownloadRow(for: "222"))
      XCTAssertFalse(row.needsAuthentication)
      try await waitFor { heard.rows.first.map { $0.prompt == nil } == true }

      let job = try XCTUnwrap(panel.workshop.downloader.download(for: "222"))
      try await controller.cancelDownload(id: "222")
      try await panel.waitUntil { !job.isPending }
      XCTAssertTrue(try XCTUnwrap(controller.steamDownloadRow(for: "222")).isCancelled)
      try await waitFor { heard.rows.first?.isCancelled == true }
      XCTAssertNil(controller.errors.message)
    }
  }

  // MARK: Secrets

  func testASecretGoesStraightToTheJobThatIsAskingAndNowhereElse() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await useFakeSteamCMD(panel)
      try await controller.steamSignIn(account: "fixture", remembersSession: false)
      let signIn = try await panel.waitForSignIn()
      try await panel.waitUntil { signIn.worker.prompt == .password }

      for secret in ["", "line one\nline two", "with\0nul", "carriage\rreturn"] {
        do {
          try await controller.submitDownloadInput(secret, toJob: WorkshopStore.signInRequestID)
          XCTFail("\(secret.debugDescription) is not an answer the dialog sends")
        } catch is InvalidControlValue {}
      }
      do {
        try await controller.submitDownloadInput("secret", toJob: "no-such-job")
        XCTFail("an unknown job cannot be answered")
      } catch is InvalidControlValue {}
      XCTAssertNotNil(signIn.worker.prompt, "no refused answer reached the job")

      let secret = "correct horse battery staple"
      try await controller.submitDownloadInput(secret, toJob: WorkshopStore.signInRequestID)
      try await panel.waitUntil { !signIn.isPending }
      XCTAssertEqual(try String(contentsOf: panel.root.appendingPathComponent("password"), encoding: .utf8), secret)
      for state in [
        String(describing: controller.steamDownloadRows), String(describing: controller.downloadQueue),
        String(describing: controller.steamSetup), String(describing: controller.steamAccount),
        String(describing: controller.errors.message as Any),
      ] {
        XCTAssertFalse(state.contains(secret), "the secret is never part of any state the panel keeps")
      }
      XCTAssertFalse(controller.downloadQueue.isVisible, "a finished sign-in is not a download")

      do {
        try await controller.submitDownloadInput("again", toJob: WorkshopStore.signInRequestID)
        XCTFail("a job that is not asking takes no answer")
      } catch is InvalidControlValue {}
    }
  }

  // MARK: Controlling jobs

  private func startRunningJob(_ panel: PanelFixture) async throws -> WorkshopDownload {
    try await useFakeSteamCMD(panel)
    let wanted = item()
    panel.workshop.selectedItem = wanted
    panel.workshop.username = "localtest"
    panel.controller.remembersSession = false
    try await panel.controller.requestDownload(item: wanted)
    try await panel.waitUntil { panel.workshop.downloader.download(for: "222")?.worker.prompt == .password }
    return try XCTUnwrap(panel.workshop.downloader.download(for: "222"))
  }

  func testPausingAndCancellingNeedAJobAndCancellingNeedsNoSuchCheck() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let job = try await startRunningJob(panel)
      do {
        try await controller.pauseDownload(id: "no-such-job")
        XCTFail("only a job can be paused")
      } catch is InvalidControlValue {}
      try await controller.pauseDownload(id: "222")
      try await panel.waitUntil { job.isPaused && !job.isPending }
      XCTAssertTrue(controller.downloadQueue.unresolved.contains { $0.id == "222" }, "a paused job stays in view")
      XCTAssertEqual(
        controller.workshopItemDownload(for: item()).action, .resume,
        "its inspector offers to resume it")
      let ring = controller.workshopTile(for: item()).download
      XCTAssertEqual(ring?.action, .resume)

      try await controller.cancelDownload(id: "no-such-job")
      try await controller.cancelDownload(id: "222")
      XCTAssertNil(controller.errors.message)
      XCTAssertTrue(try XCTUnwrap(controller.steamDownloadRow(for: "222")).isCancelled)
    }
  }

  func testRetryNeedsAJobThatIsNotUnderWayAndResumeNeedsARequestOrAJob() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      _ = try await startRunningJob(panel)
      do {
        try await controller.retryDownload(id: "222")
        XCTFail("a job that is still under way cannot be retried")
      } catch is InvalidControlValue {}
      do {
        try await controller.retryDownload(id: "no-such-job")
        XCTFail("only a job can be retried")
      } catch is InvalidControlValue {}
      do {
        try await controller.resumeDownload(id: "no-such-job")
        XCTFail("neither a request nor a job")
      } catch is InvalidControlValue {}
      try await controller.resumeDownload(id: "222")
      XCTAssertNil(controller.errors.message, "resuming a job that is not paused changes nothing")
    }
  }

  func testChangingTheAccountStopsThatJobAndKeepsItsWallpaperAsARefusedRequest() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let job = try await startRunningJob(panel)
      do {
        try await controller.changeDownloadAccount(id: "no-such-job")
        XCTFail("only a running job has an account to change")
      } catch is InvalidControlValue {}
      try await controller.changeDownloadAccount(id: "222")
      XCTAssertFalse(job.isPending)
      let request = try XCTUnwrap(controller.downloadRequestRows.first)
      XCTAssertEqual(request.id, "222")
      XCTAssertEqual(request.account, "", "nothing signs in again under the name the user rejected")
      XCTAssertEqual(request.stage, .account)
      XCTAssertEqual(controller.downloadAccountSeed(for: "222").account, "")
    }
  }

  func testClearingRemovesFinishedWorkFromBothQueuesAndKeepsWhatIsPaused() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let job = try await startRunningJob(panel)
      try await controller.cancelDownload(id: "222")
      try await panel.waitUntil { !job.isPending }
      let work = PixivWork(
        id: "301", title: "Sky", authorID: "1", authorName: "A", thumbnailURL: nil, width: 1, height: 1,
        pageCount: 1, rating: .everyone, aiGenerated: nil, tags: [], rank: nil)
      let save = panel.pixiv.downloads.enqueue(work, page: 0)
      try await controller.pixivCancel(id: "pixiv-301-p0")
      try await panel.waitUntil(timeout: 10) { !save.isPending }
      XCTAssertEqual(controller.downloadQueue.downloads.count, 2, "a cancelled or finished save is listed until cleared")

      try await controller.clearDownloads()
      XCTAssertTrue(controller.steamDownloadRows.isEmpty, "\(controller.steamDownloadRows)")
      XCTAssertTrue(controller.pixivDownloadRows.isEmpty, "\(controller.pixivDownloadRows)")
      XCTAssertFalse(controller.downloadQueue.isVisible)
    }
  }

  func testRetryFailedTriesEveryStoppedDownloadOfBothQueuesAgain() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let job = try await startRunningJob(panel)
      try await controller.cancelDownload(id: "222")
      try await panel.waitUntil { !job.isPending }
      let work = PixivWork(
        id: "301", title: "Sky", authorID: "1", authorName: "A", thumbnailURL: nil, width: 1, height: 1,
        pageCount: 1, rating: .everyone, aiGenerated: nil, tags: [], rank: nil)
      let save = panel.pixiv.downloads.enqueue(work, page: 0)
      try await controller.pixivCancel(id: "pixiv-301-p0")
      try await panel.waitUntil(timeout: 10) { !save.isPending }
      XCTAssertEqual(Set(controller.retryableDownloads.map(\.id)), ["222", "pixiv-301-p0"])

      try await controller.retryFailedDownloads()
      try await panel.waitUntil { panel.workshop.downloader.download(for: "222")?.isPending == true }
      XCTAssertTrue(controller.retryableDownloads.allSatisfy { $0.id != "222" }, "the Steam job is back in line")
      XCTAssertFalse(
        controller.pixivDownloadRows.contains { $0.id == "pixiv-301-p0" && $0.status == .cancelled },
        "and so is the pixiv save")
    }
  }

  func testLoggingOutAsksFirstAndTheDownloaderRefusesWhileDownloadsRun() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await controller.logOutSteam()
      XCTAssertEqual(panel.dialogs.confirmations.count, 1)
      XCTAssertEqual(panel.dialogs.confirmations.first?.title, "Log out of Steam?")
      XCTAssertEqual(panel.dialogs.confirmations.first?.button, "Log Out")

      panel.dialogs.confirmAnswer = true
      try await controller.logOutSteam()
      XCTAssertNil(controller.errors.message)

      _ = try await startRunningJob(panel)
      do {
        try await controller.logOutSteam()
        XCTFail("a running download needs the sign-in")
      } catch let error as WallpaperActionError {
        XCTAssertEqual(
          error.message, "Wait for active and queued downloads to finish before logging out of Steam.")
      }
    }
  }

  // MARK: SteamCMD setup

  func testLocatingACopyAsksForAFileOrAFolderAndSelectsTheAnswer() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      XCTAssertFalse(controller.steamSetup.isReady)
      try await controller.locateSteamCMD()
      XCTAssertFalse(controller.steamSetup.isReady, "Cancel changes nothing")
      let asked = try XCTUnwrap(panel.dialogs.panels.last as? NSOpenPanel)
      XCTAssertEqual(asked.title, "Locate SteamCMD")
      XCTAssertTrue(asked.canChooseFiles)
      XCTAssertTrue(asked.canChooseDirectories)

      panel.dialogs.chosenURL = panel.executable
      try await controller.locateSteamCMD()
      try await panel.waitUntil { controller.steamSetup.isReady }
      XCTAssertEqual(controller.steamSetup.status, "Ready")
      XCTAssertFalse(controller.steamSetup.isBusy)
      XCTAssertNil(controller.steamSetup.errorDetail)
    }
  }

  func testReinstallingOverAManagedCopyAsksFirstAndAnAnswerOfNoChangesNothing() async throws {
    try await withPanel { panel in
      // The fixture's fake tool shares this path on a case-insensitive volume; make sure it exists.
      if !FileManager.default.fileExists(atPath: ClientPaths.managedSteamCMDURL.path) {
        try FileManager.default.createDirectory(
          at: ClientPaths.managedSteamCMDURL, withIntermediateDirectories: true)
      }
      try await panel.controller.installSteamCMD()
      XCTAssertEqual(panel.dialogs.confirmations.first?.title, "Reinstall SteamCMD?")
      XCTAssertEqual(panel.dialogs.confirmations.first?.button, "Reinstall")
      XCTAssertFalse(panel.controller.steamSetup.isBusy, "no install began")
      XCTAssertFalse(panel.controller.steamSetup.isReady)
    }
  }

  func testApprovingNeedsADownloadedCopyThatIsKeptAndDiscardingAsksFirst() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      do {
        try await controller.approveSteamCMD()
        XCTFail("there is no kept copy to approve")
      } catch is SteamCMDSetupIssue {}
      XCTAssertTrue(panel.dialogs.confirmations.isEmpty, "nothing is asked about a copy that is not there")
      XCTAssertFalse(controller.steamSetup.canApprove)
      XCTAssertNil(controller.steamSetup.candidatePath)

      try await controller.discardSteamCMDCandidate()
      XCTAssertEqual(panel.dialogs.confirmations.first?.title, "Discard downloaded SteamCMD?")
      XCTAssertEqual(panel.dialogs.confirmations.first?.button, "Discard Download")
      try await controller.revealSteamCMDCandidate()
      try await controller.cancelSteamCMDSetup()
      XCTAssertNil(controller.errors.message)
    }
  }

  func testLocatingSceneAssetsFinishesTheWaitingRequestAndARefusedFolderLeavesItWaiting() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await controller.requestSceneAssets()
      XCTAssertEqual(controller.downloadRequestRows.map(\.id), [WorkshopStore.sceneAssetsRequestID])

      try await controller.locateSceneAssets()
      let asked = try XCTUnwrap(panel.dialogs.panels.last as? NSOpenPanel)
      XCTAssertEqual(asked.title, "Locate Scene Assets")
      XCTAssertTrue(asked.canChooseDirectories)
      XCTAssertFalse(asked.canChooseFiles)
      XCTAssertEqual(controller.downloadRequestRows.count, 1, "Cancel changes nothing")

      let folder = panel.root.appendingPathComponent("elsewhere")
      panel.dialogs.chosenURL = folder
      var configured: [URL] = []
      controller.configureSceneAssets = { _ in throw WorkshopFailure(message: "Not an assets folder.") }
      await controller.launch { try await controller.locateSceneAssets() }.value
      XCTAssertEqual(controller.errors.message, "Not an assets folder.")
      XCTAssertEqual(controller.downloadRequestRows.count, 1, "a folder that is refused satisfies nothing")

      controller.configureSceneAssets = { configured.append($0) }
      try await controller.locateSceneAssets()
      XCTAssertEqual(configured, [folder])
      XCTAssertTrue(controller.downloadRequestRows.isEmpty, "located assets satisfy the need: the intent is finished")
    }
  }

  // MARK: What the account state says

  func testTheAccountStateFollowsTheDownloaderAndTheLastChoice() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      var account = controller.steamAccount
      XCTAssertEqual(account.suggested, "")
      XCTAssertNil(account.saved)
      XCTAssertTrue(account.remembersSession, "a new panel keeps the session by default")
      XCTAssertEqual(account.slotLimit, WorkshopDownloadManager.defaultConcurrentDownloads)
      XCTAssertFalse(account.downloadsRunOneAtATimeAfterConflict)

      controller.remembersSession = false
      panel.workshop.username = "typed"
      account = controller.steamAccount
      XCTAssertFalse(account.remembersSession)
      XCTAssertEqual(account.suggested, "typed")
      panel.workshop.setConcurrentDownloads(5)
      XCTAssertEqual(controller.steamAccount.slotLimit, 5)
    }
  }
}

/// The rows a view that observes the queue last read.
@MainActor
private final class Heard {
  var rows: [DownloadRow] = []
}
