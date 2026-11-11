import Observation
import XCTest

@testable import WallpaperMachine

/// What the sidebar, the title and the banners read about the library: Now Playing, the target
/// display, the counts and the history.
@MainActor
final class PanelLibraryStateTests: PanelTestCase {
  private final class Flag: @unchecked Sendable {
    private(set) var raised = false
    func raise() { raised = true }
  }

  private func entry(_ id: String, supported: Bool = true, preview: URL? = nil) -> BridgeWallpaperEntry {
    BridgeWallpaperEntry(
      id: id, title: "Title \(id)", kind: .video, supported: supported, active: false, selected: false,
      previewPath: preview?.path)
  }

  private func target(
    _ id: String = "primary", enabled: Bool = true, mirror: Bool = false, wallpaper: String? = "a"
  ) -> TargetDisplayOption {
    TargetDisplayOption(id: id, title: "Studio", isEnabled: enabled, isMirror: mirror, wallpaperID: wallpaper)
  }

  private func row(_ id: String) -> LibraryRow {
    LibraryRow.make(entry(id), isActive: true, covers: [:], metrics: nil, update: nil, energy: nil)
  }

  // MARK: Now Playing

  func testTheCardNamesTheTargetsWallpaperAndTheStatusFollowsEveryDisplayAndTheGlobalPause() {
    let playing = NowPlayingState.make(
      target: target(), item: row("a"), hasWallpaper: true, hasOtherWallpaper: true, previousID: "b",
      isPaused: false, isBusy: false)
    XCTAssertEqual(playing.title, "Title a")
    XCTAssertEqual(playing.status, L("Playback running"))
    XCTAssertEqual(playing.detail, L("Playback running"))
    XCTAssertEqual(playing.help, "Studio · \(L("Playback running"))")
    XCTAssertEqual(playing.accessibilityLabel, L("Now playing on \("Studio")"))
    XCTAssertEqual(playing.showInLibraryLabel, L("Show \("Title a") in your library"))
    XCTAssertEqual(playing.playbackLabel, L("Pause wallpaper playback"))
    XCTAssertFalse(playing.showsPlay)
    XCTAssertTrue(playing.isEqualizerRunning)
    XCTAssertTrue(playing.canTogglePlayback && playing.canGoPrevious && playing.canGoNext)

    let paused = NowPlayingState.make(
      target: target(), item: row("a"), hasWallpaper: true, hasOtherWallpaper: true, previousID: "b",
      isPaused: true, isBusy: false)
    XCTAssertEqual(paused.status, L("Playback paused"))
    XCTAssertEqual(paused.playbackLabel, L("Resume wallpaper playback"))
    XCTAssertTrue(paused.showsPlay)
    XCTAssertFalse(paused.isEqualizerRunning, "the bars move only while the wallpaper plays")
    XCTAssertNotEqual(paused.status, playing.status)
  }

  func testNothingPlayingAnywhereSaysSoAndLocksTheToggleWhateverThePauseState() {
    for paused in [false, true] {
      let idle = NowPlayingState.make(
        target: target(wallpaper: nil), item: nil, hasWallpaper: false, hasOtherWallpaper: true,
        previousID: nil, isPaused: paused, isBusy: false)
      XCTAssertEqual(idle.status, L("No wallpaper playing"), "no assignments must not read as running or paused")
      XCTAssertEqual(idle.detail, L("Pick a wallpaper and press Play to show it here."))
      XCTAssertEqual(idle.title, L("Nothing on this display"))
      XCTAssertEqual(idle.help, idle.status)
      XCTAssertNil(idle.showInLibraryLabel)
      XCTAssertEqual(idle.playbackLabel, L("No wallpaper playing"))
      XCTAssertTrue(idle.showsPlay)
      XCTAssertFalse(idle.canTogglePlayback)
      XCTAssertFalse(idle.isEqualizerRunning)
    }
  }

  func testAnotherDisplaysWallpaperKeepsTheTogglePlayableWhileTheTargetShowsNothing() {
    let card = NowPlayingState.make(
      target: target(wallpaper: nil), item: nil, hasWallpaper: true, hasOtherWallpaper: true,
      previousID: nil, isPaused: false, isBusy: false)
    XCTAssertTrue(card.canTogglePlayback, "play and pause act on every display")
    XCTAssertEqual(card.status, L("Playback running"))
    XCTAssertEqual(card.detail, L("Playback running"), "the line reports it even when this display is empty")
    XCTAssertEqual(card.title, L("Nothing on this display"))
    let paused = NowPlayingState.make(
      target: target(wallpaper: nil), item: nil, hasWallpaper: true, hasOtherWallpaper: true,
      previousID: nil, isPaused: true, isBusy: false)
    XCTAssertTrue(paused.canTogglePlayback, "paused playback stays resumable")
    XCTAssertNotEqual(paused.status, card.status)
  }

