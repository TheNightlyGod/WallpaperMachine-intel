import XCTest

@testable import WallpaperMachine

/// How every Settings control edits: it shows what it just sent until the change has run, then what
/// the stores report; one change of a setting at a time; the controls wait while the Mac is busy; a
/// refusal puts the old value back and reaches the error banner. The port of the web page's drafts,
/// pending actions and busy gating (`settings-a.editing-model`).
@MainActor
final class SettingsEditingModelTests: PanelTestCase {
  /// Holds the command queue until `release` runs, as a wallpaper switch in progress does.
  private func holdTheQueue(_ panel: PanelFixture) async throws -> (release: () -> Void, held: Task<Bool, Error>) {
    var continuation: CheckedContinuation<Void, Never>?
    let held = Task { try await panel.store.commands.run { await withCheckedContinuation { continuation = $0 } } }
    try await panel.waitUntil { continuation != nil }
    return ({ continuation?.resume() }, held)
  }

  // MARK: Drafts

  func testASwitchShowsWhatItSentUntilTheChangeHasRunThenWhatTheStoresSay() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      XCTAssertFalse(settings.isOn(.wallpapersMuted))

      let task = try XCTUnwrap(settings.set(.wallpapersMuted, to: true))
      XCTAssertTrue(settings.isOn(.wallpapersMuted), "The press is shown at once")
      XCTAssertFalse(controller.isSwitchOn(.wallpapersMuted), "while the stores have not taken it yet")
      XCTAssertFalse(controller.playback.wallpapersMuted)

