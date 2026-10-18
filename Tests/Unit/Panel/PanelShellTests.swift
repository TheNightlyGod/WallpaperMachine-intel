import XCTest

@testable import WallpaperMachine

/// The shell's small rules for Settings and the guide: which section is on show, what stays open,
/// and when the guide is up. The title lives in `PanelTitleTests`, the rest of the shell in
/// `ShellModelTests`.
@MainActor
final class PanelShellTests: PanelTestCase {
  func testChoosingASectionEndsTheSearchAndScrollsBackToTheTopEvenForTheSameSection() async throws {
    try await withPanel { panel in
      let settings = panel.controller.settings
      XCTAssertEqual(settings.selectedSection, .quick, "A window starts on Quick Settings")
      settings.query = "battery"
      let epoch = settings.scrollEpoch
      settings.select(.quick)
      XCTAssertEqual(settings.query, "")
      XCTAssertEqual(settings.selectedSection, .quick)
      XCTAssertGreaterThan(settings.scrollEpoch, epoch)
    }
  }

  func testAnAppRevealOpensItsSectionOnceAndAWindowOpenedLaterStartsOnQuickSettings() async throws {
    try await withPanel { panel in
      let navigation = panel.navigation
      navigation.revealSettingsSection(.about)
      panel.controller.settings.adoptReveal()
      XCTAssertEqual(panel.controller.settings.selectedSection, .about)

      panel.controller.settings.select(.general)
      panel.controller.settings.adoptReveal()
      XCTAssertEqual(
        panel.controller.settings.selectedSection, .general, "The same reveal is not repeated")

      let reopened = panel.buildController()
      reopened.settings.adoptReveal()
      XCTAssertEqual(
        reopened.settings.selectedSection, .quick,
        "A reveal a window acted on is not repeated by the next")

      navigation.revealSettingsSection(.about)
      panel.controller.settings.adoptReveal()
      XCTAssertEqual(
        panel.controller.settings.selectedSection, .about,
        "Revealing the same section again still works")
    }
  }

  func testADisclosureStaysOpenWhereThePersonLeftItAndASearchOnlyOpensItForItsDuration()
    async throws
  {
    try await withPanel { panel in
      let settings = panel.controller.settings
      let help = SettingsItem(id: "test.help", section: .general, title: "Help")
      XCTAssertFalse(settings.isOpen(help))
      settings.setOpen(true, for: help)
      XCTAssertTrue(settings.isOpen(help))
      settings.setOpen(false, for: help)
      XCTAssertFalse(settings.isOpen(help))
    }
  }

  func testSettingsHasNoInspector() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      XCTAssertTrue(shell.hasInspector)
      panel.navigation.selection = .settings
      XCTAssertFalse(shell.hasInspector)
      XCTAssertEqual(shell.selection, .settings)
    }
  }

  func testTheGuideIsOpenUntilTheFirstRunFlagIsSetAndCanBeAskedForAgain() async throws {
    try await withPanel(welcomeSeen: false) { panel in
      let shell = panel.controller.shell
      XCTAssertTrue(shell.isWelcomeOpen)
      PanelPreferences.markWelcomeSeen(in: panel.defaults)
      panel.controller.welcomeSeen = true
      XCTAssertFalse(shell.isWelcomeOpen)
      shell.isWelcomeRequested = true
      XCTAssertTrue(shell.isWelcomeOpen, "Settings can show it again")
    }
  }
}