  func testPreviousAndNextNeedADisplayThatCanShowItsOwnWallpaperAndSomethingToSwitchTo() {
    func card(_ target: TargetDisplayOption?, previous: String? = "b", other: Bool = true, busy: Bool = false)
      -> NowPlayingState
    {
      NowPlayingState.make(
        target: target, item: nil, hasWallpaper: true, hasOtherWallpaper: other, previousID: previous,
        isPaused: false, isBusy: busy)
    }
    XCTAssertTrue(card(target()).canGoPrevious && card(target()).canGoNext)
    XCTAssertFalse(card(target(), previous: nil).canGoPrevious, "no previous wallpaper still in the library")
    XCTAssertFalse(card(target(), other: false).canGoNext, "nothing else supported to switch to")
    for unusable in [target(enabled: false), target(mirror: true), nil] {
      XCTAssertFalse(card(unusable).canGoPrevious)
      XCTAssertFalse(card(unusable).canGoNext)
      XCTAssertTrue(card(unusable).canTogglePlayback, "pausing is not per display")
    }
    XCTAssertFalse(card(target(), busy: true).canTogglePlayback, "locked while a command runs")
    XCTAssertTrue(card(target(), busy: true).canGoNext, "only the toggle waits for the queue")
  }

  func testTheControllersCardUsesEveryDisplaysAssignmentAndTheGlobalPause() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      panel.navigation.targetDisplayID = "primary"
      panel.store.monitorInformationSnapshot.rows.removeAll { $0.displayId == "primary" }
      panel.store.librarySnapshot.wallpapers = [entry("second")]
      panel.store.appSnapshot = BridgeAppSnapshot(
        playbackState: .playing, selectedWallpaperId: nil, activeWallpaperIds: ["second"], errors: [],
        heldWallpaperIds: [])
      let controller = panel.controller

      XCTAssertNil(controller.targetDisplays[0].wallpaperID)
      XCTAssertEqual(controller.targetDisplays[1].wallpaperID, "second")
      XCTAssertFalse(controller.libraryRows.contains(where: \.isActive), "the target shows nothing")
      var card = controller.nowPlaying
      XCTAssertNil(card.item)
      XCTAssertTrue(card.hasWallpaper && card.canTogglePlayback, "a non-target display still needs the global control")
      let running = card.status

      let runningLabel = card.playbackLabel

      panel.store.appSnapshot.playbackState = .paused
      card = controller.nowPlaying
      XCTAssertTrue(card.canTogglePlayback)
      XCTAssertNotEqual(card.status, running)
      XCTAssertNotEqual(card.playbackLabel, runningLabel)

