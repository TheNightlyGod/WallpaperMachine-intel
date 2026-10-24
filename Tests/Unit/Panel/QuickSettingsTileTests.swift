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
          .writeDesktopPicture, .desktopWallpapers, .hideAfterActivating, .livePropertyEdits,
        ], "One display has no other to pause")

      panel.configureDisplays()
      XCTAssertEqual(
        tiles(panel).map(\.key),
        [
          .launchAtLogin, .wallpapersMuted, .lockScreenEnabled, .screenSaverEnabled,
          .writeDesktopPicture, .desktopWallpapers, .playOnlyOnActiveDisplay, .hideAfterActivating,
          .livePropertyEdits,
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

  // MARK: Wallpaper per Desktop

  /// One display, `primary`, whose renderer title names display 1, with two desktops.
  private func desktopsPanel(available: Bool = true) throws -> (PanelFixture, WallpaperSpaceMonitor) {
    let topology: [String: WallpaperDisplaySpaces]? = available ? [
      "1": .init(
        displayUUID: "screen", spaces: [.init(id: "space-a", number: 1), .init(id: "space-b", number: 2)],
        current: "space-a")
    ] : nil
    let spaces = WallpaperSpaceMonitor(provider: { topology })
    spaces.refresh()
    let panel = try makeController(spaces: spaces)
    panel.store.settingsSnapshot.displays = [OrganizationFixtures.display("primary", title: "Main (1 - Primary)")]
    panel.store.librarySnapshot.wallpapers = [OrganizationFixtures.wallpaper("a")]
    panel.store.monitorInformationSnapshot.rows = [OrganizationFixtures.monitor("primary", wallpaper: "a")]
    return (panel, spaces)
  }

  func testTheWallpaperPerDesktopTileSwitchesTheTargetDisplayLikeItsCard() async throws {
    let (panel, spaces) = try desktopsPanel()
    defer { spaces.stop(); Task { await panel.shutdown() } }
    let controller = panel.controller
    var desktops = try tile(.desktopWallpapers, in: tiles(panel))
    XCTAssertFalse(desktops.isOn, "Off by default")
    XCTAssertTrue(desktops.isEnabled)
    XCTAssertNil(desktops.note, "One display needs no name")

    await controller.settings.set(.desktopWallpapers, to: true)?.value
    XCTAssertEqual(panel.automations.configuration(for: "primary").mode, .spaces)
    XCTAssertEqual(controller.automationState(for: "primary").mode, .spaces, "the display's card reads the same")
    desktops = try tile(.desktopWallpapers, in: tiles(panel))
    XCTAssertTrue(desktops.isOn)

    // Turned off on the card, the tile follows.
    try await controller.setDesktopWallpapers(false, display: "primary")
    XCTAssertFalse(try tile(.desktopWallpapers, in: tiles(panel)).isOn)
  }

  func testTheWallpaperPerDesktopTileNamesTheDisplayBesideAnotherAndWaitsForDesktops() async throws {
    try pinPanelLanguageToEnglish()
    let (panel, spaces) = try desktopsPanel()
    defer { spaces.stop(); Task { await panel.shutdown() } }
    panel.store.settingsSnapshot.displays.append(OrganizationFixtures.display("secondary", title: "Side (2)"))
    XCTAssertEqual(try tile(.desktopWallpapers, in: tiles(panel)).note, "Off · Main",
                   "With two displays the tile says which one it switches")

    let (unavailable, noSpaces) = try desktopsPanel(available: false)
    defer { noSpaces.stop(); Task { await unavailable.shutdown() } }
    let desktops = try tile(.desktopWallpapers, in: tiles(unavailable))
    XCTAssertFalse(desktops.isEnabled, "Without desktop information there is nothing to switch on")
    XCTAssertEqual(desktops.note, "Unavailable")
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
      QuickSettingsSection.items.map(\.id).filter { $0.hasPrefix("quick.tile-") }.count, 9,
      "Nine tiles are declared; the search lists the same ones the page draws")
  }
}
