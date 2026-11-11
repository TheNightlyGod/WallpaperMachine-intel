import XCTest

@testable import WallpaperMachine

/// The Compatibility check card at the panel level: what it is certified against, which backend it
/// names, when a check is refused, and that a result is shown only for the wallpaper and display it
/// was taken for.
@MainActor
final class PanelCompatibilityTests: PanelTestCase {
  private func withFixture(_ body: (PanelFixture) async throws -> Void) async throws {
    let panel = try makeController()
    do {
      let store = panel.store
      panel.navigation.targetDisplayID = "7"
      store.appSnapshot.selectedWallpaperId = "one"
      store.librarySnapshot.wallpapers = ["one", "two"].map {
        .init(
          id: $0, title: $0, kind: .video, supported: true, active: false, selected: $0 == "one",
          previewPath: nil)
      }
      store.settingsSnapshot.displays = [
        .init(
          displayId: "7", title: "Display", enabled: true, mode: .standalone, mirrorTargets: [],
          selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 60, maxFps: 60,
          muted: false, volume: 1)
      ]
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "one", kind: .video)
      try await body(panel)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  func testTheBackendNamedIsTheOneRunningThisWallpaperOnTheTargetDisplayNotAPreference() async throws {
    try await withFixture { panel in
      let store = panel.store
      store.settingsSnapshot.videoBackends = [
        .init(
          displayId: 7, displayName: "Display", wallpaperId: "one", wallpaperTitle: "One", backend: "legacy",
          fallbackReason: "Target FPS is below content"),
        .init(
          displayId: 8, displayName: "Other", wallpaperId: "one", wallpaperTitle: "One", backend: "native",
          fallbackReason: nil),
      ]
      var state = try XCTUnwrap(panel.controller.compatibilityState)
      XCTAssertEqual(state.backend, "legacy")
      XCTAssertEqual(state.fallbackReason, "Target FPS is below content")

      store.settingsSnapshot.videoBackends.removeFirst()
      state = try XCTUnwrap(panel.controller.compatibilityState)
      XCTAssertNil(state.backend, "another display's native backend cannot certify this target")

      store.settingsSnapshot.videoBackends = [
        .init(
          displayId: 7, displayName: "Display", wallpaperId: "two", wallpaperTitle: "Two", backend: "native",
          fallbackReason: nil)
      ]
      XCTAssertNil(
        panel.controller.compatibilityState?.backend,
        "a previous wallpaper's report cannot leak into this card")

      // A scene's renderer report counts too, when no video report names the wallpaper.
      store.settingsSnapshot.videoBackends = []
      store.settingsSnapshot.sceneRenderers = [
        .init(
          displayId: 7, displayName: "Display", wallpaperId: "one", wallpaperTitle: "One", backend: "metal",
          failureStage: nil, failureReason: nil, videoPath: "none", optimizationApplied: nil, qualityInForce: nil)
      ]
      XCTAssertEqual(panel.controller.compatibilityState?.backend, "metal")
    }
  }

  func testStableDisplaySelectorsResolveTheActualBackendWithoutMatchingAnotherDisplay() async throws {
    try await withFixture { panel in
      for selector in ["primary", "identity:{\"uuid\":\"AABB\"}"] {
        panel.navigation.targetDisplayID = selector
        panel.store.settingsSnapshot.displays[0].displayId = selector
        panel.store.settingsSnapshot.displays[0].title = "Studio Display (7 - Primary)"
        panel.store.settingsSnapshot.videoBackends = [
          .init(
            displayId: 8, displayName: "Other", wallpaperId: "one", wallpaperTitle: "One", backend: "native",
            fallbackReason: nil),
          .init(
            displayId: 7, displayName: "Studio", wallpaperId: "one", wallpaperTitle: "One", backend: "legacy",
            fallbackReason: "Target FPS is below content"),
        ]
        let state = try XCTUnwrap(panel.controller.compatibilityState)
        XCTAssertEqual(state.backend, "legacy", selector)
        XCTAssertEqual(state.fallbackReason, "Target FPS is below content", selector)
      }
    }
  }

  func testAStaleCardOrATargetThatCannotBeCheckedIsRefusedWithoutStartingACheck() async throws {
    try await withFixture { panel in
      let controller = panel.controller
      do {
        try await controller.checkCompatibility("two", display: "7")
        XCTFail("a wallpaper that is not selected")
      } catch {
        XCTAssertEqual(
          error.localizedDescription, "Wallpaper settings are unavailable. Refresh Library and retry.",
          "the options held are for the selected wallpaper, not the card's")
      }
      await assertInspectorInvalidValue("a display that is not the target") {
        try await controller.checkCompatibility("one", display: "8")
      }
      panel.store.settingsSnapshot.displays[0].mode = .mirror
      await assertInspectorInvalidValue("a mirror, which follows its source") {
        try await controller.checkCompatibility("one", display: "7")
      }
      XCTAssertEqual(controller.compatibilityState?.canCheck, false)
      panel.store.settingsSnapshot.displays[0].mode = .standalone
      panel.store.settingsSnapshot.displays[0].enabled = false
      await assertInspectorInvalidValue("a disabled display") {
        try await controller.checkCompatibility("one", display: "7")
      }
      panel.store.settingsSnapshot.displays[0].enabled = true
      XCTAssertEqual(controller.compatibilityState?.canCheck, true)

      panel.store.wallpaperOptionsSnapshot = nil
      do {
        try await controller.checkCompatibility("one", display: "7")
        XCTFail("with no options for the wallpaper there is nothing to certify")
      } catch {
        XCTAssertEqual(error.localizedDescription, "Wallpaper settings are unavailable. Refresh Library and retry.")
      }
      XCTAssertEqual(controller.compatibilityState?.canCheck, false)
      XCTAssertFalse(panel.compatibility.checking)
      XCTAssertEqual(panel.compatibility.checks, [])
    }
  }

  func testTheCheckedRateIsLoweredByAMirrorAndByTheGlobalCap() async throws {
    try await withFixture { panel in
      panel.store.settingsSnapshot.displays.append(
        .init(
          displayId: "8", title: "Mirror", enabled: true, mode: .mirror, mirrorTargets: ["7"],
          selectedMirrorTarget: "7", scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60,
          muted: false, volume: 1))
      panel.controller.reconcileInspectorContext()
      XCTAssertEqual(
        panel.compatibility.context?.targetFPS, 30,
        "a 30 FPS mirror makes the whole group fall back, so a 60 FPS source is not certified")
      panel.store.settingsSnapshot.frameRateCap = 24
      panel.controller.reconcileInspectorContext()
      XCTAssertEqual(panel.compatibility.context?.targetFPS, 24)
    }
  }

  func testAResultIsShownOnlyForTheWallpaperAndDisplayItWasTakenForAndTheReinstallRuleFollowsIt() async throws {
    try await withFixture { panel in
      let controller = panel.controller
      XCTAssertEqual(controller.compatibilityState?.checks, [], "not checked yet on this display")
      XCTAssertEqual(controller.compatibilityState?.isChecking, false)

      // The fixture library holds no project folder, so the installed files are what is unavailable.
      try await controller.checkCompatibility("one", display: "7")
      var state = try XCTUnwrap(controller.compatibilityState)
      XCTAssertFalse(state.checks.isEmpty)
      XCTAssertFalse(state.isChecking)
      XCTAssertEqual(state.checks.first?.id, "target")
      XCTAssertTrue(state.checks.contains { $0.id == "project" && $0.status == .unavailable })
      XCTAssertGreaterThan(state.unavailableCount, 0)
      XCTAssertFalse(state.foundNoProblems)
      XCTAssertTrue(
        state.installedFilesAreUnavailable, "a missing project is what a fresh copy from the Workshop repairs")

      // Another wallpaper's card shows nothing, before and after the stores catch up.
      panel.store.appSnapshot.selectedWallpaperId = "two"
      panel.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "two", kind: .video)
      state = try XCTUnwrap(controller.compatibilityState)
      XCTAssertEqual(state.wallpaperID, "two")
      XCTAssertEqual(state.checks, [], "one's result is not two's")
      controller.reconcileInspectorContext()
      XCTAssertEqual(panel.compatibility.checks, [], "the store drops it when the context changes")

      // An unknown wallpaper type is not repairable by reinstalling.
      let unknown = CompatibilityState(
        wallpaperID: "x", displayID: "7", kind: .unknown, isChecking: false,
        checks: [.init(id: "project", status: .unavailable, title: "", detail: "")], backend: nil,
        fallbackReason: nil, canCheck: true)
      XCTAssertFalse(unknown.installedFilesAreUnavailable)
      let lockOnly = CompatibilityState(
        wallpaperID: "x", displayID: "7", kind: .video, isChecking: false,
        checks: [.init(id: "lockScreen", status: .unavailable, title: "", detail: "")], backend: nil,
        fallbackReason: nil, canCheck: true)
      XCTAssertFalse(lockOnly.installedFilesAreUnavailable, "the lock screen is not repaired by a fresh copy")
      let clean = CompatibilityState(
        wallpaperID: "x", displayID: "7", kind: .video, isChecking: false,
        checks: [.init(id: "project", status: .ok, title: "", detail: "")], backend: nil,
        fallbackReason: nil, canCheck: true)
      XCTAssertTrue(clean.foundNoProblems)
    }
  }
}
