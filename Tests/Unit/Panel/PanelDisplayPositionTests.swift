import XCTest

@testable import WallpaperMachine

/// The inspector's Position sliders: the saves, the drag previews and the rows they are drawn from,
/// against a bridge that moves a display row the way the engine does. Whether the wallpaper visibly
/// moves on a display is a desktop check, not one made here.
@MainActor
final class PanelDisplayPositionTests: XCTestCase {
  // MARK: Saving a position

  func testOneAxisReachesTheBridgeAndTheOtherKeepsItsSavedValue() async throws {
    try await Context.with { context in
      try await context.controller.setDisplayPosition("scene-1", display: "primary", x: 0.25)

      XCTAssertEqual(
        context.bridge.calls, [.init(wallpaperID: "scene-1", displayID: "primary", panX: 0.25, panY: nil)],
        "a horizontal slider must not send the vertical position along with it")
      XCTAssertEqual(context.position(), .init(x: 0.25, y: 0.8), "the axis that was not sent keeps its value")

      try await context.controller.setDisplayPosition("scene-1", display: "primary", x: 0, y: 0.1)
      XCTAssertEqual(
        context.bridge.calls.last, .init(wallpaperID: "scene-1", displayID: "primary", panX: 0, panY: 0.1),
        "both axes may be sent together, and the edges of the range are positions too")
    }
  }

  func testARequestNamingNoAxisIsRefused() async throws {
    try await Context.with { context in
      let controller = context.controller
      await assertInspectorInvalidValue("a move of no axis") {
        try await controller.setDisplayPosition("scene-1", display: "primary")
      }
      await assertInspectorInvalidValue("a preview of no axis") {
        try await controller.previewDisplayPosition("scene-1", display: "primary")
      }
      XCTAssertTrue(context.bridge.calls.isEmpty)
      XCTAssertTrue(context.bridge.previews.isEmpty)
    }
  }

  func testValuesThatAreNotAFractionAreRefusedWithoutAnyBridgeCall() async throws {
    try await Context.with { context in
      let controller = context.controller
      let bad: [Double] = [-0.1, 1.1, .nan, .infinity, -.infinity]

      for value in bad {
        await assertInspectorInvalidValue("x = \(value)") {
          try await controller.setDisplayPosition("scene-1", display: "primary", x: value, y: 0.5)
        }
        await assertInspectorInvalidValue("y = \(value)") {
          try await controller.setDisplayPosition("scene-1", display: "primary", x: 0.5, y: value)
        }
        await assertInspectorInvalidValue("a preview of x = \(value)") {
          try await controller.previewDisplayPosition("scene-1", display: "primary", x: value, y: 0.5)
        }
      }

      XCTAssertTrue(
        context.bridge.calls.isEmpty, "a value outside the display must be refused, not moved to the nearest edge")
      XCTAssertTrue(context.bridge.previews.isEmpty, "and never reaches the renderer, not even as a step")
      XCTAssertEqual(context.position(), .init(x: 0.2, y: 0.8))
    }
  }

  func testOnlySceneAndVideoWallpapersOnTheirOwnDisplaysCanBeMoved() async throws {
    try await Context.with { context in
      let controller = context.controller
      // A web page always fills its window; there is nothing to move. The wallpaper has no row
      // for the other display, and an unknown wallpaper cannot be moved at all.
      for (id, display) in [("web-1", "primary"), ("scene-1", "gone")] {
        await assertInspectorInvalidValue("a position for \(id) on \(display)") {
          try await controller.setDisplayPosition(id, display: display, x: 0.5)
        }
        await assertInspectorInvalidValue("a reset for \(id) on \(display)") {
          try await controller.resetDisplayPosition(id, display: display)
        }
      }
      do {
        try await controller.setDisplayPosition("nope", display: "primary", x: 0.5)
        XCTFail("an unknown wallpaper must be refused")
      } catch {}
      XCTAssertTrue(context.bridge.calls.isEmpty)

      // A drag step is refused for the same, before the renderer hears of it.
      for (id, display) in [("web-1", "primary"), ("scene-1", "gone"), ("nope", "primary")] {
        do {
          try await controller.previewDisplayPosition(id, display: display, x: 0.5)
          XCTFail("a preview for \(id) on \(display) must be refused")
        } catch {}
      }
      XCTAssertTrue(context.bridge.previews.isEmpty, "not even as a step")

      try await controller.setDisplayPosition("video-1", display: "primary", x: 0.6)
      XCTAssertEqual(context.bridge.calls.map(\.wallpaperID), ["video-1"], "a video can be moved too")
    }
  }

