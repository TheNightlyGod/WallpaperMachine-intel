import XCTest

@testable import WallpaperMachine

/// Retry for a scene that stopped after a rendering failure: only a live, enabled display can be
/// named, and the reload takes that display's wallpaper off and puts it back, no other display's.
@MainActor
final class PanelSceneRetryTests: PanelTestCase {
  /// A real panel over a two-display bridge that applies and ejects for real. Both displays show
  /// wallpaper `a`; display 7 (the primary) reports a scene that stopped drawing and display 8 one that
  /// is running. With `mirroring`, display 8 shows the primary's wallpaper by mirroring it, and it is
  /// display 8 whose scene stopped.
  private func withRetryPanel(
    mirroring: Bool = false, _ body: (PanelFixture, DisplayTransferTestBridge) async throws -> Void
  ) async throws {
    let bridge = DisplayTransferTestBridge(noPointer: .init())
    bridge.assignments = mirroring ? ["primary": "a"] : ["primary": "a", "secondary": "a"]
    bridge.mirrors = mirroring ? ["secondary": "primary"] : [:]
    bridge.physicalIDs = ["primary": 7, "secondary": 8]
    bridge.sceneUpdateModes = [
      BridgeSceneUpdateModeReport(
        displayId: 7, displayName: "Display 7", wallpaperId: "a", wallpaperTitle: "a",
        mode: mirroring ? "continuous" : "stopped_after_failure", reasons: mirroring ? ["video"] : []),
      BridgeSceneUpdateModeReport(
        displayId: 8, displayName: "Display 8", wallpaperId: "a", wallpaperTitle: "a",
        mode: mirroring ? "stopped_after_failure" : "continuous", reasons: mirroring ? [] : ["video"]),
    ]
    let store = BridgeStore(bridge: bridge)
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    do {
      try bridge.installProjects(in: panel.library)
      try await store.refreshAllAsync()
      try await panel.start()
      try await body(panel, bridge)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  /// Retry reloads a scene on its display, so only a live physical id of an enabled display can be
  /// named. Anything else is a stale request, and nothing may be ejected for it.
  func testRetryRefusesADisplayThatIsUnknownOrSwitchedOff() async throws {
    try await withRetryPanel { panel, bridge in
      for rejected: UInt32 in [99, 0, 6, 4_294_967_295] {
        do {
          try await panel.controller.retryScene(onPhysicalDisplay: rejected)
          XCTFail("A display id that names no live display must be refused: \(rejected)")
        } catch is InvalidControlValue {}
      }
      bridge.eligible = ["secondary"]
      try await panel.store.refreshAllAsync()
      do {
        try await panel.controller.retryScene(onPhysicalDisplay: 7)
        XCTFail("A display that is switched off has nothing to retry")
      } catch is InvalidControlValue {}
      XCTAssertEqual(bridge.events, [], "A refused retry must not take a wallpaper off any display")
    }
  }

  /// The one row that reads "stopped after a rendering failure" carries the control, and pressing it
  /// reloads that wallpaper on that display and no other. Like any direct action, it clears an older
  /// banner.
  func testRetryReloadsTheWallpaperOfTheStoppedDisplayOnly() async throws {
    try await withRetryPanel { panel, bridge in
      let reports = panel.controller.performanceSettings.sceneUpdates
      XCTAssertEqual(reports.map(\.displayID), [7, 8])
      XCTAssertEqual(reports.map(\.canRetry), [true, false], "A scene that is running has nothing to retry")

      panel.controller.errors.report(WallpaperActionError(message: "Older"))
      try await panel.controller.retryScene(onPhysicalDisplay: try XCTUnwrap(reports.first { $0.canRetry }).displayID)
      XCTAssertEqual(
        bridge.events, ["eject primary a", "apply primary a"],
        "Display 7 is the panel's primary display; display 8 keeps its wallpaper untouched")
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "a"])
      XCTAssertNil(panel.controller.errors.actionError, "A direct action clears the banner")
    }
  }

  /// A display that mirrors another presents a scene of its own and can stop drawing like any other,
  /// but holds no assignment: its Retry reloads the display it mirrors.
  func testRetryOnAMirroringDisplayReloadsTheDisplayItMirrors() async throws {
    try await withRetryPanel(mirroring: true) { panel, bridge in
      let reports = panel.controller.performanceSettings.sceneUpdates
      XCTAssertEqual(reports.map(\.canRetry), [false, true], "The stopped scene is the mirror's")

      try await panel.controller.retryScene(onPhysicalDisplay: 8)
      XCTAssertEqual(
        bridge.events, ["eject primary a", "apply primary a"],
        "Display 8 mirrors the primary display, so the wallpaper is reloaded there and never ejected from the mirror")
      XCTAssertEqual(bridge.assignments, ["primary": "a"])
      XCTAssertNil(panel.controller.errors.actionError)
    }
  }
}
