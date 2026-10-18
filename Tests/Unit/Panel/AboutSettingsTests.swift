import XCTest

@testable import WallpaperMachine

/// Settings › About: which update buttons can be pressed, the page's rows and the release notes the
/// card shows.
@MainActor
final class AboutSettingsTests: SettingsBTestCase {
  private func controls(
    _ state: AppUpdateState, storeBusy: Bool = false, pending: Set<UpdatePresentation.Action> = [],
    openingReleases: Bool = false, revealing: Bool = false
  ) -> AboutUpdateControls {
    AboutUpdateControls.make(
      presentation: UpdatePresentation(state: state), isStoreBusy: storeBusy,
      isPending: { pending.contains($0) }, openingReleases: openingReleases, revealing: revealing)
  }

  func testAnIdleCardCanBePressedAndACheckInFlightDisablesEveryButton() {
    let idle = controls(.idle(currentVersion: "1.0.0"))
    XCTAssertFalse(idle.isBusy)
    XCTAssertFalse(idle.primaryIsDisabled)
    XCTAssertFalse(idle.releasesIsDisabled)
    let checking = controls(.checking(currentVersion: "1.0.0"))
    XCTAssertTrue(checking.isBusy)
    XCTAssertTrue(checking.primaryIsDisabled, "Check for Updates waits for the check")
    XCTAssertTrue(checking.releasesIsDisabled)
    let pressed = controls(.idle(currentVersion: "1.0.0"), pending: [.checkForUpdates])
    XCTAssertTrue(pressed.primaryIsDisabled, "a press is not repeated while it runs")
    XCTAssertTrue(controls(.idle(currentVersion: "1.0.0"), openingReleases: true).primaryIsDisabled)
    XCTAssertTrue(controls(.idle(currentVersion: "1.0.0"), revealing: true).revealIsDisabled)
  }

  func testDownloadingDisablesTheButtonThatSaysDownloadingPercent() {
    let downloading = controls(
      .downloading(currentVersion: "1.0.0", availableVersion: "1.1.0", percent: 40, transferred: 4, total: 10, bytesPerSecond: 1))
    XCTAssertTrue(downloading.primaryIsDisabled)
    XCTAssertTrue(downloading.isBusy)
  }

  func testCancelStaysPossibleWhilePreparingAndOnlyItsOwnPressDisablesIt() {
    let preparing = controls(.preparing(currentVersion: "1.0.0", availableVersion: "1.1.0"), storeBusy: true)
    XCTAssertTrue(preparing.isBusy)
    XCTAssertFalse(preparing.primaryIsDisabled, "Cancel works even while a wallpaper switches")
    XCTAssertTrue(
      controls(.preparing(currentVersion: "1.0.0", availableVersion: "1.1.0"), pending: [.cancelUpdate]).primaryIsDisabled)
  }

  func testInstallAndDownloadWaitForWallpaperCommandsToo() {
    let ready = controls(.ready(currentVersion: "1.0.0", availableVersion: "1.1.0"))
    XCTAssertFalse(ready.primaryIsDisabled)
    XCTAssertTrue(controls(.ready(currentVersion: "1.0.0", availableVersion: "1.1.0"), storeBusy: true).primaryIsDisabled)
    XCTAssertTrue(
      controls(.ready(currentVersion: "1.0.0", availableVersion: "1.1.0"), pending: [.installUpdate]).primaryIsDisabled)
    XCTAssertFalse(ready.revealIsDisabled)
  }

