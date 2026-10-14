import Foundation
import XCTest

@testable import WallpaperMachine

/// Restore all defaults, driven through the live panel: the page, the native action and the
/// bridge's answer, with the unsent text only the page holds.
@MainActor
final class ControlPanelRestoreAllTests: ControlPanelTestCase {
  private func property(
    _ id: String, _ kind: BridgePropertyKind, value: BridgePropertyValue,
    defaultValue: BridgePropertyValue, dirty: Bool
  ) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(
      id: id, kind: kind, labelHtml: id.capitalized, value: value, defaultValue: defaultValue,
      slider: kind == .slider ? BridgeSliderMetadata(min: 0, max: 100, step: 1, precision: 0) : nil,
      comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: dirty,
      canRestoreDefaults: dirty, enabled: true, assetManaged: false, assetMissing: false,
      assetSourcePath: nil)
  }

  func testRestoreAllDropsUnsentTextAndShowsTheDefaultsTheBridgeStaged() async throws {
    try await withPanel { panel in
      panel.store.librarySnapshot.wallpapers = [
        .init(
          id: "scene-1", title: "Scene one", kind: .projectScene, supported: true, active: false,
          selected: true, previewPath: nil)
      ]
      panel.store.appSnapshot = .init(
        playbackState: .playing, selectedWallpaperId: "scene-1", activeWallpaperIds: [], errors: [], heldWallpaperIds: [])
      let edited = BridgeSnapshotFixtures.options(
        wallpaperId: "scene-1", kind: .projectScene,
        properties: [
          property(
            "size", .slider, value: .number(value: 42), defaultValue: .number(value: 10),
            dirty: true),
          property(
            "message", .textInput, value: .string(value: "Saved"),
            defaultValue: .string(value: "Saved"), dirty: false),
        ])
      // What the engine reports once the defaults are staged: the slider is back at its
      // default and the draft differs from what is applied, so Apply and Revert are offered.
      let staged = BridgeSnapshotFixtures.options(
        wallpaperId: "scene-1", kind: .projectScene, dirty: true,
        properties: [
          property(
            "size", .slider, value: .number(value: 10), defaultValue: .number(value: 10),
            dirty: false),
          property(
            "message", .textInput, value: .string(value: "Saved"),
            defaultValue: .string(value: "Saved"), dirty: false),
        ])
      panel.bridge.options["scene-1"] = edited
      panel.store.wallpaperOptionsSnapshot = edited
      let store = panel.store
      panel.bridge.restoreAllProvider = { _ in
        BridgeWallpaperMutationBundle(
          app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: staged,
          monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
      }
      try await panel.finishWelcome()
      panel.show()
      let restore = "#inspector [data-action=\"restoreAllProperties\"]"
      try await panel.waitJS("document.querySelector('\(restore)') && !document.querySelector('\(restore)').disabled")

      _ = try await panel.js("""
        const input = document.querySelector('input[data-input="property"][data-property-id="message"]');
        input.value = 'Typed, not sent';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        """)
      try await panel.waitJS("document.querySelector('#inspector [data-key=\"message\"] .field-flag')")
      try await panel.expectJS(
        "return Boolean(document.querySelector('#inspector [data-key=\"size\"] .field-flag'))",
        equals: true)

      _ = try await panel.js("document.querySelector('\(restore)').click()")
      try await panel.waitUntil { panel.bridge.restoreAllCalls == ["scene-1"] }

      try await panel.waitJS("""
        !document.querySelector('#inspector [data-key="size"] .field-flag')
          && !document.querySelector('#inspector [data-key="message"] .field-flag')
        """)
      try await panel.expectJS(
        "return document.querySelector('input[data-input=\"property\"][data-property-id=\"message\"]').value",
        equals: "Saved")
      try await panel.expectJS(
        "return document.querySelector('#inspector [data-key=\"size\"] input[type=\"range\"]').value",
        equals: "10")
      try await panel.expectJS(
        "return document.querySelector('#inspector [data-action=\"apply\"]').disabled",
        equals: false)
      // Everything now reads as its default, so there is nothing left to restore.
      try await panel.expectJS(
        "return document.querySelector('\(restore)').disabled", equals: true)
    }
  }
}
