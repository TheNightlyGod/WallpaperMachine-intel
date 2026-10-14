import Foundation
import XCTest
@testable import WallpaperMachine

@MainActor
final class ControlPanelPreviewTests: ControlPanelTestCase {
  func testPreviewUsesSelectedWallpaperAndUnappliedTextWithoutChangingTheDesktop() async throws {
    try await withPanel { panel in
      panel.store.librarySnapshot.wallpapers = [
        .init(id: "preview", title: "Preview", kind: .webpage, supported: true, active: false, selected: true, previewPath: nil),
        .init(id: "active", title: "Active", kind: .video, supported: true, active: true, selected: false, previewPath: nil),
      ]
      panel.store.appSnapshot = .init(playbackState: .playing, selectedWallpaperId: "preview", activeWallpaperIds: ["active"], errors: [], heldWallpaperIds: [])
      panel.store.monitorInformationSnapshot.rows = [.init(displayId: "primary", title: "Primary",
        wallpaperId: "active", wallpaperTitle: "Active", mirrorTargetDisplayId: nil, mirrorTargetTitle: nil,
        scalingMode: "fill", targetFps: "30", audioResponse: false)]
      let property = BridgePropertyDescriptor(id: "message", kind: .textInput, labelHtml: "Message",
        value: .string(value: "Saved"), defaultValue: .string(value: "Saved"), slider: nil, comboOptions: [],
        fileFilter: nil, directoryMode: nil, dirty: false, canRestoreDefaults: false, enabled: true,
        assetManaged: false, assetMissing: false, assetSourcePath: nil)
      panel.store.wallpaperOptionsSnapshot = BridgeSnapshotFixtures.options(wallpaperId: "preview", kind: .webpage, properties: [property])
      var previews: [WallpaperPreviewSession.Selection] = []
      panel.store.openPreview = { previews.append($0) }
      let before = panel.store.appSnapshot
      try await panel.finishWelcome()
      panel.show()
      try await panel.waitJS("Boolean(document.querySelector('#inspector [data-action=\"previewWallpaper\"]'))")
      _ = try await panel.js("""
        const input = document.querySelector('input[data-input="property"][data-property-id="message"]');
        input.value = 'Draft <b>text</b>';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        document.querySelector('#inspector [data-action="previewWallpaper"]').click();
        """)
      try await panel.waitUntil { previews.count == 1 }
      XCTAssertEqual(previews.first, .init(wallpaperID: "preview", displayID: "primary", textOverrides: ["message": "Draft <b>text</b>"]))
      XCTAssertEqual(panel.store.appSnapshot, before)
      XCTAssertEqual(panel.store.monitorInformationSnapshot.rows.first?.wallpaperId, "active")
      XCTAssertTrue(panel.store.history.entries.isEmpty)
      XCTAssertEqual(panel.store.wallpaperOptionsSnapshot?.properties.first?.value, .string(value: "Saved"))
    }
  }
}
