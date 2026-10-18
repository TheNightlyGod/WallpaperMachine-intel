import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// Moving between any two pages, with the inspector open or closed, in a window that is never
/// shown. Each page used to bring its own toolbar search field, and going from Installed straight to
/// pixiv made SwiftUI's toolbar bridge insert an item at an index NSToolbar refuses: an exception
/// that ends the app. A crash here fails the run.
@MainActor
final class PanelPageTransitionTests: PanelTestCase {
  private let pages: [SidebarSelection] = [.wallpaper, .workshop, .pixiv, .settings]

  private func settle(_ window: NSWindow, _ hosting: NSView) async throws {
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
  }

  private func walkEveryTransition(inspectorShown: Bool) async throws {
    let panel = try makeController()
    let controller = panel.controller
    panel.navigation.selection = .wallpaper
    panel.presentation.show()
    controller.start()
    controller.shell.isInspectorShown = inspectorShown
    let hosting = NSHostingController(
      rootView: AnyView(
        PanelRootView().frame(maxWidth: .infinity, maxHeight: .infinity).environment(controller)
          .environment(\.panelImages, controller.images)))
    hosting.sizingOptions = []
    hosting.sceneBridgingOptions = [.toolbars, .title]
    let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
    window.setContentSize(NSSize(width: 1240, height: 800))
    XCTAssertFalse(window.isVisible, "Never shown")
    try await settle(window, hosting.view)

    for from in pages {
      for to in pages where to != from {
        panel.navigation.selection = from
        try await settle(window, hosting.view)
        panel.navigation.selection = to
        try await settle(window, hosting.view)
        XCTAssertEqual(controller.shell.selection, to, "\(from) -> \(to)")
      }
    }
    // A page change and an inspector change in the same update, as the narrow-window rule and the
    // toolbar toggle can make them.
    panel.navigation.selection = .wallpaper
    try await settle(window, hosting.view)
    panel.navigation.selection = .pixiv
    controller.shell.isInspectorShown.toggle()
    try await settle(window, hosting.view)
    panel.navigation.selection = .wallpaper
    controller.shell.isInspectorShown.toggle()
    try await settle(window, hosting.view)

    window.close()
    await panel.shutdown()
  }

  func testEveryPageChangeWithTheInspectorOpenLeavesTheWindowWhole() async throws {
    try await walkEveryTransition(inspectorShown: true)
  }

  func testEveryPageChangeWithTheInspectorClosedLeavesTheWindowWhole() async throws {
    try await walkEveryTransition(inspectorShown: false)
  }
}