      await task.value
      XCTAssertTrue(controller.playback.wallpapersMuted, "The change ran")
      XCTAssertTrue(settings.drafts.isEmpty, "and the draft is gone")
      XCTAssertTrue(settings.isOn(.wallpapersMuted), "The control now shows the stores' value")
    }
  }

  func testARefusedChangePutsTheOldValueBackAndReachesTheBanner() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      XCTAssertEqual(controller.playbackSettings.lowBatteryThreshold, 20)

      // 15 lies inside the range but is not a level the menu offers.
      let task = try XCTUnwrap(
        settings.commit("lowBatteryThreshold", to: 15) { try await controller.setLowBatteryThreshold($0) })
      XCTAssertEqual(settings.value("lowBatteryThreshold", saved: 20), 15, "Shown while it is on its way")
      await task.value
      XCTAssertEqual(settings.value("lowBatteryThreshold", saved: 20), 20, "Snaps back")
      XCTAssertEqual(controller.playbackSettings.lowBatteryThreshold, 20)
      XCTAssertNotNil(controller.errors.message, "The refusal is the error banner's to show")
    }
  }

  func testAChangeOfTheSameSettingWhileItsOwnIsRunningIsDroppedAndOtherSettingsAreNot() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      let (release, held) = try await holdTheQueue(panel)

      let first = try XCTUnwrap(settings.set(.wallpapersMuted, to: true))
      XCTAssertNil(settings.set(.wallpapersMuted, to: false), "One change of a setting at a time")
      XCTAssertTrue(settings.isOn(.wallpapersMuted), "The dropped press leaves the first one's value")
      let other = settings.set(.hideAfterActivating, to: true)
      XCTAssertNotNil(other, "Another setting is not held up by it")

      release()
      _ = try await held.value
      await first.value
      await other?.value
      XCTAssertTrue(controller.playback.wallpapersMuted)
      XCTAssertTrue(controller.hidesAfterActivating)
      XCTAssertTrue(settings.drafts.isEmpty)
    }
  }

  /// A slider or a field sends everything it settles on, in order, and the newest lands last. An older
  /// change finishing must not take the newer one's draft away.
  func testALatestWinsChangeKeepsItsDraftWhenAnOlderOneFinishesFirst() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      let (release, held) = try await holdTheQueue(panel)

      var applied: [Int] = []
      let perform: @MainActor (Int) async throws -> Void = { value in
        try await controller.setFrameRateCap(value)
        applied.append(value)
      }
      let first = try XCTUnwrap(settings.commit("frameRateCap", to: 30, policy: .latestWins, perform: perform))
      let second = try XCTUnwrap(settings.commit("frameRateCap", to: 45, policy: .latestWins, perform: perform))
      XCTAssertEqual(settings.value("frameRateCap", saved: 60), 45)

      release()
      _ = try await held.value
      await first.value
      XCTAssertEqual(settings.value("frameRateCap", saved: 60), 45, "The older change finishing leaves the newer value showing")
      await second.value
      XCTAssertEqual(applied, [30, 45], "Both ran, in the order they were made")
      XCTAssertTrue(settings.drafts.isEmpty)
    }
  }

  // MARK: Gating

  func testControlsWaitWhileTheMacIsBusyButTheOneWhoseChangeIsRunningDoesNot() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      XCTAssertFalse(settings.isLocked("wallpapersMuted"))
      XCTAssertFalse(settings.isDisabled(.wallpapersMuted))

      let (release, held) = try await holdTheQueue(panel)
      XCTAssertTrue(controller.isStoreBusy)
      XCTAssertTrue(settings.isLocked("wallpapersMuted"), "A running command holds every control")
      XCTAssertTrue(settings.isDisabled(.hideAfterActivating))

      let change = try XCTUnwrap(settings.set(.wallpapersMuted, to: true))
      XCTAssertFalse(
        settings.isLocked("wallpapersMuted"),
        "The control whose own change is running stays enabled, so its focus is not taken away")
      XCTAssertTrue(
        settings.isLocked("wallpapersMuted", whileRunning: true),
        "A button that must not be pressed twice waits for its own change too")
      XCTAssertTrue(settings.isLocked("hideAfterActivating"), "Every other control still waits")

      release()
      _ = try await held.value
      await change.value
      XCTAssertFalse(settings.isLocked("wallpapersMuted", whileRunning: true))
      XCTAssertFalse(controller.isStoreBusy)
    }
  }

  /// A control reads `isLocked` in its body; it has to be asked again the moment a command starts or
  /// ends, or it would stay enabled behind a wallpaper switch.
  func testAControlThatReadsTheLockIsToldWhenTheMacBecomesBusyAndWhenItIsFree() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let settings = panel.controller.settings
      let busy = SettingsObservedFlag()
      withObservationTracking { _ = settings.isLocked("renderScale") } onChange: { busy.set() }
      XCTAssertFalse(busy.value)
      let (release, held) = try await holdTheQueue(panel)
      XCTAssertTrue(busy.value, "Becoming busy reaches the control")

      let free = SettingsObservedFlag()
      withObservationTracking { _ = settings.isLocked("renderScale") } onChange: { free.set() }
      release()
      _ = try await held.value
      try await panel.waitUntil { free.value }
      XCTAssertFalse(settings.isLocked("renderScale"))
    }
  }

  func testWithoutASettingsSnapshotTheRendererControlsWaitButAppearanceAndLanguageDoNot() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let settings = controller.settings
      XCTAssertEqual(panel.store.snapshotRevision, 0)
      XCTAssertTrue(settings.isUnavailable)
      XCTAssertTrue(settings.isLocked("renderScale"))
      XCTAssertTrue(settings.isDisabled(.wallpapersMuted))

      // Appearance is the app's own and never asks the renderer.
      settings.applyTheme { try controller.setThemeMode(.dark) }
      XCTAssertEqual(controller.themePreferences.mode, .dark)
      settings.applyTheme { try controller.setThemeAccent("#b43271") }
      XCTAssertEqual(controller.themePreferences.accent, "#b43271")
      XCTAssertNil(controller.errors.message)

      // So is the language, which runs on a busy Mac too.
      let (release, held) = try await holdTheQueue(panel)
      let language = try XCTUnwrap(
        settings.commit("language", to: "ja") { tag in try await controller.setLanguage(AppLanguage.named(tag)) })
      await language.value
      XCTAssertEqual(controller.effectiveLanguage.tag, "ja", "The language did not wait behind the command")
      release()
      _ = try await held.value

      panel.store.snapshotRevision = 1
      XCTAssertFalse(settings.isUnavailable)
      XCTAssertFalse(settings.isLocked("renderScale"))
    }
  }

  func testAThemeValueTheStoreRefusesGoesToTheBannerAndChangesNothing() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let before = controller.themePreferences
      controller.settings.applyTheme { try controller.setThemeAccent("not a colour") }
      XCTAssertEqual(controller.themePreferences, before)
      XCTAssertNotNil(controller.errors.message)
    }
  }

  // MARK: The button actions

  func testAButtonActionIsTrackedUnderItsNameAndLocksItselfWhileItRuns() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      var release: CheckedContinuation<Void, Never>?
      var runs = 0
      let retry = settings.perform("sceneRetry:7") {
        runs += 1
        await withCheckedContinuation { release = $0 }
      }
      try await panel.waitUntil { release != nil }
      XCTAssertTrue(settings.isLocked("sceneRetry:7", whileRunning: true), "Retry is disabled while its reload runs")
      XCTAssertFalse(settings.isLocked("sceneRetry:8", whileRunning: true), "Another display's Retry is not")
      settings.perform("sceneRetry:7") { runs += 1 }
      XCTAssertEqual(runs, 1, "A second press while it runs is dropped")

      release?.resume()
      await retry.value
      XCTAssertFalse(settings.isLocked("sceneRetry:7", whileRunning: true))
    }
  }

  // MARK: Switches shared by a tile and a row

  func testATileAndTheRowOfTheSameSettingShareOneDraftAndOneSavedValue() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      // The same key is the same setting: the draft a tile makes is the one the row shows.
      let task = try XCTUnwrap(settings.set(.hideAfterActivating, to: true))
      let tile = QuickTile.tiles(for: controller) { settings.isOn($0) }
        .first { $0.key == .hideAfterActivating }
      XCTAssertEqual(tile?.isOn, true, "The tile follows the press at once")
      XCTAssertEqual(settings.isOn(.hideAfterActivating), true, "and so does the row, which reads the same key")
      await task.value
      XCTAssertTrue(controller.hidesAfterActivating)
      XCTAssertTrue(controller.generalSettings.hidesAfterActivating)

      // And the other way round: a change from elsewhere (the menu bar mutes) moves both.
      controller.playback.wallpapersMuted = true
      XCTAssertTrue(settings.isOn(.wallpapersMuted))
      XCTAssertEqual(
        QuickTile.tiles(for: controller) { settings.isOn($0) }.first { $0.key == .wallpapersMuted }?.isOn, true)

      for key in SettingsSwitchKey.allCases {
        _ = controller.isSwitchOn(key)
        _ = controller.isSwitchEnabled(key)
      }
    }
  }

  func testTheMuteRowLeadsPlaybackAndFollowsThePreferenceWhoeverChangesIt() async throws {
    try await withRecordingPanel { panel, _ in
      XCTAssertEqual(PlaybackSettingsSection.items.first?.id, "playback.mute-all", "Mute leads the Playback group")
      let controller = panel.controller
      XCTAssertFalse(controller.isSwitchOn(.wallpapersMuted))
      controller.playback.wallpapersMuted = true
      XCTAssertTrue(controller.isSwitchOn(.wallpapersMuted), "A change from the menu bar or a link shows")
      panel.store.snapshotRevision = 1
      await controller.settings.set(.wallpapersMuted, to: false)?.value
      XCTAssertFalse(controller.playback.wallpapersMuted, "Pressing the row changes the preference")
    }
  }

  func testTheDesktopPictureRefreshWaitsForThePictureToBeWritten() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      XCTAssertTrue(controller.isSwitchEnabled(.writeDesktopPicture))
      XCTAssertTrue(controller.isSwitchEnabled(.refreshDesktopPicture))
      await settings.set(.writeDesktopPicture, to: false)?.value
      XCTAssertFalse(controller.desktopSettings.writesDesktopPicture)
      XCTAssertFalse(controller.isSwitchEnabled(.refreshDesktopPicture), "A retake of a picture that is not written does nothing")
      XCTAssertTrue(settings.isDisabled(.refreshDesktopPicture))
      XCTAssertFalse(settings.isDisabled(.writeDesktopPicture))
    }
  }

  func testALockScreenTheMacCannotOfferCannotBeSwitched() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      XCTAssertNil(panel.store.lockScreenWallpaper)
      XCTAssertFalse(controller.lockScreenState.isAvailable)
      XCTAssertFalse(controller.isSwitchEnabled(.lockScreenEnabled))
      XCTAssertFalse(controller.isSwitchEnabled(.screenSaverEnabled))
      XCTAssertTrue(controller.settings.isDisabled(.lockScreenEnabled))
      XCTAssertFalse(controller.isSwitchOn(.lockScreenEnabled))
    }
  }

  func testALoginItemOutsideApplicationsCannotBeSwitched() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      XCTAssertFalse(controller.generalSettings.launchAtLogin.isAvailable)
      XCTAssertTrue(controller.settings.isDisabled(.launchAtLogin))
      var settings = panel.store.settingsSnapshot
      settings.launchAtLoginAvailable = true
      panel.store.settingsSnapshot = settings
      XCTAssertFalse(controller.settings.isDisabled(.launchAtLogin))
    }
  }

  // MARK: What a snapshot does not touch

  func testANewSnapshotNeverClosesAnOpenDisclosureOrMovesThePage() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let settings = panel.controller.settings
      settings.select(.performance)
      settings.setOpen(true, for: PerformanceSettingsSection.advanced)
      settings.setOpen(true, for: PlaybackSettingsSection.appRules)
      let epoch = settings.scrollEpoch

      var snapshot = panel.store.settingsSnapshot
      snapshot.frameRateCap = 24
      snapshot.renderScale = 0.5
      panel.store.settingsSnapshot = snapshot
      panel.store.snapshotRevision &+= 1

      XCTAssertTrue(settings.isOpen(PerformanceSettingsSection.advanced), "An open disclosure stays open")
      XCTAssertTrue(settings.isOpen(PlaybackSettingsSection.appRules))
      XCTAssertEqual(settings.scrollEpoch, epoch, "and the page is not sent back to its top")
      XCTAssertEqual(settings.selectedSection, .performance)
    }
  }
}