      panel.store.monitorInformationSnapshot.rows.removeAll()
      panel.store.appSnapshot.activeWallpaperIds = []
      card = controller.nowPlaying
      XCTAssertFalse(card.hasWallpaper)
      XCTAssertFalse(card.canTogglePlayback)
      XCTAssertEqual(card.status, L("No wallpaper playing"))
      panel.store.appSnapshot.playbackState = .playing
      XCTAssertEqual(controller.nowPlaying.status, L("No wallpaper playing"), "no assignments is not running")
    }
  }

  func testTheCardsArtworkIsTheStampedCoverAndNothingBeforeIt() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      let preview = panel.library.appendingPathComponent("first/preview.gif")
      try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Self.gif(frames: 2, brightness: 0.5).write(to: preview)
      panel.store.librarySnapshot.wallpapers = [entry("first", preview: preview), entry("second")]
      let controller = panel.controller

      var card = controller.nowPlaying
      XCTAssertEqual(card.item?.id, "first")
      XCTAssertNil(card.item?.still, "never the full-size preview while the cover is pending")
      await controller.libraryCovers.settled()
      card = controller.nowPlaying
      let stamp = try XCTUnwrap(LibraryPreviewFetcher.coverStamp(of: preview))
      XCTAssertEqual(card.item?.still, .libraryCover(file: preview, stamp: stamp))
      XCTAssertEqual(controller.nowPlaying.showInLibraryLabel, L("Show \("Title first") in your library"))
    }
  }

  func testAnAssignmentThatIsNotInTheLibraryLeavesTheCardEmpty() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      panel.store.librarySnapshot.wallpapers = [entry("elsewhere")]
      let card = panel.controller.nowPlaying
      XCTAssertNil(card.item, "the display's wallpaper is not installed")
      XCTAssertTrue(card.hasWallpaper)
      XCTAssertEqual(card.title, L("Nothing on this display"))
    }
  }

  // MARK: Displays

  func testEveryDisplayIsListedAndOnlyAnEnabledOneThatShowsItsOwnWallpaperIsSelectable() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      panel.store.settingsSnapshot.displays.append(
        BridgeDisplaySettingsRow(
          displayId: "third", title: "third", enabled: false, mode: .standalone, mirrorTargets: [],
          selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60,
          muted: false, volume: 1))
      panel.store.settingsSnapshot.displays[1].mode = .mirror
      let options = panel.controller.targetDisplays
      XCTAssertEqual(options.map(\.id), ["primary", "secondary", "third"])
      XCTAssertEqual(options.map(\.isSelectable), [true, false, false], "a mirror and a disabled display stay listed")
      XCTAssertEqual(options.map(\.isMirror), [false, true, false])
      XCTAssertEqual(options.map(\.isEnabled), [true, true, false])
      XCTAssertEqual(options.map(\.wallpaperID), ["first", "second", nil])
      XCTAssertEqual(panel.controller.targetDisplay?.id, "primary")
      panel.navigation.targetDisplayID = "gone"
      XCTAssertNil(panel.controller.targetDisplay)
    }
  }

  func testDisplaysAreNamedByTheSystemWithTheRenderersSuffixKeptAndAnUnnamedOneKeepsItsLabel() async throws {
    let names = DisplayTitleResolver(names: { ["primary": "Built-in Retina Display"] })
    try await withPanel(displayTitles: names) { panel in
      panel.configureDisplays()
      panel.store.settingsSnapshot.displays[0].title = "Vendor 1552 - Model 41055 (primary - Primary)"
      XCTAssertEqual(
        panel.controller.targetDisplays.map(\.title),
        ["Built-in Retina Display (primary - Primary)", "secondary"])
    }
  }

  // MARK: History

  func testTheHistoryIsNewestFirstLimitedToWhatIsInstalledAndSupportedAndPreviousSkipsWhatIsGone() async throws {
    try await withApplyingPanel { panel, _, _ in
      let controller = panel.controller
      try await controller.activate("c")
      try await controller.activate("b")
      XCTAssertEqual(controller.libraryHistory.recentIDs, ["b", "c", "a"])
      XCTAssertEqual(controller.libraryHistory.previousID, "c")

      panel.store.librarySnapshot.wallpapers[2].supported = false
      XCTAssertEqual(controller.libraryHistory.recentIDs, ["b", "a"], "a wallpaper that cannot run is not offered")
      XCTAssertEqual(controller.libraryHistory.previousID, "a")

      panel.store.history.clear(on: "primary")
      XCTAssertEqual(controller.libraryHistory, LibraryHistory(recentIDs: [], previousID: nil))
      panel.navigation.targetDisplayID = "secondary"
      XCTAssertEqual(controller.libraryHistory.recentIDs, [], "each display has its own")
    }
  }

  // MARK: Selection and apply state

  func testSelectionApplyStateAndLoadingFollowTheStore() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      XCTAssertFalse(controller.isLibraryLoading)
      XCTAssertNil(controller.applyingWallpaperID)
      XCTAssertTrue(controller.queuedApplyIDs.isEmpty)
      try await controller.select("c")
      XCTAssertEqual(controller.selectedWallpaperID, "c")
      XCTAssertTrue(controller.isPlaybackPaused, "the bridge reports paused")

      var applying: [String?] = []
      bridge.beforeApply = { applying.append(controller.applyingWallpaperID) }
      try await controller.activate("c")
      XCTAssertEqual(applying, ["c"], "the wallpaper being switched to wears the Applying mark")
      XCTAssertNil(controller.applyingWallpaperID)
      XCTAssertFalse(controller.isStoreBusy)
    }
  }

  // MARK: Sidebar

  func testTheSidebarCountsTheWholeLibraryTheFavoritesThatStillExistAndEveryMemberOfACollection() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      panel.store.librarySnapshot.wallpapers = ["a", "b", "c"].map { entry($0) }
      controller.favoriteIDs = ["a", "ghost"]
      try panel.collections.create(name: "Mix", wallpaperIDs: ["a", "ghost"])
      try panel.collections.create(name: "Empty")
      let counts = controller.sidebarCounts
      XCTAssertEqual(counts.all, 3)
      XCTAssertEqual(counts.favorites, 1, "a favorite that was deleted does not count")
      XCTAssertEqual(counts.updates, 0)
      XCTAssertNil(counts.updateTooltip)
      XCTAssertEqual(counts.collections.map(\.name), ["Mix", "Empty"])
      XCTAssertEqual(counts.collections.map(\.count), [2, 0], "a stale id still counts until it is pruned")
    }
  }

  func testTheSidebarFollowsACollectionThatChangesElsewhere() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let fired = Flag()
      withObservationTracking({ MainActor.assumeIsolated { _ = controller.sidebarCounts } }, onChange: { fired.raise() })
      try panel.collections.create(name: "New")
      XCTAssertTrue(fired.raised, "the collection store posts a notification, which the counter turns into an update")
      XCTAssertEqual(controller.sidebarCounts.collections.map(\.name), ["New"])
    }
  }

  func testTheUpdateDotsTooltipSaysOneOrManyAndNothingForNone() {
    func tooltip(_ updates: Int) -> String? {
      SidebarCounts(all: 3, favorites: 0, updates: updates, collections: []).updateTooltip
    }
    XCTAssertNil(tooltip(0))
    XCTAssertEqual(tooltip(1), L("1 wallpaper has an update"))
    XCTAssertEqual(tooltip(4), L("\(4) wallpapers have updates"))
  }

  // MARK: Problem report

  func testTheReportCarriesTheAppVersionTheBackendThatDrewTheWallpaperAndTheFailure() async throws {
    try await withPanel { panel in
      panel.store.librarySnapshot.wallpapers = [
        BridgeWallpaperEntry(
          id: "ghost", title: "Ghost", kind: .projectScene, supported: true, active: false,
          selected: false, previewPath: nil),
        BridgeWallpaperEntry(
          id: "123456", title: "Workshop item", kind: .video, supported: true, active: false,
          selected: false, previewPath: nil),
      ]
      panel.store.settingsSnapshot.sceneRenderers = [
        BridgeSceneBackendReport(
          displayId: 1, displayName: "Main", wallpaperId: "ghost", wallpaperTitle: "Ghost",
          backend: "native_metal", failureStage: nil, failureReason: nil, videoPath: "none",
          optimizationApplied: nil, qualityInForce: nil),
        BridgeSceneBackendReport(
          displayId: 2, displayName: "Side", wallpaperId: "ghost", wallpaperTitle: "Ghost",
          backend: "native_metal", failureStage: nil, failureReason: nil, videoPath: "none",
          optimizationApplied: nil, qualityInForce: nil),
      ]
      func fields(_ url: URL?) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(url), resolvingAgainstBaseURL: false))
        XCTAssertTrue(components.path.hasSuffix("/issues/new"))
        return Dictionary(
          uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })
      }
      func details(_ url: URL?) throws -> [String] {
        try XCTUnwrap(fields(url)["app-details"]).components(separatedBy: "\n")
      }
      let version = try XCTUnwrap(
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

      let plainFields = try fields(panel.controller.issueReportURL(for: "ghost"))
      XCTAssertEqual(plainFields["version"], version)
      XCTAssertEqual(plainFields["wallpaper"], "ghost")
      let plain = try details(panel.controller.issueReportURL(for: "ghost"))
      XCTAssertTrue(plain.contains("**Renderer:** native_metal"), "each backend once: \(plain)")
      XCTAssertTrue(plain.contains("**Type:** Scene"))
      XCTAssertFalse(plain.contains { $0.hasPrefix("**Error:**") }, "\(plain)")

      let failed = try details(panel.controller.issueReportURL(for: "ghost", failure: "The scene file is damaged."))
      XCTAssertTrue(failed.contains("**Error:** The scene file is damaged."), "\(failed)")

      let workshop = try fields(panel.controller.issueReportURL(for: "123456"))
      XCTAssertEqual(workshop["wallpaper"], "https://steamcommunity.com/sharedfiles/filedetails/?id=123456")
      XCTAssertFalse(
        workshop["app-details"]?.contains("**Renderer:**") ?? true, "nothing reported for it, nothing claimed")
      XCTAssertNil(panel.controller.issueReportURL(for: "not-installed"))

      // A scene held because Native Metal cannot draw it has no backend to name: the report says it was not drawn.
      panel.store.settingsSnapshot.sceneRenderers = [
        BridgeSceneBackendReport(
          displayId: 1, displayName: "Main", wallpaperId: "ghost", wallpaperTitle: "Ghost",
          backend: "unknown", failureStage: "unsupported",
          failureReason: "the scene uses a puppet", videoPath: "none", optimizationApplied: nil, qualityInForce: nil)
      ]
      let held = try details(panel.controller.issueReportURL(for: "ghost"))
      XCTAssertTrue(
        held.contains("**Renderer:** not drawn (unsupported: the scene uses a puppet)"), "\(held)")
      XCTAssertFalse(held.contains { $0.contains("unknown") }, "a backend nobody named is not a renderer: \(held)")
    }
  }

  func testTheReportListsThePropertiesChangedFromTheirDefaultsWithoutTypedTextOrPaths() async throws {
    try await withPanel { panel in
      panel.store.librarySnapshot.wallpapers = [
        BridgeWallpaperEntry(
          id: "ghost", title: "Ghost", kind: .projectScene, supported: true, active: false,
          selected: false, previewPath: nil),
        BridgeWallpaperEntry(
          id: "other", title: "Other", kind: .projectScene, supported: true, active: false,
          selected: false, previewPath: nil),
      ]
      typealias Context = PanelPropertyContext
      panel.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "ghost",
        properties: [
          Context.property("speed", .slider, .number(value: 0.25), defaultValue: .number(value: 1)),
          Context.property("fine", .slider, .number(value: 0.123456789), defaultValue: .number(value: 0)),
          Context.property("rain", .bool, .bool(value: true), dirty: true, defaultValue: .bool(value: false)),
          Context.property(
            "tint", .color, .colorRgb(red: 1, green: 0.5, blue: 0),
            defaultValue: .colorRgb(red: 1, green: 1, blue: 1)),
          Context.property("unchanged", .slider, .number(value: 3)),
          Context.property(
            "name", .textInput, .string(value: "my secret note"), defaultValue: .string(value: "")),
          Context.property(
            "photo", .file, .string(value: "/Users/someone/Pictures/me.jpg"), defaultValue: .string(value: "")),
        ])
      func details(_ url: URL?) throws -> String {
        let items = try XCTUnwrap(URLComponents(url: XCTUnwrap(url), resolvingAgainstBaseURL: false)?.queryItems)
        return try XCTUnwrap(items.first { $0.name == "app-details" }?.value)
      }

      let report = try details(panel.controller.issueReportURL(for: "ghost"))
      XCTAssertTrue(report.contains("`speed`: 0.25 (default: 1)"), report)
      XCTAssertTrue(report.contains("`fine`: 0.123456789 (default: 0)"), "every digit, to reproduce it: \(report)")
      XCTAssertTrue(report.contains("`rain`: true (default: false) (not applied)"), report)
      XCTAssertTrue(report.contains("`tint`: 1 0.5 0 (default: 1 1 1)"), report)
      XCTAssertFalse(report.contains("`unchanged`"), "a property at its default is not listed: \(report)")
      XCTAssertTrue(report.contains("`name`"), report)
      XCTAssertFalse(report.contains("my secret note"), "typed text stays out: \(report)")
      XCTAssertTrue(report.contains("`photo`"), report)
      XCTAssertFalse(report.contains("/Users/"), "file paths stay out: \(report)")

      let other = try details(panel.controller.issueReportURL(for: "other"))
      XCTAssertFalse(other.contains("`speed`"), "another wallpaper's options are not this one's")
    }
  }

  func testTheReportQuotesTheFilesTheLastCheckFoundMissing() throws {
    let url = LibraryIssueReport.url(
      for: row("rain"), missingFiles: [
        MissingSceneFile(layer: "Drops", path: "materials/drops.json"),
        MissingSceneFile(layer: "", path: "effects/glow/effect.json"),
      ], version: "1.0")
    let items = try XCTUnwrap(URLComponents(url: XCTUnwrap(url), resolvingAgainstBaseURL: false)?.queryItems)
    let details = try XCTUnwrap(items.first { $0.name == "app-details" }?.value)
    XCTAssertTrue(details.contains("`materials/drops.json`"), details)
    XCTAssertTrue(details.contains("Drops"), "the layer that asked for it: \(details)")
    XCTAssertTrue(details.contains("`effects/glow/effect.json`"), details)
  }

  func testTheChangedPropertyListIsCappedAndCountsTheRest() {
    let changed = (0..<25).map {
      PanelPropertyContext.property("p\($0)", .slider, .number(value: 1), defaultValue: .number(value: 0))
    }
    let lines = LibraryIssueReport.changedProperties(changed)
    XCTAssertEqual(lines.count, LibraryIssueReport.changedPropertyLimit + 1)
    XCTAssertEqual(lines.last, "- and 5 more")
  }
}
