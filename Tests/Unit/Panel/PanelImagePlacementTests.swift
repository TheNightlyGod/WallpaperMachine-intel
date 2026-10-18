import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// Where a still image that this app packaged sits on a display: the card's state, the two actions
/// and the rule that keeps a late request from overwriting a newer one.
@MainActor
final class PanelImagePlacementTests: PanelTestCase {
  /// An image project as this app generates it: a tiny PNG, a manifest and the generated page.
  private func installImage(
    _ id: String, in library: URL, fit: StillImageWallpaper.Fit = .fill
  ) throws {
    let project = library.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let bitmap = try XCTUnwrap(
      CGContext(
        data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    bitmap.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
    let bytes = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    try (bytes as Data).write(to: project.appendingPathComponent("image.png"))
    let manifest: [String: Any] = [
      "type": "web", "file": "index.html", "title": "Image",
      "general": ["properties": StillImageWallpaper.properties(fit: fit)],
      "image": ["file": "image.png", "width": 4, "height": 2],
    ]
    try JSONSerialization.data(withJSONObject: manifest).write(
      to: project.appendingPathComponent("project.json"))
    try StillImageWallpaper.legacyPage(showing: "image.png", fit: fit)
      .write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  private func withImages(
    _ ids: [String] = ["image-a.png"], fit: StillImageWallpaper.Fit = .fill,
    _ body: (PanelFixture) async throws -> Void
  ) async throws {
    let panel = try makeController()
    do {
      for id in ids {
        try installImage(id, in: panel.library, fit: fit)
        // Inspecting a page is asynchronous: the card reads "not supported" until it has been,
        // which is what the store's change notification then corrects.
        _ = try await panel.imagePlacement.prepare(wallpaperID: id)
      }
      panel.store.librarySnapshot.wallpapers =
        ids.map {
          BridgeWallpaperEntry(
            id: $0, title: $0, kind: .webpage, supported: true, active: false, selected: false,
            previewPath: nil)
        }
        + [
          BridgeWallpaperEntry(
            id: "plain", title: "plain", kind: .webpage, supported: true, active: false, selected: false,
            previewPath: nil)
        ]
      panel.store.appSnapshot.selectedWallpaperId = ids.first
      try await body(panel)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  func testAPlacementIsKeptPerWallpaperAndDisplayAndResetPutsTheFitBack() async throws {
    try await withImages { panel in
      let controller = panel.controller
      let initial = try XCTUnwrap(controller.imagePlacementState)
      XCTAssertTrue(initial.isSupported)
      XCTAssertNil(initial.reason)
      XCTAssertFalse(initial.isCustomized)
      XCTAssertEqual([initial.x, initial.y, initial.zoom], [0.5, 0.5, 1], "the fit alone centres it")
      XCTAssertEqual(initial.fit, .fill)
      XCTAssertEqual(initial.imagePixelSize, CGSize(width: 4, height: 2))
      XCTAssertEqual(initial.imageAspectRatio, 2)
      XCTAssertEqual(initial.displayID, "primary")

      try await controller.setImagePlacement("image-a.png", display: "primary", x: 0.1, y: 0.9, zoom: 2)

      XCTAssertEqual(
        panel.imagePlacement.placement(wallpaperID: "image-a.png", displayID: "primary"),
        try StillImagePlacement(x: 0.1, y: 0.9, zoom: 2))
      let moved = try XCTUnwrap(controller.imagePlacementState)
      XCTAssertEqual([moved.x, moved.y, moved.zoom], [0.1, 0.9, 2])
      XCTAssertTrue(moved.isCustomized, "a custom value stays custom even at the centre")

      try await controller.resetImagePlacement("image-a.png", display: "primary")
      XCTAssertNil(panel.imagePlacement.placement(wallpaperID: "image-a.png", displayID: "primary"))
      XCTAssertFalse(try XCTUnwrap(controller.imagePlacementState).isCustomized)
      XCTAssertTrue(controller.imagePlacementRequests.isEmpty, "no request is left registered")
    }
  }

  func testFillKeepingTheTopStartsAtTheTopAndTheAppliedFitWins() async throws {
    try await withImages(fit: .fillTop) { panel in
      let controller = panel.controller
      XCTAssertEqual(controller.imagePlacementState?.fit, .fillTop)
      XCTAssertEqual(controller.imagePlacementState?.y, 0, "Fill keeping the top starts at the top")

      // The fit the user applied since is the one in force, not the page's own.
      panel.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(
        wallpaperId: "image-a.png", kind: .webpage,
        properties: [PanelPropertyContext.property("fit", .combo, .string(value: "blur"))])
      XCTAssertEqual(controller.imagePlacementState?.fit, .blur)
      XCTAssertEqual(controller.imagePlacementState?.y, 0.5)
    }
  }

  func testARequestOutsideTheRangesOrForAnUnusableTargetIsRefusedAndSavesNothing() async throws {
    try await withImages { panel in
      let controller = panel.controller
      let cases: [(Double, Double, Double)] = [
        (-0.1, 0.5, 1), (1.1, 0.5, 1), (0.5, -0.1, 1), (0.5, 1.1, 1), (.nan, 0.5, 1), (0.5, .infinity, 1),
        (0.5, 0.5, 0.99), (0.5, 0.5, 3.01), (0.5, 0.5, .nan),
      ]
      for (x, y, zoom) in cases {
        await assertInspectorInvalidValue("placement \(x), \(y), \(zoom)") {
          try await controller.setImagePlacement("image-a.png", display: "primary", x: x, y: y, zoom: zoom)
        }
      }
      for display in ["gone"] {
        await assertInspectorInvalidValue("display \(display)") {
          try await controller.setImagePlacement("image-a.png", display: display, x: 0.5, y: 0.5, zoom: 1)
        }
        await assertInspectorInvalidValue("a reset on display \(display)") {
          try await controller.resetImagePlacement("image-a.png", display: display)
        }
      }
      panel.store.settingsSnapshot.displays[0].mode = .mirror
      await assertInspectorInvalidValue("a mirror") {
        try await controller.setImagePlacement("image-a.png", display: "primary", x: 0.5, y: 0.5, zoom: 1)
      }
      XCTAssertEqual(controller.imagePlacementState?.isSupported, false)
      XCTAssertEqual(
        controller.imagePlacementState?.reason, "Image placement requires an enabled independent display.")
      panel.store.settingsSnapshot.displays[0].mode = .standalone
      panel.store.settingsSnapshot.displays[0].enabled = false
      await assertInspectorInvalidValue("a disabled display") {
        try await controller.resetImagePlacement("image-a.png", display: "primary")
      }
      do {
        try await controller.setImagePlacement("nope", display: "primary", x: 0.5, y: 0.5, zoom: 1)
        XCTFail("an unknown wallpaper must be refused")
      } catch {}
      XCTAssertNil(panel.imagePlacement.placement(wallpaperID: "image-a.png", displayID: "primary"))
      XCTAssertTrue(controller.imagePlacementRequests.isEmpty)
    }
  }

  func testAWallpaperThatIsNotAnUnmodifiedGeneratedImagePageIsRefusedAndTheCardSaysWhy() async throws {
    try await withImages { panel in
      let controller = panel.controller
      panel.store.appSnapshot.selectedWallpaperId = "plain"
      let state = try XCTUnwrap(controller.imagePlacementState)
      XCTAssertFalse(state.isSupported)
      XCTAssertEqual(
        state.reason,
        "Image placement is available only for unmodified image pages generated by WallpaperMachine.")
      XCTAssertNil(state.fit)

      do {
        try await controller.setImagePlacement("plain", display: "primary", x: 0.5, y: 0.5, zoom: 1)
        XCTFail("a page this app did not generate cannot be positioned")
      } catch {
        XCTAssertEqual(
          error.localizedDescription, "This wallpaper is not an unmodified image page generated by WallpaperMachine.")
      }
      panel.store.appSnapshot.selectedWallpaperId = nil
      XCTAssertNil(controller.imagePlacementState, "with nothing selected there is no card")
    }
  }

  func testAPlacementRequestLeavesTheBannerAloneAndDoesNotWaitForTheCommandQueue() async throws {
    try await withImages { panel in
      let controller = panel.controller
      controller.errors.actionError = "An earlier failure"
      var release: CheckedContinuation<Void, Never>?
      let store = panel.store
      let running = Task { @MainActor in
        await store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      for _ in 0..<200 where release == nil { await Task.yield() }

      try await controller.setImagePlacement("image-a.png", display: "primary", x: 0.3, y: 0.3, zoom: 1.5)

      XCTAssertEqual(
        panel.imagePlacement.placement(wallpaperID: "image-a.png", displayID: "primary")?.zoom, 1.5,
        "it did not wait behind the running command")
      XCTAssertEqual(controller.errors.actionError, "An earlier failure")
      release?.resume()
      _ = await running.value
    }
  }

  /// A request that has to prepare an older page first suspends, and a newer request for the same
  /// wallpaper and display may be made meanwhile. Each takes a sequence number and goes ahead only
  /// if it is still the newest once the page is ready, so a Reset can never lose to a cold placement
  /// request it overtook.
  func testResetWinsOverAnEarlierColdPlacementRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Library")
    let id = "image-race.png"
    try installImage(id, in: library)
    let gate = Gate(entered: expectation(description: "cold preparation held"))
    defer { gate.release() }
    let images = StillImagePlacementStore(
      defaults: defaults, library: library, beforeValidation: { gate.pause() })
    try images.set(StillImagePlacement(x: 0.7, y: 0.4, zoom: 1.2), wallpaperID: id, displayID: "primary")
    let store = BridgeStore(bridge: LayoutSnapshotBridge(noPointer: .init()))
    store.librarySnapshot.wallpapers = [
      .init(
        id: id, title: "Image", kind: .webpage, supported: true, active: false, selected: true,
        previewPath: nil)
    ]
    store.settingsSnapshot.displays = [
      .init(
        displayId: "primary", title: "Display", enabled: true, mode: .standalone, mirrorTargets: [],
        selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60,
        muted: false, volume: 1)
    ]
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let controller = PanelController(
      store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
      appLanguage: .english(), imagePlacement: images)
    let set = Task { @MainActor in
      try await controller.setImagePlacement(id, display: "primary", x: 0.1, y: 0.9, zoom: 2)
    }
    await fulfillment(of: [gate.entered], timeout: 5)
    let started = expectation(description: "newer reset registered")
    let reset = Task { @MainActor in
      started.fulfill()
      try await controller.resetImagePlacement(id, display: "primary")
    }
    await fulfillment(of: [started], timeout: 5)
    gate.release()
    try await set.value
    try await reset.value

    XCTAssertNil(images.placement(wallpaperID: id, displayID: "primary"))
    XCTAssertNil(
      StillImagePlacementStore(defaults: defaults, library: library).placement(
        wallpaperID: id, displayID: "primary"), "and nothing was saved behind it")
    XCTAssertTrue(controller.imagePlacementRequests.isEmpty)
  }

  /// The requests of two wallpapers or two displays never sequence against each other: each key has
  /// its own newest request.
  func testRequestsForDifferentWallpapersAndDisplaysKeepTheirOwnSequence() async throws {
    try await withImages(["image-a.png", "image-b.png"]) { panel in
      panel.store.settingsSnapshot.displays.append(
        BridgeDisplaySettingsRow(
          displayId: "secondary", title: "Second", enabled: true, mode: .standalone, mirrorTargets: [],
          selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60,
          muted: false, volume: 1))
      let controller = panel.controller
      async let first: Void = controller.setImagePlacement("image-a.png", display: "primary", x: 0.2, y: 0.2, zoom: 1)
      async let second: Void = controller.setImagePlacement("image-b.png", display: "primary", x: 0.4, y: 0.4, zoom: 1)
      async let third: Void = controller.setImagePlacement("image-a.png", display: "secondary", x: 0.6, y: 0.6, zoom: 1)
      _ = try await (first, second, third)

      XCTAssertEqual(panel.imagePlacement.placement(wallpaperID: "image-a.png", displayID: "primary")?.x, 0.2)
      XCTAssertEqual(panel.imagePlacement.placement(wallpaperID: "image-b.png", displayID: "primary")?.x, 0.4)
      XCTAssertEqual(panel.imagePlacement.placement(wallpaperID: "image-a.png", displayID: "secondary")?.x, 0.6)
      XCTAssertTrue(controller.imagePlacementRequests.isEmpty)
    }
  }

  private final class Gate: @unchecked Sendable {
    let entered: XCTestExpectation
    private let condition = NSCondition()
    private var waiting = true
    private var first = true
    init(entered: XCTestExpectation) { self.entered = entered }
    func pause() {
      condition.lock()
      defer { condition.unlock() }
      guard first else { return }
      first = false
      entered.fulfill()
      while waiting { condition.wait() }
    }
    func release() {
      condition.lock()
      waiting = false
      condition.broadcast()
      condition.unlock()
    }
  }
}
