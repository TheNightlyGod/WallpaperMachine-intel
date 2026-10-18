import Observation
import XCTest

@testable import WallpaperMachine

/// A typed getter that reads a store SwiftUI cannot see must read its counter first, or its view
/// silently freezes. Each inspector getter is read under observation and the state it depends on is
/// changed; the read must be told.
@MainActor
final class PanelInspectorObservationTests: XCTestCase {
  private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
  }

  /// Whether reading `read` is told of the change `change` makes.
  private func isTold(_ read: () -> Void, after change: () -> Void) -> Bool {
    let flag = Flag()
    withObservationTracking(read) { flag.set() }
    change()
    return flag.isSet
  }

  func testTheOptionsAreToldOfWhateverTheRowsAreBuiltFrom() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      let store = context.store
      let read = { _ = controller.inspectorOptions(for: "wp") }

      XCTAssertTrue(isTold(read) { store.wallpaperOptionsSnapshot?.dirty = true }, "the bridge's options")
      XCTAssertTrue(
        isTold(read) { controller.setPropertyText("typed", property: "note", in: "wp") }, "typed text")
      XCTAssertTrue(
        isTold(read) { controller.pendingPropertyValues["wp"] = ["mode": .bool(value: true)] },
        "a value on its way")
      XCTAssertTrue(
        isTold(read) { controller.propertyPathErrors["wp"] = ["cover": "Failed"] }, "a path failure")
      // A measured file matters only to a wallpaper that has a file property with a path.
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "wp", kind: .webpage,
        properties: [PanelPropertyContext.property("cover", .file, .string(value: "/a/cover.png"))])
      XCTAssertTrue(
        isTold(read) { controller.propertyAssets["wp"] = ["cover": PanelPropertyAsset(path: "/a/cover.png", name: "cover.png")] },
        "a measured file")
      XCTAssertTrue(
        isTold(read) { store.settingsSnapshot.frameRateCap = 12 },
        "the settings the display cards and the native-player note read")
      XCTAssertTrue(isTold(read) { store.webWallpaperDeliveryRevision &+= 1 }, "the running host's report")

      // The lock: a command running or waiting, or this wallpaper being applied.
      var release: CheckedContinuation<Void, Never>?
      let told = Flag()
      withObservationTracking(read) { told.set() }
      let running = Task { @MainActor in
        await store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      for _ in 0..<200 where release == nil { await Task.yield() }
      XCTAssertTrue(told.isSet, "a command starting locks the controls")
      release?.resume()
      _ = await running.value

      let pending = Flag()
      withObservationTracking(read) { pending.set() }
      let apply = controller.launch(InspectorAction.apply("wp")) { try await controller.apply("wp") }
      await apply.value
      XCTAssertTrue(pending.isSet)
    }
  }

  func testTheStatesOfTheStoresThatAreNotObservableAreToldThroughTheirCounters() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      controller.start()
      defer { controller.stop() }

      XCTAssertTrue(
        isTold({ _ = controller.presetsState }) {
          NotificationCenter.default.post(
            name: WallpaperPresetStore.didChangeNotification, object: context.panel.presets)
        }, "the preset store posts a notification when its list changes")
      for _ in 0..<5 { await Task.yield() }

      XCTAssertTrue(
        isTold({ _ = controller.imagePlacementState }) {
          NotificationCenter.default.post(
            name: StillImagePlacementStore.didChangeNotification, object: context.panel.imagePlacement)
        }, "the placement store posts one when an image page was inspected or a placement moved")
      for _ in 0..<5 { await Task.yield() }

      XCTAssertTrue(
        isTold({ _ = controller.presetsState }) { context.panel.presets.status = "Saved." },
        "the status is the store's own observable state")
    }
  }

  func testTheCardsAreToldOfTheirStoresAndTheirContext() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      let store = context.store
      store.settingsSnapshot.displays = [
        .init(
          displayId: "primary", title: "Display", enabled: true, mode: .standalone, mirrorTargets: [],
          selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 60, maxFps: 60,
          muted: false, volume: 1)
      ]
      store.appSnapshot.selectedWallpaperId = "clip"
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "clip", kind: .video)

      let compatibility = { _ = controller.compatibilityState }
      let compatibilityContext = try XCTUnwrap(controller.compatibilityContext())
      XCTAssertTrue(
        isTold(compatibility) { context.panel.compatibility.select(compatibilityContext) },
        "the compatibility store's context")
      XCTAssertTrue(
        isTold(compatibility) { store.settingsSnapshot.frameRateCap = 30 },
        "the frame-rate cap it certifies against")

      let letterbox = { _ = controller.letterboxState }
      XCTAssertTrue(isTold(letterbox) { store.wallpaperOptionsSnapshot?.dirty = true }, "the draft the card judges pending by")
      XCTAssertTrue(
        isTold(letterbox) { store.appSnapshot.selectedWallpaperId = "wp" }, "the selection")
    }
  }

  func testReadingTheStateStartsTheContextObservationOnlyOnAStartedPanel() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      _ = controller.inspectorOptions(for: "wp")
      XCTAssertNil(controller.inspectorContextLoop, "a panel that was never started observes nothing")

      controller.start()
      _ = controller.inspectorOptions(for: "wp")
      let loop = try XCTUnwrap(controller.inspectorContextLoop)
      _ = controller.compatibilityState
      _ = controller.letterboxState
      XCTAssertTrue(controller.inspectorContextLoop === loop, "a second read starts nothing more")

      controller.stop()
      // A loop that outlives a stopped panel ends itself at its next change.
      context.store.wallpaperOptionsSnapshot?.dirty = true
      for _ in 0..<20 { await Task.yield() }
      XCTAssertNil(controller.inspectorContextLoop)
    }
  }
}
