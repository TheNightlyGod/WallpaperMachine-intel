import XCTest

@testable import WallpaperMachine

/// What the panel shows and accepts for updates of installed Workshop wallpapers.
@MainActor
final class WebPanelWorkshopUpdateTests: XCTestCase {
  func testAnOutdatedWallpaperIsMarkedAndOnlyItCanBeUpdated() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-updates-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defer { try? FileManager.default.removeItem(at: root) }
    // Installed two hours ago; its author changed it an hour ago.
    let folder = root.appendingPathComponent("Library/123")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manifest = folder.appendingPathComponent("project.json")
    try Data("{}".utf8).write(to: manifest)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: manifest.path)
    let changed = WorkshopItem(
      id: "123", title: "Changed", creator: "Creator", summary: "", previewURL: nil, tags: ["Video"],
      size: 1, subscriptions: 0, timeUpdated: Date().addingTimeInterval(-3600))
    let updates = WorkshopUpdateStore(defaults: defaults, fetch: { _ in [changed] })
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults, updates: updates)
    let store = BridgeStore(bridge: WallpaperBridge(noPointer: .init()))
    store.librarySnapshot = BridgeLibrarySnapshot(
      wallpapers: ["123", "456"].map {
        BridgeWallpaperEntry(
          id: $0, title: $0, kind: .video, supported: true, active: false, selected: false, previewPath: nil)
      },
      scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 0,
      videoCount: 2, webpageCount: 0, unknownCount: 0)
    let controller = WebPanelController(
      store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
      appLanguage: .english())
    defer { controller.stop() }

    updates.check(installed: ["123", "456"], library: root.appendingPathComponent("Library"))
    for _ in 0..<200 where updates.isChecking { try await Task.sleep(for: .milliseconds(5)) }

    let wallpapers = try XCTUnwrap(controller.snapshot()["wallpapers"] as? [[String: Any]])
    XCTAssertEqual(wallpapers.first { $0["id"] as? String == "123" }?["updateAvailable"] as? Bool, true)
    XCTAssertEqual(wallpapers.first { $0["id"] as? String == "456" }?["updateAvailable"] as? Bool, false)
    XCTAssertEqual((controller.snapshot()["workshopUpdates"] as? [String: Any])?["count"] as? Int, 1)

    do {
      try await controller.perform("workshopUpdate", body: ["id": "456"])
      XCTFail("a wallpaper without an update has nothing to download")
    } catch {}

    try await controller.perform("setting", body: ["key": "workshopUpdateChecks", "value": false])
    XCTAssertFalse(updates.checksAutomatically)
  }

  /// Reinstalling downloads an installed wallpaper again, so it needs a wallpaper that is
  /// installed and the user's yes. Until both are there, Steam is not asked and nothing is queued.
  func testReinstallNeedsAnInstalledWallpaperAndAConfirmation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-reinstall-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let stub = WorkshopDetailsStub()
    stub.rows["123"] = WorkshopDetailsStub.row("123", title: "Current", tags: ["Video"])
    defer {
      stub.invalidate()
      try? FileManager.default.removeItem(at: root)
    }
    let workshop = WorkshopStore(
      service: stub.service, downloader: WorkshopDownloadManager(sessionDirectory: root),
      supportDirectory: root, defaults: defaults)
    let store = BridgeStore(bridge: WallpaperBridge(noPointer: .init()))
    store.librarySnapshot = BridgeLibrarySnapshot(
      wallpapers: [BridgeWallpaperEntry(
        id: "123", title: "Installed", kind: .video, supported: true, active: false, selected: false,
        previewPath: nil)],
      scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 0,
      videoCount: 1, webpageCount: 0, unknownCount: 0)
    let controller = WebPanelController(
      store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
      appLanguage: .english())
    defer { controller.stop() }

    do {
      try await controller.perform("workshopReinstall", body: ["id": "456"])
      XCTFail("a wallpaper that is not installed has nothing to reinstall")
    } catch {}
    // No panel window means no sheet to answer it, which is a no.
    try await controller.perform("workshopReinstall", body: ["id": "123"])
    XCTAssertEqual(stub.requests, [])
    XCTAssertTrue(workshop.downloadRequests.isEmpty)
    XCTAssertTrue(workshop.downloader.downloads.isEmpty)
  }
}
