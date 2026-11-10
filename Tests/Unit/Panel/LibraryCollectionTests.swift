import AppKit
import Observation
import SwiftUI
import XCTest

@testable import WallpaperMachine

@MainActor
final class LibraryCollectionTests: PanelTestCase {
  private final class ChangeFlag: @unchecked Sendable {
    var changed = false
  }

  func testReconfiguringATileOnlyInvalidatesItWhenVisibleContentChanges() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let item = LibraryCollectionItem()
    let row = LibraryRows.row("one")
    var environment = EnvironmentValues()
    environment.panelImages = panel.controller.images
    item.configure(row: row, others: [], controller: panel.controller, environment: environment)
    let flag = ChangeFlag()
    withObservationTracking {
      _ = item.tile.row
      _ = item.tile.otherDisplays
      _ = item.tile.appearance
    } onChange: { flag.changed = true }
    item.configure(row: row, others: [], controller: panel.controller, environment: environment)
    XCTAssertFalse(flag.changed, "an unchanged collection update must not redraw every tile")
    environment.locale = Locale(identifier: "ko")
    item.configure(row: row, others: [], controller: panel.controller, environment: environment)
    XCTAssertTrue(flag.changed, "the panel's language still reaches a reused tile")
  }

  private func prepare(_ panel: PanelFixture, count: Int = 240) async throws {
    panel.show()
    panel.configureDisplays()
    try panel.installLibrary((0..<count).map {
      LibrarySpec("item\($0)", "Wallpaper \($0)", kind: .projectScene)
    })
    try await panel.loadLibrary()
    try await panel.settleLibrary()
  }

  private func grid(in view: NSView) -> LibraryCollectionCoordinator? {
    if let view = view as? LibraryCollectionScrollView { return view.owner }
    return view.subviews.lazy.compactMap { self.grid(in: $0) }.first
  }

  private func key(_ code: UInt16, command: Bool = false, window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: code)!
  }

  /// Command-Delete asks to move the focused wallpaper to the Trash, as the Finder's shortcut
  /// does, and Command-Return applies it. Return alone still only chooses it for the inspector,
  /// and a Command key the grid has no use for is left to the menus.
  func testCommandDeleteTrashesAndCommandReturnAppliesTheFocusedTile() async throws {
    // A bridge that really applies: the primary display shows `a`, and `c` is on neither display.
    try await withApplyingPanel { panel, bridge, _ in
      panel.show()
      let hosted = HostedPanel(panel, size: NSSize(width: 1240, height: 800))
      defer { hosted.close() }
      try await hosted.settle(0.3)
      let coordinator = try XCTUnwrap(self.grid(in: hosted.hosting.view))
      let controller = panel.controller
      let id = try XCTUnwrap(coordinator.rows.first { $0.id == "c" }?.id)
      coordinator.focus(id, byKeyboard: true)

      XCTAssertFalse(
        coordinator.keyDown(self.key(35, command: true, window: hosted.window)), "Command-P is not the grid's")
      XCTAssertTrue(coordinator.keyDown(self.key(36, window: hosted.window)))
      try await panel.waitUntil { controller.selectedWallpaperID == id }
      XCTAssertEqual(bridge.assignments["primary"], "a", "Return alone chooses the wallpaper for the inspector")

      XCTAssertTrue(coordinator.keyDown(self.key(36, command: true, window: hosted.window)))
      try await panel.waitUntil { bridge.assignments["primary"] == id }

      try await panel.waitUntil { controller.library.canTrash }
      XCTAssertTrue(coordinator.keyDown(self.key(51, command: true, window: hosted.window)))
      try await panel.waitUntil { !panel.dialogs.confirmations.isEmpty }
      XCTAssertEqual(panel.dialogs.confirmations.count, 1, "the Trash still asks first")
      try await panel.waitUntil { !controller.isBusy(PanelActionCoordinator.key("deleteMany")) }
      XCTAssertFalse(hosted.window.isVisible)
    }
  }

  func testLayoutQueriesOnlyIntersectingRowsAndKeepsSweepCoordinatesInSync() {
    let layout = LibraryCollectionLayout()
    layout.configure(viewport: CGSize(width: 1000, height: 700), preferredWidth: 140, count: 10_000)
    for y: CGFloat in [0, 3_200, 100_000] {
      let visible = layout.layoutAttributesForElements(in: CGRect(x: 0, y: y, width: 1000, height: 700))
      XCTAssertFalse(visible.isEmpty)
      XCTAssertLessThan(visible.count, 40, "query cost depends on the viewport, not the library size")
      var geometry = layout.geometry
      geometry.offsetY = y
      for attributes in visible {
        let center = CGPoint(x: attributes.frame.midX, y: attributes.frame.midY - y)
        XCTAssertEqual(geometry.index(at: center, count: 10_000), attributes.indexPath?.item)
      }
    }
    XCTAssertFalse(layout.shouldInvalidateLayout(forBoundsChange: CGRect(x: 0, y: 5000, width: 1000, height: 700)))
  }

  func testRapidScrollReusesHostsAndReportsOnlyVisiblePreviewIDs() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await prepare(panel)
    let hosted = HostedPanel(panel, size: NSSize(width: 1400, height: 860))
    defer { hosted.close() }
    try await hosted.settle(0.3)
    let coordinator = try XCTUnwrap(grid(in: hosted.hosting.view))
    var hosts = Set<ObjectIdentifier>()
    var largestVisible = 0
    for index in 0..<20 {
      let target = CGFloat(index % 2 == 0 ? 3000 : 0)
      coordinator.scroll(to: target)
      coordinator.collection.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(5))
      let items = coordinator.collection.visibleItems()
      XCTAssertFalse(items.isEmpty)
      largestVisible = max(largestVisible, items.count)
      hosts.formUnion(items.map { ObjectIdentifier($0.view) })
      XCTAssertLessThan(panel.controller.library.tilesOnScreen.count, 50)
      let viewport = coordinator.scrollView.contentView.bounds
      for id in panel.controller.library.tilesOnScreen {
        let row = try XCTUnwrap(coordinator.rows.firstIndex { $0.id == id })
        let frame = coordinator.gridLayout.geometry.frame(ofIndex: row)
        XCTAssertGreaterThanOrEqual(frame.intersection(viewport).height, frame.height * 0.25 - 1)
      }
    }
    XCTAssertLessThanOrEqual(hosts.count, largestVisible * 3,
      "fast reversals must reuse a bounded pool of hosts, not keep building the library")
    XCTAssertFalse(hosted.window.isVisible)
  }

  func testKeyboardMovesFocusByRowsAndCanReachOffscreenLastTile() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await prepare(panel, count: 60)
    let hosted = HostedPanel(panel, size: NSSize(width: 1240, height: 800))
    defer { hosted.close() }
    try await hosted.settle(0.3)
    let coordinator = try XCTUnwrap(grid(in: hosted.hosting.view))
    XCTAssertTrue(hosted.window.makeFirstResponder(coordinator.collection))
    coordinator.focus(coordinator.rows[0].id, byKeyboard: true)
    coordinator.collection.keyDown(with: key(125, window: hosted.window))
    XCTAssertEqual(panel.controller.library.focusedID, coordinator.rows[coordinator.gridLayout.geometry.columns].id)
    coordinator.collection.keyDown(with: key(119, window: hosted.window))
    XCTAssertEqual(panel.controller.library.focusedID, coordinator.rows.last?.id)
    XCTAssertGreaterThan(panel.controller.library.scrollOffset, 0)
    coordinator.collection.keyDown(with: key(115, window: hosted.window))
    XCTAssertEqual(panel.controller.library.focusedID, coordinator.rows.first?.id)
    XCTAssertLessThanOrEqual(panel.controller.library.scrollOffset, LibraryGridGeometry.insets.top)
    XCTAssertFalse(hosted.window.isVisible)
  }

  func testPointerEventsKeepSweepSelectionAndTheEndingClickSemantics() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await prepare(panel, count: 60)
    let hosted = HostedPanel(panel, size: NSSize(width: 1240, height: 800))
    defer { hosted.close() }
    try await hosted.settle(0.3)
    let coordinator = try XCTUnwrap(grid(in: hosted.hosting.view))
    let model = panel.controller.library
    model.toggleSelecting()
    func mouse(_ type: NSEvent.EventType, index: Int) -> NSEvent {
      let frame = coordinator.gridLayout.geometry.frame(ofIndex: index)
      let point = coordinator.collection.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
      return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    coordinator.pointerEvent(mouse(.leftMouseDown, index: 0))
    XCTAssertTrue(model.isPointerDown)
    coordinator.pointerEvent(mouse(.leftMouseDragged, index: 2))
    coordinator.pointerEvent(mouse(.leftMouseUp, index: 2))
    XCTAssertFalse(model.isPointerDown)
    XCTAssertTrue(model.isChecked(coordinator.rows[0].id))
    XCTAssertTrue(model.isChecked(coordinator.rows[2].id))
    model.tileClicked(coordinator.rows[2].id, clickCount: 1, modifiers: [])
    XCTAssertTrue(model.isChecked(coordinator.rows[2].id), "the ending click cannot undo the sweep")
  }
}
