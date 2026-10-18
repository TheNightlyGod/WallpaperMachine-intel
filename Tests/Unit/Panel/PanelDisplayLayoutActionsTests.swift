import os
import XCTest

@testable import WallpaperMachine

/// Saved display layouts, and copying and swapping wallpapers between displays, over a two-display
/// bridge that really moves wallpapers.
@MainActor
final class PanelDisplayLayoutActionsTests: PanelTestCase {
  func testSaveRenameApplyAndDeleteALayout() async throws {
    try await withTwoDisplayPanel { panel, bridge in
      let controller = panel.controller
      XCTAssertTrue(controller.displayLayoutsState.canSave)
      XCTAssertTrue(controller.displayLayoutsState.layouts.isEmpty)

      let layout = try await controller.saveDisplayLayout(name: "Work <img src=x>")
      XCTAssertEqual(layout.assignments.map(\.wallpaperID), ["a", "b"])
      var state = controller.displayLayoutsState
      XCTAssertEqual(state.layouts.map(\.name), ["Work <img src=x>"], "a name is text, whatever it looks like")
      XCTAssertEqual(state.layouts[0].assignments.map(\.displayID), ["primary", "secondary"])
      XCTAssertEqual(state.layouts[0].assignments.map(\.wallpaperTitle), ["Ocean <img src=x>", "b"], "the library's title, as text")
      XCTAssertNil(state.layouts[0].unavailableReason)
      XCTAssertEqual(state.limit, 64)

      try await controller.renameDisplayLayout(layout.id, to: "Evening")
      XCTAssertEqual(controller.displayLayoutsState.layouts.map(\.name), ["Evening"])

      bridge.assignments = ["primary": "c", "secondary": "a"]
      try await panel.store.refreshAllAsync()
      try await controller.applyDisplayLayout(layout.id)
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"], "restored after c and a were put there")

      try await controller.deleteDisplayLayout(layout.id)
      state = controller.displayLayoutsState
      XCTAssertTrue(state.layouts.isEmpty)
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"], "Current wallpapers stay as they are")
      do {
        try await controller.applyDisplayLayout(layout.id)
        XCTFail("a layout that no longer exists")
      } catch {
        XCTAssertEqual(error.localizedDescription, String(localized: "This display layout no longer exists. Choose another layout."))
      }
    }
  }

  func testNamesFollowTheCollectionsRuleAndAnInvalidNameSavesNothing() async throws {
    try await withTwoDisplayPanel { panel, _ in
      let controller = panel.controller
      for name in ["", "  ", String(repeating: "x", count: 129), "two\nlines"] {
        do {
          _ = try await controller.saveDisplayLayout(name: name)
          XCTFail("saved \(name.debugDescription)")
        } catch {
          XCTAssertEqual(error.localizedDescription, String(localized: "Enter a name between 1 and 128 characters, on one line."))
        }
      }
      XCTAssertTrue(controller.displayLayoutsState.layouts.isEmpty)
      let saved = try await controller.saveDisplayLayout(name: String(repeating: "长", count: 128))
      do {
        try await controller.renameDisplayLayout(saved.id, to: " ")
        XCTFail("renamed to nothing")
      } catch {}
      XCTAssertEqual(controller.displayLayoutsState.layouts.map(\.name), [String(repeating: "长", count: 128)])
    }
  }

  func testACopyGivesTheOtherDisplayTheWallpaperAndASwapExchangesThemOrChangesNothing() async throws {
    try await withTwoDisplayPanel { panel, bridge in
      let controller = panel.controller
      try await controller.copyWallpaper(from: "primary", to: "secondary")
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "a"])

      bridge.assignments["secondary"] = "b"
      try await panel.store.refreshAllAsync()
      try await controller.swapWallpapers("primary", "secondary")
      XCTAssertEqual(bridge.assignments, ["primary": "b", "secondary": "a"])

