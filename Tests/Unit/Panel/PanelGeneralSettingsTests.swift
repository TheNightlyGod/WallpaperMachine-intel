import XCTest

@testable import WallpaperMachine

/// The General, Desktop and lock-screen settings the panel keeps itself or hands to a service, and
/// the derived state their rows read. Replaces `WebPanelGeneralSettingsTests`.
@MainActor
final class PanelGeneralSettingsTests: PanelTestCase {
  func testHidingAfterApplyingIsOffUntilTurnedOnAndPersists() async throws {
    try await withRecordingPanel { panel, _ in
      XCTAssertFalse(panel.controller.hidesAfterActivating, "The panel stays open after applying unless the user opts in")
      XCTAssertFalse(panel.controller.generalSettings.hidesAfterActivating)

      try await panel.controller.setHidesAfterActivating(true)
      XCTAssertTrue(panel.controller.hidesAfterActivating)
      XCTAssertTrue(panel.controller.generalSettings.hidesAfterActivating)

      let reopened = panel.buildController()
      XCTAssertTrue(reopened.hidesAfterActivating, "The choice must survive a relaunch")
      reopened.stop()
    }
  }

  func testInspectingWebWallpapersIsStoredReportedAndSurvivesARelaunch() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      // Both directions are written: a debug build starts on, a release build off.
      try await controller.setInspectsWebWallpapers(true)
      XCTAssertTrue(WebWallpaperInspection.isEnabled(defaults: panel.defaults))
      XCTAssertTrue(controller.storageState.inspectsWebWallpapers)

      try await controller.setInspectsWebWallpapers(false)
      XCTAssertFalse(WebWallpaperInspection.isEnabled(defaults: panel.defaults))
      XCTAssertFalse(controller.storageState.inspectsWebWallpapers)

