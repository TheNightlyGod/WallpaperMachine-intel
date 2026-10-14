import Foundation
import XCTest

@testable import WallpaperMachine

/// A wallpaper the load journal holds back after the app died twice while loading it: the panel
/// names it in its own words, offers Try again, and a retry reaches the bridge once, for a held
/// wallpaper only. The journal itself is covered in the bridge crate (`tests::crash_loop_guard`).
@MainActor
final class ControlPanelHeldWallpaperTests: ControlPanelTestCase {
  private func message(_ title: String) -> String {
    String(
      localized:
        "“\(title)” was not restored: WallpaperMachine quit unexpectedly twice in a row while loading it. Nothing was deleted."
    )
  }

  /// Two installed wallpapers, `held` of them held back, and a bridge that answers a release
  /// with the same snapshots minus the wallpaper it was asked to release.
  private func configure(_ panel: PanelFixture, held: [String]) {
    panel.store.librarySnapshot.wallpapers = [("alpha", "Moody Forest"), ("beta", "Quiet Lake")].map {
      .init(id: $0.0, title: $0.1, kind: .projectScene, supported: true,
        active: false, selected: false, previewPath: nil)
    }
    panel.store.appSnapshot.heldWallpaperIds = held
    let fallback = Self.bundle(panel.store.appSnapshot, panel.store)
    panel.bridge.bundleProvider = { [weak store = panel.store, weak bridge = panel.bridge] in
      guard let store, let bridge else { return fallback }
      var app = store.appSnapshot
      app.heldWallpaperIds.removeAll { bridge.releaseHeldCalls.contains($0) }
      return Self.bundle(app, store)
    }
  }

  private static func bundle(_ app: BridgeAppSnapshot, _ store: BridgeStore) -> BridgeSnapshotBundle {
    .init(app: app, library: store.librarySnapshot, wallpaperOptions: store.wallpaperOptionsSnapshot,
      monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
  }

  private func rejection(_ panel: PanelFixture, _ id: String) async -> WallpaperActionError? {
    do {
      try await panel.controller.perform("releaseHeld", body: ["id": id])
      return nil
    } catch let error as WallpaperActionError {
      return error
    } catch {
      XCTFail("unexpected error \(error)")
      return nil
    }
  }

  func testThePanelSnapshotNamesEachHeldWallpaperInTheLocalizedSentence() async throws {
    try await withPanel { panel in
      configure(panel, held: ["alpha", "beta"])
      let held = try XCTUnwrap(panel.controller.snapshot()["held"] as? [[String: Any]])
      XCTAssertEqual(held.compactMap { $0["id"] as? String }, ["alpha", "beta"])
      XCTAssertEqual(held.compactMap { $0["title"] as? String }, ["Moody Forest", "Quiet Lake"])
      XCTAssertEqual(
        held.compactMap { $0["message"] as? String },
        [message("Moody Forest"), message("Quiet Lake")])

      panel.store.appSnapshot.heldWallpaperIds = []
      let none = try XCTUnwrap(panel.controller.snapshot()["held"] as? [[String: Any]])
      XCTAssertTrue(none.isEmpty, "nothing held, nothing to say")
    }
  }

  func testAHeldWallpaperMissingFromTheLibraryIsStillNamedByItsID() async throws {
    try await withPanel { panel in
      configure(panel, held: ["gone"])
      let held = try XCTUnwrap(panel.controller.snapshot()["held"] as? [[String: Any]])
      XCTAssertEqual(held.first?["message"] as? String, message("gone"),
        "a display left blank must still be explained")
    }
  }

  func testReleaseHeldReachesTheBridgeOnceForAHeldWallpaperAndRejectsAnythingElse() async throws {
    try await withPanel { panel in
      configure(panel, held: ["alpha"])

      // Installed but not held: a stale tile from before an earlier release.
      let notHeld = await rejection(panel, "beta")
      XCTAssertEqual(notHeld?.message, WebPanelRequest.invalid.message)
      // Not installed at all.
      let unknown = await rejection(panel, "ghost")
      XCTAssertNotNil(unknown)
      XCTAssertNotEqual(unknown?.message, WebPanelRequest.invalid.message)
      XCTAssertTrue(panel.bridge.releaseHeldCalls.isEmpty, "nothing reached the bridge")

      try await panel.controller.perform("releaseHeld", body: ["id": "alpha"])
      XCTAssertEqual(panel.bridge.releaseHeldCalls, ["alpha"])
      XCTAssertTrue(panel.store.heldWallpaperIDs.isEmpty, "the reply's snapshot is applied")

      // The same click arriving again is a stale one.
      let again = await rejection(panel, "alpha")
      XCTAssertEqual(again?.message, WebPanelRequest.invalid.message)
      XCTAssertEqual(panel.bridge.releaseHeldCalls, ["alpha"])
    }
  }

  func testTheBannerListsHeldWallpapersAndItsButtonPostsReleaseHeld() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.show()
      try await panel.expectJS("return document.getElementById('held-banner').hidden", equals: true)

      configure(panel, held: ["alpha", "beta"])
      panel.store.snapshotRevision &+= 1
      try await panel.waitJS("!document.getElementById('held-banner').hidden")
      try await panel.expectJS(
        "return [...document.querySelectorAll('#held-banner .held-row p')].map(p => p.textContent)",
        equals: [message("Moody Forest"), message("Quiet Lake")])
      try await panel.expectJS(
        "return [...document.querySelectorAll('#held-banner [data-action=\"releaseHeld\"]')].map(b => b.dataset.id)",
        equals: ["alpha", "beta"])

      _ = try await panel.js("document.querySelector('#held-banner [data-id=\"alpha\"]').click()")
      try await panel.waitUntil { panel.bridge.releaseHeldCalls == ["alpha"] }
      try await panel.waitJS("document.querySelectorAll('#held-banner .held-row').length === 1")
      try await panel.expectJS(
        "return document.querySelector('#held-banner [data-action=\"releaseHeld\"]').dataset.id",
        equals: "beta")

      _ = try await panel.js("document.querySelector('#held-banner [data-id=\"beta\"]').click()")
      try await panel.waitJS("document.getElementById('held-banner').hidden")
      XCTAssertEqual(panel.bridge.releaseHeldCalls, ["alpha", "beta"])
    }
  }

  func testAFailedRetryKeepsTheBannerAndShowsTheBridgeError() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      configure(panel, held: ["alpha"])
      panel.bridge.releaseHeldFailure = WallpaperActionError(message: "The engine is unavailable.")
      panel.show()
      try await panel.waitJS("!document.getElementById('held-banner').hidden")

      _ = try await panel.js("document.querySelector('#held-banner [data-id=\"alpha\"]').click()")
      try await panel.waitUntil { panel.bridge.releaseHeldCalls == ["alpha"] }
      try await panel.waitJS(
        "!document.getElementById('error-banner').hidden && document.getElementById('error-banner').textContent.includes('The engine is unavailable.')"
      )
      XCTAssertEqual(panel.store.heldWallpaperIDs, ["alpha"], "a refused retry is not a release")
      try await panel.expectJS("return document.getElementById('held-banner').hidden", equals: false)

      // The retry works once the bridge does, from the same banner.
      panel.bridge.releaseHeldFailure = nil
      _ = try await panel.js("document.querySelector('#held-banner [data-id=\"alpha\"]').click()")
      try await panel.waitJS("document.getElementById('held-banner').hidden")
      XCTAssertTrue(panel.store.heldWallpaperIDs.isEmpty)
    }
  }
}
