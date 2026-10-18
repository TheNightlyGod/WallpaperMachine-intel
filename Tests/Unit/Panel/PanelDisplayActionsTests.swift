import XCTest

@testable import WallpaperMachine

/// Settings › Displays: the rows the page and the target picker read, and the actions on a display.
@MainActor
final class PanelDisplayActionsTests: PanelTestCase {
  // MARK: Rows

  func testAnIndependentDisplaysValuesComeFromItsOwnWallpapersConfiguration() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.configureDisplays()
    let controller = panel.controller
    try await panel.start()

    var rows = controller.displayRows
    XCTAssertEqual(rows.map(\.id), ["primary", "secondary"])
    XCTAssertEqual(rows[0].fps, 24, "the open wallpaper's configuration")
    XCTAssertEqual(rows[0].volume, 0.2)
    XCTAssertEqual(rows[1].fps, 30, "another display's wallpaper has not been read: the display's saved values")
    XCTAssertEqual(rows[1].volume, 1)
    XCTAssertEqual(rows.map(\.wallpaperID), ["first", "second"])
    XCTAssertTrue(panel.bridge.optionRequests.isEmpty, "nothing is read while Settings is not on screen")

    panel.navigation.selection = .settings
    panel.show()
    await controller.displayOptions.settled()
    XCTAssertEqual(panel.bridge.optionRequests, ["second"], "only the wallpaper the inspector does not hold")
    rows = controller.displayRows
    XCTAssertEqual(rows[1].fps, 48)
    XCTAssertEqual(rows[1].volume, 0.7)
    XCTAssertFalse(rows[1].muted)

