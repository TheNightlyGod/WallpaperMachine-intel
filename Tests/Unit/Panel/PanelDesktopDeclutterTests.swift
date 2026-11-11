import AppKit
import XCTest

@testable import WallpaperMachine

/// Settings › Desktop & Lock Screen › Hide desktop icons and Hide the notch. Finder is the test
/// bundle's stand-in (`DesktopActionLog`), so nothing here changes or restarts the developer's.
@MainActor
final class PanelDesktopDeclutterTests: PanelTestCase {
  /// The stand-in Finder, showing its icons as a fresh Mac does, put back that way afterwards.
  private func standInFinder(storing value: Any? = nil) -> DesktopActionLog {
    let log = DesktopActionLog.shared
    log.finderDesktopPreference = value
    log.acceptsFinderDesktopWrites = true
    log.finderEndsForRestart = true
    addTeardownBlock { @MainActor in
      log.finderDesktopPreference = nil
      log.acceptsFinderDesktopWrites = true
      log.finderEndsForRestart = true
    }
    return log
  }

  func testHidingTheIconsAsksFirstAndCancelLeavesFinderAlone() async throws {
    try await withRecordingPanel { panel, _ in
      let finder = standInFinder()
      let writes = finder.finderDesktopWrites.count
      let restarts = finder.finderRestarts
      panel.store.snapshotRevision = 1
      let controller = panel.controller

      await controller.settings.set(.hideDesktopIcons, to: true)?.value

      XCTAssertEqual(panel.dialogs.confirmations.count, 1, "Finder restarts, so the switch asks first")
      XCTAssertEqual(finder.finderDesktopWrites.count, writes, "Cancel writes nothing")
      XCTAssertEqual(finder.finderRestarts, restarts, "and restarts nothing")
      XCTAssertFalse(controller.settings.isOn(.hideDesktopIcons), "the switch goes back to what Finder does")
    }
  }

  func testAConfirmedChangeWritesFindersChoiceOnceAndRestartsItOnce() async throws {
    try await withRecordingPanel { panel, _ in
      let finder = standInFinder()
      let writes = finder.finderDesktopWrites.count
      let restarts = finder.finderRestarts
      let controller = panel.controller
      panel.dialogs.confirmAnswer = true

      try await controller.setHidesDesktopIcons(true)
      XCTAssertEqual(Array(finder.finderDesktopWrites.dropFirst(writes)), [false])
      XCTAssertEqual(finder.finderRestarts, restarts + 1)
      XCTAssertTrue(controller.isSwitchOn(.hideDesktopIcons))

      try await controller.setHidesDesktopIcons(false)
      XCTAssertEqual(Array(finder.finderDesktopWrites.dropFirst(writes)), [false, true])
      XCTAssertEqual(finder.finderRestarts, restarts + 2)
      XCTAssertFalse(controller.desktopSettings.hidesDesktopIcons)
      XCTAssertEqual(panel.dialogs.confirmations.count, 2, "each restart is asked for")
    }
  }

  func testIconsHiddenElsewhereShowAsHiddenAndAskForNothing() async throws {
    try await withRecordingPanel { panel, _ in
      // `defaults write com.apple.finder CreateDesktop 0` in Terminal stores a string.
      let finder = standInFinder(storing: "0")
      let writes = finder.finderDesktopWrites.count
      let restarts = finder.finderRestarts
      let controller = panel.controller
      panel.dialogs.confirmAnswer = true
      XCTAssertTrue(controller.desktopSettings.hidesDesktopIcons)

      try await controller.setHidesDesktopIcons(true)
      XCTAssertTrue(panel.dialogs.confirmations.isEmpty, "Finder already does it")
      XCTAssertEqual(finder.finderDesktopWrites.count, writes)
      XCTAssertEqual(finder.finderRestarts, restarts)
    }
  }

  func testARefusedWriteIsReportedAndFinderKeepsRunning() async throws {
    try await withRecordingPanel { panel, _ in
      let finder = standInFinder()
      finder.acceptsFinderDesktopWrites = false
      let restarts = finder.finderRestarts
      panel.dialogs.confirmAnswer = true

      do {
        try await panel.controller.setHidesDesktopIcons(true)
        XCTFail("a refused write must not pass for a change")
      } catch {}
      XCTAssertEqual(finder.finderRestarts, restarts)
      XCTAssertFalse(panel.controller.desktopSettings.hidesDesktopIcons)
    }
  }

  func testAFinderThatCannotBeRestartedIsReportedNotTakenForAChange() async throws {
    try await withRecordingPanel { panel, _ in
      let finder = standInFinder()
      finder.finderEndsForRestart = false
      panel.dialogs.confirmAnswer = true

      do {
        try await panel.controller.setHidesDesktopIcons(true)
        XCTFail("a Finder still showing its icons must not pass for a change")
      } catch {
        XCTAssertTrue(error is FinderDesktopIcons.RestartFailed)
      }
      XCTAssertTrue(
        panel.controller.desktopSettings.hidesDesktopIcons,
        "the switch shows the stored choice, which Finder applies when it next starts")
    }
  }

  func testTheNotchSwitchPutsTheStripUpAtOnceAndIsKept() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let screens = [
        NotchMaskController.Screen(
          displayID: 1, frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
          visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 944), hasNotch: true)
      ]
      let mask = NotchMaskController(
        defaults: panel.defaults, screens: { screens },
        makeMask: { NotchMaskController.makeMaskWindow(frame: $0) })
      mask.start()
      defer { mask.stop() }
      XCTAssertFalse(controller.isSwitchOn(.hideNotch), "off until turned on")
      XCTAssertTrue(mask.placedFrames.isEmpty)

      try await controller.setHidesNotch(true)
      XCTAssertTrue(controller.desktopSettings.hidesNotch)
      XCTAssertEqual(mask.placedFrames.count, 1, "the strip follows the switch without a relaunch")

      try await controller.setHidesNotch(false)
      XCTAssertTrue(mask.placedFrames.isEmpty)
    }
  }

  func testResetTurnsTheNotchStripOffAndLeavesFindersIconsAsTheyAre() async throws {
    try await withRecordingPanel { panel, _ in
      let finder = standInFinder(storing: false)
      let writes = finder.finderDesktopWrites.count
      let restarts = finder.finderRestarts
      let controller = panel.controller
      try await controller.setHidesNotch(true)

      panel.dialogs.confirmAnswer = true
      try await controller.resetAllSettings()

      XCTAssertFalse(controller.desktopSettings.hidesNotch)
      XCTAssertTrue(controller.desktopSettings.hidesDesktopIcons, "Finder's own choice is not the app's to reset")
      XCTAssertEqual(finder.finderDesktopWrites.count, writes)
      XCTAssertEqual(finder.finderRestarts, restarts, "a reset never restarts Finder")
    }
  }
}
