import XCTest

@testable import WallpaperMachine

/// What the Workshop inspector offers for an item's download, what a tile wears, and the links the
/// page opens: the page's own rules over the model's state.
@MainActor
final class WorkshopInspectorTests: MediaPanelTestCase {
  private func item(_ id: String = "222", kind: String = "Video", collection: Int? = nil) -> WorkshopItem {
    WorkshopItem(
      id: id, title: "Local video", creator: "Fixture", summary: "", previewURL: nil, tags: [kind],
      size: 0, subscriptions: 0, collectionSize: collection)
  }

  private func download(
    _ item: WorkshopItem, request: DownloadRequestRow? = nil, job: DownloadRow? = nil,
    installed: Bool = false, canApply: Bool = true
  ) -> WorkshopItemDownload {
    WorkshopItemDownload.make(
      item: item, request: request, job: job, isInstalled: installed, canApplyToTarget: canApply,
      applyNote: nil, locale: english)
  }

  // MARK: The buttons

  func testDownloadAndApplyIsOfferedBesideDownloadOnlyWhereTheWallpaperCanRunAndTheTargetCanShowIt() {
    XCTAssertEqual(
      WorkshopInspectorButton.buttons(for: download(item())), [.download, .downloadAndApply],
      "a video, an enabled independent target")
    XCTAssertEqual(
      WorkshopInspectorButton.buttons(for: download(item(), canApply: false)), [.download],
      "a mirror or a disabled target cannot take a wallpaper of its own")
    XCTAssertEqual(
      WorkshopInspectorButton.buttons(for: download(item(kind: "Application"))), [.download],
      "an Application cannot run on a Mac")
    XCTAssertEqual(
      WorkshopInspectorButton.buttons(for: download(item(collection: 3))), [.openCollection],
      "a collection is opened, never downloaded")
    XCTAssertEqual(
      WorkshopInspectorButton.buttons(
        for: download(item(), job: DownloadRow(id: "222", title: "T", errorMessage: "No."))),
      [.downloadAgain, .downloadAndApply], "after a failure Download says again; the plain one stays beside it")
  }

  func testWhileADownloadIsUnderWayTheInspectorWatchesItAndOffersNoSecondRequest() {
    let running = DownloadRow(
      id: "222", title: "T", status: "Downloading", progress: 0.42, isPending: true)
    XCTAssertEqual(
      WorkshopInspectorButton.buttons(for: download(item(), job: running)),
      [.progress(label: "Downloading 42%"), .cancel])
    let unknown = DownloadRow(id: "222", title: "T", isPending: true)
    XCTAssertEqual(
      WorkshopInspectorButton.buttons(for: download(item(), job: unknown)),
      [.progress(label: "Downloading"), .cancel])
    let queued = DownloadRow(id: "222", title: "T", isPending: true, isQueued: true)
    XCTAssertEqual(
      WorkshopInspectorButton.buttons(for: download(item(), job: queued)),
      [.progress(label: "Waiting to download"), .removeFromQueue])
    let signingIn = DownloadRow(id: "222", title: "T", isPending: true, prompt: .password)
    XCTAssertEqual(WorkshopInspectorButton.buttons(for: download(item(), job: signingIn)), [.finishSignIn])
  }

  func testARetainedRequestOrAPausedJobIsResumedOrContinuedAndOffersNothingElse() {
    let waiting = DownloadRequestRow(id: "222", title: "T", stage: .setup)
    XCTAssertEqual(WorkshopInspectorButton.buttons(for: download(item(), request: waiting)), [.continueSetup])
    let paused = DownloadRequestRow(id: "222", title: "T", stage: .setup, isPaused: true)
    XCTAssertEqual(WorkshopInspectorButton.buttons(for: download(item(), request: paused)), [.resume])
    let job = DownloadRow(id: "222", title: "T", isPaused: true)
    XCTAssertEqual(WorkshopInspectorButton.buttons(for: download(item(), job: job)), [.resume])
  }