    panel.store.snapshotRevision &+= 1
    XCTAssertEqual(
      controller.displayRows[1].fps, 30, "options read for an older snapshot are never shown")
  }

  func testAMirrorShowsItsOwnValuesAndItsSourcesWallpaper() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.configureDisplays()
    panel.store.settingsSnapshot.displays[1].mode = .mirror
    panel.store.settingsSnapshot.displays[1].mirrorTargets = ["primary"]
    panel.store.settingsSnapshot.displays[1].selectedMirrorTarget = "primary"
    panel.store.settingsSnapshot.displays[1].targetFps = 15
    panel.store.settingsSnapshot.displays[1].volume = 0.4
    panel.store.settingsSnapshot.displays[1].muted = true
    panel.store.monitorInformationSnapshot.rows[1] = OrganizationFixtures.monitor("secondary", wallpaper: "first", mirroring: "primary")
    let mirror = panel.controller.displayRows[1]
    XCTAssertTrue(mirror.isMirror)
    XCTAssertEqual(mirror.fps, 15, "a mirror never takes a wallpaper's configuration")
    XCTAssertEqual(mirror.volume, 0.4)
    XCTAssertTrue(mirror.muted)
    XCTAssertEqual(mirror.mirrorTarget, "primary")
    XCTAssertEqual(mirror.mirrorTargets.map(\.id), ["primary"])
    XCTAssertEqual(mirror.wallpaperID, "first", "it shows what its source shows")
    XCTAssertFalse(mirror.isStandalone)
  }

  func testADisplayWithNoWallpaperHasNoneAndAWallpaperTheLibraryLacksShowsItsId() throws {
    let panel = try makeController()
    let controller = panel.controller
    XCTAssertNil(controller.displayRows[0].wallpaperID, "no monitor row")
    panel.store.monitorInformationSnapshot.rows = [OrganizationFixtures.monitor("primary", wallpaper: "")]
    XCTAssertNil(controller.displayRows[0].wallpaperID, "an empty id is no wallpaper")
    XCTAssertNil(controller.displayRows[0].wallpaperTitle)
    panel.store.monitorInformationSnapshot.rows = [OrganizationFixtures.monitor("primary", wallpaper: "stale")]
    XCTAssertEqual(controller.displayRows[0].wallpaperTitle, "stale")
    panel.store.librarySnapshot.wallpapers = [OrganizationFixtures.wallpaper("stale", title: "Ocean")]
    XCTAssertEqual(controller.displayRows[0].wallpaperTitle, "Ocean")
    XCTAssertTrue(controller.displayRows[0].isPrimary)
  }

  func testPlaybackCanBeAdjustedOnAnEnabledMirrorAndOnAnEnabledDisplayThatShowsAWallpaper() throws {
    let panel = try makeController()
    panel.store.settingsSnapshot.displays = [
      OrganizationFixtures.display("shows"), OrganizationFixtures.display("empty"),
      OrganizationFixtures.display("off", enabled: false), OrganizationFixtures.display("mirror", mode: .mirror),
      OrganizationFixtures.display("mirror-off", enabled: false, mode: .mirror),
    ]
    panel.store.monitorInformationSnapshot.rows = [
      OrganizationFixtures.monitor("shows", wallpaper: "a"), OrganizationFixtures.monitor("off", wallpaper: "a"),
      OrganizationFixtures.monitor("mirror", wallpaper: "a", mirroring: "shows"),
    ]
    XCTAssertEqual(
      panel.controller.displayRows.map(\.canAdjustPlayback), [true, false, false, true, false],
      "an independent display needs a wallpaper; a mirror has settings of its own")
  }

  func testDisplayTitlesUseTheSystemNameEverywhereTheRendererLabelAppears() async throws {
    let names = DisplayTitleResolver(names: { ["primary": "Built-in Retina Display"] })
    let panel = try makeController(displayTitles: names)
    defer { Task { await panel.shutdown() } }
    panel.configureDisplays()
    panel.store.librarySnapshot.wallpapers = ["first", "second"].map { OrganizationFixtures.wallpaper($0) }
    panel.store.settingsSnapshot.displays[1].mirrorTargets = ["primary"]
    panel.store.settingsSnapshot.displays[0].title = "Vendor 1552 - Model 41055 (primary - Primary)"
    panel.store.snapshotRevision &+= 1
    let controller = panel.controller
    let named = "Built-in Retina Display (primary - Primary)"

    let rows = controller.displayRows
    XCTAssertEqual(rows.map(\.title), [named, "secondary"], "a screen macOS does not name keeps the renderer's label")
    XCTAssertEqual(rows[1].mirrorTargets.map(\.title), [named])
    XCTAssertEqual(controller.targetDisplayChoices.map(\.title), [named, "secondary"])

    let layout = try await controller.saveDisplayLayout(name: "Both")
    XCTAssertEqual(layout.assignments.map(\.displayTitle), [named, "secondary"], "the stored title is the resolved one")
    XCTAssertEqual(controller.displayLayoutsState.layouts[0].assignments.map(\.displayTitle), [named, "secondary"])
  }

  func testTheTargetPickerListsEveryDisplayAndOnlyAnEnabledIndependentOneCanBeChosen() throws {
    let panel = try makeController()
    let controller = panel.controller
    panel.store.settingsSnapshot.displays = [
      OrganizationFixtures.display("primary", title: "Studio"),
      OrganizationFixtures.display("mirror", title: "TV", mode: .mirror),
      OrganizationFixtures.display("off", title: "Spare", enabled: false),
      OrganizationFixtures.display("both", title: "Both", enabled: false, mode: .mirror),
    ]
    let choices = controller.targetDisplayChoices
    XCTAssertEqual(choices.map(\.id), ["primary", "mirror", "off", "both"])
    XCTAssertEqual(choices.map(\.isSelectable), [true, false, false, false])
    XCTAssertEqual(choices[0].label, "Studio")
    XCTAssertEqual(choices[1].label, L("\("TV") (mirrored)"))
    XCTAssertEqual(choices[2].label, L("\("Spare") (disabled)"))
    XCTAssertEqual(choices[3].label, L("\("Both") (mirrored)"), "a mirror is a mirror whether or not it is enabled")
    XCTAssertEqual(choices[3].title, "Both")
  }

  /// The displays **Apply to all displays** counts (the rule itself is
  /// `InspectorPolicyTests.testApplyToAllDisplaysNeedsTwoSharedDisplaysAndAWallpaperThatCanRun`).
  func testOnlyDisplaysThatCanTakeAWallpaperOfTheirOwnAreSharedDisplays() async throws {
    try await withTwoDisplayPanel { panel, bridge in
      let controller = panel.controller
      XCTAssertEqual(
        controller.standaloneDisplayRows.map(\.id), ["primary", "secondary"],
        "the display showing the wallpaper counts too: the other display can take it")

      // A display that cannot take a wallpaper of its own leaves one display, and no button.
      bridge.eligible.remove("secondary")
      try await panel.store.refreshAllAsync()
      XCTAssertEqual(controller.standaloneDisplayRows.map(\.id), ["primary"])
      bridge.eligible.insert("secondary")
      bridge.mirrors = ["secondary": "primary"]
      try await panel.store.refreshAllAsync()
      XCTAssertEqual(
        controller.standaloneDisplayRows.map(\.id), ["primary"], "a mirror follows its source")
    }
  }

  func testCopyOrSwapIsOfferedForADisplayWithAWallpaperAndAnotherIndependentDisplay() async throws {
    try await withTwoDisplayPanel { panel, bridge in
      let controller = panel.controller
      XCTAssertEqual(controller.transferPeers(of: "primary").map(\.id), ["secondary"])
      XCTAssertEqual(controller.transferPeers(of: "secondary").map(\.id), ["primary"])
      XCTAssertTrue(controller.transferPeers(of: "gone").isEmpty)

      bridge.eligible.remove("secondary")
      try await panel.store.refreshAllAsync()
      XCTAssertTrue(controller.transferPeers(of: "primary").isEmpty, "no other display can take it")
      bridge.eligible.insert("secondary")
      bridge.assignments["secondary"] = nil
      try await panel.store.refreshAllAsync()
      XCTAssertEqual(controller.transferPeers(of: "primary").map(\.id), ["secondary"], "an empty peer can take a copy")
      XCTAssertTrue(controller.transferPeers(of: "secondary").isEmpty, "a display with no wallpaper has nothing to copy or swap")
    }
  }

  // MARK: Settings

  private func config(_ display: String, fps: UInt32 = 30, maxFps: UInt32 = 60) -> BridgeDisplayConfigRow {
    BridgeDisplayConfigRow(
      displayId: display, title: display, enabled: true, scalingMode: .fill, scalingFactor: 1, framing: .centered,
      targetFps: fps, maxFps: maxFps, muted: false, volume: 1, dirty: false, canRestoreDefaults: false)
  }

  /// A started panel over two independent displays showing wallpapers a and b, the inspector open on a.
  private func withSettingsPanel(_ body: (PanelFixture, DisplaySettingsBridge) async throws -> Void) async throws {
    let bridge = DisplaySettingsBridge(noPointer: .init())
    bridge.displays = [
      OrganizationFixtures.display("primary"),
      OrganizationFixtures.display("secondary", mirrorTargets: ["primary"]),
    ]
    bridge.monitorRows = [
      OrganizationFixtures.monitor("primary", wallpaper: "a"), OrganizationFixtures.monitor("secondary", wallpaper: "b"),
    ]
    bridge.wallpapers = ["a", "b"].map { OrganizationFixtures.wallpaper($0) }
    for id in ["a", "b"] {
      bridge.options[id] = BridgeSnapshotFixtures.options(
        wallpaperId: id, title: id, kind: .webpage, displayConfigurations: [config("primary"), config("secondary")])
    }
    let store = BridgeStore(bridge: bridge)
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    do {
      for id in ["a", "b"] { try OrganizationFixtures.installWebProject(id, in: panel.library) }
      try await store.refreshAllAsync()
      store.wallpaperOptionsSnapshot = bridge.options["a"]
      try await panel.start()
      try await body(panel, bridge)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  func testEnablingTheModeAndTheMirrorSourceGoToTheDisplayItself() async throws {
    try await withSettingsPanel { panel, bridge in
      let controller = panel.controller
      try await controller.setDisplay("secondary", .enabled(false))
      try await controller.setDisplay("secondary", .enabled(true))
      try await controller.setDisplay("secondary", .mode(.mirror))
      try await controller.setDisplay("secondary", .mirrorTarget("primary"))
      XCTAssertEqual(
        bridge.calls,
        [
          "setDisplayEnabled secondary false", "setDisplayEnabled secondary true", "setDisplayMode secondary mirror",
          "setMirrorTarget secondary primary",
        ])
      let row = controller.displayRows[1]
      XCTAssertEqual(row.mode, .mirror)
      XCTAssertEqual(row.mirrorTarget, "primary")
    }
  }

  func testAMirrorsPlaybackSettingsGoToTheMirrorAndApplyNothing() async throws {
    try await withSettingsPanel { panel, bridge in
      let controller = panel.controller
      bridge.displays[1] = OrganizationFixtures.display(
        "secondary", mode: .mirror, mirrorTargets: ["primary"], selectedMirrorTarget: "primary", maxFps: 120)
      bridge.monitorRows[1] = OrganizationFixtures.monitor("secondary", wallpaper: "a", mirroring: "primary")
      try await panel.store.refreshAllAsync()

      try await controller.setDisplay("secondary", .scalingMode(.stretch))
      try await controller.setDisplay("secondary", .scalingFactor(1.25))
      try await controller.setDisplay("secondary", .fps(120))
      try await controller.setDisplay("secondary", .volume(0.5))
      try await controller.setDisplay("secondary", .muted(true))
      XCTAssertEqual(
        bridge.calls,
        [
          "setMirrorScalingMode secondary stretch", "setMirrorScalingFactor secondary 1.25",
          "setMirrorTargetFps secondary 120", "setMirrorVolume secondary 0.5", "setMirrorMuted secondary true",
        ], "nothing is applied: a mirror has no wallpaper of its own")
      let row = controller.displayRows[1]
      XCTAssertEqual(
        [row.scalingMode == .stretch, row.scalingFactor == 1.25, row.fps == 120, row.volume == 0.5, row.muted],
        [true, true, true, true, true])
    }
  }

  func testAnIndependentDisplaysPlaybackSettingsGoToItsWallpaperAndAreAppliedAtOnce() async throws {
    try await withSettingsPanel { panel, bridge in
      let controller = panel.controller
      try await controller.setDisplay("primary", .volume(0.4))
      XCTAssertEqual(bridge.calls, ["setVolume a 0.4", "applyWallpaperOptions a false"])
      XCTAssertEqual(controller.displayRows[0].volume, 0.4)

      try await controller.setDisplay("primary", .muted(true))
      try await controller.setDisplay("primary", .scalingMode(.match))
      try await controller.setDisplay("primary", .scalingFactor(1.5))
      try await controller.setDisplay("primary", .fps(24))
      XCTAssertEqual(
        Array(bridge.calls.filter { !$0.hasPrefix("applyWallpaperOptions") }.dropFirst()),
        [
          "setMuted a true", "setScalingMode a primary match", "editScalingFactor a primary 1.5",
          "setTargetFps a primary 24",
        ])
      XCTAssertEqual(bridge.calls.filter { $0 == "applyWallpaperOptions a false" }.count, 5, "every edit is applied")
      let row = controller.displayRows[0]
      XCTAssertTrue(row.muted)
      XCTAssertEqual(row.scalingMode, .match)
      XCTAssertEqual(row.scalingFactor, 1.5)
      XCTAssertEqual(row.fps, 24)
    }
  }

  func testApplyingADisplaySettingAlsoCommitsTheWallpapersOtherPendingEdits() async throws {
    try await withSettingsPanel { panel, bridge in
      let controller = panel.controller
      // The inspector holds a scale factor for the other display that it has not sent yet.
      panel.store.editorState.setScalingText(
        "1.75", key: .init(wallpaperID: "a", fieldID: "secondary"), locale: Locale(identifier: "en_US"))
      try await controller.setDisplay("primary", .muted(true))
      XCTAssertEqual(
        bridge.calls,
        ["setMuted a true", "editScalingFactor a secondary 1.75", "applyWallpaperOptions a false"],
        "the pending draft is sent before the apply")
      XCTAssertFalse(panel.store.editorState.hasPendingEdits(wallpaperID: "a"))
    }
  }

  func testAnIndependentDisplayNeedsAnInstalledWallpaperBeforeItsSettingsCanChange() async throws {
    try await withSettingsPanel { panel, bridge in
      let controller = panel.controller
      bridge.monitorRows.removeAll { $0.displayId == "primary" }
      try await panel.store.refreshAllAsync()
      do {
        try await controller.setDisplay("primary", .volume(0.4))
        XCTFail("a display with no wallpaper has no volume of its own")
      } catch { XCTAssertEqual(error.localizedDescription, L("Choose a wallpaper for this display first.")) }

      bridge.monitorRows.append(OrganizationFixtures.monitor("primary", wallpaper: "removed"))
      try await panel.store.refreshAllAsync()
      do {
        try await controller.setDisplay("primary", .volume(0.4))
        XCTFail("a wallpaper the library no longer holds")
      } catch { XCTAssertEqual(error.localizedDescription, L("This wallpaper is no longer installed. Refresh your library.")) }
      XCTAssertTrue(bridge.calls.isEmpty, "nothing reached the engine")
    }
  }

  func testValuesNoControlOffersAreRefusedBeforeAnythingChanges() async throws {
    try await withSettingsPanel { panel, bridge in
      let controller = panel.controller
      let refused: [(String, DisplaySetting)] = [
        ("primary", .volume(1.5)), ("primary", .volume(-0.1)), ("primary", .volume(.nan)),
        ("primary", .scalingFactor(0)), ("primary", .scalingFactor(-1)), ("primary", .scalingFactor(.nan)),
        ("primary", .scalingFactor(.infinity)), ("primary", .fps(0)), ("primary", .fps(61)),
        ("secondary", .mirrorTarget("")), ("gone", .enabled(true)), ("gone", .volume(0.5)),
      ]
      for (display, setting) in refused {
        do {
          try await controller.setDisplay(display, setting)
          XCTFail("accepted \(setting) on \(display)")
        } catch { XCTAssertTrue(error is InvalidControlValue, "\(setting) on \(display): \(error)") }
      }
      XCTAssertTrue(bridge.calls.isEmpty)

      // A mirror's frame rate is held to the mirror display's own maximum.
      bridge.displays[1] = OrganizationFixtures.display(
        "secondary", mode: .mirror, mirrorTargets: ["primary"], selectedMirrorTarget: "primary", maxFps: 60)
      bridge.monitorRows[1] = OrganizationFixtures.monitor("secondary", wallpaper: "a", mirroring: "primary")
      try await panel.store.refreshAllAsync()
      do {
        try await controller.setDisplay("secondary", .fps(61))
        XCTFail("a mirror cannot run faster than its display")
      } catch { XCTAssertTrue(error is InvalidControlValue) }
      XCTAssertTrue(bridge.calls.isEmpty)
    }
  }

  func testAnIndependentDisplaysFrameRateIsHeldToTheMaximumOfItsWallpapersConfiguration() async throws {
    try await withSettingsPanel { panel, bridge in
      let controller = panel.controller
      bridge.options["a"]?.displayConfigurations[0].maxFps = 30
      do {
        try await controller.setDisplay("primary", .fps(31))
        XCTFail("the wallpaper's display configuration allows 30 fps")
      } catch { XCTAssertTrue(error is InvalidControlValue) }
      XCTAssertTrue(bridge.calls.isEmpty)
      try await controller.setDisplay("primary", .fps(30))
      XCTAssertEqual(bridge.calls, ["setTargetFps a primary 30", "applyWallpaperOptions a false"])
    }
  }

  func testDisplayChangesClearTheBannerAndWaitBehindARunningCommand() async throws {
    try await withSettingsPanel { panel, bridge in
      let controller = panel.controller
      struct Refused: LocalizedError { var errorDescription: String? { "Refused" } }
      controller.errors.report(Refused())
      let gate = QueueGate()
      let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
      try await panel.waitUntil { panel.store.commands.isBusy }
      let refresh = Task { try await controller.refreshDisplays() }
      let enable = Task { try await controller.setDisplay("secondary", .enabled(false)) }
      try await panel.waitUntil { panel.store.commands.waiting.count == 2 }
      XCTAssertNil(controller.errors.message, "a queued action clears an older banner as soon as it is asked for")
      XCTAssertTrue(bridge.calls.isEmpty)
      gate.open()
      _ = await running.value
      try await refresh.value
      try await enable.value
      XCTAssertEqual(bridge.calls, ["refreshDisplays", "setDisplayEnabled secondary false"], "in the order they were asked")
    }
  }

  func testEjectingTakesTheWallpaperOffTheDisplayAndTellsThePlaylistOnlyWhenItIsEmpty() async throws {
    try await withSettingsPanel { panel, bridge in
      let controller = panel.controller
      var removed: [String] = []
      panel.store.onUserWallpaperRemoved = { wallpaper, display in removed.append("\(wallpaper) \(display)") }
      try await controller.eject("a", from: "primary")
      XCTAssertEqual(bridge.calls, ["eject primary a"])
      XCTAssertEqual(removed, ["a primary"], "the user's removal, so a playlist does not fill the display again")
      XCTAssertNil(controller.displayRows[0].wallpaperID)
      do {
        try await controller.eject("gone", from: "secondary")
        XCTFail("a wallpaper the library no longer holds")
      } catch { XCTAssertEqual(error.localizedDescription, L("This wallpaper is no longer installed. Refresh your library.")) }
      XCTAssertEqual(bridge.calls, ["eject primary a"])
    }
  }
}
