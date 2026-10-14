import XCTest

@testable import WallpaperMachine

/// Settings the panel keeps itself rather than handing to the engine, and the General rows
/// that point the user at System Settings.
@MainActor
final class WebPanelGeneralSettingsTests: ControlPanelTestCase {
  /// Controllers that share one preferences suite, the way a relaunch does.
  @MainActor private struct Panel {
    let defaults: UserDefaults
    let root: URL
    let workshop: WorkshopStore
    func makeController(store: BridgeStore? = nil, playback: PlaybackPreferences? = nil)
      -> WebPanelController
    {
      WebPanelController(
        store: store ?? BridgeStore(bridge: WallpaperBridge(noPointer: .init())),
        navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
        appLanguage: .english(), playback: playback)
    }
  }

  private func makePanel() throws -> Panel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-general-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let workshop = WorkshopStore(
      downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
      defaults: defaults)
    return Panel(defaults: defaults, root: root, workshop: workshop)
  }

  /// The Settings row, the action that records the key and the one that clears it all take the
  /// action by its name, so a new shortcut action needs no panel code of its own.
  func testTheRandomWallpaperShortcutIsListedRecordedAndCleared() async throws {
    let panel = try makePanel()
    let hotKeys = HotKeyPreferences(defaults: panel.defaults)
    let controller = WebPanelController(
      store: BridgeStore(bridge: WallpaperBridge(noPointer: .init())), navigation: ControlPanelNavigation(),
      workshop: panel.workshop, defaults: panel.defaults, appLanguage: .english(), hotKeys: hotKeys)
    defer { controller.stop() }
    func rows() throws -> [[String: Any]] {
      let settings = try XCTUnwrap(controller.snapshot()["settings"] as? [String: Any])
      return try XCTUnwrap(settings["hotkeys"] as? [[String: Any]])
    }
    func shortcut() throws -> String? {
      try rows().first { $0["id"] as? String == "randomWallpaper" }?["shortcut"] as? String
    }

    let ids = try rows().compactMap { $0["id"] as? String }
    let next = try XCTUnwrap(ids.firstIndex(of: "nextWallpaper"))
    XCTAssertEqual(ids.firstIndex(of: "randomWallpaper"), next + 1, "it is listed after Next wallpaper")
    XCTAssertNil(try shortcut(), "no shortcut is taken until one is recorded")

    try await controller.perform(
      "hotkeySet",
      body: ["id": "randomWallpaper", "code": "KeyR", "command": true, "option": true, "control": true, "shift": false])
    XCTAssertEqual(hotKeys.bindings[.randomWallpaper]?.label, try shortcut())
    XCTAssertNotNil(try shortcut())
    XCTAssertEqual(HotKeyPreferences(defaults: panel.defaults).bindings[.randomWallpaper], hotKeys.bindings[.randomWallpaper])

    try await controller.perform("hotkeyClear", body: ["id": "randomWallpaper"])
    XCTAssertNil(try shortcut())
    XCTAssertNil(hotKeys.bindings[.randomWallpaper])
  }

  /// The muting of every wallpaper is the app's own preference: the panel stores it, reports it
  /// and takes nothing but a boolean for it.
  func testMutingEveryWallpaperIsStoredReportedAndTakesOnlyABoolean() async throws {
    let panel = try makePanel()
    let playback = PlaybackPreferences(defaults: panel.defaults)
    let controller = panel.makeController(playback: playback)
    defer { controller.stop() }
    func reported() throws -> Bool? {
      let settings = try XCTUnwrap(controller.snapshot()["settings"] as? [String: Any])
      return settings["wallpapersMuted"] as? Bool
    }

    XCTAssertEqual(try reported(), false, "Wallpapers keep their own sound until the user mutes them all")
    try await controller.perform("setting", body: ["key": "wallpapersMuted", "value": true])
    XCTAssertTrue(playback.wallpapersMuted)
    XCTAssertEqual(try reported(), true)
    XCTAssertTrue(
      PlaybackPreferences(defaults: panel.defaults).wallpapersMuted, "The choice must survive a relaunch")

    for bad: Any in ["true", "yes", 1, NSNull()] {
      do {
        try await controller.perform("setting", body: ["key": "wallpapersMuted", "value": bad])
        XCTFail("\(bad) must not be accepted for a switch")
      } catch {}
    }
    XCTAssertTrue(playback.wallpapersMuted, "A refused value leaves the saved one alone")

    try await controller.perform("setting", body: ["key": "wallpapersMuted", "value": false])
    XCTAssertFalse(playback.wallpapersMuted)
    XCTAssertEqual(try reported(), false)
  }

  /// What the user reads and presses: the first row of Playback, ticked as the preference says, even
  /// when the change comes from elsewhere (the menu bar, a link), and pressing it changes the preference.
  func testTheMuteRowLeadsPlaybackAndFollowsThePreference() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'settings'")
      _ = try await panel.js("document.querySelector('[data-section=\"performance\"]').click()")
      let toggle = "document.querySelector('.settings-row[data-key=\"wallpapersMuted\"] input[type=\"checkbox\"]')"
      try await panel.waitJS(toggle)

      let first = try await panel.js(
        "return document.querySelector('[data-key=\"performance-playback\"] .settings-row').dataset.key")
      XCTAssertEqual(first as? String, "wallpapersMuted", "Muting everything leads the Playback group")
      let initial = try await panel.js("return \(toggle).checked")
      XCTAssertEqual(initial as? Bool, false)
      let usable = try await panel.js("return !\(toggle).disabled")
      XCTAssertEqual(usable as? Bool, true)

      // Muted from the menu bar or a link: the open panel follows.
      panel.controller.playback.wallpapersMuted = true
      try await panel.waitJS("powerProbe.received.at(-1)?.settings?.wallpapersMuted === true")
      try await panel.waitJS("\(toggle).checked")

      _ = try await panel.js("\(toggle).click()")
      try await panel.waitUntil(timeout: 10) { !panel.controller.playback.wallpapersMuted }
      try await panel.waitJS("!\(toggle).checked")
    }
  }

  func testHidingAfterApplyingIsOffUntilTurnedOnAndPersists() async throws {
    let panel = try makePanel()
    let controller = panel.makeController()
    defer { controller.stop() }

    XCTAssertFalse(controller.hidesAfterActivating, "The panel stays open after applying unless the user opts in")
    try await controller.perform("setting", body: ["key": "hideAfterActivating", "value": true])
    XCTAssertTrue(controller.hidesAfterActivating)

    let reopened = panel.makeController()
    defer { reopened.stop() }
    XCTAssertTrue(reopened.hidesAfterActivating, "The choice must survive a relaunch")
  }

  func testInspectingWebWallpapersIsStoredReportedAndSurvivesARelaunch() async throws {
    let panel = try makePanel()
    let controller = panel.makeController()
    defer { controller.stop() }
    func reported(_ controller: WebPanelController) throws -> Bool? {
      let settings = try XCTUnwrap(controller.snapshot()["settings"] as? [String: Any])
      return settings["inspectWebWallpapers"] as? Bool
    }

    // Both directions are written: a debug build starts on, a release build off.
    try await controller.perform("setting", body: ["key": "inspectWebWallpapers", "value": true])
    XCTAssertTrue(WebWallpaperInspection.isEnabled(defaults: panel.defaults))
    XCTAssertEqual(try reported(controller), true)

    try await controller.perform("setting", body: ["key": "inspectWebWallpapers", "value": false])
    XCTAssertFalse(WebWallpaperInspection.isEnabled(defaults: panel.defaults))
    XCTAssertEqual(try reported(controller), false)

    let reopened = panel.makeController()
    defer { reopened.stop() }
    XCTAssertEqual(try reported(reopened), false, "turning inspection off must stick after a relaunch")
    try await reopened.perform("setting", body: ["key": "inspectWebWallpapers", "value": true])
    let third = panel.makeController()
    defer { third.stop() }
    XCTAssertEqual(try reported(third), true)
  }

  /// Showing pending property edits on the desktop is the app's own preference: it starts off, the
  /// panel stores it, reports it and takes nothing but a boolean for it.
  func testLivePropertyEditsDefaultsOffRoundTripsAndRefusesNonBooleans() async throws {
    let panel = try makePanel()
    let controller = panel.makeController()
    defer { controller.stop() }
    func reported(_ controller: WebPanelController) throws -> Bool? {
      let settings = try XCTUnwrap(controller.snapshot()["settings"] as? [String: Any])
      return settings["livePropertyEdits"] as? Bool
    }

    XCTAssertEqual(try reported(controller), false, "The desktop keeps showing the saved look until the user opts in")
    try await controller.perform("setting", body: ["key": "livePropertyEdits", "value": true])
    XCTAssertTrue(LivePropertyEditing.isEnabled(defaults: panel.defaults))
    XCTAssertEqual(try reported(controller), true)

    for bad: Any in ["true", "yes", 1, NSNull()] {
      do {
        try await controller.perform("setting", body: ["key": "livePropertyEdits", "value": bad])
        XCTFail("\(bad) must not be accepted for a switch")
      } catch {}
    }
    XCTAssertTrue(LivePropertyEditing.isEnabled(defaults: panel.defaults), "A refused value leaves the saved one alone")

    let reopened = panel.makeController()
    defer { reopened.stop() }
    XCTAssertEqual(try reported(reopened), true, "The choice must survive a relaunch")

    try await reopened.perform("setting", body: ["key": "livePropertyEdits", "value": false])
    XCTAssertFalse(LivePropertyEditing.isEnabled(defaults: panel.defaults))
    XCTAssertEqual(try reported(reopened), false)
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
    let panel = try makePanel()
    let playback = PlaybackPreferences(defaults: panel.defaults)
    let store = BridgeStore(bridge: WallpaperBridge(noPointer: .init()))
    let controller = panel.makeController(store: store, playback: playback)
    defer { controller.stop() }
    func settings() throws -> [String: Any] {
      try XCTUnwrap(controller.snapshot()["settings"] as? [String: Any])
    }

    XCTAssertEqual(try settings()["writeDesktopPicture"] as? Bool, true, "On until the user turns it off")
    XCTAssertEqual(try settings()["desktopPictureLocked"] as? Bool, false)
    try await controller.perform("setting", body: ["key": "writeDesktopPicture", "value": false])
    XCTAssertFalse(playback.writesDesktopPicture)
    XCTAssertEqual(try settings()["writeDesktopPicture"] as? Bool, false)
    XCTAssertFalse(
      PlaybackPreferences(defaults: panel.defaults).writesDesktopPicture, "The choice must survive a relaunch")
    do {
      try await controller.perform("setting", body: ["key": "writeDesktopPicture", "value": "yes"])
      XCTFail("A string must not be accepted for a switch")
    } catch {}
    XCTAssertFalse(playback.writesDesktopPicture)

    // Animate lock screen sets the picture itself: the choice waits until it is off again.
    store.lockScreenWallpaper = try lockScreen(requested: true)
    XCTAssertEqual(try settings()["desktopPictureLocked"] as? Bool, true)
    do {
      try await controller.perform("setting", body: ["key": "writeDesktopPicture", "value": true])
      XCTFail("The picture belongs to the lock screen while it is requested")
    } catch let error as WallpaperActionError {
      XCTAssertFalse(error.localizedDescription.isEmpty, "The user is told why")
    }
    XCTAssertFalse(playback.writesDesktopPicture, "A refused change must not be stored")
    XCTAssertEqual(try settings()["writeDesktopPicture"] as? Bool, false)

    store.lockScreenWallpaper = try lockScreen(requested: false)
    XCTAssertEqual(try settings()["desktopPictureLocked"] as? Bool, false, "Off, the lock screen owns nothing")
    try await controller.perform("setting", body: ["key": "writeDesktopPicture", "value": true])
    XCTAssertTrue(playback.writesDesktopPicture)
  }

  /// What the user reads and can press: the switch is on by default, turning it off disables the
  /// timed Mission Control refresh that depends on it, and the lock screen locks it with a reason.
  func testDesktopPictureRowFollowsThePreferenceAndTheLockScreen() async throws {
    try await withPanel { panel in
      try await panel.finishWelcome()
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'settings'")
      _ = try await panel.js("document.querySelector('[data-section=\"general\"]').click()")
      let rows = """
        const read = key => {
          const toggle = document.querySelector(`.settings-row[data-key="${key}"] input[type="checkbox"]`);
          const note = document.getElementById(toggle.getAttribute('aria-describedby') || '');
          return { checked: toggle.checked, usable: !toggle.disabled, note: note?.textContent.trim() ?? '' };
        };
        return { writes: read('writeDesktopPicture'), refresh: read('refreshDesktopPicture') };
        """
      func state() async throws -> (writes: [String: Any], refresh: [String: Any]) {
        let result = try await panel.js(rows)
        let page = try XCTUnwrap(result as? [String: Any])
        return (
          try XCTUnwrap(page["writes"] as? [String: Any]), try XCTUnwrap(page["refresh"] as? [String: Any])
        )
      }
      try await panel.waitJS("document.querySelector('.settings-row[data-key=\"writeDesktopPicture\"]')")

      let initial = try await state()
      XCTAssertEqual(initial.writes["checked"] as? Bool, true)
      XCTAssertEqual(initial.writes["usable"] as? Bool, true)
      XCTAssertEqual(initial.refresh["usable"] as? Bool, true)

      panel.controller.playback.writesDesktopPicture = false
      try await panel.waitJS("powerProbe.received.at(-1)?.settings?.writeDesktopPicture === false")
      try await panel.waitJS(
        "!document.querySelector('.settings-row[data-key=\"writeDesktopPicture\"] input').checked")
      let off = try await state()
      XCTAssertEqual(off.writes["usable"] as? Bool, true, "It can be turned back on")
      XCTAssertEqual(
        off.refresh["usable"] as? Bool, false, "A timed retake of a picture that is not written does nothing")

      panel.store.lockScreenWallpaper = try lockScreen(requested: true)
      panel.store.snapshotRevision &+= 1
      try await panel.waitJS("powerProbe.received.at(-1)?.settings?.desktopPictureLocked === true")
      try await panel.waitJS(
        "document.querySelector('.settings-row[data-key=\"writeDesktopPicture\"] input').disabled")
      let locked = try await state()
      XCTAssertEqual(locked.writes["checked"] as? Bool, false, "The lock does not change the choice")
      let note = try XCTUnwrap(locked.writes["note"] as? String)
      XCTAssertFalse(note.isEmpty, "The row says why it cannot be changed")
      XCTAssertNotEqual(note, initial.writes["note"] as? String)
    }
  }

  /// A launch at login the user switched off in System Settings stays off however often the app
  /// registers it. The row must say what the user has to do and offer the way there, and the
  /// native action must open Login Items and nothing else.
  func testLaunchAtLoginNeedsApprovalIsInTheSnapshotAndTheActionOpensLoginItemsOnly() async throws {
    try await withPanel { panel in
      var openedLoginItems = 0
      panel.controller.openLoginItemsSettings = { openedLoginItems += 1 }
      panel.store.settingsSnapshot.launchAtLoginAvailable = true
      panel.store.settingsSnapshot.launchAtLoginEnabled = false
      panel.store.settingsSnapshot.launchAtLoginNeedsApproval = true

      let settings = try XCTUnwrap(panel.controller.snapshot()["settings"] as? [String: Any])
      XCTAssertEqual(settings["launchAtLoginNeedsApproval"] as? Bool, true)
      XCTAssertEqual(
        settings["launchAtLogin"] as? Bool, false, "Waiting for approval is not being enabled")
      XCTAssertEqual(
        settings["launchAtLoginAvailable"] as? Bool, true,
        "The app is installed where it can register, so the switch stays usable")

      try await panel.finishWelcome()
      panel.navigation.selection = .settings
      panel.show()
      try await panel.waitJS("powerProbe.received.at(-1)?.page === 'settings'")
      _ = try await panel.js("document.querySelector('[data-section=\"general\"]').click()")
      let row = "document.querySelector('.settings-row[data-key=\"launchAtLogin\"]')"
      let rowState = """
        const row = \(row);
        const toggle = row.querySelector('input[type="checkbox"]');
        const described = document.getElementById(toggle.getAttribute('aria-describedby') || '');
        return {
          note: described?.textContent.trim() ?? '',
          button: row.querySelector('[data-action="openLoginItemsSettings"]') !== null,
          usable: !toggle.disabled, checked: toggle.checked,
        };
        """
      try await panel.waitJS("\(row)?.querySelector('[data-action=\"openLoginItemsSettings\"]')")

      let waitingPage = try await panel.js(rowState) as? [String: Any]
      let waiting = try XCTUnwrap(waitingPage)
      XCTAssertEqual(waiting["button"] as? Bool, true)
      XCTAssertEqual(waiting["usable"] as? Bool, true)
      XCTAssertEqual(waiting["checked"] as? Bool, false)
      XCTAssertFalse((waiting["note"] as? String ?? "").isEmpty, "The row must say what to do")

      _ = try await panel.js("\(row).querySelector('[data-action=\"openLoginItemsSettings\"]').click()")
      try await panel.waitUntil { openedLoginItems == 1 }
      try await panel.quiet()
      XCTAssertEqual(openedLoginItems, 1, "One click opens Login Items once")

      // The user allows it in System Settings and comes back to the panel. Nothing else asks the
      // bridge, so the return itself has to read the status again and drop the prompt.
      var granted = panel.store.settingsSnapshot
      granted.launchAtLoginEnabled = true
      granted.launchAtLoginNeedsApproval = false
      panel.reportFromBridge(granted)
      panel.controller.windowStateChanged(NSWindow.didBecomeKeyNotification)
      try await panel.waitUntil { !panel.store.settingsSnapshot.launchAtLoginNeedsApproval }
      try await panel.waitJS("powerProbe.received.at(-1)?.settings?.launchAtLoginNeedsApproval === false")
      try await panel.waitJS("!\(row).querySelector('[data-action=\"openLoginItemsSettings\"]')")
      let allowedPage = try await panel.js(rowState) as? [String: Any]
      let allowed = try XCTUnwrap(allowedPage)
      XCTAssertEqual(allowed["button"] as? Bool, false)
      XCTAssertEqual(allowed["checked"] as? Bool, true)
      XCTAssertEqual(allowed["note"] as? String, "", "Nothing is left to explain once it is enabled")
      XCTAssertEqual(openedLoginItems, 1)
    }
  }

  /// Returning to the panel costs a bridge round trip only while a Login Items note is waiting
  /// to be cleared; a panel with nothing pending does not re-read the bridge on every focus.
  func testReturningToThePanelReadsTheBridgeOnlyWhileAnApprovalIsPending() async throws {
    try await withPanel { panel in
      panel.store.settingsSnapshot.launchAtLoginAvailable = true
      panel.reportFromBridge(panel.store.settingsSnapshot)

      panel.controller.windowStateChanged(NSWindow.didBecomeKeyNotification)
      try await panel.quiet()
      XCTAssertEqual(panel.bridge.snapshotReads, 0, "Nothing is waiting for approval")

      var waiting = panel.store.settingsSnapshot
      waiting.launchAtLoginNeedsApproval = true
      panel.store.settingsSnapshot = waiting
      panel.reportFromBridge(waiting)
      panel.controller.windowStateChanged(NSWindow.didDeminiaturizeNotification)
      try await panel.quiet()
      XCTAssertEqual(panel.bridge.snapshotReads, 0, "Only becoming key counts as returning to the panel")

      panel.controller.windowStateChanged(NSWindow.didBecomeKeyNotification)
      panel.controller.windowStateChanged(NSWindow.didBecomeKeyNotification)
      try await panel.waitUntil { panel.bridge.snapshotReads >= 1 }
      try await panel.quiet()
      XCTAssertEqual(
        panel.bridge.snapshotReads, 1, "Focus changes in a row share the read that is in flight")
    }
  }

  /// The first-run guide offers the same switch, so a login item waiting for approval must be
  /// explained there too, without disabling the switch the way a copy outside Applications is.
  func testFirstRunPreferencesExplainAPendingLoginItemApproval() async throws {
    try await withPanel { panel in
      panel.store.settingsSnapshot.launchAtLoginAvailable = true
      panel.show()
      _ = try await panel.js("document.querySelector('#welcome [data-action=\"go\"][data-step=\"3\"]').click()")
      let row = "document.querySelector('#welcome .welcome-pref[data-key=\"pref-launchAtLogin\"]')"
      let rowState = """
        const row = \(row);
        return {
          note: row.querySelector('.welcome-pref-note').textContent.trim(),
          usable: !row.querySelector('input').disabled,
        };
        """
      panel.store.snapshotRevision &+= 1
      try await panel.waitJS("powerProbe.received.at(-1)?.settings?.launchAtLoginAvailable === true")
      let plainPage = try await panel.js(rowState) as? [String: Any]
      let plain = try XCTUnwrap(plainPage)

      panel.store.settingsSnapshot.launchAtLoginNeedsApproval = true
      panel.store.snapshotRevision &+= 1
      try await panel.waitJS("powerProbe.received.at(-1)?.settings?.launchAtLoginNeedsApproval === true")
      try await panel.waitJS("\(row).querySelector('.welcome-pref-note').textContent.trim().length > \((plain["note"] as? String ?? "").count)")
      let waitingPage = try await panel.js(rowState) as? [String: Any]
      let waiting = try XCTUnwrap(waitingPage)

      XCTAssertEqual(plain["usable"] as? Bool, true)
      XCTAssertEqual(
        waiting["usable"] as? Bool, true,
        "Approval is something the user does in System Settings; the switch is not disabled")
      let plainNote = try XCTUnwrap(plain["note"] as? String)
      let waitingNote = try XCTUnwrap(waiting["note"] as? String)
      XCTAssertTrue(
        waitingNote.hasPrefix(plainNote) && waitingNote.count > plainNote.count,
        "The row keeps its own description and adds what the user has to do")
    }
  }
}