  func testAButtonIsDisabledWhileTheActionItStartedIsPending() async throws {
    let id = "222"
    let keys = [
      WorkshopInspectorButton.download, .downloadAgain, .downloadAndApply, .resume, .cancel,
      .removeFromQueue, .openCollection,
    ].map { $0.actionKey(forItem: id) }
    XCTAssertTrue(keys.allSatisfy { $0 != nil })
    XCTAssertEqual(keys[0], keys[2], "Download and its apply variant are one request: either holds both")
    XCTAssertEqual(keys[4], keys[5], "Cancel and Remove from queue are one action")
    for opener in [WorkshopInspectorButton.continueSetup, .finishSignIn, .progress(label: "Downloading")] {
      XCTAssertNil(opener.actionKey(forItem: id), "\(opener) only opens the dialog or the list")
    }

    // The keys are the ones the actions run under: busy from the click until the action is over.
    let panel = try makeDiscoverPanel()
    let controller = panel.controller
    let downloads = controller.downloads
    let wanted = item(id)
    func busy(_ button: WorkshopInspectorButton) -> Bool {
      controller.isBusy(button.actionKey(forItem: id)!)
    }
    let request = downloads.requestDownload(wanted, apply: true)
    XCTAssertTrue(busy(.download) && busy(.downloadAndApply))
    await request.value
    XCTAssertFalse(busy(.download))
    downloads.closeDialog()

    downloads.perform(.resume, forItem: id)
    XCTAssertTrue(busy(.resume))
    downloads.perform(.cancel, forItem: id)
    XCTAssertTrue(busy(.cancel))
    controller.workshopBrowser.openCollection(item("900", collection: 3))
    XCTAssertTrue(controller.isBusy(WorkshopInspectorButton.openCollection.actionKey(forItem: "900")!))
  }

  func testAnItemThatIsAlreadyInstalledOffersNoDownloadAndTheStateSaysSo() {
    let installed = download(item(), installed: true)
    XCTAssertTrue(installed.isInstalled)
    XCTAssertFalse(installed.offersDownloadAndApply, "never for an installed wallpaper")
  }

  // MARK: Tiles

  func testATileWearsTheMarksOfWhatItIsInTheOrderTheyStack() {
    func tile(installed: Bool = false, favorite: Bool = false, tags: [String] = ["Scene"])
      -> WorkshopTile
    {
      WorkshopTile(
        item: WorkshopItem(
          id: "1", title: "T", creator: "", summary: "", previewURL: nil, tags: tags, size: 0,
          subscriptions: 0),
        isInstalled: installed, isFavorite: favorite, download: nil)
    }
    XCTAssertEqual(WorkshopTileCell.marks(of: tile()), [])
    XCTAssertEqual(WorkshopTileCell.marks(of: tile(installed: true)), [.installed])
    XCTAssertEqual(WorkshopTileCell.marks(of: tile(tags: ["Scene", "Approved"])), [.approved])
    XCTAssertEqual(
      WorkshopTileCell.marks(of: tile(installed: true, favorite: true, tags: ["Approved"])),
      [.installed, .approved, .favorite], "the check, the trophy, then the heart")
    XCTAssertEqual(WorkshopTileCell.Mark.installed.label, "In your library")
    XCTAssertEqual(WorkshopTileCell.Mark.approved.label, "Approved by Wallpaper Engine")
    XCTAssertEqual(WorkshopTileCell.Mark.favorite.label, "Favorite")
  }

