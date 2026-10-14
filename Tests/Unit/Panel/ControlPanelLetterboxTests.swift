import XCTest

@testable import WallpaperMachine

/// The Black bars card in the real page: drawn from the snapshot's `videoLetterbox`, only for an
/// installed video, with the button that fills in the display's Scale factor. Offscreen; the frames
/// come from an injected source, so nothing is decoded.
@MainActor
final class ControlPanelLetterboxTests: ControlPanelTestCase {
  func testCardShowsTheMeasuredBarsAndTheFactorForTheTargetDisplayOnlyForAVideo() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("panel-letterbox-page-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("clip.mp4")
    try Data("x".utf8).write(to: video)
    let letterbox = VideoLetterboxStore(
      probe: VideoLetterboxProbe(frames: { _ in LetterboxFixtures.frames(top: 23, bottom: 23) }, timeout: .seconds(600)),
      entry: { _, _ in video })
    letterbox.viewportProvider = { _ in CGSize(width: 1920, height: 1080) }

    let fixture = makeStore()
    let panel = try PanelFixture(store: fixture.store, bridge: fixture.bridge, displayTitles: .renderer, letterbox: letterbox)
    do {
      try await panel.start()
      try await panel.finishWelcome()
      let store = panel.store
      store.librarySnapshot.wallpapers = [
        .init(id: "clip", title: "Clip", kind: .video, supported: true, active: false, selected: true, previewPath: nil),
        .init(id: "scene", title: "Scene", kind: .projectScene, supported: true, active: false, selected: false, previewPath: nil),
      ]
      store.appSnapshot.selectedWallpaperId = "clip"
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "clip", kind: .video)
      panel.show()
      let card = "document.querySelector('#inspector [data-key=\"letterbox-clip\"]')"
      try await panel.waitJS("\(card) !== null")
      try await panel.expectJS("return \(card).textContent.includes('Look for black bars')", equals: true)
      try await panel.expectJS("return \(card).querySelector('[data-action=\"videoLetterboxCheck\"]').disabled", equals: false)

      await letterbox.check(wallpaperID: "clip", displayID: "primary", libraryRevision: store.libraryRefreshRevision)
      try await panel.waitJS("\(card).textContent.includes('Black bars found at the top and bottom, about 13% of the picture on each side.')")
      // 23 of 180 rows a side on a 16:9 display: 180 / 134 plus half a percent, rounded up.
      try await panel.expectJS("return \(card).textContent.includes('With Fill on this display, a scale factor of ×1.35 hides them.')", equals: true)
      try await panel.expectJS("return \(card).textContent.includes('Look again')", equals: true)

      // Setting the factor: offered with what it does, whichever video backend plays the clip,
      // and then done through the same call as the Displays section's field.
      let stage = "\(card).querySelector('[data-action=\"videoLetterboxStage\"]')"
      try await panel.expectJS("return \(stage).textContent.includes('Set scale factor to ×1.35')", equals: true)
      try await panel.expectJS("return \(stage).disabled", equals: false)
      try await panel.expectJS("return \(card).textContent.includes('Nothing is saved until you choose Apply changes.')", equals: true)
      store.settingsSnapshot.videoBackend = "native_preferred"
      try await panel.expectJS("return \(stage).disabled", equals: false)

      fixture.bridge.scalingFactorReply = { [store] _, display, factor in
        var options = try XCTUnwrap(store.wallpaperOptionsSnapshot)
        options.displayConfigurations = [
          BridgeDisplayConfigRow(displayId: display, title: "Display", enabled: true, scalingMode: .fill,
                                 scalingFactor: factor, framing: .centered, targetFps: 30, maxFps: 60,
                                 muted: false, volume: 1, dirty: true, canRestoreDefaults: true)
        ]
        options.dirty = true
        return BridgeWallpaperMutationBundle(
          app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: options,
          monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
      }
      _ = try await panel.js("\(stage).click()")
      try await panel.waitJS("\(card).textContent.includes('Scale factor is set to ×1.35. Choose Apply changes to keep it, or Revert to undo.')")
      XCTAssertEqual(fixture.bridge.scalingFactorCalls.count, 1)
      XCTAssertEqual(fixture.bridge.scalingFactorCalls.first?.wallpaperId, "clip")
      XCTAssertEqual(fixture.bridge.scalingFactorCalls.first?.displayId, "primary")
      XCTAssertEqual(try XCTUnwrap(fixture.bridge.scalingFactorCalls.first?.factor), 1.35, accuracy: 0.0001)
      try await panel.expectJS("return \(stage) === null", equals: true)

      store.appSnapshot.selectedWallpaperId = "scene"
      store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "scene", kind: .projectScene)
      try await panel.waitJS("document.querySelector('#inspector [data-key^=\"letterbox-\"]') === null")
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }
}