      for refused in [{ try await controller.copyWallpaper(from: "primary", to: "primary") },
        { try await controller.swapWallpapers("secondary", "secondary") },
        { try await controller.copyWallpaper(from: "primary", to: "gone") }] as [() async throws -> Void] {
        do {
          try await refused()
          XCTFail("a transfer needs two different independent displays")
        } catch {}
      }
      XCTAssertEqual(bridge.assignments, ["primary": "b", "secondary": "a"])
    }
  }

  func testAFailedSwapPutsBothDisplaysBackAndSaysSo() async throws {
    try await withTwoDisplayPanel { panel, bridge in
      let controller = panel.controller
      bridge.failOnce = "primary=b"
      bridge.failAfterMutation = true
      do {
        try await controller.swapWallpapers("primary", "secondary")
        XCTFail("the engine refused the second display")
      } catch {
        XCTAssertFalse(error.localizedDescription.isEmpty)
        XCTAssertTrue(
          error.localizedDescription.hasPrefix(WallpaperDisplayLayoutError.restored("").errorDescription ?? "?"),
          "the failure says the previous wallpapers were restored: \(error.localizedDescription)")
      }
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"], "no display kept half of the swap")
      bridge.failAfterMutation = false
      try await controller.swapWallpapers("primary", "secondary")
      XCTAssertEqual(bridge.assignments, ["primary": "b", "secondary": "a"])
    }
  }

  func testALayoutWhoseDisplayIsGoneStaysListedWithItsReasonAndCannotBeApplied() async throws {
    try await withTwoDisplayPanel { panel, bridge in
      let controller = panel.controller
      let layout = try controller.displayLayouts.save(
        name: String(repeating: "长い名称", count: 25),
        assignments: WallpaperDisplayTransfer.capture(panel.store.displayTransferSnapshot()))
      XCTAssertNil(controller.displayLayoutsState.layouts[0].unavailableReason)

      bridge.eligible.remove("secondary")
      try await panel.store.refreshAllAsync()
      let state = controller.displayLayoutsState
      XCTAssertEqual(state.layouts.map(\.id), [layout.id], "it stays")
      XCTAssertNotNil(state.layouts[0].unavailableReason, "with the reason Apply is disabled")
      XCTAssertEqual(state.layouts[0].assignments.count, 2)
      do {
        try await controller.applyDisplayLayout(layout.id)
        XCTFail("a layout names a display that is disabled")
      } catch {}
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
      XCTAssertEqual(bridge.events, [], "nothing was applied or ejected")
    }
  }

  func testTheLastAllowedLayoutDisablesSavingAndAnotherIsRefused() async throws {
    try await withTwoDisplayPanel { panel, _ in
      let controller = panel.controller
      let assignments = try WallpaperDisplayTransfer.capture(panel.store.displayTransferSnapshot())
      for index in 1..<WallpaperDisplayLayoutStore.limit {
        try controller.displayLayouts.save(name: "Layout \(index)", assignments: assignments)
      }
      XCTAssertFalse(controller.displayLayoutsState.isFull)
      _ = try await controller.saveDisplayLayout(name: "Last layout")
      XCTAssertEqual(controller.displayLayoutsState.layouts.count, 64)
      XCTAssertTrue(controller.displayLayoutsState.isFull)
      do {
        _ = try await controller.saveDisplayLayout(name: "One too many")
        XCTFail("saved a 65th layout")
      } catch {
        XCTAssertEqual(
          error.localizedDescription,
          String(localized: "This display layout is invalid or exceeds the limit of 64 layouts and 64 displays per layout."))
      }
      XCTAssertEqual(controller.displayLayoutsState.layouts.count, 64)
    }
  }

  func testNothingCanBeSavedWhileNoIndependentDisplayShowsAWallpaper() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    XCTAssertFalse(controller.displayLayoutsState.canSave)
    do {
      _ = try await controller.saveDisplayLayout(name: "Empty")
      XCTFail("an arrangement with nothing in it")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        String(localized: "Apply a wallpaper to an enabled independent display before saving or copying a layout."))
    }
  }

  func testTheStateReportsLayoutsThatCouldNotBeReadAndFollowsTheStore() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let original = panel.controller
    panel.defaults.set(Data("not layouts".utf8), forKey: WallpaperDisplayLayoutStore.storageKey)
    let reopened = panel.buildController()
    XCTAssertNotNil(reopened.displayLayoutsState.loadError)
    XCTAssertTrue(reopened.displayLayoutsState.layouts.isEmpty)
    XCTAssertNil(original.displayLayoutsState.loadError, "a controller built before the bad data was read nothing")
  }

  func testTheLayoutListFollowsTheStoreWithoutAnyOtherChange() async throws {
    try await withTwoDisplayPanel { panel, _ in
      let controller = panel.controller
      let changes = OSAllocatedUnfairLock(initialState: 0)
      withObservationTracking {
        _ = controller.displayLayoutsState
      } onChange: {
        changes.withLock { $0 += 1 }
      }
      _ = try controller.displayLayouts.save(
        name: "Behind the panel's back",
        assignments: WallpaperDisplayTransfer.capture(panel.store.displayTransferSnapshot()))
      try await panel.waitUntil { changes.withLock { $0 } == 1 }
      XCTAssertEqual(controller.displayLayoutsState.layouts.map(\.name), ["Behind the panel's back"])
    }
  }
}
