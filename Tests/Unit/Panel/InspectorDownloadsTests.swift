import XCTest

@testable import WallpaperMachine

/// What the Installed inspector offers for a wallpaper that has a download: **Show in downloads**,
/// which opens the Downloads list, and no second Reinstall.
@MainActor
final class InspectorDownloadsTests: MediaPanelTestCase {
  private func entry(_ id: String) -> BridgeWallpaperEntry {
    BridgeWallpaperEntry(
      id: id, title: id, kind: .video, supported: true, active: false, selected: false,
      previewPath: nil)
  }

  /// The page's `download || request ? Show in downloads`: a request waiting for setup is in the
  /// list, so the inspector links to it, and the link opens the list.
  func testAnInstalledWallpaperWithARequestWaitingOffersShowInDownloads() async throws {
    let stub = WorkshopDetailsStub()
    stub.rows["123"] = WorkshopDetailsStub.row("123", title: "Current", tags: ["Video"])
    addTeardownBlock { stub.invalidate() }
    let panel = try makeBrowsingPanel(service: stub.service)
    panel.store.librarySnapshot.wallpapers = [entry("123"), entry("456")]
    let controller = panel.controller
    XCTAssertFalse(controller.offersShowInDownloads(for: "123"), "nothing of it is in the list")
    XCTAssertTrue(controller.canReinstall("123"))

    panel.dialogs.confirmAnswer = true
    try await controller.reinstallWorkshopItem(id: "123")
    XCTAssertEqual(controller.downloadRequestRows.map(\.id), ["123"])
    XCTAssertTrue(controller.offersShowInDownloads(for: "123"), "the request waiting for setup is listed")
    XCTAssertFalse(controller.offersShowInDownloads(for: "456"), "another wallpaper has nothing listed")
    XCTAssertFalse(controller.canReinstall("123"), "a request waiting is continued, not repeated")

    XCTAssertFalse(controller.downloads.isQueuePopoverOpen)
    controller.downloads.showDownloads()  // what the link does
    XCTAssertTrue(controller.downloads.isQueuePopoverOpen)
  }
}
