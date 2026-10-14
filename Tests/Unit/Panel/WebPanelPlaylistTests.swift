import XCTest

@testable import WallpaperMachine

/// The playlist actions the panel sends, checked against the store without a web view.
@MainActor
final class WebPanelPlaylistTests: XCTestCase {
  private var root: URL!
  private var defaults: UserDefaults!
  private var playlists: PlaylistStore!
  private var controller: WebPanelController!
  private var store: BridgeStore!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-playlist-\(UUID().uuidString)")
    defaults = try TemporaryDefaults.make(for: self).defaults
    playlists = PlaylistStore(defaults: defaults)
    store = BridgeStore(bridge: WallpaperBridge(noPointer: .init()))
    store.settingsSnapshot = BridgeSnapshotFixtures.settings(displays: [
      display("primary", enabled: true, mode: .standalone),
      display("mirrored", enabled: true, mode: .mirror),
    ])
    store.librarySnapshot = BridgeLibrarySnapshot(
      wallpapers: [
        BridgeWallpaperEntry(
          id: "a", title: "A", kind: .video, supported: true, active: false, selected: false, previewPath: nil),
        BridgeWallpaperEntry(
          id: "b", title: "B", kind: .video, supported: true, active: false, selected: false, previewPath: nil),
        BridgeWallpaperEntry(
          id: "app", title: "App", kind: .unknown, supported: false, active: false, selected: false,
          previewPath: nil),
      ],
      scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 0,
      videoCount: 2, webpageCount: 0, unknownCount: 1)
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    controller = WebPanelController(
      store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
      appLanguage: .english(), playlists: playlists)
  }

  override func tearDown() async throws {
    controller.stop()
    try? FileManager.default.removeItem(at: root)
  }

  private func display(_ id: String, enabled: Bool, mode: BridgeDisplayMode) -> BridgeDisplaySettingsRow {
    BridgeDisplaySettingsRow(
      displayId: id, title: id, enabled: enabled, mode: mode, mirrorTargets: [],
      selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60,
      muted: false, volume: 1)
  }

  func testSettingsReachThePlaylistOfTheNamedDisplay() async throws {
    try await controller.perform("playlistSetting", body: ["displayID": "primary", "key": "mode", "value": "rotate"])
    try await controller.perform("playlistSetting", body: ["displayID": "primary", "key": "interval", "value": 60])
    try await controller.perform("playlistSetting", body: ["displayID": "primary", "key": "dayStart", "value": 390])
    try await controller.perform("playlistSetting", body: ["displayID": "primary", "key": "dayWallpaper", "value": "b"])
    let playlist = playlists.playlist(for: "primary")
    XCTAssertEqual(playlist.mode, .rotate)
    XCTAssertEqual(playlist.interval, 60)
    XCTAssertEqual(playlist.dayStart, 390)
    XCTAssertEqual(playlist.dayWallpaperID, "b")
    let snapshot = try XCTUnwrap(controller.snapshot()["playlists"] as? [String: [String: Any]])
    XCTAssertEqual(snapshot["primary"]?["mode"] as? String, "rotate")
  }

  func testATypedIntervalOutsideTheMenuIsKept() async throws {
    try await controller.perform("playlistSetting", body: ["displayID": "primary", "key": "interval", "value": 45])
    XCTAssertEqual(playlists.playlist(for: "primary").interval, 45)
    try await controller.perform("playlistSetting", body: ["displayID": "primary", "key": "interval", "value": 7 * 24 * 60])
    XCTAssertEqual(playlists.playlist(for: "primary").interval, 7 * 24 * 60)
  }

  func testTheUnlockTriggerIsStoredAndATimeBringsTheTimerBack() async throws {
    try await controller.perform("playlistSetting", body: ["displayID": "primary", "key": "mode", "value": "rotate"])
    try await controller.perform("playlistSetting", body: ["displayID": "primary", "key": "trigger", "value": "unlock"])
    XCTAssertEqual(playlists.playlist(for: "primary").trigger, .unlock)
    XCTAssertEqual(PlaylistStore(defaults: defaults).playlist(for: "primary").trigger, .unlock)
    var snapshot = try XCTUnwrap(controller.snapshot()["playlists"] as? [String: [String: Any]])
    XCTAssertEqual(snapshot["primary"]?["trigger"] as? String, "unlock")

    try await controller.perform("playlistSetting", body: ["displayID": "primary", "key": "interval", "value": 60])
    XCTAssertEqual(playlists.playlist(for: "primary").trigger, .interval, "choosing a time is choosing the timer")
    XCTAssertEqual(playlists.playlist(for: "primary").interval, 60)
    snapshot = try XCTUnwrap(controller.snapshot()["playlists"] as? [String: [String: Any]])
    XCTAssertEqual(snapshot["primary"]?["trigger"] as? String, "interval")
  }

  func testValuesThePanelNeverOffersAreRefused() async {
    for body: [String: Any] in [
      ["displayID": "primary", "key": "interval", "value": 0],
      ["displayID": "primary", "key": "interval", "value": 7 * 24 * 60 + 1],
      ["displayID": "primary", "key": "interval", "value": 7.5],
      ["displayID": "primary", "key": "dayStart", "value": 1440],
      ["displayID": "primary", "key": "mode", "value": "sometimes"],
      ["displayID": "primary", "key": "trigger", "value": "weekly"],
      ["displayID": "primary", "key": "trigger", "value": 5],
      ["displayID": "mirrored", "key": "trigger", "value": "unlock"],
      ["displayID": "primary", "key": "nightWallpaper", "value": "app"],
      ["displayID": "mirrored", "key": "mode", "value": "rotate"],
      ["displayID": "gone", "key": "mode", "value": "rotate"],
    ] {
      do {
        try await controller.perform("playlistSetting", body: body)
        XCTFail("accepted \(body)")
      } catch {}
    }
    XCTAssertEqual(playlists.playlist(for: "primary"), DisplayPlaylist())
    XCTAssertEqual(playlists.playlist(for: "mirrored"), DisplayPlaylist())
  }

  func testTheListGrowsFromTheLibraryAndShrinksOnRequest() async throws {
    try await controller.perform("playlistAdd", body: ["ids": ["b", "a", "b"]])
    XCTAssertEqual(playlists.playlist(for: "primary").wallpaperIDs, ["b", "a"], "the target display, once each")
    do {
      try await controller.perform("playlistAdd", body: ["ids": ["missing"]])
      XCTFail("a wallpaper that is not installed cannot join a list")
    } catch {}
    try await controller.perform("playlistRemove", body: ["id": "b"])
    XCTAssertEqual(playlists.playlist(for: "primary").wallpaperIDs, ["a"])
  }

  func testChangeNowNeedsARotatingDisplay() async throws {
    do {
      try await controller.perform("playlistSkip", body: ["displayID": "primary"])
      XCTFail("a display without a scheduler to move it cannot change now")
    } catch {}
    var asked: [String] = []
    playlists.skipHandler = { display in
      asked.append(display)
      return true
    }
    try await controller.perform("playlistSkip", body: ["displayID": "primary"])
    XCTAssertEqual(asked, ["primary"])
  }

  /// A removal that holds the playlist shows in the snapshot as a paused playlist, and the
  /// panel's Resume reaches the scheduler for the display it names.
  func testResumeReachesTheSchedulerAndTheSnapshotReportsTheHold() async throws {
    playlists.update("primary") { $0.mode = .rotate }
    func held() throws -> Bool? {
      let snapshot = try XCTUnwrap(controller.snapshot()["playlists"] as? [String: [String: Any]])
      return snapshot["primary"]?["held"] as? Bool
    }
    XCTAssertEqual(try held(), false)
    playlists.setHold(.removedWallpaper, on: "primary")
    XCTAssertEqual(try held(), true)

    var asked: [String] = []
    playlists.resumeHandler = { asked.append($0) }
    try await controller.perform("playlistResume", body: ["displayID": "primary"])
    XCTAssertEqual(asked, ["primary"])
    try await controller.perform("playlistResume", body: [:])
    XCTAssertEqual(asked, ["primary", "primary"], "the target display is the default")
    for body: [String: Any] in [["displayID": "mirrored"], ["displayID": "gone"]] {
      do {
        try await controller.perform("playlistResume", body: body)
        XCTFail("resumed \(body)")
      } catch {}
    }
    XCTAssertEqual(asked.count, 2)

    playlists.setHold(nil, on: "primary")
    XCTAssertEqual(try held(), false)
  }

  func testReorderingUsesExactMembershipAndAnEligibleDisplay() async throws {
    playlists.update("primary") { $0.source = .list; $0.wallpaperIDs = ["a", "b"] }
    try await controller.perform("playlistReorder", body: ["ids": ["b", "a"], "expectedIDs": ["a", "b"]])
    XCTAssertEqual(playlists.playlist(for: "primary").wallpaperIDs, ["b", "a"])
    for body: [String: Any] in [
      ["ids": ["a", "a"], "expectedIDs": ["b", "a"]],
      ["ids": ["a", "b"], "expectedIDs": ["a", "b"]],
      ["ids": ["a", "b"], "expectedIDs": ["b", "a"], "displayID": "mirrored"],
    ] {
      do { try await controller.perform("playlistReorder", body: body); XCTFail("accepted stale/invalid order") }
      catch {}
    }
    XCTAssertEqual(playlists.playlist(for: "primary").wallpaperIDs, ["b", "a"])
  }

  func testManualPlaylistEditsWaitForActivationAndKeepEveryField() async throws {
    var release: CheckedContinuation<Void, Never>?
    let activation = Task { @MainActor in
      await store.commands.run(slot: BridgeStore.activationSlot(displayId: "primary")) {
        await withCheckedContinuation { release = $0 }
        playlists.update("primary") { $0.mode = .off }
      }
    }
    while release == nil { await Task.yield() }
    var manual: [String] = []
    controller.automations.manualChoice = { manual.append($0) }
    let first = Task { try await controller.perform("playlistSetting", body: ["displayID": "primary", "key": "mode", "value": "rotate"]) }
    let second = Task { try await controller.perform("playlistSetting", body: ["displayID": "primary", "key": "interval", "value": 60]) }
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(store.commands.waiting.count, 2)
    XCTAssertEqual(playlists.playlist(for: "primary").mode, .off)
    release?.resume()
    await activation.value
    try await first.value
    try await second.value
    XCTAssertEqual(playlists.playlist(for: "primary").mode, .rotate)
    XCTAssertEqual(playlists.playlist(for: "primary").interval, 60)
    XCTAssertEqual(manual, ["primary", "primary"])
  }

  func testAutomationActionsSaveOnlyValidInstalledTargetsAndExposeThemInSnapshot() async throws {
    try await controller.perform("automationMode", body: ["displayID": "primary", "value": "schedule"])
    try await controller.perform("automationRuleSave", body: ["displayID": "primary", "rule": [
      "weekdays": [2, 3, 4, 5, 6], "event": "sunrise", "minute": 480, "offset": -20,
      "target": ["kind": "wallpaper", "id": "a"],
    ]])
    try await controller.perform("automationLocation", body: ["latitude": 1.35, "longitude": 103.82])
    let rule = try XCTUnwrap(controller.automations.configuration(for: "primary").rules.first)
    XCTAssertEqual(rule.weekdays, [2, 3, 4, 5, 6])
    XCTAssertEqual(rule.offset, -20)
    let snapshot = controller.wallpaperAutomationSnapshot()
    XCTAssertEqual((snapshot["location"] as? [String: Double])?["latitude"], 1.35)
    let displays = try XCTUnwrap(snapshot["displays"] as? [String: [String: Any]])
    XCTAssertEqual(displays["primary"]?["mode"] as? String, "schedule")
    try await controller.perform("automationRuleRemove", body: ["displayID": "primary", "id": rule.id])
    XCTAssertTrue(controller.automations.configuration(for: "primary").rules.isEmpty)
  }

  func testAutomationRefusesMalformedDaysTimesTargetsAndMirrorsWithoutChangingSettings() async throws {
    let valid: [String: Any] = ["weekdays": [2], "event": "time", "minute": 480, "offset": 0,
                                "target": ["kind": "wallpaper", "id": "a"]]
    for (key, value): (String, Any) in [
      ("weekdays", [true]), ("weekdays", [1.5]), ("weekdays", [1, 1]), ("weekdays", []),
      ("minute", 1440), ("offset", 181), ("minute", 60.5), ("event", "sometimes"),
      ("target", ["kind": "wallpaper", "id": "app"]), ("target", ["kind": "playlist", "id": "gone"]),
    ] {
      var rule = valid; rule[key] = value
      do { try await controller.perform("automationRuleSave", body: ["rule": rule]); XCTFail("accepted \(key): \(value)") }
      catch {}
    }
    for display in ["mirrored", "gone"] {
      do { try await controller.perform("automationMode", body: ["displayID": display, "value": "schedule"]); XCTFail("accepted \(display)") }
      catch {}
    }
    XCTAssertTrue(controller.automations.configurations.isEmpty)
  }
}
