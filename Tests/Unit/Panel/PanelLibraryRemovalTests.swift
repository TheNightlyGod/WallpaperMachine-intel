import XCTest

@testable import WallpaperMachine

/// Moving wallpapers to the Trash: the question first, the queue after it, and everything the app
/// kept about a wallpaper forgotten afterwards.
@MainActor
final class PanelLibraryRemovalTests: PanelTestCase {
  @MainActor private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
      isOpen = true
      let waiting = waiters
      waiters = []
      for waiter in waiting { waiter.resume() }
    }
  }

  private struct Refused: LocalizedError {
    var errorDescription: String? { "Refused" }
  }

  /// What the app keeps about wallpapers `a` and `b`: favorites, a collection, a playlist and history.
  private func rememberWallpapers(_ panel: PanelFixture) throws {
    panel.controller.favoriteIDs = ["a", "b"]
    try PanelPreferences.saveFavorites(["a", "b"], in: panel.defaults)
    try panel.collections.create(name: "Mine", wallpaperIDs: ["a", "b"])
    panel.playlists.update("primary") {
      $0.source = .list
      $0.wallpaperIDs = ["a", "b"]
    }
    panel.store.history.recordSwitch(from: nil, to: "a", on: "primary")
    panel.store.history.recordSwitch(from: "a", to: "b", on: "primary")
  }

  func testDeleteAsksFirstAndAPanelWithNoWindowDeletesNothing() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      var recycled: [URL] = []
      controller.recycleWallpaperFolder = { recycled.append($0) }
      try rememberWallpapers(panel)

      try await controller.delete("a")
      XCTAssertEqual(panel.dialogs.confirmations.count, 1)
      let asked = try XCTUnwrap(panel.dialogs.confirmations.first)
      XCTAssertEqual(asked.title, L("Move \("Ocean <img src=x>") to Trash?"), "the wallpaper is named as text")
      XCTAssertEqual(asked.button, L("Move to Trash"))
      XCTAssertTrue(recycled.isEmpty && bridge.ejections.isEmpty, "a refused question deletes nothing")
      XCTAssertEqual(controller.favoriteIDs, ["a", "b"])
    }
  }

  func testDeleteEjectsTrashesForgetsEverythingAndRescansOnce() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      var recycled: [URL] = []
      controller.recycleWallpaperFolder = { recycled.append($0) }
      panel.dialogs.confirmAnswer = true
      try rememberWallpapers(panel)
      let rescans = panel.store.libraryRefreshRevision

      try await controller.delete("a")
      XCTAssertEqual(bridge.ejections.map { "\($0.0)/\($0.1)" }, ["primary/a"], "it stops playing first")
      XCTAssertEqual(recycled, [panel.library.appendingPathComponent("a")])
      XCTAssertEqual(panel.store.libraryRefreshRevision, rescans + 1, "one rescan for the deletion")
      XCTAssertEqual(controller.favoriteIDs, ["b"])
      XCTAssertEqual(PanelPreferences.favorites(in: panel.defaults), ["b"])
      XCTAssertEqual(panel.collections.collections.first?.wallpaperIDs, ["b"])
      XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["b"])
      XCTAssertNil(panel.store.history.entries["primary"]?.recent.first { $0 == "a" })
      XCTAssertNil(controller.errors.message)
    }
  }

  func testTheQuestionIsAskedAtOnceWhileACommandRunsAndOnlyTheDeletionWaitsForTheQueue() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      controller.recycleWallpaperFolder = { _ in }
      panel.dialogs.confirmAnswer = true
      let gate = Gate()
      let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
      try await panel.waitUntil { panel.store.commands.isBusy }

      let task = controller.launch("delete:a") { try await controller.delete("a") }
      try await panel.waitUntil { panel.dialogs.confirmations.count == 1 }
      try await panel.waitUntil { panel.store.commands.waiting.count == 1 }
      XCTAssertTrue(bridge.ejections.isEmpty, "the deletion waits behind the running command")

      gate.open()
      _ = await running.value
      await task.value
      XCTAssertEqual(bridge.ejections.map { "\($0.0)/\($0.1)" }, ["primary/a"])
    }
  }

  func testAStaleWallpaperIsRefusedBeforeAnythingIsAsked() async throws {
    try await withApplyingPanel { panel, _, _ in
      let controller = panel.controller
      panel.dialogs.confirmAnswer = true
      await controller.launch { try await controller.delete("gone") }.value
      XCTAssertEqual(controller.errors.message, L("This wallpaper is no longer installed. Refresh your library."))
      await controller.launch { try await controller.deleteMany(["a", "gone"]) }.value
      XCTAssertEqual(
        controller.errors.message, L("Some selected wallpapers are no longer installed. Refresh your library."),
        "one stale id refuses the whole batch")
      XCTAssertTrue(panel.dialogs.confirmations.isEmpty)
      do {
        try await controller.deleteMany([])
        XCTFail("an empty selection is not a request")
      } catch {
        XCTAssertTrue(error is InvalidControlValue)
      }
    }
  }

  func testABatchIsOneQuestionOverDistinctWallpapersNamedByCountOrByTitle() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      var recycled: [String] = []
      controller.recycleWallpaperFolder = { recycled.append($0.lastPathComponent) }

      try await controller.deleteMany(["a", "c", "a"])
      XCTAssertEqual(
        panel.dialogs.confirmations.map(\.title), [L("Move \(2) wallpapers to Trash?")],
        "the repeat counts once")
      try await controller.deleteMany(["c"])
      XCTAssertEqual(panel.dialogs.confirmations.last?.title, L("Move \("c") to Trash?"))
      XCTAssertTrue(recycled.isEmpty)

      panel.dialogs.confirmAnswer = true
      try await controller.deleteMany(["a", "c"])
      XCTAssertEqual(recycled, ["a", "c"])
      XCTAssertEqual(bridge.ejections.map { "\($0.0)/\($0.1)" }, ["primary/a"])
    }
  }

  func testABatchThatPartlyFailsCleansUpWhatWasDeletedAndNamesWhatWasNot() async throws {
    try await withApplyingPanel { panel, _, _ in
      let controller = panel.controller
      panel.dialogs.confirmAnswer = true
      controller.recycleWallpaperFolder = { url in
        if url.lastPathComponent == "b" { throw Refused() }
      }
      try rememberWallpapers(panel)

      await controller.launch { try await controller.deleteMany(["a", "b"]) }.value
      XCTAssertEqual(
        controller.errors.message, L("Moved \(1) of \(2) wallpapers to Trash. Couldn’t move \("b: Refused")"))
      XCTAssertEqual(controller.favoriteIDs, ["b"], "what was deleted is forgotten even though a later one failed")
      XCTAssertEqual(panel.collections.collections.first?.wallpaperIDs, ["b"])
    }
  }

  func testASingleDeletionThatFailsReportsTheFailureAndForgetsNothing() async throws {
    try await withApplyingPanel { panel, _, _ in
      let controller = panel.controller
      panel.dialogs.confirmAnswer = true
      controller.recycleWallpaperFolder = { _ in throw Refused() }
      try rememberWallpapers(panel)
      await controller.launch { try await controller.delete("a") }.value
      XCTAssertEqual(controller.errors.message, "Refused")
      XCTAssertEqual(controller.favoriteIDs, ["a", "b"])
    }
  }
}
