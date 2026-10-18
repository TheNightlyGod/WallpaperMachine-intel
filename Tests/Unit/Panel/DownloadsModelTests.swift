import XCTest

@testable import WallpaperMachine

/// The download dialog and the Downloads list as the window runs them: when the dialog opens and
/// closes, what **Not now** silences, what survives a closed dialog, where a failure shows, and the
/// six-second hand-off. A fake `steamcmd` script stands in for Valve's tool.
@MainActor
final class DownloadsModelTests: MediaPanelTestCase {
  private func item(_ id: String = "222", kind: String = "Video") -> WorkshopItem {
    WorkshopItem(
      id: id, title: "Local video", creator: "Fixture", summary: "", previewURL: nil, tags: [kind],
      size: 0, subscriptions: 0)
  }

  /// Selects the fake SteamCMD, as Locate a copy does, and waits for it to be ready.
  private func useFakeSteamCMD(_ panel: PanelFixture) async throws {
    panel.workshop.steamCMDSetup.selectExisting(at: panel.executable)
    try await panel.waitUntil(timeout: 15) { panel.workshop.steamCMDSetup.selectedRuntime != nil }
  }

  /// A download that has started and asks for its password, with the panel on screen.
  private func startPromptingJob(_ panel: PanelFixture) async throws -> WorkshopDownload {
    try await useFakeSteamCMD(panel)
    let wanted = item()
    panel.workshop.selectedItem = wanted
    panel.workshop.username = "localtest"
    panel.controller.remembersSession = false
    try await panel.controller.requestDownload(item: wanted)
    try await panel.waitUntil(timeout: 15) { panel.workshop.downloader.download(for: "222")?.worker.prompt == .password }
    return try XCTUnwrap(panel.workshop.downloader.download(for: "222"))
  }

  // MARK: Opening and closing

  func testTheDialogOpensOnAnExplicitRequestAtTheStageThePrerequisiteNeeds() async throws {
    try await withPanel { panel in
      let downloads = panel.controller.downloads
      XCTAssertFalse(downloads.isDialogOpen)
      XCTAssertNil(downloads.resolution)

      await downloads.requestSceneAssets().value
      XCTAssertTrue(downloads.isDialogOpen, "a request that waits on SteamCMD opens the dialog on it")
      XCTAssertEqual(downloads.target, WorkshopStore.sceneAssetsRequestID)
      XCTAssertEqual(downloads.resolution?.stage, .setup)
      XCTAssertEqual(downloads.resolution?.title, "Install SteamCMD")
    }
  }

  func testNotNowClosesTheDialogNeverTheRequestAndReopeningResumesTheSameStage() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let downloads = controller.downloads
      await downloads.requestSceneAssets().value
      XCTAssertEqual(downloads.resolution?.stage, .setup)

      downloads.closeDialog()
      XCTAssertFalse(downloads.isDialogOpen)
      downloads.reconcile()
      XCTAssertFalse(downloads.isDialogOpen, "a later change of the state never reopens it by itself")
      XCTAssertEqual(
        controller.downloadRequestRows.map(\.id), [WorkshopStore.sceneAssetsRequestID],
        "closing keeps what the person asked for")

      downloads.openDialog(for: WorkshopStore.sceneAssetsRequestID)
      XCTAssertEqual(downloads.resolution?.stage, .setup, "the same stage as before")