  /// With no published release the card reads Check Again and offers nothing to open, with its button
  /// pressable; a release found next brings its notes for the What's new disclosure. Download and
  /// install are `UpdatePresentationTests`' walk.
  func testWithNoReleaseTheCardOffersCheckAgainAndAFoundReleaseBringsItsNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("about-card-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let client = PanelUpdateClient()
    let installer = PanelUpdateInstaller()
    let scheduled = SettingsCallCounter()
    let updater = AppUpdateStore(
      currentVersion: "1.0.0", client: client, installer: installer,
      workspace: AppUpdateWorkspace(
        archiveURL: { _, _ in root.appendingPathComponent("update.dmg") }, reveal: { _ in }, open: { _ in }),
      scheduleInstall: { _ in scheduled.bump() }, terminate: {})
    let panel = try makeController()
    do {
      let controller = panel.buildSettingsController(updater: updater)
      try await controller.checkForUpdates()
      var card = controller.updatePresentation(locale: english)
      XCTAssertEqual(card.status, .noRelease)
      XCTAssertEqual(card.actionLabel, "Check Again")
      XCTAssertFalse(card.showsReleases)
      XCTAssertFalse(card.showsReveal)
      XCTAssertFalse(
        AboutUpdateControls.make(
          presentation: card, isStoreBusy: false, isPending: { _ in false }, openingReleases: false, revealing: false
        ).primaryIsDisabled)

      client.release = PanelUpdateClient.release(version: "1.1.0", notes: PanelUpdateClient.notesBody)
      try await controller.checkForUpdates()
      card = controller.updatePresentation(locale: english)
      XCTAssertEqual(card.action, .downloadUpdate)
      XCTAssertEqual(card.actionLabel, "Download Update")
      XCTAssertTrue(card.isActionProminent)
      XCTAssertEqual(card.notesVersion, "1.1.0")
      XCTAssertTrue(card.hasNotes)
      XCTAssertEqual(card.notes.first?.title, "Fixed")
      XCTAssertEqual(card.notes.first?.items.count, 1)
      XCTAssertEqual(scheduled.count, 0)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  func testTheVersionRowsReadTheBundleAndTheProductHasAnIconForEveryDockChoice() async throws {
    try await withPanel { panel in
      let info = panel.controller.aboutInfo
      XCTAssertEqual(
        info.version, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        "what a bug report is filed with")
      for icon in AppThemePreferences.Icon.allCases {
        XCTAssertNoThrow(try icon.image(), "\(icon)")
      }
    }
  }

  func testEveryRowOfThePagesIsASearchableItemWithItsOwnId() {
    let sections: [(String, [SettingsItem])] = [
      ("displays", DisplaysSettingsSection.items), ("shortcuts", ShortcutsSettingsSection.items),
      ("library", LibrarySettingsSection.items), ("storage", StorageSettingsSection.items),
      ("about", AboutSettingsSection.items),
    ]
    for (name, items) in sections {
      XCTAssertFalse(items.isEmpty, name)
      XCTAssertTrue(items.allSatisfy { $0.id.hasPrefix("\(name).") }, name)
    }
    XCTAssertEqual(SettingsRegistry.problems(in: SettingsRegistry.items), [], "no duplicate id, no lost disclosure")
  }

  func testASearchFindsTheChoicesOfARowAndTheLabelsOfItsButtons() {
    let search = { (query: String) -> SettingsSearch in
      SettingsSearch(query: query, index: SettingsIndex(locale: PanelLocale.shared))
    }
    XCTAssertTrue(search("Shuffle").shows(DisplaysSettingsSection.playlistOrder), "an option label finds its row")
    XCTAssertTrue(search("Shuffle").opens(DisplaysSettingsSection.playlist), "and opens the disclosure around it")
    XCTAssertTrue(search("Eject").shows(DisplaysSettingsSection.wallpaper))
    XCTAssertTrue(search("Locate").shows(LibrarySettingsSection.steamActions))
    XCTAssertTrue(search("Diagnostics").shows(StorageSettingsSection.diagnostics))
    XCTAssertTrue(search("Check Again").shows(AboutSettingsSection.updateActions))
    XCTAssertTrue(search("Record").shows(ShortcutsSettingsSection.togglePlayback))
    XCTAssertTrue(
      search("Keyboard shortcuts").shows(ShortcutsSettingsSection.nextWallpaper),
      "the page's name, which its card no longer repeats as a title, still finds every shortcut")
    XCTAssertFalse(search("Shuffle").shows(DisplaysSettingsSection.playlistInterval))
  }
}