      let reopened = panel.buildController()
      XCTAssertFalse(reopened.storageState.inspectsWebWallpapers, "Turning inspection off must stick after a relaunch")
      try await reopened.setInspectsWebWallpapers(true)
      XCTAssertTrue(panel.buildController().storageState.inspectsWebWallpapers)
      reopened.stop()
    }
  }

  /// Showing pending property edits on the desktop starts off, and turning it off puts the saved
  /// look back on what the displays were shown.
  func testLivePropertyEditsDefaultsOffAndRoundTrips() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertFalse(controller.desktopSettings.livePropertyEdits, "The desktop keeps showing the saved look until the user opts in")

      try await controller.setLivePropertyEdits(true)
      XCTAssertTrue(LivePropertyEditing.isEnabled(defaults: panel.defaults))
      XCTAssertTrue(controller.desktopSettings.livePropertyEdits)

      let reopened = panel.buildController()
      XCTAssertTrue(reopened.desktopSettings.livePropertyEdits, "The choice must survive a relaunch")

      try await reopened.setLivePropertyEdits(false)
      XCTAssertFalse(LivePropertyEditing.isEnabled(defaults: panel.defaults))
      XCTAssertFalse(controller.desktopSettings.livePropertyEdits)
      reopened.stop()
    }
  }

  /// The lock screen as the app finds it after a launch: asked for, or left off. It only starts and
  /// recovers; no publication, activation or monitor runs.
  private func lockScreen(requested: Bool) throws -> LockScreenWallpaperService {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    defaults.set(requested, forKey: "WallpaperMachineAnimateLockScreen")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-lock-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let service = LockScreenWallpaperService(
      prepareExtension: {}, notifyConfigurationChanged: {}, scenes: { [] },
      selection: LockScreenWallpaperSelection(
        storeURL: root.appendingPathComponent("Index.plist"),
        journalURL: root.appendingPathComponent("journal.plist"), reload: {}),
      exchange: root, defaults: defaults,
      // Never registered with a run loop, so the monitor cannot fire during the test.
      scheduleMonitor: { _ in Timer(timeInterval: 2, repeats: true) { _ in } })
    try service.start()
    return service
  }

  func testDesktopPictureSwitchPersistsAndIsRefusedWhileTheLockScreenIsRequested() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertTrue(controller.desktopSettings.writesDesktopPicture, "On until the user turns it off")
      XCTAssertFalse(controller.desktopSettings.desktopPictureLocked)

      try await controller.setWritesDesktopPicture(false)
      XCTAssertFalse(controller.playback.writesDesktopPicture)
      XCTAssertFalse(controller.desktopSettings.writesDesktopPicture)
      XCTAssertFalse(
        PlaybackPreferences(defaults: panel.defaults).writesDesktopPicture,
        "The choice must survive a relaunch")

      // Animate lock screen sets the picture itself: the choice waits until it is off again.
      panel.store.lockScreenWallpaper = try lockScreen(requested: true)
      XCTAssertTrue(controller.desktopSettings.desktopPictureLocked)
      do {
        try await controller.setWritesDesktopPicture(true)
        XCTFail("The picture belongs to the lock screen while it is requested")
      } catch let error as WallpaperActionError {
        XCTAssertEqual(
          error.localizedDescription,
          "Turn off Animate lock screen before changing this: it sets the desktop picture itself.")
      }
      XCTAssertFalse(controller.playback.writesDesktopPicture, "A refused change must not be stored")
      XCTAssertFalse(controller.desktopSettings.writesDesktopPicture)

      panel.store.lockScreenWallpaper = try lockScreen(requested: false)
      XCTAssertFalse(controller.desktopSettings.desktopPictureLocked, "Off, the lock screen owns nothing")
      try await controller.setWritesDesktopPicture(true)
      XCTAssertTrue(controller.playback.writesDesktopPicture)
    }
  }

  /// What the user reads and can press: the switch is on by default, turning it off disables the
  /// timed Mission Control refresh that depends on it, and the lock screen locks it with a reason.
  func testDesktopPictureRowFollowsThePreferenceAndTheLockScreen() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let initial = controller.desktopSettings
      XCTAssertTrue(initial.writesDesktopPicture)
      XCTAssertTrue(initial.canChangeWritesDesktopPicture)
      XCTAssertTrue(initial.canChangeRefresh)
      XCTAssertNil(initial.lockedNote)

      controller.playback.writesDesktopPicture = false
      let off = controller.desktopSettings
      XCTAssertTrue(off.canChangeWritesDesktopPicture, "It can be turned back on")
      XCTAssertFalse(off.canChangeRefresh, "A timed retake of a picture that is not written does nothing")

      panel.store.lockScreenWallpaper = try lockScreen(requested: true)
      let locked = controller.desktopSettings
      XCTAssertFalse(locked.canChangeWritesDesktopPicture)
      XCTAssertFalse(locked.writesDesktopPicture, "The lock does not change the choice")
      XCTAssertEqual(locked.lockedNote?.isEmpty, false, "The row says why it cannot be changed")
    }
  }

  /// A launch at login the user switched off in System Settings stays off however often the app
  /// registers it. The row must say what the user has to do and offer the way there, and the action
  /// must open Login Items and nothing else.
  func testLaunchAtLoginNeedsApprovalAndTheActionOpensLoginItemsOnly() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      var openedLoginItems = 0
      controller.openLoginItemsSettings = { openedLoginItems += 1 }
      panel.store.settingsSnapshot.launchAtLoginAvailable = true
      panel.store.settingsSnapshot.launchAtLoginEnabled = false
      panel.store.settingsSnapshot.launchAtLoginNeedsApproval = true

      let waiting = controller.generalSettings.launchAtLogin
      XCTAssertTrue(waiting.needsApproval)
      XCTAssertFalse(waiting.isOn, "Waiting for approval is not being enabled")
      XCTAssertTrue(waiting.isAvailable, "The app is installed where it can register, so the switch stays usable")
      XCTAssertTrue(waiting.showsLoginItemsButton)
      XCTAssertEqual(waiting.note?.isEmpty, false, "The row must say what to do")

      try await controller.showLoginItemsSettings()
      XCTAssertEqual(openedLoginItems, 1, "One press opens Login Items once")

      // The user allows it in System Settings and comes back; the bridge then reports it enabled.
      panel.store.settingsSnapshot.launchAtLoginEnabled = true
      panel.store.settingsSnapshot.launchAtLoginNeedsApproval = false
      let allowed = controller.generalSettings.launchAtLogin
      XCTAssertTrue(allowed.isOn)
      XCTAssertFalse(allowed.showsLoginItemsButton)
      XCTAssertNil(allowed.note, "Nothing is left to explain once it is enabled")
      XCTAssertEqual(openedLoginItems, 1)
    }
  }

  /// "Keep windows in place" is the inverse of macOS's own "Click wallpaper to reveal desktop". The
  /// write goes to the user's real macOS preference, so it is not exercised here; the read is.
  func testKeepingWindowsInPlaceReadsTheInverseOfMacOSsRevealPreference() async throws {
    try await withRecordingPanel { panel, _ in
      XCTAssertEqual(
        panel.controller.desktopSettings.keepsWindowsOnWallpaperClick,
        !DesktopClickRevealPreference.isEnabled)
    }
  }

  func testALoginItemOutsideApplicationsIsUnavailableWithAReason() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.settingsSnapshot.launchAtLoginAvailable = false
      let state = panel.controller.generalSettings.launchAtLogin
      XCTAssertFalse(state.isAvailable)
      XCTAssertFalse(state.showsLoginItemsButton, "Approval is something to ask for only where the item can register")
      XCTAssertEqual(state.note?.isEmpty, false)
    }
  }

  // MARK: Lock screen and screen saver

  func testWithoutTheServiceTheLockScreenAndScreenSaverAreUnavailableAndRefuseToChange() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertNil(panel.store.lockScreenWallpaper)
      for state in [controller.lockScreenState, controller.screenSaverState] {
        XCTAssertFalse(state.isAvailable)
        XCTAssertFalse(state.isSwitchEnabled)
        XCTAssertFalse(state.isRequested)
        XCTAssertFalse(state.canRetry)
        XCTAssertFalse(state.statusText.isEmpty, "The status says why: unsupported system or unavailable")
      }
      do {
        try await controller.setLockScreenEnabled(true)
        XCTFail("Without the service there is nothing to enable")
      } catch let error as WallpaperActionError {
        XCTAssertEqual(error.localizedDescription, "Lock Screen integration is unavailable.")
      }
      do {
        try await controller.setScreenSaverEnabled(true)
        XCTFail("Without the service there is nothing to enable")
      } catch let error as WallpaperActionError {
        XCTAssertEqual(error.localizedDescription, "Screen saver integration is unavailable.")
      }
      // A retry with no service is a silent no-op.
      try await controller.retryLockScreen()
      try await controller.retryScreenSaver()
    }
  }

  /// The animated lock screen shows one wallpaper per display, so it is refused while a display's
  /// automatic wallpaper follows the desktop Space.
  func testTheLockScreenIsRefusedWhileADisplayFollowsDesktopSpaces() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      panel.store.lockScreenWallpaper = try lockScreen(requested: false)
      try panel.automations.update("primary") {
        $0.mode = .spaces
        $0.spaces["desktop-uuid"] = .init(kind: .wallpaper, id: "ocean")
      }
      do {
        try await controller.setLockScreenEnabled(true)
        XCTFail("Space-based wallpaper choices cannot be combined with the lock screen")
      } catch let error as WallpaperActionError {
        XCTAssertEqual(
          error.localizedDescription,
          "Choose another automatic wallpaper mode for your displays before enabling animated lock-screen wallpaper."
        )
      }
      XCTAssertFalse(panel.store.lockScreenWallpaper?.isRequested ?? true)
    }
  }

  func testLockScreenStatusWordsFollowTheServiceAndItsBusyFlag() throws {
    try pinPanelLanguageToEnglish()
    func state(
      _ kind: LockScreenState.Kind, available: Bool = true, busy: Bool = false,
      status: String, error: String? = nil
    ) -> LockScreenState {
      LockScreenState(
        kind: kind, isRequested: false, isAvailable: available, isBusy: busy, status: status,
        error: error)
    }
    XCTAssertEqual(state(.lockScreen, status: "Enabled for 1 display").statusText, "Enabled for 1 display")
    XCTAssertEqual(
      state(.lockScreen, available: false, status: "Requires macOS 26 or later").statusText,
      "Requires macOS 26 or later", "An unavailable service says why")
    XCTAssertEqual(state(.lockScreen, busy: true, status: "Preparing").statusText, "Preparing…")
    XCTAssertEqual(
      state(.lockScreen, busy: true, status: "Preparing committed wallpapers...").statusText,
      "Preparing committed wallpapers...", "A status that already ends in an ellipsis gets no second one")
    XCTAssertEqual(state(.lockScreen, busy: true, status: "").statusText, "Updating…")
    XCTAssertEqual(
      state(.screenSaver, busy: true, status: "Preparing").statusText, "Preparing",
      "The screen saver's reading is plain while busy")
    XCTAssertEqual(state(.screenSaver, status: "").statusText, "Updating")

    let failed = state(.lockScreen, status: "Not enabled - action required", error: "It failed")
    XCTAssertTrue(failed.canRetry)
    XCTAssertFalse(state(.lockScreen, busy: true, status: "x", error: "It failed").canRetry, "Retry waits for the service")
    XCTAssertFalse(state(.lockScreen, status: "Off").canRetry, "Retry appears with an error")
    XCTAssertFalse(state(.lockScreen, busy: true, status: "x").isSwitchEnabled)
    XCTAssertTrue(state(.lockScreen, status: "x").isSwitchEnabled)
  }

  /// The quick tiles say less than the rows: a plain "Unavailable", an ellipsis while busy for both
  /// features, and "Needs approval" for a login item the user has to allow.
  func testTheQuickTilesWordTheirStateLineShorterThanTheRows() throws {
    try pinPanelLanguageToEnglish()
    func state(_ kind: LockScreenState.Kind, available: Bool = true, busy: Bool = false, status: String) -> LockScreenState {
      LockScreenState(kind: kind, isRequested: false, isAvailable: available, isBusy: busy, status: status, error: nil)
    }
    XCTAssertEqual(state(.lockScreen, available: false, status: "Requires macOS 26 or later").tileNote, "Unavailable")
    XCTAssertEqual(state(.screenSaver, busy: true, status: "Preparing").tileNote, "Preparing…")
    XCTAssertEqual(state(.lockScreen, busy: true, status: "Waiting...").tileNote, "Waiting...")
    XCTAssertEqual(state(.lockScreen, busy: true, status: "").tileNote, "Updating…")
    XCTAssertNil(state(.lockScreen, status: "Off").tileNote, "Otherwise the tile reads On or Off")

    XCTAssertEqual(LaunchAtLoginState(isOn: false, isAvailable: false, needsApproval: false).tileNote, "Unavailable")
    XCTAssertEqual(LaunchAtLoginState(isOn: false, isAvailable: true, needsApproval: true).tileNote, "Needs approval")
    XCTAssertNil(LaunchAtLoginState(isOn: true, isAvailable: true, needsApproval: false).tileNote)
  }

  func testTheLockScreenAndScreenSaverShareTheServiceBusyFlagButNotTheirRequests() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.lockScreenWallpaper = try lockScreen(requested: true)
      let lock = panel.controller.lockScreenState
      let saver = panel.controller.screenSaverState
      XCTAssertTrue(lock.isRequested)
      XCTAssertFalse(saver.isRequested)
      XCTAssertEqual(lock.isBusy, saver.isBusy)
      XCTAssertTrue(lock.isAvailable && saver.isAvailable)
    }
  }
}
