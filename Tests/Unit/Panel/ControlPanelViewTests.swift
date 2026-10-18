import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The root view creates the panel's controller for the life of its window: it starts it when the
/// view appears and ends it when the window goes away.
@MainActor
final class ControlPanelViewTests: PanelTestCase {
  func testTheRootStartsItsControllerWhenHostedAndStopsItWhenItsWindowCloses() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    let navigation = ControlPanelNavigation()
    let controller = NSHostingController(
      rootView: ControlPanelView(
        store: BridgeStore(bridge: LayoutSnapshotBridge(noPointer: .init())), navigation: navigation,
        workshop: workshop, pixiv: PixivStore(),
        updater: AppUpdateStore(currentVersion: "0.1.0", client: DisabledAppUpdateClient()),
        imports: LibraryImportStore(), defaults: defaults))
    controller.sizingOptions = []
    controller.sceneBridgingOptions = [.toolbars, .title]
    XCTAssertFalse(workshop.prefetchesNextPage, "nothing is wired until the view appears")
    let window = ControlPanelWindow.make(contentViewController: controller, delegate: nil)

    window.layoutIfNeeded()
    let deadline = Date().addingTimeInterval(5)
    while !workshop.prefetchesNextPage, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(workshop.prefetchesNextPage, "appearing started the controller, which wires the Workshop's prefetch")
    XCTAssertFalse(window.isVisible, "the window stays offscreen")

    window.contentViewController = nil
    window.close()
    await workshop.steamCMDSetup.shutdown()
  }
}
