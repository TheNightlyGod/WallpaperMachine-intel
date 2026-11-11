import Observation
import XCTest

@testable import WallpaperMachine

/// The menu bar panel's controller over a fixture source: what its buttons ask the app to do, that
/// it follows the stores only while it is open, and the Settings choice of what a click opens; and
/// that the sound edits the app makes for it leave an open inspector on its own wallpaper.
@MainActor
final class StatusPanelControllerTests: PanelTestCase {
  typealias Command = StatusPanelModel.Command

  // MARK: Fixtures

  /// Answers the panel with an observable input and records what the panel asks for.
  @MainActor
  @Observable
  final class Source: StatusPanelSource {
    var input: StatusPanelModel.Input
    @ObservationIgnored var reads = 0
    @ObservationIgnored var performed: [Command] = []
    @ObservationIgnored var volumes: [String: StatusPanelModel.Volume] = [:]
    @ObservationIgnored var volumeReads: [String] = []
    @ObservationIgnored var failure: Error?
    @ObservationIgnored var log: [String] = []

    init(_ input: StatusPanelModel.Input) { self.input = input }

    func statusPanelInput() -> StatusPanelModel.Input {
      reads += 1
      return input
    }

    func performStatusPanel(_ command: Command) async throws {
      performed.append(command)
      log.append("perform")
      if let failure { throw failure }
    }

    func statusPanelVolume(of wallpaperID: String) async throws -> StatusPanelModel.Volume {
      volumeReads.append(wallpaperID)
      guard let volume = volumes[wallpaperID] else { throw CancellationError() }
      return volume
    }
  }

  private static let library = (1...20).map { "w\($0)" }

  private func display(_ id: String, shows wallpaper: String?, recent: [String] = []) -> StatusMenuModel.Display {
    .init(id: id, title: "Display \(id)", wallpaperID: wallpaper, canPrevious: true, canNext: true,
          canRandom: true, recent: recent.map { .init(id: $0, title: "Wallpaper \($0)") })
  }

  private func input(
    displays: [StatusMenuModel.Display]? = nil, muted: Bool = false, revision: UInt64 = 1
  ) -> StatusPanelModel.Input {
    StatusPanelModel.Input(
      menu: .init(playbackIsCurrent: true, hasActiveWallpapers: true, paused: false, wallpapersMuted: muted,
                  displays: displays ?? [display("primary", shows: "w1"), display("2", shows: "w2")],
                  canLockScreen: true),
      library: Self.library.map {
        .init(id: $0, title: "Wallpaper \($0)", kind: .video, previewFile: nil, isPlayable: true)
      },
      targetDisplayID: "primary", snapshotRevision: revision)
  }

  private func makeController(
    _ source: Source, previousStrip: [String] = [], center: NotificationCenter = NotificationCenter(),
    dismiss: @escaping @MainActor () -> Void = {}
  ) -> StatusPanelController {
    let controller = StatusPanelController(
      source: source, previousStrip: previousStrip, center: center,
      random: PlaylistPlannerTests.SplitMix(state: 5), dismiss: dismiss)
    // The controller holds its source weakly, as it does the app; the test keeps it to the end.
    addTeardownBlock { @MainActor in
      controller.stop()
      withExtendedLifetime(source) {}
    }
    return controller
  }

