import AppKit
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

  func testDownloadingAllowsCancellation() {
    let downloading = controls(
      .downloading(currentVersion: "1.0.0", availableVersion: "1.1.0", percent: 40, transferred: 4, total: 10, bytesPerSecond: 1))
    XCTAssertFalse(downloading.primaryIsDisabled)
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

  /// Three versions above the running one: the newest is in its own Release notes card, the two
  /// before it fold behind Earlier versions, a search finds them, and the page fits the narrowest
  /// window in every shipped language with them open. Set `WALLPAPER_MACHINE_ABOUT_SNAPSHOTS` to a
  /// folder for PNGs to look at; a review only, never an assertion.
  func testReleaseNotesHaveTheirOwnCardWithEarlierVersionsFoldedAndFitEveryLanguage() async throws {
    let client = PanelUpdateClient()
    client.release = GitHubRelease(
      version: SemanticVersion("1.3.0")!,
      htmlURL: URL(string: "https://github.com/o/r/releases/tag/v1.3.0")!, prerelease: false,
      assets: PanelUpdateClient.release(version: "1.3.0").assets,
      changelog: ["1.3.0", "1.2.0", "1.1.0"].map(Self.changelogEntry).joined(separator: "\n"))
    let updater = AppUpdateStore(
      currentVersion: "1.0.0", client: client, installer: PanelUpdateInstaller(),
      defaults: try TemporaryDefaults.make(for: self).defaults)
    try await withPanel { panel in
      let controller = panel.buildSettingsController(updater: updater)
      try await controller.checkForUpdates()
      XCTAssertEqual(updater.notesReleases.map(\.version.display), ["1.3.0", "1.2.0", "1.1.0"])
      XCTAssertEqual(controller.updatePresentation(locale: english).mark, .update)

      let settings = controller.settings
      XCTAssertFalse(settings.isOpen(AboutSettingsSection.earlierReleases), "earlier versions start folded")
      settings.query = "Earlier versions"
      XCTAssertTrue(settings.search.shows(AboutSettingsSection.earlierReleases))
      XCTAssertFalse(settings.search.shows(AboutSettingsSection.updateAutomatic))
      settings.query = ""

      let host = SettingsBHost(panel: panel, controller: controller)
      let size = NSSize(width: 760, height: 560)
      let folder = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_ABOUT_SNAPSHOTS"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      }
      for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "pt-BR"] {
        for open in [false, true] {
          settings.setOpen(open, for: AboutSettingsSection.earlierReleases)
          host.use(language: language, dark: false, panel: panel)
          try await host.show(.about, size: size)
          try await host.settle(size)
          XCTAssertTrue(host.fits(size), "About \(language) \(open ? "open" : "folded") fits 760 x 560")
          if let folder {
            try await host.scroll(to: open ? 420 : 170)
            try host.snapshot(to: folder.appendingPathComponent("about-\(language)-\(open ? "open" : "folded").png"))
          }
        }
      }
      if let folder {
        host.use(language: "zh-Hans", dark: true, panel: panel)
        try await host.show(.about, size: NSSize(width: 1240, height: 800))
        try await host.scroll(to: 300)
        try host.snapshot(to: folder.appendingPathComponent("about-zh-Hans-dark-wide.png"))
      }
      host.close()
    }
  }

  func testReleaseDaysAreWrittenInThePanelsLanguage() {
    XCTAssertEqual(ReleaseNotesEntryView.day("2026-11-09", locale: english), "Nov 9, 2026")
    XCTAssertEqual(ReleaseNotesEntryView.day("2026-11-09", locale: Locale(identifier: "zh-Hans")), "2026年11月9日")
    XCTAssertEqual(ReleaseNotesEntryView.day("soon", locale: english), "soon", "not a day: as written")
    XCTAssertNil(ReleaseNotesEntryView.day(nil, locale: english))
  }

  private static func changelogEntry(_ version: String) -> String {
    let previous = "1.\(max(0, (Int(version.split(separator: ".")[1]) ?? 1) - 1)).0"
    let link = "([abc1234](https://github.com/o/r/commit/abc1234def))"
    return """
      ## [\(version)](https://github.com/o/r/compare/v\(previous)...v\(version)) (2026-11-09)
      ### English
      This release makes switching between desktops feel quicker
      #### Improvements
      - Switching to another desktop shows its wallpaper sooner \(link)
      #### Bug Fixes
      - Mission Control no longer leaves trails of foreground windows across the desktop, and wallpapers keep playing during the transition \(link)
      ### 简体中文
      本次更新让切换桌面更加迅速
      #### 改进
      - 切换桌面时壁纸会更快出现 \(link)
      #### 问题修复
      - 打开调度中心时，前台窗口不再在桌面上留下残影，壁纸在过渡期间也会继续播放 \(link)
      ### 한국어
      이번 업데이트로 데스크탑 전환이 더 빨라졌습니다
      #### 개선 사항
      - 다른 데스크탑으로 전환하면 배경화면이 더 빨리 표시됩니다 \(link)

      """
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
