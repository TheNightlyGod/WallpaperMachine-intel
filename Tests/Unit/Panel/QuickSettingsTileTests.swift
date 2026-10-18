import AppKit
import XCTest

@testable import WallpaperMachine

/// Which Quick Settings tiles exist, what each says and when one cannot be pressed: the rules of the
/// page's tile grid (`quick.tile-*`), as plain values.
@MainActor
final class QuickSettingsTileTests: PanelTestCase {
  private func tiles(_ panel: PanelFixture) -> [QuickTile] {
    let settings = panel.controller.settings
    return QuickTile.tiles(for: panel.controller) { settings.isOn($0) }
  }

  private func tile(_ key: SettingsSwitchKey, in tiles: [QuickTile]) throws -> QuickTile {
    try XCTUnwrap(tiles.first { $0.key == key }, "\(key) has no tile")
  }

  func testThePageHasTheseTilesInThisOrderAndActiveDisplayOnlyNeedsASecondDisplay() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      XCTAssertEqual(
        tiles(panel).map(\.key),
        [
          .launchAtLogin, .wallpapersMuted, .lockScreenEnabled, .screenSaverEnabled,
          .writeDesktopPicture, .hideAfterActivating, .livePropertyEdits,
        ], "One display has no other to pause")

      panel.configureDisplays()
      XCTAssertEqual(
        tiles(panel).map(\.key),
        [
          .launchAtLogin, .wallpapersMuted, .lockScreenEnabled, .screenSaverEnabled,
          .writeDesktopPicture, .playOnlyOnActiveDisplay, .hideAfterActivating, .livePropertyEdits,
        ])

      // While it is on it stays, so it can be turned off with one display left.
      panel.store.settingsSnapshot.displays = Array(panel.store.settingsSnapshot.displays.prefix(1))
      panel.controller.playback.playsOnlyOnActiveDisplay = true
      XCTAssertTrue(tiles(panel).contains { $0.key == .playOnlyOnActiveDisplay })
    }
  }

  func testEachTileSwitchesTheSettingItIsNamedAfterAndTheirStatesFollowTheStores() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      XCTAssertFalse(try tile(.wallpapersMuted, in: tiles(panel)).isOn)
      controller.playback.wallpapersMuted = true
      XCTAssertTrue(try tile(.wallpapersMuted, in: tiles(panel)).isOn)

      // Desktop Picture is on until turned off; Hide After Applying and Live Edits are off until on.
      XCTAssertTrue(try tile(.writeDesktopPicture, in: tiles(panel)).isOn)
      XCTAssertFalse(try tile(.hideAfterActivating, in: tiles(panel)).isOn)
      XCTAssertFalse(try tile(.livePropertyEdits, in: tiles(panel)).isOn)
      controller.playback.writesDesktopPicture = false
      XCTAssertFalse(try tile(.writeDesktopPicture, in: tiles(panel)).isOn)
    }
  }

  func testTheMuteTileChangesItsGlyphWhileMuted() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let before = try tile(.wallpapersMuted, in: tiles(panel)).symbol
      panel.controller.playback.wallpapersMuted = true
      let after = try tile(.wallpapersMuted, in: tiles(panel)).symbol
      XCTAssertNotEqual(before, after)
    }
  }

  func testTheLoginTileSaysWhyItCannotBePressedOrThatItNeedsApproval() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      var login = try tile(.launchAtLogin, in: tiles(panel))
      XCTAssertFalse(login.isEnabled, "Outside Applications there is nothing to switch")
      XCTAssertEqual(login.note, "Unavailable")
      XCTAssertEqual(login.stateLine, "Unavailable")

      var settings = panel.store.settingsSnapshot
      settings.launchAtLoginAvailable = true
      settings.launchAtLoginNeedsApproval = true
      panel.store.settingsSnapshot = settings
      login = try tile(.launchAtLogin, in: tiles(panel))
      XCTAssertTrue(login.isEnabled)
      XCTAssertEqual(login.note, "Needs approval")
      XCTAssertFalse(login.isOn, "A request waiting for approval is not on")

      settings.launchAtLoginNeedsApproval = false
      settings.launchAtLoginEnabled = true
      panel.store.settingsSnapshot = settings
      login = try tile(.launchAtLogin, in: tiles(panel))
      XCTAssertNil(login.note)
      XCTAssertEqual(login.stateLine, "On")
      XCTAssertTrue(login.isOn)
    }
  }

  func testTheLockScreenAndScreenSaverTilesAreExperimentalAndUnavailableWithoutTheService() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let lock = try tile(.lockScreenEnabled, in: tiles(panel))
      let saver = try tile(.screenSaverEnabled, in: tiles(panel))
      for tile in [lock, saver] {
        XCTAssertFalse(tile.isEnabled)
        XCTAssertTrue(tile.isExperimental)
        XCTAssertEqual(tile.note, "Unavailable")
        XCTAssertEqual(tile.stateLine, "Unavailable · Experimental")
        XCTAssertEqual(tile.state, "Unavailable", "The state alone is what a narrow tile shows")
      }
      let hide = try tile(.hideAfterActivating, in: tiles(panel))
      XCTAssertFalse(hide.isExperimental)
      XCTAssertEqual(hide.stateLine, "Off")
    }
  }

  func testTheDesktopPictureTileGivesNoReasonOnlyTheRowDoes() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let tile = try tile(.writeDesktopPicture, in: tiles(panel))
      XCTAssertNil(tile.note)
      XCTAssertEqual(tile.stateLine, "On")
    }
  }

  /// Glyphs that the Mac does not know would draw as nothing.
  func testEveryGlyphOfTheTilesIsASymbolThisMacHas() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      panel.configureDisplays()
      var symbols = Set(tiles(panel).map(\.symbol))
      panel.controller.playback.wallpapersMuted = true
      symbols.formUnion(tiles(panel).map(\.symbol))
      XCTAssertGreaterThanOrEqual(symbols.count, 8)
      for symbol in symbols {
        XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(symbol) is not an SF Symbol")
      }
    }
  }

  /// The pressed tile and the row it stands for are one setting, so the search finds both and both
  /// are declared on their own page.
  func testEveryItemOfTheSixSectionsLivesInItsOwnSectionAndThePageRegistersCleanly() {
    let sections: [SettingsSection] = [.quick, .general, .appearance, .desktop, .playback, .performance]
    let own = SettingsRegistry.items.filter { sections.contains($0.section) }
    XCTAssertGreaterThan(own.count, 60)
    for item in own {
      XCTAssertTrue(item.id.hasPrefix(item.section.rawValue + "."), "\(item.id) is declared in \(item.section)")
    }
    XCTAssertEqual(SettingsRegistry.problems(in: SettingsRegistry.items), [])
    XCTAssertEqual(
      QuickSettingsSection.items.map(\.id).filter { $0.hasPrefix("quick.tile-") }.count, 8,
      "Eight tiles are declared; the search lists the same ones the page draws")
  }
}