  private func waitUntil(
    _ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      guard ContinuousClock.now < deadline else {
        XCTFail("Timed out waiting until \(what)", file: file, line: line)
        return
      }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  // MARK: Commands

  func testTheButtonsAskForTheMenusOwnCommandsOnTheChosenDisplay() async throws {
    let source = Source(input())
    let controller = makeController(source)
    controller.start()
    XCTAssertEqual(controller.panel.displayID, "primary", "The panel starts on the control panel's target display")

    controller.chooseDisplay("2")
    try await controller.previous()
    try await controller.next()
    try await controller.randomWallpaper()
    try await controller.apply("w7")
    try await controller.togglePlayback()

    XCTAssertEqual(source.performed, [
      .menu(.previous(display: "2")), .menu(.next(display: "2")), .menu(.random(display: "2")),
      .menu(.apply(wallpaper: "w7", display: "2")), .menu(.playPause),
    ])
    // The display's submenu offers the same commands, which reach the same automation path.
    let submenu = StatusMenuModel.entries(for: source.input.menu).compactMap { entry -> [StatusMenuModel.Entry]? in
      if case .submenu(let title, let entries) = entry, title == "Display 2" { return entries }
      return nil
    }.first ?? []
    let offered = submenu.compactMap { entry -> StatusMenuModel.Command? in
      if case .command(let command, _, _) = entry { return command }
      return nil
    }
    for command in [StatusMenuModel.Command.previous(display: "2"), .next(display: "2"), .random(display: "2")] {
      XCTAssertTrue(offered.contains(command), "The menu's submenu for the display offers \(command) too")
    }
    XCTAssertEqual(StatusMenuModel.Command.next(display: "2").automation, .next(display: "2"))
  }

  func testTheHeartAndTheSoundActOnTheShownWallpaper() async throws {
    let source = Source(input())
    let controller = makeController(source)
    controller.start()

    try await controller.toggleFavorite()
    try await controller.setVolume(0.25)
    try await controller.setMuted(true)
    try await controller.unmuteAll()

    XCTAssertEqual(source.performed, [
      .toggleFavorite(wallpaper: "w1"), .setVolume(wallpaper: "w1", volume: 0.25),
      .setMuted(wallpaper: "w1", muted: true), .unmuteAll,
    ])
  }

  func testAnEmptyDisplayRefusesTheHeartAndTheVolume() async throws {
    let source = Source(input(displays: [display("primary", shows: nil)]))
    let controller = makeController(source)
    controller.start()

    do {
      try await controller.toggleFavorite()
      XCTFail("There is no wallpaper to favorite")
    } catch {}
    XCTAssertEqual(source.performed, [])
    XCTAssertNil(controller.volume)
  }

  func testWindowActionsCloseThePanelBeforeTheyAct() async throws {
    let source = Source(input())
    let controller = makeController(source) { source.log.append("dismiss") }
    controller.start()
    controller.chooseDisplay("2")

    await controller.openControlPanel().value
    await controller.openSettings().value
    await controller.quit().value

    XCTAssertEqual(source.log, ["dismiss", "perform", "dismiss", "perform", "dismiss", "perform"])
    XCTAssertEqual(source.performed, [.menu(.openInPanel(display: "2")), .openSettings, .quit],
                   "The control panel opens with the panel's display as its target")
  }

  func testQuitWithoutARendererLetsShutdownRunAfterThePanelCloses() async throws {
    try await withPanel { _ in
      final class Shutdown { var finished = false }
      let shutdown = Shutdown()
      let terminated = expectation(description: "the quit wait finished")
      var dismissed = false
      var teardown: Task<Void, Never>?
      let app = AppDelegate(terminateApplication: {
        XCTAssertTrue(dismissed)
        // AppKit's terminateLater waits in a nested run loop for the asynchronous teardown.
        // Bound that wait here so a regression fails instead of hanging the test host.
        teardown = Task { @MainActor in
          await Task.yield()
          shutdown.finished = true
        }
        let deadline = Date().addingTimeInterval(2)
        while !shutdown.finished, Date() < deadline {
          _ = RunLoop.main.run(mode: .default, before: deadline)
        }
        XCTAssertTrue(shutdown.finished, "Quit must let main-actor cleanup run while it waits")
        terminated.fulfill()
      })
      XCTAssertNil(app.store, "Quit must work before the renderer is available")
      let controller = StatusPanelController(source: app, dismiss: { dismissed = true })

      await controller.quit().value
      await fulfillment(of: [terminated], timeout: 5)
      await teardown?.value
    }
  }

  func testAFailureShowsUntilAnActionSucceeds() async throws {
    let source = Source(input())
    let controller = makeController(source)
    controller.start()

    source.failure = AutomationError(message: "Nope")
    await controller.launch(controller.key("next")) { try await controller.next() }.value
    XCTAssertEqual(controller.failure, "Nope")

    source.failure = nil
    await controller.launch(controller.key("next")) { try await controller.next() }.value
    XCTAssertNil(controller.failure)
  }

  func testUpdateNoticeFollowsTheStoreAndOpensUpdatesAfterDismissal() async throws {
    let source = Source(input())
    let controller = makeController(source, dismiss: { source.log.append("dismiss") })
    controller.start()
    source.input.update = AppUpdateNotice(kind: .available, version: "2.0.0", automatic: false)
    try await waitUntil("update is visible") { controller.panel.update?.version == "2.0.0" }
    await controller.openUpdates().value
    XCTAssertEqual(source.performed.last, .openUpdates)
    XCTAssertEqual(source.log.suffix(2), ["dismiss", "perform"])
    controller.stop()
    let reads = source.reads
    source.input.update = nil
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(source.reads, reads)
  }

  // MARK: Following the stores while open

  func testNothingIsReadBeforeThePanelOpensOrAfterItCloses() async throws {
    let center = NotificationCenter()
    let source = Source(input())
    source.volumes["w1"] = .init(wallpaperID: "w1", volume: 0.5, muted: false)
    let controller = makeController(source, center: center)
    XCTAssertEqual(source.reads, 0, "A panel that is not open reads nothing")

    controller.start()
    XCTAssertEqual(source.reads, 1)

    source.input = input(displays: [display("primary", shows: "w3"), display("2", shows: "w2")])
    try await waitUntil("the panel follows the store") { controller.panel.wallpaper?.id == "w3" }

    let reads = source.reads
    center.post(name: PlaybackPreferences.didChangeNotification, object: nil)
    try await waitUntil("a preference change is read") { source.reads > reads }

    controller.stop()
    let closed = source.reads
    source.input = input(displays: [display("primary", shows: "w4"), display("2", shows: "w2")])
    for name in StatusPanelController.notifications { center.post(name: name, object: nil) }
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(source.reads, closed, "A closed panel neither observes the stores nor hears the preferences")
    XCTAssertEqual(controller.panel.wallpaper?.id, "w3")
  }

  func testTheVolumeIsReadForTheShownWallpaperAgainAfterEachSnapshot() async throws {
    let source = Source(input(revision: 1))
    source.volumes["w1"] = .init(wallpaperID: "w1", volume: 0.4, muted: false)
    let controller = makeController(source)
    controller.start()
    await controller.settled()
    XCTAssertEqual(controller.volume?.volume, 0.4)

    source.volumes["w1"] = .init(wallpaperID: "w1", volume: 0.7, muted: true)
    source.input = input(revision: 2)
    try await waitUntil("the new snapshot's volume is shown") { controller.volume?.volume == 0.7 }
    XCTAssertEqual(controller.volume?.muted, true)
    XCTAssertEqual(source.volumeReads, ["w1", "w1"], "Read once per snapshot, not on every refresh")
  }

  func testMuteAllIsReportedSoTheSoundCanBeLocked() async throws {
    let source = Source(input(muted: true))
    let controller = makeController(source)
    controller.start()
    XCTAssertTrue(controller.panel.wallpapersMuted)
  }

  // MARK: The quick switcher

  func testTheBatchStaysPutWhileOpenAndAvoidsTheLastOpening() async throws {
    let source = Source(input())
    let first = makeController(source)
    first.start()
    let shown = first.stripIDs
    XCTAssertEqual(shown.first, "w1")
    XCTAssertEqual(shown.count, StatusPanelModel.stripSize)

    source.input = input(revision: 9)
    try await waitUntil("the refresh lands") { source.reads > 1 }
    XCTAssertEqual(first.stripIDs, shown, "A refresh does not move the tiles under the pointer")
    first.stop()

    let reopenedSource = Source(input())
    let reopened = makeController(reopenedSource, previousStrip: shown)
    reopened.start()
    XCTAssertEqual(reopened.stripIDs.first, "w1")
    XCTAssertTrue(Set(reopened.stripIDs.dropFirst()).isDisjoint(with: shown),
                  "The next opening shows wallpapers the last one did not")

    reopened.chooseDisplay("2")
    XCTAssertEqual(reopened.stripIDs.first, "w2", "Another display draws around its own wallpaper")
  }

  func testTheCaptionStaysWithTheBatchOnShowUntilAnotherIsDrawn() async throws {
    var favorite = input(displays: [display("primary", shows: "w1")])
    favorite.favorites = ["w5"]
    let source = Source(favorite)
    let controller = makeController(source)
    controller.start()
    XCTAssertEqual(controller.stripIDs, ["w1", "w5"])
    XCTAssertEqual(controller.panel.stripSource, .favorites)

    // A click on the one favorite: the display shows it, so a new draw would take the whole library.
    var applied = favorite
    applied.menu.displays = [display("primary", shows: "w5")]
    source.input = applied
    try await waitUntil("the panel follows the store") { controller.panel.wallpaper?.id == "w5" }
    XCTAssertEqual(controller.stripIDs, ["w1", "w5"], "The tiles under the pointer stay")
    XCTAssertEqual(controller.panel.stripSource, .favorites, "and so does what they are called")

    controller.showOtherWallpapers()
    XCTAssertEqual(controller.panel.stripSource, .all)
    XCTAssertEqual(controller.stripIDs.first, "w5")
    XCTAssertEqual(controller.stripIDs.count, StatusPanelModel.stripSize)
  }

  func testOnlyTheCoversOnShowAreStamped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("status-panel-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    var fixture = input(displays: [display("primary", shows: "w1", recent: ["w20", "w19"])])
    fixture.library = Self.library.map {
      .init(id: $0, title: $0, kind: .scene, previewFile: root.appendingPathComponent("\($0).jpg"), isPlayable: true)
    }
    let source = Source(fixture)
    let controller = makeController(source)
    controller.start()
    await controller.settled()

    let shown = Set(controller.panel.strip.map(\.id) + controller.panel.recent.map(\.id) + ["w1"])
    XCTAssertEqual(Set(controller.coverStamps.keys), shown, "The panel never stamps the whole library")
    XCTAssertNotNil(controller.panel.wallpaper.flatMap(controller.cover(for:)))
  }

  // MARK: Settings › General

  func testWhatAClickOpensIsSavedAndResetWithEverySetting() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertEqual(controller.statusItemClick, .panel, "A click opens the panel until the user chooses the menu")

      try await controller.setStatusItemClick(.menu)
      XCTAssertEqual(StatusItemClick.current(in: panel.defaults), .menu)
      XCTAssertEqual(controller.statusItemClick, .menu)
      XCTAssertEqual(panel.buildController().statusItemClick, .menu, "The choice survives a relaunch")

      panel.dialogs.confirmAnswer = true
      try await controller.resetAllSettings()
      XCTAssertEqual(StatusItemClick.current(in: panel.defaults), .panel)
    }
  }

  func testAFavoriteSavedFromTheMenuBarShowsInAnOpenControlPanel() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      panel.store.librarySnapshot = BridgeLibrarySnapshot(
        wallpapers: [
          BridgeWallpaperEntry(
            id: "menu-bar", title: "Menu bar", kind: .video, supported: true, active: false, selected: false,
            previewPath: nil)
        ],
        scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 0,
        videoCount: 1, webpageCount: 0, unknownCount: 0)
      XCTAssertFalse(controller.favoriteIDs.contains("menu-bar"))

      try PanelPreferences.toggleFavorite("menu-bar", in: panel.defaults)
      try await waitUntil("the open panel reads the favorites again") {
        controller.favoriteIDs.contains("menu-bar")
      }

      try await controller.toggleFavorite("menu-bar")
      XCTAssertFalse(PanelPreferences.favorites(in: panel.defaults).contains("menu-bar"),
                     "The panel's own heart works on the favorites the menu bar saved, not an old copy")
    }
  }

  // MARK: The sound edits the app makes for it

  /// The menu bar panel changes the sound of the wallpaper on a display while the control panel's
  /// inspector may show another one: the inspector keeps its options and the drag on them.
  func testTheSoundOfAnotherWallpaperLeavesTheInspectorOnItsOwn() async throws {
    let bridge = SoundBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    bridge.store = store
    store.librarySnapshot.wallpapers = ["open", "shown"].map {
      BridgeWallpaperEntry(
        id: $0, title: $0, kind: .video, supported: true, active: $0 == "shown", selected: $0 == "open",
        previewPath: nil)
    }
    store.appSnapshot.selectedWallpaperId = "open"
    store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "open", kind: .video)
    let drag = WallpaperEditorState.FieldKey(wallpaperID: "open", fieldID: "speed")
    store.editorState.setPropertyPreview(.number(value: 2), key: drag)
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    do {
      try await store.setVolumeAsync(wallpaperId: "shown", volume: 0.3, keepingOpenOptions: true)
      try await store.setMutedAsync(wallpaperId: "shown", muted: true, keepingOpenOptions: true)

      XCTAssertEqual(bridge.calls, ["volume shown 0.3", "muted shown true"])
      XCTAssertNotNil(panel.controller.inspectorOptions(for: "open"), "The inspector does not fall back to loading")
      XCTAssertEqual(store.editorState.propertyPreviews(wallpaperID: "open").map(\.propertyId), ["speed"],
                     "A drag on the inspector's wallpaper goes on")

      // An edit of the wallpaper the inspector shows still shows there.
      try await store.setVolumeAsync(wallpaperId: "open", volume: 0.6, keepingOpenOptions: true)
      XCTAssertEqual(try XCTUnwrap(panel.controller.inspectorOptions(for: "open")).volume, Double(Float(0.6)))
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }
}

/// Answers a sound edit as the engine does: with the options of the wallpaper it edited.
private final class SoundBridge: LayoutSnapshotBridge {
  @MainActor weak var store: BridgeStore?
  @MainActor var calls: [String] = []

  override func setVolume(wallpaperId: String, volume: Float) async throws -> BridgeWallpaperMutationBundle {
    try await edited("volume \(wallpaperId) \(volume)", wallpaperId) { $0.volume = volume }
  }

  override func setMuted(wallpaperId: String, muted: Bool) async throws -> BridgeWallpaperMutationBundle {
    try await edited("muted \(wallpaperId) \(muted)", wallpaperId) { $0.muted = muted }
  }

  @MainActor private func edited(
    _ call: String, _ id: String, _ edit: (inout BridgeWallpaperOptionsSnapshot) -> Void
  ) throws -> BridgeWallpaperMutationBundle {
    calls.append(call)
    guard let store else { throw CancellationError() }
    var options = BridgeSnapshotFixtures.options(wallpaperId: id, kind: .video)
    edit(&options)
    return BridgeWallpaperMutationBundle(
      app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: options,
      monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
  }
}
