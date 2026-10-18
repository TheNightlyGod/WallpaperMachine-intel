import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The strip above a page: it takes no room with nothing to report, shows a row for each wallpaper
/// the app held back with a Try again that keeps the row when the engine refuses, and an error line
/// whose Dismiss never touches the held rows.
@MainActor
final class ShellBannersTests: PanelTestCase {
  /// The two wallpapers a held row can name, installed in the fixture's library.
  private func configureHeld(_ panel: PanelFixture, held: [String]) {
    panel.store.librarySnapshot.wallpapers = [("alpha", "Moody Forest"), ("beta", "Quiet Lake")].map {
      .init(
        id: $0.0, title: $0.1, kind: .projectScene, supported: true, active: false, selected: false,
        previewPath: nil)
    }
    panel.store.appSnapshot.heldWallpaperIds = held
    panel.bridge.bundleProvider = { [weak store = panel.store, weak bridge = panel.bridge] in
      var app = store!.appSnapshot
      app.heldWallpaperIds.removeAll { bridge!.releaseHeldCalls.contains($0) }
      return BridgeSnapshotBundle(
        app: app, library: store!.librarySnapshot, wallpaperOptions: store!.wallpaperOptionsSnapshot,
        monitorInformation: store!.monitorInformationSnapshot, settings: store!.settingsSnapshot)
    }
  }

  /// How tall the strip is when drawn at `width`: zero when it has nothing to say.
  private func height(of panel: PanelFixture, width: CGFloat = 640) -> CGFloat {
    let controller = panel.controller
    let hosting = NSHostingView(
      rootView: PanelBanners()
        .environment(controller)
        .frame(width: width))
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
    hosting.layoutSubtreeIfNeeded()
    return hosting.fittingSize.height
  }

  func testTheStripTakesNoRoomWithNothingToReportAndGrowsForEachRowAndForTheErrorLine() async throws {
    try await withPanel { panel in
      configureHeld(panel, held: [])
      XCTAssertEqual(height(of: panel), 0, "nothing is drawn and no room is kept")

      panel.store.appSnapshot.heldWallpaperIds = ["alpha"]
      let one = height(of: panel)
      XCTAssertGreaterThan(one, 20, "a row for the held wallpaper")
      panel.store.appSnapshot.heldWallpaperIds = ["alpha", "beta"]
      let two = height(of: panel)
      XCTAssertGreaterThan(two, one, "one row for each")

      panel.controller.errors.report(WallpaperActionError(message: "The engine is unavailable."))
      XCTAssertGreaterThan(height(of: panel), two, "the error line sits above them")
      panel.controller.dismissError()
      XCTAssertEqual(height(of: panel), two, "Dismiss takes the error line and leaves the held rows")
      XCTAssertEqual(panel.controller.heldWallpapers.count, 2, "a warning has no Dismiss")
    }
  }

  func testTryAgainRunsTheRetryAndAFailedOneKeepsTheRowAndShowsTheReasonInTheSameStrip() async throws {
    try await withPanel { panel in
      configureHeld(panel, held: ["alpha"])
      let controller = panel.controller
      let shell = controller.shell
      let held = height(of: panel)
      panel.bridge.releaseHeldFailure = WallpaperActionError(message: "The engine is unavailable.")

      await shell.releaseHeld("alpha").value
      XCTAssertEqual(panel.bridge.releaseHeldCalls, ["alpha"])
      XCTAssertEqual(controller.errors.message, "The engine is unavailable.")
      XCTAssertEqual(controller.heldWallpapers.map(\.id), ["alpha"], "a refused retry is not a release")
      XCTAssertGreaterThan(height(of: panel), held, "the reason is shown above the row that stays")
      XCTAssertFalse(shell.isReleasingHeld("alpha"), "and its button can be pressed again")

      panel.bridge.releaseHeldFailure = nil
      await shell.releaseHeld("alpha").value
      XCTAssertTrue(controller.heldWallpapers.isEmpty, "the row goes when the hold is released")
    }
  }

  func testAHeldRowIsSpokenWhenItAppearsAsTheStatusLineWas() async throws {
    try await withPanel { panel in
      configureHeld(panel, held: ["alpha"])
      let spoken = SpokenLines()
      panel.controller.shell.announce = { spoken.lines.append($0) }
      _ = height(of: panel)
      let row = try XCTUnwrap(panel.controller.heldWallpapers.first)
      XCTAssertEqual(spoken.lines, [row.message])
    }
  }

  func testTheStripWrapsALongReasonInsteadOfWideningTheWindow() async throws {
    try await withPanel { panel in
      configureHeld(panel, held: [])
      panel.controller.errors.report(
        WallpaperActionError(
          message: String(repeating: "A long reason that the engine gave for refusing. ", count: 6)))
      let wide = height(of: panel, width: 900)
      let narrow = height(of: panel, width: 260)
      XCTAssertGreaterThan(narrow, wide, "a narrow column wraps the reason onto more lines")
    }
  }
}

/// What the panel handed to VoiceOver, in order.
@MainActor
private final class SpokenLines {
  var lines: [String] = []
}