  func testVoiceOversActionForATileIsNamedForWhatTheDoubleClickDoes() throws {
    XCTAssertEqual(WorkshopTileCell.doubleClickName(.apply), "Apply wallpaper")
    XCTAssertEqual(WorkshopTileCell.doubleClickName(.openCollection), "Open collection")
    XCTAssertEqual(WorkshopTileCell.doubleClickName(.continueSetup), "Continue setup")
    XCTAssertEqual(WorkshopTileCell.doubleClickName(.requestDownload), "Download")
    XCTAssertNil(WorkshopTileCell.doubleClickName(.select), "selecting is the click's, not an action")

    // An installed wallpaper the target display cannot show is only selected, so it offers nothing.
    let panel = try makeDiscoverPanel()
    let controller = panel.controller
    let installed = item("333")
    panel.store.librarySnapshot.wallpapers = [
      BridgeWallpaperEntry(
        id: "333", title: "x", kind: .video, supported: true, active: false, selected: false,
        previewPath: nil)
    ]
    panel.store.settingsSnapshot.displays = [
      BridgeDisplaySettingsRow(
        displayId: "primary", title: "Primary", enabled: false, mode: .standalone,
        mirrorTargets: [], selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
        targetFps: 30, maxFps: 60, muted: false, volume: 1)
    ]
    XCTAssertNil(WorkshopTileCell.doubleClickName(controller.workshopDoubleClick(for: installed)))
  }

  func testEveryGlyphOfARingHasItsOwnSymbol() {
    let glyphs: [TileDownloadState.Glyph] = [.play, .shield, .download, .refresh]
    let symbols = glyphs.map(WorkshopTileRing.symbol(for:))
    XCTAssertEqual(Set(symbols).count, glyphs.count)
    XCTAssertTrue(symbols.allSatisfy { !$0.isEmpty })
  }

  func testTheGuideCardHasASymbolForEveryWayOfAnsweringSteam() {
    let symbols = [SteamGuardGuide.mobileApproval, .authenticatorCode, .emailCode, .unknown]
      .map(\.systemImage)
    XCTAssertEqual(symbols, ["iphone", "iphone", "envelope", "shield"])
  }

  // MARK: Subscriptions and links

  func testTheDownloadOfWhatIsMissingWaitsForAJobAndNeedsSomethingMissing() {
    typealias Bar = WorkshopSubscriptionBar
    XCTAssertTrue(Bar.canDownloadMissing(isBusy: false, hasLoaded: false, totalCount: 0), "before the list loaded")
    XCTAssertTrue(Bar.canDownloadMissing(isBusy: false, hasLoaded: true, totalCount: 31))
    XCTAssertFalse(Bar.canDownloadMissing(isBusy: false, hasLoaded: true, totalCount: 0), "nothing subscribed")
    XCTAssertFalse(Bar.canDownloadMissing(isBusy: true, hasLoaded: true, totalCount: 31), "one is under way")
  }

  func testTheLinksTheWorkshopPageOpensAreTheItemsOwnPageAndTheListOnSteam() throws {
    let panel = try makeDiscoverPanel()
    let model = panel.controller.workshopBrowser
    var opened: [URL] = []
    model.openURL = { opened.append($0); return true }

    model.viewOnSteam(item("3632513108"))
    XCTAssertEqual(
      opened, [URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=3632513108")!])
    model.viewOnSteam(item("not-a-number"))
    XCTAssertEqual(opened.count, 1, "an item with no Workshop id has no page")

    model.openOnSteam()
    XCTAssertEqual(opened.count, 2)
    XCTAssertEqual(opened.last?.host, "steamcommunity.com", "the list's own page, through the allowlist")
  }

  func testWithoutAnOverrideTheLinksGoThroughTheDesktopActions() throws {
    let panel = try makeDiscoverPanel()
    let model = panel.controller.workshopBrowser
    XCTAssertNil(model.openURL, "the app's own opener: DesktopActions.current")
    let log = DesktopActionLog.shared
    let before = log.opened.count
    model.viewOnSteam(item("3632513108"))
    model.openOnSteam()
    XCTAssertEqual(log.opened.count, before + 2, "the test bundle's recorder saw both, no browser did")
    XCTAssertEqual(
      log.opened[before], URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=3632513108")!)
  }

  func testAnAddressTheAllowlistRefusesIsNeverOpened() throws {
    let panel = try makeDiscoverPanel()
    let model = panel.controller.workshopBrowser
    var opened: [URL] = []
    model.openURL = { opened.append($0); return true }
    XCTAssertFalse(ExternalLink.open(URL(string: "https://example.com/x")!, using: model.openURL))
    XCTAssertTrue(opened.isEmpty)
  }
}