  func testResetCentresBothAxesAndReportsTheChangeOnce() async throws {
    try await Context.with { context in
      var changes: [String] = []
      context.store.onDisplayFramingChanged = { wallpaper, display in changes.append("\(wallpaper)@\(display)") }

      try await context.controller.resetDisplayPosition("scene-1", display: "primary")

      XCTAssertEqual(
        context.bridge.calls, [.init(wallpaperID: "scene-1", displayID: "primary", panX: 0.5, panY: 0.5)])
      XCTAssertEqual(changes, ["scene-1@primary"])
      XCTAssertEqual(context.position(), .centered)
      XCTAssertTrue(context.position().isCentered)

      context.bridge.failure = InspectorTestRefusal()
      do {
        try await context.controller.setDisplayPosition("scene-1", display: "primary", x: 0.9)
        XCTFail("the bridge's refusal must reach the caller")
      } catch is InspectorTestRefusal {}
      XCTAssertEqual(changes, ["scene-1@primary"], "a move the bridge refused changed nothing to report")
      XCTAssertEqual(context.position(), .centered)
    }
  }

  func testAMoveWaitsItsTurnBehindTheCommandThatIsRunning() async throws {
    try await Context.with { context in
      var release: CheckedContinuation<Void, Never>?
      let store = context.store
      let running = Task { @MainActor in
        await store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      for _ in 0..<200 where release == nil { await Task.yield() }
      XCTAssertNotNil(release, "the first command must be running before the move is sent")

      let controller = context.controller
      let move = Task { try await controller.setDisplayPosition("scene-1", display: "primary", x: 0.4) }
      for _ in 0..<200 where store.commands.waiting.isEmpty { await Task.yield() }
      XCTAssertEqual(store.commands.waiting.count, 1)
      XCTAssertTrue(
        context.bridge.calls.isEmpty, "a move that arrives mid-activation must not reach the engine ahead of it")

      release?.resume()
      _ = await running.value
      try await move.value
      XCTAssertEqual(context.bridge.calls.map(\.panX), [0.4])
    }
  }

  func testAMoveLeavesAnOlderBannerAloneAndTwoAxesOfOneDisplayKeepTheirOrder() async throws {
    try await Context.with { context in
      let controller = context.controller
      controller.errors.actionError = "An earlier failure"
      try await controller.setDisplayPosition("scene-1", display: "primary", x: 0.4)
      XCTAssertEqual(controller.errors.actionError, "An earlier failure", "a position change is not a banner-clearing action")

      var release: CheckedContinuation<Void, Never>?
      let store = context.store
      let running = Task { @MainActor in
        await store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      for _ in 0..<200 where release == nil { await Task.yield() }
      let key = InspectorAction.displayPosition("scene-1", display: "primary")
      let x = controller.launch(key, policy: .latestWins) {
        try await controller.setDisplayPosition("scene-1", display: "primary", x: 0.1)
      }
      let y = controller.launch(key, policy: .latestWins) {
        try await controller.setDisplayPosition("scene-1", display: "primary", y: 0.9)
      }
      XCTAssertTrue(controller.isBusy(key))
      release?.resume()
      _ = await running.value
      await x.value
      await y.value
      XCTAssertEqual(
        context.bridge.calls.suffix(2).map { [$0.panX, $0.panY] as [Double?] }, [[0.1, nil], [nil, 0.9]],
        "the newest value lands last")
      XCTAssertFalse(controller.isBusy(key))
    }
  }

  // MARK: Drag previews

  func testAPreviewShowsThePositionAndNeitherSavesItNorReportsAMove() async throws {
    try await Context.with { context in
      var changes: [String] = []
      context.store.onDisplayFramingChanged = { wallpaper, display in changes.append("\(wallpaper)@\(display)") }

      try await context.controller.previewDisplayPosition("scene-1", display: "primary", x: 0.25)
      try await context.controller.previewDisplayPosition("video-1", display: "primary", x: 1, y: 0)

      XCTAssertEqual(
        context.bridge.previews,
        [
          .init(wallpaperID: "scene-1", displayID: "primary", panX: 0.25, panY: nil),
          .init(wallpaperID: "video-1", displayID: "primary", panX: 1, panY: 0),
        ], "each step reaches the bridge's preview alone, with the axis it moved")
      XCTAssertTrue(context.bridge.calls.isEmpty, "a step is not a position the bridge keeps")
      XCTAssertTrue(changes.isEmpty, "nothing was moved for good, so nothing retakes the desktop picture")
      XCTAssertEqual(context.position(), .init(x: 0.2, y: 0.8), "the inspector is still told where the wallpaper is saved")
    }
  }

  func testAFailedPreviewReachesTheCallerAndMovesNothing() async throws {
    try await Context.with { context in
      context.bridge.previewFailure = InspectorTestRefusal()
      do {
        try await context.controller.previewDisplayPosition("scene-1", display: "primary", x: 0.4)
        XCTFail("the bridge's refusal must reach the caller, which ignores it")
      } catch is InspectorTestRefusal {}
      XCTAssertEqual(context.bridge.previews.count, 1)
      XCTAssertTrue(context.bridge.calls.isEmpty)
      XCTAssertEqual(context.position().x, 0.2)
      XCTAssertNil(context.controller.errors.message, "a preview step's refusal is not an error to show")
    }
  }

  func testAPreviewDoesNotWaitBehindTheCommandThatIsRunning() async throws {
    try await Context.with { context in
      var release: CheckedContinuation<Void, Never>?
      let store = context.store
      let running = Task { @MainActor in
        await store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      for _ in 0..<200 where release == nil { await Task.yield() }
      XCTAssertNotNil(release, "the first command must be running before the step is sent")

      try await context.controller.previewDisplayPosition("scene-1", display: "primary", x: 0.4)

      XCTAssertEqual(
        context.bridge.previews.map(\.panX), [0.4],
        "a step that waited for a wallpaper switch would reach the display long after the thumb moved on")
      XCTAssertTrue(store.commands.waiting.isEmpty)
      release?.resume()
      _ = await running.value
    }
  }

  func testASliderDragShowsTheNewestStepAndTheReleaseSavesItsAxisAloneOnce() async throws {
    try await Context.with { context in
      let sleeper = ManualSleeper()
      let horizontal = context.controller.displayPositionDragPump(
        "scene-1", display: "primary", axis: .horizontal, sleep: sleeper.closure)

      for value in [0.31, 0.32, 0.33, 0.34, 0.35] { horizontal.update(value) }
      for _ in 0..<40 { await Task.yield() }
      XCTAssertEqual(
        context.bridge.previews.map(\.panX), [0.31], "the first step is shown at once, the rest wait for the interval")
      sleeper.fireNext()
      for _ in 0..<40 { await Task.yield() }
      XCTAssertEqual(context.bridge.previews.map(\.panX), [0.31, 0.35])
      XCTAssertTrue(context.bridge.previews.allSatisfy { $0.panY == nil }, "a slider previews only its own axis")
      XCTAssertTrue(context.bridge.calls.isEmpty, "dragging saves nothing")

      let controller = context.controller
      try await horizontal.release(0.35) { value in
        try await controller.setDisplayPosition("scene-1", display: "primary", x: value)
      }
      XCTAssertEqual(
        context.bridge.calls, [.init(wallpaperID: "scene-1", displayID: "primary", panX: 0.35, panY: nil)],
        "the release saves the value it settled on, once")
      XCTAssertEqual(context.bridge.previews.count, 2, "and no step follows it")

      let vertical = context.controller.displayPositionDragPump(
        "scene-1", display: "primary", axis: .vertical, sleep: sleeper.closure)
      vertical.update(0.1)
      for _ in 0..<40 { await Task.yield() }
      XCTAssertEqual(context.bridge.previews.last, .init(wallpaperID: "scene-1", displayID: "primary", panX: nil, panY: 0.1))
      try await vertical.release(0.1) { value in
        try await controller.setDisplayPosition("scene-1", display: "primary", y: value)
      }
      XCTAssertEqual(
        context.bridge.calls.last, .init(wallpaperID: "scene-1", displayID: "primary", panX: nil, panY: 0.1))
    }
  }

  // MARK: Doubles

  @MainActor
  private final class Context {
    let panel: PanelFixture
    let bridge: PositionBridge
    var store: BridgeStore { panel.store }
    var controller: PanelController { panel.controller }

    init() throws {
      let bridge = PositionBridge(noPointer: .init())
      let store = BridgeStore(bridge: bridge)
      self.bridge = bridge
      let kinds: [(String, BridgeWallpaperKind)] = [
        ("scene-1", .projectScene), ("video-1", .video), ("web-1", .webpage),
      ]
      store.librarySnapshot.wallpapers = kinds.map {
        BridgeWallpaperEntry(
          id: $0.0, title: $0.0, kind: $0.1, supported: true, active: false, selected: false, previewPath: nil)
      }
      for (id, kind) in kinds {
        bridge.options[id] = BridgeSnapshotFixtures.options(
          wallpaperId: id, title: id, kind: kind,
          displayConfigurations: [Self.row("primary", "Studio Display (7 - Primary)")])
      }
      store.appSnapshot.selectedWallpaperId = "scene-1"
      store.wallpaperOptionsSnapshot = bridge.options["scene-1"]
      bridge.bundleProvider = { [store] in
        BridgeSnapshotBundle(
          app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
          monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
      }
      panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    }

    nonisolated static func row(_ id: String, _ title: String) -> BridgeDisplayConfigRow {
      BridgeDisplayConfigRow(
        displayId: id, title: title, enabled: true, scalingMode: .fill, scalingFactor: 1,
        framing: .init(panX: 0.2, panY: 0.8), targetFps: 30, maxFps: 60, muted: false, volume: 1,
        dirty: false, canRestoreDefaults: false)
    }

    /// The position of the first display of the open wallpaper, as the inspector is given it. The
    /// store follows what the bridge answered to the last move.
    func position() -> InspectorOptions.Position {
      controller.inspectorOptions(for: "scene-1")?.displays.first?.position ?? .centered
    }

    static func with(_ body: (Context) async throws -> Void) async throws {
      let context = try Context()
      do { try await body(context) } catch {
        await context.panel.shutdown()
        throw error
      }
      await context.panel.shutdown()
    }
  }
}

/// A bridge that moves a display row's position and answers with the wallpaper's options as they are
/// then, which is what the engine does; one that returned the old options could not tell a move that
/// happened from a click that was dropped.
private final class PositionBridge: LayoutSnapshotBridge {
  struct Call: Equatable {
    var wallpaperID: String
    var displayID: String
    var panX: Double?
    var panY: Double?
  }

  @MainActor var calls: [Call] = []
  /// What the next move fails with, when a test needs the bridge to refuse it.
  @MainActor var failure: Error?
  /// The positions shown for a drag in progress: they move nothing the double keeps.
  @MainActor var previews: [Call] = []
  @MainActor var previewFailure: Error?

  override func previewDisplayPosition(
    wallpaperId: String, displayId: String, panX: Double?, panY: Double?
  ) async throws {
    try await receivePreview(Call(wallpaperID: wallpaperId, displayID: displayId, panX: panX, panY: panY))
  }

  @MainActor private func receivePreview(_ call: Call) throws {
    previews.append(call)
    if let previewFailure { throw previewFailure }
  }

  override func setDisplayPosition(wallpaperId: String, displayId: String, panX: Double?, panY: Double?)
    async throws -> BridgeWallpaperMutationBundle
  {
    try await move(Call(wallpaperID: wallpaperId, displayID: displayId, panX: panX, panY: panY))
  }

  @MainActor private func move(_ call: Call) throws -> BridgeWallpaperMutationBundle {
    calls.append(call)
    if let failure { throw failure }
    guard var moved = options[call.wallpaperID], let base = bundleProvider?() else {
      throw CancellationError()
    }
    moved.displayConfigurations = moved.displayConfigurations.map { row in
      guard row.displayId == call.displayID else { return row }
      var row = row
      row.framing = BridgeFraming(
        panX: call.panX ?? row.framing.panX, panY: call.panY ?? row.framing.panY)
      return row
    }
    options[call.wallpaperID] = moved
    return BridgeWallpaperMutationBundle(
      app: base.app, library: base.library, wallpaperOptions: moved,
      monitorInformation: base.monitorInformation, settings: base.settings)
  }
}
