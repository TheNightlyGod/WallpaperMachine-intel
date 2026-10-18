import XCTest

@testable import WallpaperMachine

/// The library's typed actions over a bridge that really selects, applies and ejects on two
/// displays: what they ask the store, in which queue slot, and what reaches the banner.
@MainActor
final class PanelLibraryActionsTests: PanelTestCase {
  @MainActor private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
      isOpen = true
      let waiting = waiters
      waiters = []
      for waiter in waiting { waiter.resume() }
    }
  }

  private func wallpaper(_ id: String, supported: Bool = true) -> BridgeWallpaperEntry {
    BridgeWallpaperEntry(
      id: id, title: id, kind: .video, supported: supported, active: false, selected: false,
      previewPath: nil)
  }

  /// Runs `action` the way a view does and returns the banner afterwards.
  private func banner(_ panel: PanelFixture, _ action: @escaping @MainActor () async throws -> Void) async -> String? {
    await panel.controller.launch(operation: action).value
    return panel.controller.errors.message
  }

  // MARK: Favorites and Finder

  func testFavoritesPersistTheSortedJSONInTheInjectedDefaultsAndRefuseAStaleWallpaper() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let other = try TemporaryDefaults.make(for: self).defaults
    panel.store.librarySnapshot.wallpapers = ["b", "a"].map { wallpaper($0) }
    let controller = panel.controller

    try await controller.toggleFavorite("b")
    try await controller.toggleFavorite("a")
    XCTAssertEqual(controller.favoriteIDs, ["a", "b"])
    XCTAssertEqual(PanelPreferences.favorites(in: panel.defaults), ["a", "b"])
    XCTAssertEqual(
      try JSONDecoder().decode(
        [String].self, from: XCTUnwrap(panel.defaults.data(forKey: PanelPreferences.favoritesKey))),
      ["a", "b"], "the key holds the sorted JSON the Random Wallpaper pool reads")
    XCTAssertNil(other.data(forKey: PanelPreferences.favoritesKey), "no other suite is written")

    try await controller.toggleFavorite("a")
    XCTAssertEqual(PanelPreferences.favorites(in: panel.defaults), ["b"], "a second toggle removes it")
    XCTAssertEqual(panel.buildController().favoriteIDs, ["b"], "and a reopened panel has it")

    let message = await banner(panel) { try await controller.toggleFavorite("gone") }
    XCTAssertEqual(message, L("This wallpaper is no longer installed. Refresh your library."))
    XCTAssertEqual(PanelPreferences.favorites(in: panel.defaults), ["b"])
  }

  func testForgettingFavoritesRemovesOnlyTheNamedOnesAndWritesOnlyWhenOneChanged() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try PanelPreferences.saveFavorites(["a", "b"], in: panel.defaults)
    let controller = panel.buildController()
    XCTAssertEqual(controller.favoriteIDs, ["a", "b"])
    try controller.forgetFavorites(["zzz"])
    XCTAssertEqual(controller.favoriteIDs, ["a", "b"])
    try controller.forgetFavorites(["a", "zzz"])
    XCTAssertEqual(controller.favoriteIDs, ["b"])
    XCTAssertEqual(PanelPreferences.favorites(in: panel.defaults), ["b"])
  }

  func testRevealSelectsTheWallpapersLibraryFolderInFinderAndRefusesAStaleOne() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.store.librarySnapshot.wallpapers = [wallpaper("a")]
    let controller = panel.controller
    var revealed: [[URL]] = []
    controller.revealInFinder = { revealed.append($0) }
    try await controller.reveal("a")
    XCTAssertEqual(revealed, [[ClientPaths.libraryURL.appendingPathComponent("a")]])
    let message = await banner(panel) { try await controller.reveal("gone") }
    XCTAssertNotNil(message)
    XCTAssertEqual(revealed.count, 1)
  }

  // MARK: Selecting

  func testANewerSelectionReplacesOneStillWaitingAndNothingElseRunsBehindIt() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      let gate = Gate()
      var applied = 0
      panel.store.onSnapshotApplied = { applied += 1 }
      let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
      try await panel.waitUntil { panel.store.commands.isBusy }

      let first = Task { @MainActor in try await controller.select("a") }
      try await panel.waitUntil { panel.store.commands.hasWaiting(slot: BridgeStore.selectionSlot) }
      let second = Task { @MainActor in try await controller.select("c") }
      gate.open()
      _ = await running.value
      try await first.value
      try await second.value
      XCTAssertEqual(panel.store.appSnapshot.selectedWallpaperId, "c")
      XCTAssertEqual(applied, 1, "the replaced selection never reached the bridge")
    }
  }

  func testASelectionOfAStaleWallpaperIsRefusedBeforeItIsQueued() async throws {
    try await withApplyingPanel { panel, _, _ in
      let controller = panel.controller
      let gate = Gate()
      let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
      try await panel.waitUntil { panel.store.commands.isBusy }
      let message = await banner(panel) { try await controller.select("gone") }
      XCTAssertEqual(message, L("This wallpaper is no longer installed. Refresh your library."))
      XCTAssertFalse(panel.store.commands.hasWaiting(slot: BridgeStore.selectionSlot))
      gate.open()
      _ = await running.value
    }
  }

  // MARK: Applying

  func testOnlyReapplyRestartsTheShownWallpaperAndEverythingElseLeavesItRunning() async throws {
    try await withApplyingPanel { panel, bridge, log in
      let controller = panel.controller
      // Wallpaper "a" is shown on the target display, so Reapply restarts it.
      try await controller.reapply("a")
      XCTAssertEqual(bridge.ejections.map { "\($0.0)/\($0.1)" }, ["primary/a"])
      XCTAssertEqual(bridge.assignments["primary"], "a")

      // A wallpaper the display does not show is applied, not restarted.
      try await controller.select("c")
      try await controller.activate("c")
      XCTAssertEqual(bridge.assignments["primary"], "c")
      XCTAssertEqual(bridge.ejections.count, 1)

      // Choosing the shown wallpaper again, as a double-click on its tile does, keeps it running.
      log.entries.removeAll()
      try await controller.activate("c")
      XCTAssertTrue(log.entries.contains { $0.text.contains("wallpaper c display primary origin user noOp") })
      XCTAssertEqual(bridge.ejections.count, 1, "only Reapply restarts a wallpaper")
      XCTAssertEqual(bridge.applications.filter { $0 == ("primary", "c") }.count, 1)
    }
  }

  func testTheDisplayIsTheOneTargetedWhenTheUserAskedNotWhenTheCommandRuns() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      let gate = Gate()
      let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
      try await panel.waitUntil { panel.store.commands.isBusy }
      panel.navigation.targetDisplayID = "primary"
      let task = controller.launch("activate:c") { try await controller.activate("c") }
      try await panel.waitUntil {
        panel.store.commands.hasWaiting(slot: BridgeStore.activationSlot(displayId: "primary"))
      }
      XCTAssertEqual(controller.queuedApplyIDs, ["c"], "its tile shows the waiting mark")

      panel.navigation.targetDisplayID = "secondary"
      gate.open()
      _ = await running.value
      await task.value
      XCTAssertEqual(bridge.assignments["primary"], "c")
      XCTAssertEqual(bridge.assignments["secondary"], "b", "the display chosen afterwards is left alone")
      XCTAssertNil(controller.errors.message)
    }
  }

  func testApplyingHidesTheAppOnlyWhenTheSettingIsOnNothingWaitsAndNoPromptIsPending() async throws {
    let prompt = SupportPromptStore(defaults: try TemporaryDefaults.make(for: self).defaults)
    try await withApplyingPanel(supportPrompt: prompt) { panel, bridge, _ in
      let controller = panel.controller
      var hidden = 0
      controller.hideApplication = { hidden += 1 }

      try await controller.activate("c")
      XCTAssertEqual(hidden, 0, "the app stays open unless the setting is on")

      panel.defaults.set(true, forKey: PanelPreferences.hideAfterActivatingKey)
      try await controller.activate("a")
      XCTAssertEqual(hidden, 1, "the freshly applied wallpaper is made visible")

      // A switch that waits to replace the running one hides the app once, after the last.
      let gate = Gate()
      var entered = false
      bridge.beforeApply = {
        entered = true
        await gate.wait()
      }
      let first = controller.launch("activate:c") { try await controller.activate("c") }
      try await panel.waitUntil { entered }
      bridge.beforeApply = nil
      let second = controller.launch("activate:b") { try await controller.activate("b") }
      try await panel.waitUntil {
        panel.store.commands.hasWaiting(slot: BridgeStore.activationSlot(displayId: "primary"))
      }
      gate.open()
      await first.value
      await second.value
      XCTAssertEqual(bridge.assignments["primary"], "b")
      XCTAssertEqual(hidden, 2, "the first of the two did not hide the app, the last did")

      // The support prompt is waiting for the user to see the app, so applying keeps it open.
      prompt.recordDownload(wallpaperID: "c")
      try await controller.activate("c")
      XCTAssertTrue(prompt.isPending)
      XCTAssertEqual(hidden, 2)
    }
  }

  func testAFailedApplyKeepsItsNoteUntilTheNextOneSucceeds() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      bridge.failOnce = "primary=c"
      let message = await banner(panel) { try await controller.activate("c") }
      XCTAssertNotNil(message)
      XCTAssertEqual(controller.activationFailures["c"], message, "the tile and the inspector name why")
      XCTAssertEqual(bridge.assignments["primary"], "a")

      let stale = await banner(panel) { try await controller.activate("gone") }
      XCTAssertEqual(controller.activationFailures["gone"], stale)
      XCTAssertEqual(controller.activationFailures["c"], message, "another wallpaper's note is untouched")

      try await controller.activate("c")
      XCTAssertNil(controller.activationFailures["c"], "an apply that succeeds clears it")
      XCTAssertEqual(bridge.assignments["primary"], "c")
    }
  }

  func testApplyingASceneWithoutTheSharedResourcesOpensTheirSetupInsteadOfFailing() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      // "c" is a scene as far as the panel knows; its files still play once resources are there.
      panel.store.librarySnapshot.wallpapers = panel.store.librarySnapshot.wallpapers.map {
        var entry = $0
        if entry.id == "c" { entry.kind = .projectScene }
        return entry
      }
      XCTAssertEqual(controller.libraryRow(id: "c")?.kind, .scene)
      XCTAssertFalse(panel.workshop.sceneAssetsReady)
      controller.activationFailures["c"] = "An earlier failure."
      let before = bridge.assignments

      let applies: [@MainActor () async throws -> Void] = [
        { try await controller.activate("c") }, { try await controller.reapply("c") },
        { try await controller.activateAll("c") },
      ]
      for apply in applies {
        controller.downloads.closeDialog()
        let message = await banner(panel, apply)
        XCTAssertNil(message, "the setup is the answer, not an error")
        XCTAssertEqual(controller.downloads.target, WorkshopStore.sceneAssetsRequestID, "their setup opens")
        XCTAssertEqual(bridge.assignments, before, "the renderer is not asked")
      }
      XCTAssertEqual(
        controller.downloadRequestRows.map(\.id), [WorkshopStore.sceneAssetsRequestID],
        "one request for the resources, however often Apply is pressed")
      XCTAssertNil(controller.activationFailures["c"], "the resources notice says why, without a report")
      let row = try XCTUnwrap(controller.libraryRow(id: "c"))
      XCTAssertNil(controller.inspectorIssueReportURL(for: row))

      // Installed meanwhile (found without waiting for the panel to come forward), it applies.
      controller.downloads.closeDialog()
      panel.sceneAssets.available = true
      try await controller.activate("c")
      XCTAssertEqual(bridge.assignments["primary"], "c")
      XCTAssertFalse(controller.downloads.isDialogOpen)
      XCTAssertNotNil(controller.inspectorIssueReportURL(for: row), "a scene that can play gets its report")
    }
  }

  func testApplyingToEveryDisplayHidesAfterwardsAndAFailureRestoresThemAndSelectsTheWallpaper() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      var hidden = 0
      controller.hideApplication = { hidden += 1 }
      panel.defaults.set(true, forKey: PanelPreferences.hideAfterActivatingKey)

      try await controller.activateAll("c")
      XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "c"])
      XCTAssertEqual(hidden, 1)

      bridge.failOnce = "secondary=a"
      let message = await banner(panel) { try await controller.activateAll("a") }
      XCTAssertNotNil(message, "the failure says so")
      XCTAssertEqual(bridge.assignments, ["primary": "c", "secondary": "c"], "every display is put back")
      XCTAssertEqual(controller.activationFailures["a"], message)
      XCTAssertEqual(panel.store.appSnapshot.selectedWallpaperId, "a", "the wallpaper that failed stays selected, where its note is")
      XCTAssertEqual(hidden, 1, "a failed transfer hides nothing")
    }
  }

  func testPreviousGoesBackOnTheTargetDisplayAndSaysWhenThereIsNothingToGoBackTo() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      try await controller.activate("c")
      XCTAssertEqual(controller.libraryHistory.previousID, "a")
      try await controller.previousWallpaper()
      XCTAssertEqual(bridge.assignments["primary"], "a")
      XCTAssertNil(controller.libraryHistory.previousID)

      let message = await banner(panel) { try await controller.previousWallpaper() }
      XCTAssertNotNil(message, "no previous wallpaper is said, not ignored")
      XCTAssertEqual(bridge.assignments["primary"], "a")

      // A display that cannot show its own wallpaper has no history to go back through.
      bridge.mirrors["secondary"] = "primary"
      try await panel.store.refreshAllAsync()
      do {
        try await controller.previousWallpaper(displayID: "secondary")
        XCTFail("a mirrored display follows its source")
      } catch {
        XCTAssertTrue(error is InvalidControlValue)
      }
    }
  }

  func testNextMovesARotatingPlaylistAlongAndOtherwiseTakesTheLibrarysNextWallpaper() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      var asked: [String] = []
      panel.playlists.skipHandler = { display in
        asked.append(display)
        return asked.count == 1
      }
      panel.playlists.update("primary") { $0.mode = .rotate }
      try await controller.nextWallpaper()
      XCTAssertEqual(asked, ["primary"], "a rotating playlist moves along with a fresh interval")
      XCTAssertEqual(bridge.assignments["primary"], "a", "the library is not asked")

      let message = await banner(panel) { try await controller.nextWallpaper() }
      XCTAssertEqual(message, L("This display’s playlist has no other wallpaper to change to."))

      // Without a rotation the library's next wallpaper is applied and the scheduler is left alone.
      panel.playlists.update("primary") { $0.mode = .off }
      try await controller.nextWallpaper()
      XCTAssertEqual(asked.count, 2, "without a rotation Next never asks the scheduler")
      XCTAssertEqual(bridge.assignments["primary"], "b")

      // With nothing else to take it does nothing.
      panel.store.librarySnapshot.wallpapers.removeAll { $0.id != "b" }
      try await controller.nextWallpaper()
      XCTAssertEqual(bridge.assignments["primary"], "b")
      XCTAssertNil(controller.errors.message)

      bridge.mirrors["secondary"] = "primary"
      try await panel.store.refreshAllAsync()
      let mirrored = await banner(panel) { try await controller.nextWallpaper(displayID: "secondary") }
      XCTAssertNotNil(mirrored, "a mirrored display follows its source")
    }
  }

  // MARK: Refresh, playback and target

  func testPlaybackPausesEveryDisplayAndResumesThemAll() async throws {
    let bridge = PlaybackProbeBridge(noPointer: .init())
    let panel = try PanelFixture(
      store: BridgeStore(bridge: bridge), bridge: bridge, displayTitles: .renderer)
    defer { Task { await panel.shutdown() } }
    panel.store.appSnapshot.playbackState = .playing
    bridge.bundleProvider = { [store = panel.store] in
      BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
    let controller = panel.controller
    XCTAssertFalse(controller.isPlaybackPaused)
    try await controller.togglePlayback()
    XCTAssertTrue(controller.isPlaybackPaused)
    try await controller.togglePlayback()
    XCTAssertFalse(controller.isPlaybackPaused)
    XCTAssertEqual(bridge.calls, ["pause", "play"])
  }

  func testRefreshReadsEverySnapshotAgainThenRescansAndAFailedRescanReachesTheBanner() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let store = panel.store
    panel.bridge.bundleProvider = {
      BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
    panel.bridge.snapshot = panel.bridge.bundleProvider?()
    let controller = panel.controller
    let rescans = store.libraryRefreshRevision
    let reads = panel.bridge.snapshotReads
    try await controller.refresh()
    XCTAssertEqual(panel.bridge.snapshotReads, reads + 1)
    XCTAssertEqual(store.libraryRefreshRevision, rescans + 1)
    XCTAssertFalse(controller.isLibraryLoading)

    panel.bridge.bundleProvider = nil
    panel.bridge.snapshot = nil
    let message = await banner(panel) { try await controller.refresh() }
    XCTAssertNotNil(message, "a library that cannot be read is shown until it is dismissed or recurs")
  }

  func testOnlyAnEnabledDisplayThatShowsItsOwnWallpaperCanBecomeTheTarget() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      XCTAssertEqual(controller.targetDisplayID, "primary")
      try await controller.setTargetDisplay("secondary")
      XCTAssertEqual(controller.targetDisplayID, "secondary")

      for display in ["nowhere", "primary-ish"] {
        do {
          try await controller.setTargetDisplay(display)
          XCTFail("\(display) is not a display")
        } catch {
          XCTAssertTrue(error is InvalidControlValue)
        }
      }
      bridge.eligible.remove("primary")
      try await panel.store.refreshAllAsync()
      do {
        try await controller.setTargetDisplay("primary")
        XCTFail("a disabled display cannot be the target")
      } catch {
        XCTAssertTrue(error is InvalidControlValue)
      }
      bridge.eligible.insert("primary")
      bridge.mirrors["secondary"] = "primary"
      try await panel.store.refreshAllAsync()
      do {
        try await controller.setTargetDisplay("secondary")
        XCTFail("a mirror shows another display's wallpaper")
      } catch {
        XCTAssertTrue(error is InvalidControlValue)
      }
      XCTAssertEqual(controller.targetDisplayID, "secondary", "a refusal changes nothing")
    }
  }

  func testChoosingADisplaysWallpaperTargetsItAndShowsInstalledAndShowInstalledSelects() async throws {
    try await withApplyingPanel { panel, _, _ in
      let controller = panel.controller
      panel.navigation.selection = .settings
      try await controller.chooseDisplayWallpaper(on: "secondary")
      XCTAssertEqual(controller.targetDisplayID, "secondary")
      XCTAssertEqual(panel.navigation.selection, .wallpaper)

      panel.navigation.selection = .workshop
      try await controller.showInstalled("c")
      XCTAssertEqual(panel.navigation.selection, .wallpaper)
      XCTAssertEqual(panel.store.appSnapshot.selectedWallpaperId, "c")

      try await controller.openSettings(.performance)
      XCTAssertEqual(panel.navigation.selection, .settings)
      XCTAssertEqual(panel.navigation.settingsSection, .performance)
      try await controller.openSettings(.playback)
      XCTAssertEqual(panel.navigation.settingsSection, .playback)
    }
  }

  // MARK: Preview window

  func testPreviewOpensTheSelectedWallpaperOnTheTargetDisplayWithTheUnsentTextAndTouchesNothing() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.store.librarySnapshot.wallpapers = [wallpaper("preview"), wallpaper("tool", supported: false)]
    panel.store.appSnapshot = BridgeAppSnapshot(
      playbackState: .playing, selectedWallpaperId: "preview", activeWallpaperIds: [], errors: [],
      heldWallpaperIds: [])
    let before = panel.store.appSnapshot
    let controller = panel.controller

    let message = await banner(panel) { try await controller.previewWallpaper("preview") }
    XCTAssertNotNil(message, "without a preview window there is nothing to open")

    var previews: [WallpaperPreviewSession.Selection] = []
    panel.store.openPreview = { previews.append($0) }
    XCTAssertTrue(controller.previewAvailable)
    controller.errors.report(WallpaperActionError(message: "An older failure"))
    try await controller.previewWallpaper("preview", textOverrides: ["message": "Draft <b>text</b>"])
    XCTAssertEqual(
      previews,
      [.init(wallpaperID: "preview", displayID: "primary", textOverrides: ["message": "Draft <b>text</b>"])])
    XCTAssertEqual(controller.errors.actionError, "An older failure", "browsing leaves a banner alone")
    XCTAssertEqual(panel.store.appSnapshot, before)
    XCTAssertTrue(panel.store.history.entries.isEmpty)

    for refused in [
      { try await controller.previewWallpaper("tool") },
      { try await controller.previewWallpaper("preview", textOverrides: Dictionary(uniqueKeysWithValues: (0...1_000).map { ("k\($0)", "") })) },
      { try await controller.previewWallpaper("preview", textOverrides: ["big": String(repeating: "x", count: 1024 * 1024 + 1)]) },
    ] as [@MainActor () async throws -> Void] {
      do {
        try await refused()
        XCTFail("a preview outside its limits was opened")
      } catch {}
    }
    XCTAssertEqual(previews.count, 1)
  }

  // MARK: Held wallpapers and the web host

  private func configureHeld(_ panel: PanelFixture, held: [String]) {
    panel.store.librarySnapshot.wallpapers = [("alpha", "Moody Forest"), ("beta", "Quiet Lake")].map {
      .init(id: $0.0, title: $0.1, kind: .projectScene, supported: true, active: false, selected: false, previewPath: nil)
    }
    panel.store.appSnapshot.heldWallpaperIds = held
    panel.bridge.bundleProvider = { [weak store = panel.store, weak bridge = panel.bridge] in
      guard let store, let bridge else { return BridgeSnapshotBundle(app: .init(playbackState: .playing, selectedWallpaperId: nil, activeWallpaperIds: [], errors: [], heldWallpaperIds: []), library: .init(wallpapers: [], scanStatus: .init(scanning: false, done: 0, total: 0), sceneCount: 0, videoCount: 0, webpageCount: 0, unknownCount: 0), wallpaperOptions: nil, monitorInformation: .init(rows: []), settings: BridgeSnapshotFixtures.settings()) }
      var app = store.appSnapshot
      app.heldWallpaperIds.removeAll { bridge.releaseHeldCalls.contains($0) }
      return BridgeSnapshotBundle(
        app: app, library: store.librarySnapshot, wallpaperOptions: store.wallpaperOptionsSnapshot,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
  }

  func testEveryHeldWallpaperIsNamedInTheLocalizedSentenceAndOneMissingFromTheLibraryByItsID() async throws {
    try await withPanel { panel in
      configureHeld(panel, held: ["alpha", "beta", "gone"])
      let held = panel.controller.heldWallpapers
      XCTAssertEqual(held.map(\.id), ["alpha", "beta", "gone"])
      XCTAssertEqual(held.map(\.title), ["Moody Forest", "Quiet Lake", "gone"], "a display left blank is still explained")
      XCTAssertEqual(
        held.map(\.message),
        ["Moody Forest", "Quiet Lake", "gone"].map { HeldWallpaperRow.message(title: $0) })
      XCTAssertTrue(held[0].message.contains("Moody Forest"))

      panel.store.appSnapshot.heldWallpaperIds = []
      XCTAssertTrue(panel.controller.heldWallpapers.isEmpty, "nothing held, nothing to say")
    }
  }

  func testReleaseHeldReachesTheBridgeOnceForAHeldWallpaperAndRejectsAnythingElse() async throws {
    try await withPanel { panel in
      configureHeld(panel, held: ["alpha"])
      let controller = panel.controller
      // Installed but not held: a stale row from before an earlier release.
      do {
        try await controller.releaseHeld("beta")
        XCTFail("a wallpaper that is not held was released")
      } catch {
        XCTAssertTrue(error is InvalidControlValue)
      }
      // Not installed at all.
      do {
        try await controller.releaseHeld("ghost")
        XCTFail("a wallpaper that is not installed was released")
      } catch {
        XCTAssertFalse(error is InvalidControlValue, "it says the wallpaper is gone, not that the value is invalid")
      }
      XCTAssertTrue(panel.bridge.releaseHeldCalls.isEmpty, "nothing reached the bridge")

      try await controller.releaseHeld("alpha")
      XCTAssertEqual(panel.bridge.releaseHeldCalls, ["alpha"])
      XCTAssertTrue(panel.store.heldWallpaperIDs.isEmpty, "the reply's snapshot is applied")
      XCTAssertTrue(controller.heldWallpapers.isEmpty)

      // The same click arriving again is a stale one.
      do {
        try await controller.releaseHeld("alpha")
        XCTFail("a released wallpaper was released twice")
      } catch {
        XCTAssertTrue(error is InvalidControlValue)
      }
      XCTAssertEqual(panel.bridge.releaseHeldCalls, ["alpha"])
    }
  }

  func testAFailedRetryKeepsTheRowShowsTheBridgesReasonAndWorksLaterFromTheSameRow() async throws {
    try await withPanel { panel in
      configureHeld(panel, held: ["alpha"])
      let controller = panel.controller
      panel.bridge.releaseHeldFailure = WallpaperActionError(message: "The engine is unavailable.")
      controller.errors.report(WallpaperActionError(message: "An older failure"))

      await controller.launch("releaseHeld:alpha") { try await controller.releaseHeld("alpha") }.value
      XCTAssertEqual(panel.bridge.releaseHeldCalls, ["alpha"])
      XCTAssertEqual(controller.errors.message, "The engine is unavailable.")
      XCTAssertEqual(panel.store.heldWallpaperIDs, ["alpha"], "a refused retry is not a release")
      XCTAssertEqual(controller.heldWallpapers.map(\.id), ["alpha"])

      panel.bridge.releaseHeldFailure = nil
      await controller.launch("releaseHeld:alpha") { try await controller.releaseHeld("alpha") }.value
      XCTAssertTrue(panel.store.heldWallpaperIDs.isEmpty)
      XCTAssertTrue(controller.heldWallpapers.isEmpty)
    }
  }

  private func hostState(
    _ id: String, display: UInt32, revision: UInt64, phase: HostWallpaperState.Phase,
    kind: HostWallpaperState.Kind = .web, admission: UInt64? = nil, message: String? = nil,
    canRetry: Bool = false
  ) -> HostWallpaperState {
    .init(
      kind: kind, displayID: display, wallpaperID: id, startupRevision: revision,
      nativeAdmissionKey: admission, phase: phase, message: message, canRetry: canRetry)
  }

  private func configureHosts(_ panel: PanelFixture) {
    panel.store.librarySnapshot.wallpapers = ["alpha", "beta"].map {
      .init(id: $0, title: "Wallpaper \($0)", kind: .webpage, supported: true, active: false, selected: false, previewPath: nil)
    }
    panel.store.settingsSnapshot.displays = [1, 2, 3].map { id in
      .init(
        displayId: String(id), title: "Display \(id)", enabled: true, mode: .standalone,
        mirrorTargets: [], selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
        targetFps: 30, maxFps: 60, muted: false, volume: 1)
    }
    panel.store.monitorInformationSnapshot.rows = [1, 2, 3].map { id in
      .init(
        displayId: String(id), title: "Display \(id)", wallpaperId: id == 3 ? "beta" : "alpha",
        wallpaperTitle: id == 3 ? "Wallpaper beta" : "Wallpaper alpha", mirrorTargetDisplayId: nil,
        mirrorTargetTitle: nil, scalingMode: "fill", targetFps: "30", audioResponse: false)
    }
    panel.navigation.targetDisplayID = "1"
    panel.store.appSnapshot.selectedWallpaperId = "alpha"
    panel.bridge.bundleProvider = { [weak store = panel.store] in
      guard let store else { return panel.bridge.snapshot! }
      return BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot,
        wallpaperOptions: store.wallpaperOptionsSnapshot,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
  }

  func testHostStatesAreScopedToTheWallpaperTheirReasonIsPlainTextAndRetryNamesTheExactDisplay() async throws {
    try await withPanel { panel in
      configureHosts(panel)
      let controller = panel.controller
      var retries: [(String, UInt32)] = []
      panel.store.retryHostWallpaper = { retries.append(($0, $1)) }
      let reason = #"Cannot open <strong>preview</strong> & "video" content."#
      panel.store.receiveHostState(hostState("alpha", display: 1, revision: 7, phase: .loading))
      panel.store.receiveHostState(
        hostState("alpha", display: 2, revision: 8, phase: .failed, message: reason, canRetry: true))
      panel.store.receiveHostState(
        hostState("beta", display: 3, revision: 9, phase: .ready, kind: .nativeVideo, admission: 42))

      let alpha = controller.hostStates(for: "alpha")
      XCTAssertEqual(alpha.map(\.displayID), [1, 2], "only the wallpaper on show, by display")
      XCTAssertEqual(alpha[1].message, reason, "kept as text, never markup")
      XCTAssertEqual(alpha.map(\.displayTitle), ["Display 1", "Display 2"])
      XCTAssertEqual(alpha.map(\.phase), [.loading, .failed])
      XCTAssertEqual(alpha.map(\.canRetry), [false, true], "Retry only where a retry is possible")
      XCTAssertEqual(controller.hostStates.map(\.id), ["nativeVideo:3", "web:1", "web:2"], "ordered by key")

      try await controller.retryHostWallpaper("alpha", on: 2)
      XCTAssertEqual(retries.map(\.0), ["alpha"])
      XCTAssertEqual(retries.map(\.1), [2], "exactly that display")

      let beta = controller.hostStates(for: "beta")
      XCTAssertEqual(beta.map(\.kind), [.nativeVideo])
      XCTAssertEqual(beta.map(\.canRetry), [false], "a native video is never retried from here")
      panel.store.receiveHostState(hostState("beta", display: 3, revision: 9, phase: .closed, kind: .nativeVideo, admission: 42))
      XCTAssertTrue(controller.hostStates(for: "beta").isEmpty, "a closed surface has no row")
    }
  }

  func testAFailureTheHostCannotRetryOffersNoRetryAndRefusesAStaleOne() async throws {
    try await withPanel { panel in
      configureHosts(panel)
      let controller = panel.controller
      panel.store.retryHostWallpaper = { _, _ in XCTFail("a failure without a retryable page must not reload") }
      panel.store.receiveHostState(
        hostState("alpha", display: 1, revision: 7, phase: .failed, message: "The project could not be read."))
      let row = try XCTUnwrap(controller.hostStates(for: "alpha").first)
      XCTAssertEqual(row.message, "The project could not be read.")
      XCTAssertFalse(row.canRetry)
      do {
        try await controller.retryHostWallpaper("alpha", on: 1)
        XCTFail("an action from an older row must recheck retry eligibility")
      } catch {
        XCTAssertTrue(error is InvalidControlValue)
      }
    }
  }

  func testAnOldWallpapersCompletionAndCloseCannotReplaceTheNewOnesState() async throws {
    try await withPanel { panel in
      configureHosts(panel)
      let controller = panel.controller
      panel.store.retryHostWallpaper = { _, _ in XCTFail("a retired failure must not expose retry") }
      panel.store.receiveHostState(hostState("alpha", display: 1, revision: 10, phase: .loading))
      panel.store.receiveHostState(hostState("beta", display: 1, revision: 11, phase: .loading))
      panel.store.receiveHostState(hostState("alpha", display: 1, revision: 10, phase: .failed, message: "Old completion"))
      panel.store.receiveHostState(hostState("alpha", display: 1, revision: 10, phase: .closed))
      panel.store.receiveHostState(hostState("alpha", display: 1, revision: 11, phase: .failed, message: "Wrong assignment"))
      panel.store.appSnapshot.selectedWallpaperId = "beta"

      XCTAssertTrue(controller.hostStates(for: "alpha").isEmpty)
      XCTAssertEqual(controller.hostStates(for: "beta").map(\.phase), [.loading])
      XCTAssertEqual(controller.hostStates(for: "beta").map(\.canRetry), [false])

      panel.store.receiveHostState(hostState("beta", display: 1, revision: 11, phase: .ready))
      XCTAssertEqual(controller.hostStates(for: "beta").map(\.phase), [.ready])
      panel.store.receiveHostState(hostState("alpha", display: 1, revision: 10, phase: .closed))
      XCTAssertEqual(controller.hostStates(for: "beta").map(\.phase), [.ready], "a late close from a replaced surface changes nothing")
      panel.store.receiveHostState(hostState("beta", display: 1, revision: 11, phase: .closed))
      XCTAssertTrue(controller.hostStates(for: "beta").isEmpty)
      XCTAssertNil(controller.errors.message)
    }
  }
}

/// A bridge that answers play and pause with the app snapshot's playback state flipped.
private final class PlaybackProbeBridge: LayoutSnapshotBridge {
  @MainActor var calls: [String] = []

  override func pauseAll() async throws -> BridgeSnapshotBundle { try await change("pause", to: .paused) }
  override func playAll() async throws -> BridgeSnapshotBundle { try await change("play", to: .playing) }

  @MainActor private func change(_ call: String, to state: BridgePlaybackState) throws -> BridgeSnapshotBundle {
    calls.append(call)
    guard var bundle = bundleProvider?() else { throw CancellationError() }
    bundle.app.playbackState = state
    return bundle
  }
}
