import os
import XCTest

@testable import WallpaperMachine

/// The playlist actions of Settings › Displays and the state its Playlist rows read, checked
/// against the stores without a window.
@MainActor
final class PanelPlaylistActionsTests: PanelTestCase {
  /// An independent display, a mirror, and a library of two wallpapers that can play and one that
  /// cannot.
  private func makePanel() throws -> PanelFixture {
    let panel = try makeController()
    panel.store.settingsSnapshot.displays = [
      OrganizationFixtures.display("primary"), OrganizationFixtures.display("mirrored", mode: .mirror),
    ]
    panel.store.librarySnapshot.wallpapers = [
      OrganizationFixtures.wallpaper("a"), OrganizationFixtures.wallpaper("b"),
      OrganizationFixtures.wallpaper("app", supported: false),
    ]
    return panel
  }

  private func minute(_ value: Int) throws -> ClockMinute { try XCTUnwrap(ClockMinute(minutes: value)) }

  func testSettingsReachThePlaylistOfTheNamedDisplay() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.editPlaylist(.mode(.rotate), display: "primary")
    try await controller.editPlaylist(.interval(.preset(60)), display: "primary")
    try await controller.editPlaylist(.dayStart(try minute(390)), display: "primary")
    try await controller.editPlaylist(.dayWallpaper("b"), display: "primary")
    try await controller.editPlaylist(.order(.shuffle))
    try await controller.editPlaylist(.source(.favorites))
    let playlist = panel.playlists.playlist(for: "primary")
    XCTAssertEqual(playlist.mode, .rotate)
    XCTAssertEqual(playlist.interval, 60)
    XCTAssertEqual(playlist.dayStart, 390)
    XCTAssertEqual(playlist.dayWallpaperID, "b")
    XCTAssertEqual(playlist.order, .shuffle, "no display named: the target display")
    XCTAssertEqual(playlist.source, .favorites)
    XCTAssertEqual(controller.playlistState(for: "primary").playlist, playlist)
    try await controller.editPlaylist(.dayWallpaper(nil))
    try await controller.editPlaylist(.nightStart(try minute(1439)))
    XCTAssertNil(panel.playlists.playlist(for: "primary").dayWallpaperID, "nil leaves the day as it is")
    XCTAssertEqual(panel.playlists.playlist(for: "primary").nightStart, 1439)
  }

  func testATypedIntervalOutsideTheMenuIsKept() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.editPlaylist(.interval(.custom(45)), display: "primary")
    XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 45)
    XCTAssertEqual(controller.playlistState(for: "primary").interval, .custom(45))
    try await controller.editPlaylist(.interval(.custom(7 * 24 * 60)), display: "primary")
    XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 7 * 24 * 60)
    try await controller.editPlaylist(.interval(.custom(60)), display: "primary")
    XCTAssertEqual(
      controller.playlistState(for: "primary").interval, .preset(60),
      "a typed number equal to a menu time reads as that time again")
  }

  func testTheUnlockTriggerIsStoredAndATimeBringsTheTimerBack() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    XCTAssertEqual(controller.playlistState(for: "primary").interval, .preset(30), "a new playlist rotates every 30 minutes")
    try await controller.editPlaylist(.mode(.rotate), display: "primary")
    try await controller.editPlaylist(.interval(.unlock), display: "primary")
    XCTAssertEqual(panel.playlists.playlist(for: "primary").trigger, .unlock)
    XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 30, "the minutes are kept for when a time is chosen again")
    XCTAssertEqual(PlaylistStore(defaults: panel.defaults).playlist(for: "primary").trigger, .unlock)
    XCTAssertEqual(controller.playlistState(for: "primary").interval, .unlock)

    try await controller.editPlaylist(.interval(.preset(60)), display: "primary")
    XCTAssertEqual(panel.playlists.playlist(for: "primary").trigger, .interval, "choosing a time is choosing the timer")
    XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 60)
    XCTAssertEqual(controller.playlistState(for: "primary").interval, .preset(60))
  }

  func testValuesThePanelNeverOffersAreRefusedAndNothingChanges() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let refused: [(PlaylistEdit, String)] = [
      (.interval(.custom(0)), "primary"), (.interval(.custom(7 * 24 * 60 + 1)), "primary"),
      (.interval(.preset(7)), "primary"), (.interval(.custom(-5)), "primary"),
      (.nightWallpaper("app"), "primary"), (.dayWallpaper("missing"), "primary"),
      (.dayWallpaper(""), "primary"),
      (.mode(.rotate), "mirrored"), (.interval(.unlock), "mirrored"), (.mode(.rotate), "gone"),
    ]
    for (edit, display) in refused {
      do {
        try await controller.editPlaylist(edit, display: display)
        XCTFail("accepted \(edit) on \(display)")
      } catch { XCTAssertTrue(error is InvalidControlValue, "\(edit) on \(display)") }
    }
    for edit in [PlaylistEdit.collection(id: "gone"), .source(.collection)] {
      do {
        try await controller.editPlaylist(edit, display: "primary")
        XCTFail("accepted \(edit)")
      } catch {
        XCTAssertEqual(
          error.localizedDescription, String(localized: "This collection no longer exists. Refresh the library and retry."))
      }
    }
    XCTAssertEqual(panel.playlists.playlist(for: "primary"), DisplayPlaylist())
    XCTAssertEqual(panel.playlists.playlist(for: "mirrored"), DisplayPlaylist())
  }

  func testTheListGrowsFromTheLibraryAndShrinksOnRequest() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.addToPlaylist(["b", "a", "b"])
    XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["b", "a"], "the target display, once each")
    do {
      try await controller.addToPlaylist(["missing"])
      XCTFail("a wallpaper that is not installed cannot join a list")
    } catch {
      XCTAssertEqual(
        error.localizedDescription, L("Some selected wallpapers are no longer installed. Refresh your library."))
    }
    do {
      try await controller.addToPlaylist([])
      XCTFail("an empty selection is not a request a control makes")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
    do {
      try await controller.addToPlaylist(["a"], display: "mirrored")
      XCTFail("a mirror has no list of its own")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
    try await controller.removeFromPlaylist("b")
    XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["a"])
    try await controller.removeFromPlaylist("never-there")
    XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["a"], "a wallpaper that left can be taken out")
  }

  func testChangeNowNeedsARotatingDisplayAndSaysWhy() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    do {
      try await controller.skipPlaylist(display: "primary")
      XCTFail("a display without a scheduler to move it cannot change now")
    } catch {
      XCTAssertEqual(error.localizedDescription, L("This display has no rotating playlist to move along."))
    }
    panel.playlists.update("primary") { $0.mode = .rotate }
    do {
      try await controller.skipPlaylist(display: "primary")
      XCTFail("a rotation the scheduler cannot move")
    } catch {
      XCTAssertEqual(
        error.localizedDescription, L("This display’s playlist has no other wallpaper to change to."))
    }
    var asked: [String] = []
    panel.playlists.skipHandler = { display in
      asked.append(display)
      return true
    }
    try await controller.skipPlaylist(display: "primary")
    try await controller.skipPlaylist()
    XCTAssertEqual(asked, ["primary", "primary"], "the target display is the default")
    do {
      try await controller.skipPlaylist(display: "mirrored")
      XCTFail("a mirror follows its source")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
    XCTAssertEqual(asked.count, 2)
  }

  /// A removal that holds the playlist shows as a paused playlist, and Resume reaches the scheduler
  /// for the display it names.
  func testResumeReachesTheSchedulerAndTheStateReportsTheHold() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    panel.playlists.update("primary") { $0.mode = .rotate }
    XCTAssertFalse(controller.playlistState(for: "primary").isHeld)
    panel.playlists.setHold(.removedWallpaper, on: "primary")
    XCTAssertTrue(controller.playlistState(for: "primary").isHeld)
    XCTAssertTrue(controller.playlistState(for: "primary").showsResume)

    var asked: [String] = []
    panel.playlists.resumeHandler = { asked.append($0) }
    try await controller.resumePlaylist(display: "primary")
    XCTAssertEqual(asked, ["primary"])
    try await controller.resumePlaylist()
    XCTAssertEqual(asked, ["primary", "primary"], "the target display is the default")
    for display in ["mirrored", "gone"] {
      do {
        try await controller.resumePlaylist(display: display)
        XCTFail("resumed \(display)")
      } catch { XCTAssertTrue(error is InvalidControlValue) }
    }
    XCTAssertEqual(asked.count, 2)

    panel.playlists.setHold(nil, on: "primary")
    XCTAssertFalse(controller.playlistState(for: "primary").isHeld)

    panel.playlists.update("primary") { $0.mode = .off }
    panel.playlists.setHold(.removedWallpaper, on: "primary")
    XCTAssertTrue(controller.playlistState(for: "primary").isHeld)
    XCTAssertFalse(controller.playlistState(for: "primary").showsResume, "a playlist that is off waits for nothing")
  }

  func testReorderingUsesExactMembershipAndAnEligibleDisplay() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    panel.playlists.update("primary") {
      $0.source = .list
      $0.wallpaperIDs = ["a", "b"]
    }
    try await controller.reorderPlaylist(["b", "a"], expected: ["a", "b"])
    XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["b", "a"])
    let refused: [(ids: [String], expected: [String], display: String?)] = [
      (["a", "a"], ["b", "a"], nil), (["a", "b"], ["a", "b"], nil), (["a", "b"], ["b", "a"], "mirrored"),
      (["a", "b", "c"], ["b", "a"], nil), (["a"], ["b", "a"], nil),
    ]
    for value in refused {
      do {
        try await controller.reorderPlaylist(value.ids, expected: value.expected, display: value.display)
        XCTFail("accepted a stale or invalid order \(value)")
      } catch {}
    }
    XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["b", "a"])
    do {
      try await controller.reorderPlaylist(Array(repeating: "a", count: 10_001), expected: ["b", "a"])
      XCTFail("more than 10,000 ids")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
  }

  /// The Move up and Move down buttons and a drop send the order they started from, and a list that
  /// changed meanwhile is never overwritten by an older view of it.
  func testButtonsAndDragReorderTheListAndRefuseAStaleDrag() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    panel.store.librarySnapshot.wallpapers = ["a", "b", "c", "d"].map { OrganizationFixtures.wallpaper($0) }
    panel.playlists.update("primary") {
      $0.mode = .rotate
      $0.source = .list
      $0.wallpaperIDs = ["a", "b", "c"]
    }
    let installed = Set(panel.store.librarySnapshot.wallpapers.map(\.id))
    func stored() -> [String] { panel.playlists.playlist(for: "primary").wallpaperIDs }
    func move(_ id: String, _ direction: Int) async throws -> Bool {
      let expected = stored()
      guard let ids = PlaylistOrdering.moved(id, by: direction, in: expected, installed: installed) else { return false }
      try await controller.reorderPlaylist(ids, expected: expected)
      return true
    }

    let movedDown = try await move("a", 1)
    XCTAssertTrue(movedDown)
    XCTAssertEqual(stored(), ["b", "a", "c"])
    let movedFurther = try await move("a", 1)
    XCTAssertTrue(movedFurther)
    XCTAssertEqual(stored(), ["b", "c", "a"])
    let movedPastTheEnd = try await move("a", 1)
    XCTAssertFalse(movedPastTheEnd, "the last wallpaper has nowhere to go down")
    let movedBack = try await move("a", -1)
    XCTAssertTrue(movedBack)
    XCTAssertEqual(stored(), ["b", "a", "c"])

    // A drop sends the order the drag started from, with the wallpaper put after the one it landed on.
    let started = stored()
    let dropped = PlaylistOrdering.reordered(started, moving: "b", relativeTo: "c", after: true)
    try await controller.reorderPlaylist(dropped, expected: started)
    XCTAssertEqual(stored(), ["a", "c", "b"])
    XCTAssertEqual(PlaylistStore(defaults: panel.defaults).playlist(for: "primary").wallpaperIDs, ["a", "c", "b"])

    // Another wallpaper joins while a drag is under way: the drop is refused and nothing is lost.
    let draggedFrom = stored()
    panel.playlists.add(["d"], to: "primary")
    let staleDrop = PlaylistOrdering.reordered(draggedFrom, moving: "a", relativeTo: "b", after: true)
    do {
      try await controller.reorderPlaylist(staleDrop, expected: draggedFrom)
      XCTFail("a stale drag overwrote the list")
    } catch {
      XCTAssertEqual(error.localizedDescription, String(localized: "The playlist changed. Refresh it and try reordering again."))
    }
    XCTAssertEqual(stored(), ["a", "c", "b", "d"])
  }

  func testAMoveKeepsTheWallpapersThatLeftTheLibraryInPlaceInBothLists() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    panel.playlists.update("primary") {
      $0.source = .list
      $0.wallpaperIDs = ["a", "gone", "b"]
    }
    let installed = Set(panel.store.librarySnapshot.wallpapers.map(\.id))
    let expected = panel.playlists.playlist(for: "primary").wallpaperIDs
    let ids = try XCTUnwrap(PlaylistOrdering.moved("a", by: 1, in: expected, installed: installed))
    XCTAssertEqual(ids, ["gone", "b", "a"], "the neighbour is the next wallpaper that is still installed")
    try await controller.reorderPlaylist(ids, expected: expected)
    XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["gone", "b", "a"])
  }

  func testManualPlaylistEditsWaitForActivationAndKeepEveryField() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    struct Refused: LocalizedError { var errorDescription: String? { "Refused" } }
    controller.errors.report(Refused())
    let gate = QueueGate()
    let activation = Task { @MainActor in
      await panel.store.commands.run(slot: BridgeStore.activationSlot(displayId: "primary")) {
        await gate.wait()
        panel.playlists.update("primary") { $0.mode = .off }
      }
    }
    try await panel.waitUntil { panel.store.commands.isBusy }
    var manual: [String] = []
    panel.automations.manualChoice = { manual.append($0) }
    let first = Task { try await controller.editPlaylist(.mode(.rotate), display: "primary") }
    let second = Task { try await controller.editPlaylist(.interval(.preset(60)), display: "primary") }
    try await panel.waitUntil { panel.store.commands.waiting.count == 2 }
    XCTAssertEqual(panel.playlists.playlist(for: "primary").mode, .off)
    XCTAssertEqual(controller.errors.message, "Refused", "an edit leaves an older banner showing")
    gate.open()
    _ = await activation.value
    try await first.value
    try await second.value
    XCTAssertEqual(panel.playlists.playlist(for: "primary").mode, .rotate)
    XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 60)
    XCTAssertEqual(manual, ["primary", "primary"], "each edit is a manual choice")
  }

  func testAnEditQueuedBehindASwitchStopsAtADisplayThatNoLongerHasAPlaylist() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let gate = QueueGate()
    let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
    try await panel.waitUntil { panel.store.commands.isBusy }
    var manual: [String] = []
    panel.automations.manualChoice = { manual.append($0) }
    let edit = Task { try await controller.editPlaylist(.mode(.rotate), display: "primary") }
    try await panel.waitUntil { panel.store.commands.waiting.count == 1 }
    panel.store.settingsSnapshot.displays[0].enabled = false
    gate.open()
    _ = await running.value
    do {
      try await edit.value
      XCTFail("the display stopped being independent while the edit waited")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
    XCTAssertEqual(panel.playlists.playlist(for: "primary"), DisplayPlaylist())
    XCTAssertTrue(manual.isEmpty, "a refused edit is no manual choice")
  }

  func testClearingTheFailuresAllowsTheWallpapersAgain() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let retry = Date(timeIntervalSince1970: 2_000_000_000)
    panel.playlists.recordFailure("b", on: "primary", message: "second", retryAfter: retry)
    panel.playlists.recordFailure("a", on: "primary", message: "first", retryAfter: retry)
    XCTAssertEqual(
      controller.playlistState(for: "primary").skipped,
      [
        .init(id: "a", message: "first", retryAfter: retry), .init(id: "b", message: "second", retryAfter: retry),
      ], "by id")
    try await controller.clearPlaylistFailures()
    XCTAssertTrue(controller.playlistState(for: "primary").skipped.isEmpty)
    do {
      try await controller.clearPlaylistFailures(display: "mirrored")
      XCTFail("a mirror has no rotation to retry")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
  }

  func testHistoryClearForgetsOnlyTheNamedDisplay() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    panel.store.history.recordSwitch(from: "a", to: "b", on: "primary")
    panel.store.history.recordSwitch(from: "b", to: "a", on: "primary")
    panel.store.history.recordSwitch(from: "app", to: "a", on: "secondary")
    try await controller.clearHistory()
    XCTAssertNil(panel.store.history.entries["primary"], "the target display's recent list and back history")
    XCTAssertEqual(
      panel.store.history.recent(on: "secondary", available: ["a", "app"]), ["a", "app"],
      "another display keeps its own")
    do {
      try await controller.clearHistory(display: "mirrored")
      XCTFail("a mirror has no history of its own")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
  }

  func testTheStateCarriesTheSchedulersRunStateAndCountsTheListedWallpapersStillInstalled() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let due = Date(timeIntervalSince1970: 2_000_000_000)
    panel.playlists.update("primary") {
      $0.mode = .rotate
      $0.source = .list
      $0.wallpaperIDs = ["a", "gone", "b"]
    }
    panel.playlists.schedule("primary", at: due)
    let state = controller.playlistState(for: "primary")
    XCTAssertEqual(state.nextChange, due)
    XCTAssertEqual(state.listedCount, 2, "the stored list keeps what left the library; the menu counts what is installed")
    XCTAssertEqual(state.source, .list)
    XCTAssertEqual(state.display, "primary")

    let untouched = controller.playlistState(for: "mirrored")
    XCTAssertEqual(untouched.playlist, DisplayPlaylist(), "a display nobody configured is off")
    XCTAssertNil(untouched.nextChange)
    XCTAssertFalse(untouched.isHeld)
    XCTAssertTrue(untouched.skipped.isEmpty)
  }

  func testTheStateFollowsTheStoreWithoutAnyOtherChange() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await panel.start()
    let changes = OSAllocatedUnfairLock(initialState: 0)
    withObservationTracking {
      _ = controller.playlistState(for: "primary")
      _ = controller.playlistPlanRows
    } onChange: {
      changes.withLock { $0 += 1 }
    }
    panel.playlists.setHold(.removedWallpaper, on: "primary")
    try await panel.waitUntil { changes.withLock { $0 } == 1 }
    XCTAssertTrue(controller.playlistState(for: "primary").isHeld)
  }
}