      // Removing the request closes the dialog first and then removes it.
      let request = try XCTUnwrap(controller.downloadRequestRows.first)
      downloads.removeRequest(request)
      XCTAssertFalse(downloads.isDialogOpen)
      try await panel.waitUntil(timeout: 15) { controller.downloadRequestRows.isEmpty }
    }
  }

  func testAnItemWithNothingToSayClosesTheDialogAtOnce() async throws {
    try await withPanel { panel in
      let downloads = panel.controller.downloads
      downloads.openDialog(for: "404")
      XCTAssertFalse(downloads.isDialogOpen, "no request and no job: nothing to show")
    }
  }

  func testAStageThatChangesWhileTheDialogIsOpenIsFollowedAndAFinishedRequestClosesIt() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let downloads = controller.downloads
      downloads.start()
      defer { downloads.stop() }
      let wanted = item()
      panel.workshop.selectedItem = wanted
      try await controller.requestDownload(item: wanted)
      downloads.openDialog(for: "222")
      XCTAssertEqual(downloads.resolution?.stage, .setup)

      try await useFakeSteamCMD(panel)
      try await waitFor { downloads.stage == .account }
      XCTAssertTrue(downloads.isDialogOpen, "SteamCMD arrived: the dialog moved on to the account")

      try await controller.removeDownloadRequest(id: "222")
      try await waitFor { !downloads.isDialogOpen }
    }
  }

  // MARK: The account stage

  /// A name the downloader refuses shows inside the dialog as well as in the banner, and the dialog
  /// keeps what was typed and the choice not to stay signed in.
  func testARejectedAccountShowsInTheDialogAndKeepsWhatWasTyped() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let downloads = controller.downloads
      try await useFakeSteamCMD(panel)
      let wanted = item()
      panel.workshop.selectedItem = wanted
      try await controller.requestDownload(item: wanted)
      downloads.openDialog(for: "222")
      let session = try XCTUnwrap(downloads.session)
      XCTAssertEqual(downloads.resolution?.stage, .account)
      XCTAssertEqual(session.account, "", "seeded from the request")
      XCTAssertTrue(session.remembersSession)

      session.account = "  anonymous "
      session.remembersSession = false
      await downloads.continueDownload(includeResources: false)?.value

      XCTAssertNotNil(session.errorMessage, "a rejected action reads inside the dialog")
      XCTAssertEqual(session.errorMessage, controller.errors.message, "and in the banner behind it")
      XCTAssertTrue(downloads.isDialogOpen)
      XCTAssertEqual(downloads.resolution?.stage, .account, "back at the account stage")
      XCTAssertEqual(session.account, "  anonymous ", "the typed account is still in the field")
      XCTAssertFalse(session.remembersSession, "and so is the choice")
      let request = try XCTUnwrap(panel.workshop.downloadRequests.first)
      XCTAssertEqual(request.account, "anonymous", "trimmed, as the field always was before it was sent")
      XCTAssertFalse(request.rememberSession)
      XCTAssertTrue(request.refused)
      XCTAssertTrue(panel.workshop.downloader.downloads.isEmpty)

      // Closing and opening again seeds the form from the request, and the old reason is gone.
      downloads.closeDialog()
      downloads.openDialog(for: "222")
      let reopened = try XCTUnwrap(downloads.session)
      XCTAssertEqual(reopened.account, "anonymous")
      XCTAssertFalse(reopened.remembersSession)
      XCTAssertNil(reopened.errorMessage)
      XCTAssertTrue(reopened !== session, "each opening is its own")
    }
  }

  /// A failure that arrives after the dialog was closed and opened again belongs to the opening that
  /// started it: it reaches the banner but never the dialog on show.
  func testALateFailureNeverLeaksIntoAReopenedDialog() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let downloads = controller.downloads
      try await useFakeSteamCMD(panel)
      let wanted = item()
      panel.workshop.selectedItem = wanted
      try await controller.requestDownload(item: wanted)
      downloads.openDialog(for: "222")
      let first = try XCTUnwrap(downloads.session)

      let gate = AsyncGate()
      let late = downloads.perform(PanelActionCoordinator.key("lateFixture")) {
        await gate.wait()
        throw WallpaperActionError(message: "Delayed fixture rejection")
      }
      await gate.waitUntilWaiting()
      downloads.closeDialog()
      downloads.openDialog(for: "222")
      let second = try XCTUnwrap(downloads.session)
      XCTAssertTrue(first !== second)

      gate.open()
      await late.value
      XCTAssertEqual(controller.errors.message, "Delayed fixture rejection", "it still reaches the banner")
      XCTAssertNil(second.errorMessage, "and the dialog on show is not told of an earlier opening's failure")
      XCTAssertNil(first.errorMessage, "nor is the one that was closed")
      XCTAssertTrue(downloads.isDialogOpen)
      XCTAssertEqual(second.account, "", "the account the person typed is untouched")
    }
  }

  func testAFailureFromTheDialogShowsThereAndTheNextActionClearsIt() async throws {
    try await withPanel { panel in
      let downloads = panel.controller.downloads
      await downloads.requestSceneAssets().value
      let session = try XCTUnwrap(downloads.session)
      await downloads.perform { throw WallpaperActionError(message: "Not this time") }.value
      XCTAssertEqual(session.errorMessage, "Not this time")
      await downloads.perform { }.value
      XCTAssertNil(session.errorMessage, "starting something new clears the old reason")
    }
  }

  func testASetupStepThatFailsSaysSoInsideTheDialogAsWellAsInTheBanner() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let downloads = controller.downloads
      await downloads.requestSceneAssets().value
      XCTAssertEqual(downloads.resolution?.stage, .setup)
      let session = try XCTUnwrap(downloads.session)

      // There is no downloaded copy to allow, so preparing the approval fails.
      await downloads.approveSteamCMD().value
      XCTAssertNotNil(session.errorMessage, "the sheet hides the banner, so the dialog says it")
      XCTAssertNotNil(controller.errors.message, "and the banner too")

      await downloads.cancelSteamCMDSetup().value
      XCTAssertNil(session.errorMessage, "the next step started in the dialog clears it")
    }
  }

  func testTheHeaderDrawsASymbolOfWhatTheDialogIsAboutWhereThereIsNoPicture() {
    func header(_ target: String, image: PanelImageSource? = nil) -> String? {
      let resolution = DownloadDialogResolution.resolve(
        target: target,
        request: DownloadRequestRow(id: target, title: "T", image: image, stage: .setup), own: nil,
        sceneAssets: nil, currentStage: nil, handoffTarget: nil)
      return resolution.flatMap(DownloadDialogView.placeholderSymbol(for:))
    }
    let symbols = [
      header(WorkshopStore.sceneAssetsRequestID), header(WorkshopStore.signInRequestID), header("222"),
    ]
    XCTAssertTrue(symbols.allSatisfy { $0 != nil }, "never an empty frame: \(symbols)")
    XCTAssertEqual(Set(symbols).count, 3, "the shared resources, the sign-in and an item each have their own")
    XCTAssertNil(
      header("222", image: .steamThumbnail(URL(string: "https://images.steamusercontent.com/ugc/1/")!)),
      "an item's own picture is shown")
  }

  // MARK: Steam asking

  /// A password request opens the dialog by itself while the window is on screen, and not while it
  /// is hidden: it is there when the window comes back.
  func testAPasswordRequestOpensTheDialogByItselfOnlyWhileTheWindowIsVisible() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let downloads = controller.downloads
      panel.hide()
      _ = try await startPromptingJob(panel)
      downloads.reconcile()
      XCTAssertFalse(downloads.isDialogOpen, "a hidden window opens nothing")

      panel.show()
      downloads.reconcile()
      XCTAssertTrue(downloads.isDialogOpen)
      XCTAssertEqual(downloads.target, "222")
      let resolution = try XCTUnwrap(downloads.resolution)
      XCTAssertEqual(resolution.stage, .auth)
      XCTAssertEqual(resolution.job?.prompt, .password)
      XCTAssertEqual(resolution.title, "Sign in to Steam")
    }
  }

  func testTheFirstRunGuidesOwnSignInIsNotSurfacedWhileTheGuideIsOpen() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      panel.show()
      try await useFakeSteamCMD(panel)
      try await controller.steamSignIn(account: "fixture", remembersSession: false)
      let signIn = try await panel.waitForSignIn()
      try await panel.waitUntil(timeout: 15) { signIn.worker.prompt == .password }
      controller.shell.isWelcomeRequested = true
      controller.downloads.reconcile()
      XCTAssertFalse(controller.downloads.isDialogOpen, "the guide answers its own sign-in")
      controller.shell.isWelcomeRequested = false
      controller.downloads.reconcile()
      XCTAssertTrue(controller.downloads.isDialogOpen, "outside the guide a password request opens it")
    }
  }

  func testNotNowSilencesWhatSteamIsAskingForAndEveryOtherJobThatIsAsking() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let downloads = controller.downloads
      panel.show()
      let job = try await startPromptingJob(panel)
      downloads.reconcile()
      XCTAssertTrue(downloads.isDialogOpen)

      downloads.closeDialog()
      XCTAssertEqual(
        downloads.dismissedAuth, [SteamAuthKey(try XCTUnwrap(controller.steamDownloadRow(for: job.id)))])
      downloads.reconcile()
      XCTAssertFalse(downloads.isDialogOpen, "that request stays quiet")
      XCTAssertNil(
        controller.steamAuthRequestToSurface(dismissed: downloads.dismissedAuth, welcomeIsOpen: false))
      // The tile's shield, a queue row or Settings reopen it on request.
      downloads.openDialog(for: job.id)
      XCTAssertEqual(downloads.resolution?.stage, .auth)
    }
  }

  func testTheDialogFollowsTheSignInToTheHandoffCardAndClosesItselfAfterSixSeconds() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let downloads = controller.downloads
      let sleeper = ManualSleeper()
      downloads.sleep = sleeper.closure
      panel.show()
      downloads.start()
      defer { downloads.stop() }
      _ = try await startPromptingJob(panel)
      try await waitFor { downloads.stage == .auth }
      XCTAssertEqual(downloads.target, "222")
      let askingKey = downloads.focusKey
      downloads.reconcile()
      XCTAssertEqual(downloads.focusKey, askingKey, "an update that changes nothing moves no focus")

      // Steam accepts the sign-in: the transfer is under way and the dialog says so.
      try Data().write(to: panel.root.appendingPathComponent("advance"))
      try await waitFor { downloads.stage == .started }
      XCTAssertNotEqual(downloads.focusKey, askingKey, "a new stage is a new thing to focus")
      XCTAssertEqual(downloads.resolution?.title, "Signed in to Steam")
      XCTAssertEqual(downloads.handoffTarget, "222")
      await sleeper.waitUntilPending(1)
      XCTAssertEqual(sleeper.requested, [.seconds(6)])
      XCTAssertTrue(downloads.isDialogOpen)

      downloads.reconcile()
      XCTAssertEqual(sleeper.requested.count, 1, "later progress keeps the card and starts no second timer")
      sleeper.fireNext()
      try await waitFor { !downloads.isDialogOpen }
      downloads.reconcile()
      XCTAssertFalse(downloads.isDialogOpen, "after the card the dialog stays closed and the tile reports")
    }
  }

  func testCloseBeforeTheTimerCancelsItAndDoneClosesTheCard() async throws {
    try await withPanel { panel in
      let downloads = panel.controller.downloads
      let sleeper = ManualSleeper()
      downloads.sleep = sleeper.closure
      panel.show()
      downloads.start()
      defer { downloads.stop() }
      _ = try await startPromptingJob(panel)
      try await waitFor { downloads.stage == .auth }
      try Data().write(to: panel.root.appendingPathComponent("advance"))
      try await waitFor { downloads.stage == .started }
      await sleeper.waitUntilPending(1)
      downloads.closeDialog()
      XCTAssertEqual(sleeper.cancelledCount, 1, "closing ends the timer")
      XCTAssertFalse(downloads.isDialogOpen)
    }
  }

  func testChangeAccountStopsTheJobAndReopensTheDialogAtTheAccountStage() async throws {
    try await withPanel { panel in
      let downloads = panel.controller.downloads
      panel.show()
      let job = try await startPromptingJob(panel)
      downloads.reconcile()
      XCTAssertEqual(downloads.resolution?.stage, .auth)

      downloads.changeAccount(forJob: job.id)
      try await waitFor { downloads.resolution?.stage == .account }
      XCTAssertEqual(downloads.target, "222")
      XCTAssertEqual(downloads.session?.account, "", "the rejected name is not offered again")
      XCTAssertTrue(panel.workshop.downloadRequests.first?.refused == true)
    }
  }

  // MARK: The button

  func testADownloadWithNoFigureYetRingsTheButtonWithoutFillingItAndAsksForAttention() async throws {
    try await withPanel { panel in
      _ = try await startPromptingJob(panel)
      let queue = panel.controller.downloadQueue
      XCTAssertTrue(queue.showsRing, "something transfers")
      XCTAssertNil(queue.progress, "but there is no figure to fill the ring with")
      XCTAssertTrue(queue.needsAttention, "Steam waits for a password")
      XCTAssertEqual(queue.count, 1, "the badge counts it")
      XCTAssertTrue(queue.buttonLabel.hasPrefix("Downloads: "))
      XCTAssertTrue(queue.buttonLabel.hasSuffix("needs attention"))
    }
  }

  // MARK: Secrets

  func testTheSecretGoesToTheJobAndIsNeverKeptByTheDialogsModel() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let downloads = controller.downloads
      try await useFakeSteamCMD(panel)
      try await controller.steamSignIn(account: "fixture", remembersSession: false)
      let signIn = try await panel.waitForSignIn()
      try await panel.waitUntil(timeout: 15) { signIn.worker.prompt == .password }
      downloads.openDialog(for: WorkshopStore.signInRequestID)

      let secret = "correct horse battery staple"
      await downloads.submitSecret(secret, toJob: WorkshopStore.signInRequestID).value
      try await panel.waitUntil(timeout: 15) { !signIn.isPending }
      XCTAssertEqual(
        try String(contentsOf: panel.root.appendingPathComponent("password"), encoding: .utf8), secret)
      var seen = String(describing: Mirror(reflecting: downloads).children.map { "\($0.value)" })
      seen += String(describing: Mirror(reflecting: try XCTUnwrap(downloads.session)).children.map { "\($0.value)" })
      XCTAssertFalse(seen.contains(secret), "the model holds no copy of what was typed")
      XCTAssertNil(downloads.session?.errorMessage)
    }
  }

  func testASecretTheDialogMayNotSendIsRefusedInsideTheDialog() async throws {
    try await withPanel { panel in
      let downloads = panel.controller.downloads
      await downloads.requestSceneAssets().value
      let session = try XCTUnwrap(downloads.session)
      await downloads.submitSecret("two\nlines", toJob: WorkshopStore.sceneAssetsRequestID).value
      XCTAssertNotNil(session.errorMessage)
    }
  }

  // MARK: Requests

  /// What the requests themselves keep (the intent, the queue) is `PanelDownloadActionsTests`'; this is
  /// what the window adds: where a refusal shows, and that only an accepted request opens the dialog.
  func testARefusedDownloadAndApplyReachesTheBannerAndOpensNoDialog() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      panel.store.settingsSnapshot.displays = [
        BridgeDisplaySettingsRow(
          displayId: "primary", title: "Primary", enabled: false, mode: .standalone,
          mirrorTargets: [], selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
          targetFps: 30, maxFps: 60, muted: false, volume: 1)
      ]
      let wanted = item()
      panel.workshop.selectedItem = wanted
      await controller.downloads.requestDownload(wanted, apply: true).value
      XCTAssertNotNil(controller.errors.message, "the refusal is the banner's")
      XCTAssertFalse(controller.downloads.isDialogOpen, "nothing was asked for, so nothing waits")

      // Without the apply the target does not matter, and the missing SteamCMD opens the dialog.
      await controller.downloads.requestDownload(wanted).value
      XCTAssertTrue(controller.downloads.isDialogOpen)
    }
  }

  func testAnActionKeyNamesTheQueueTheRowBelongsTo() {
    let steam = DownloadRow(id: "222", title: "T")
    let pixiv = DownloadRow(id: "pixiv-1-p0", source: .pixiv, title: "T")
    XCTAssertEqual(DownloadsModel.key("pause", row: steam), "downloadPause:222::")
    XCTAssertEqual(DownloadsModel.key("cancel", row: steam), "downloadCancel:222::")
    XCTAssertEqual(DownloadsModel.key("resume", row: steam), "downloadResume:222::")
    XCTAssertEqual(DownloadsModel.key("retry", row: steam), "downloadRetry:222::")
    XCTAssertEqual(DownloadsModel.key("pause", row: pixiv), "pixivPause:pixiv-1-p0::")
    XCTAssertEqual(DownloadsModel.key("cancel", row: pixiv), "pixivCancel:pixiv-1-p0::")
    XCTAssertEqual(DownloadsModel.key("resume", row: pixiv), "pixivResume:pixiv-1-p0::")
    XCTAssertEqual(DownloadsModel.key("retry", row: pixiv), "pixivRetryDownload:pixiv-1-p0::")
  }

  func testTheDownloadsListIsTheShellsPopoverSoAPageChangeClosesItAndItOpensFolded() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let downloads = controller.downloads
      let shell = controller.shell
      downloads.isQueuePopoverOpen = true
      XCTAssertTrue(shell.isPopoverOpen, "the support prompt waits behind it")
      downloads.showsCompleted = true

      shell.popover(.history).wrappedValue = true
      XCTAssertFalse(downloads.isQueuePopoverOpen, "opening another popover closes it")
      downloads.isQueuePopoverOpen = true
      XCTAssertFalse(downloads.showsCompleted, "the finished downloads fold away on every opening")

      downloads.showsCompleted = true
      // What the root does when the page changes, as Show in library makes it.
      shell.closePopover()
      XCTAssertFalse(downloads.isQueuePopoverOpen, "a popover belongs to the page it was opened on")
      XCTAssertFalse(shell.isPopoverOpen, "and the shell knows it is gone")
      downloads.isQueuePopoverOpen = true
      XCTAssertFalse(downloads.showsCompleted)
      downloads.showsCompleted = true
      downloads.isQueuePopoverOpen = false
      XCTAssertFalse(downloads.showsCompleted, "and on every closing")
    }
  }

  func testTheDownloadsListCanBeOpenedFromTheInspectorAndFromTheDialog() async throws {
    try await withPanel { panel in
      let downloads = panel.controller.downloads
      XCTAssertFalse(downloads.isQueuePopoverOpen)
      downloads.showDownloads()
      XCTAssertTrue(downloads.isQueuePopoverOpen)
      downloads.isQueuePopoverOpen = false

      await downloads.requestSceneAssets().value
      XCTAssertTrue(downloads.isDialogOpen)
      downloads.showDownloadsFromDialog()
      XCTAssertFalse(downloads.isDialogOpen)
      XCTAssertTrue(downloads.isQueuePopoverOpen, "Show downloads leaves the dialog for the list")

      downloads.openDialog(for: WorkshopStore.sceneAssetsRequestID)
      XCTAssertFalse(downloads.isQueuePopoverOpen, "opening the dialog closes the list")
    }
  }

  // MARK: The toolbar's button and pill

  func testTheDownloadsButtonIsInTheToolbarOnlyOnceThereIsSomethingToList() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      XCTAssertFalse(DownloadsToolbarButton.isActive(in: controller))
      await controller.downloads.requestSceneAssets().value
      XCTAssertTrue(DownloadsToolbarButton.isActive(in: controller), "a request that waits is something to list")
      try await controller.removeDownloadRequest(id: WorkshopStore.sceneAssetsRequestID)
      XCTAssertFalse(DownloadsToolbarButton.isActive(in: controller))
    }
  }

  func testAFinishedSignInIsNotADownloadAndNeverShowsTheButton() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await useFakeSteamCMD(panel)
      try await controller.steamSignIn(account: "fixture", remembersSession: false)
      let signIn = try await panel.waitForSignIn()
      try await panel.waitUntil(timeout: 15) { signIn.worker.prompt == .password }
      XCTAssertTrue(DownloadsToolbarButton.isActive(in: controller), "while it runs it is shown")
      try await controller.submitDownloadInput("secret", toJob: WorkshopStore.signInRequestID)
      try await panel.waitUntil(timeout: 15) { !signIn.isPending }
      XCTAssertFalse(DownloadsToolbarButton.isActive(in: controller))
    }
  }

  func testTheSetupPillIsOnlyThereWhileSteamCMDIsBeingSetUpNotWhileItIsOnlyLookedAt() async throws {
    typealias Pill = SetupActivityPill
    XCTAssertFalse(Pill.shows(state: .idle, isBusy: false))
    XCTAssertFalse(Pill.shows(state: .ready, isBusy: false))
    XCTAssertFalse(
      Pill.shows(state: .checking, isBusy: true),
      "the look at what is installed, which every opening of the window begins with, is no setup")
    XCTAssertTrue(Pill.shows(state: .downloading(received: 1, expected: 10), isBusy: true))
    XCTAssertTrue(Pill.shows(state: .downloading(received: 1, expected: nil), isBusy: true))
    XCTAssertTrue(Pill.shows(state: .extracting, isBusy: true))
    XCTAssertTrue(Pill.shows(state: .validating, isBusy: true))
    XCTAssertTrue(Pill.shows(state: .committing, isBusy: true))
    XCTAssertFalse(Pill.shows(state: .cancelled, isBusy: false))

    try await withPanel { panel in
      let controller = panel.controller
      XCTAssertFalse(Pill.isActive(in: controller))
      try await useFakeSteamCMD(panel)
      try await panel.waitUntil(timeout: 15) { !panel.workshop.steamCMDSetup.isBusy }
      XCTAssertFalse(Pill.isActive(in: controller), "and none when it is over")
    }
  }

  func testARowSaysWhatItDoesAndWhileItRunsHowFarItHasGot() {
    let running = DownloadRow(
      id: "1", title: "T", status: "Downloading", progress: 0.42, isPending: true,
      bytesReceived: 860, bytesExpected: 2048, bytesPerSecond: 600_000, secondsRemaining: 240)
    XCTAssertEqual(
      DownloadsPopoverJobRow.statusLine(for: running, locale: english),
      "Downloading · 42% · 860 B of 2 KB · Network speed: 600 KB/s · 4 min left")
    let idle = DownloadRow(
      id: "1", title: "T", status: "Downloading", progress: 0.42, isPending: true,
      bytesPerSecond: 0)
    XCTAssertEqual(
      DownloadsPopoverJobRow.statusLine(for: idle, locale: english),
      "Downloading · 42% · Network speed: 0 B/s", "zero is a speed; an unknown one is left out")
    let queued = DownloadRow(id: "1", title: "T", status: "Waiting for a free download slot", isPending: true, isQueued: true)
    XCTAssertEqual(
      DownloadsPopoverJobRow.statusLine(for: queued, locale: english), "Waiting for a free download slot",
      "a waiting job has no transfer to describe")
    let failed = DownloadRow(id: "1", title: "T", status: "Download failed", errorMessage: "No.")
    XCTAssertEqual(DownloadsPopoverJobRow.statusLine(for: failed, locale: english), "Download failed")
    let bare = DownloadRow(id: "1", title: "T", status: "Downloading", isPending: true)
    XCTAssertEqual(DownloadsPopoverJobRow.statusLine(for: bare, locale: english), "Downloading")
  }
}
