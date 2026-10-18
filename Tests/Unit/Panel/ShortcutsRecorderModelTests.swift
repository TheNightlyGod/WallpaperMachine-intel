import AppKit
import Carbon
import XCTest

@testable import WallpaperMachine

/// Recording a shortcut on Settings › Keyboard shortcuts: which presses end the recording, which one
/// is recorded and what a refusal does. The monitors that listen to the keyboard are not installed;
/// the tests feed the presses.
@MainActor
final class ShortcutsRecorderModelTests: SettingsBTestCase {
  private let allThree: NSEvent.ModifierFlags = [.command, .option, .control]

  private func recorder(_ panel: PanelFixture) -> ShortcutsRecorderModel {
    ShortcutsRecorderModel(controller: panel.controller, installsMonitors: false)
  }

  func testOnlyTheRowThatIsRecordingTakesAPressAndTheFirstKeyEndsIt() async throws {
    try await withPanel { panel in
      let model = recorder(panel)
      XCTAssertFalse(model.handle(keyCode: UInt16(kVK_ANSI_P), modifierFlags: allThree), "nothing records")
      model.begin(.togglePlayback)
      XCTAssertEqual(model.recording, .togglePlayback)
      XCTAssertEqual(model.focus, .togglePlayback, "focus goes to the row's first button")
      XCTAssertTrue(model.handle(keyCode: UInt16(kVK_ANSI_P), modifierFlags: allThree))
      XCTAssertNil(model.recording, "a press ends the recording")
      try await panel.waitUntil { panel.controller.hotKeys.bindings[.togglePlayback] != nil }
      XCTAssertEqual(panel.controller.hotKeyRows.first { $0.action == .togglePlayback }?.shortcut, "⌃⌥⌘P")
      XCTAssertFalse(model.handle(keyCode: UInt16(kVK_ANSI_Q), modifierFlags: allThree), "and the next press is nobody's")
    }
  }

  func testABareModifierKeepsWaitingAndIsLeftForTheSystem() async throws {
    try await withPanel { panel in
      let model = recorder(panel)
      model.begin(.nextWallpaper)
      for key in [kVK_Command, kVK_Shift, kVK_Option, kVK_Control, kVK_CapsLock, kVK_Function, kVK_RightCommand] {
        XCTAssertFalse(model.handle(keyCode: UInt16(key), modifierFlags: allThree), "\(key)")
        XCTAssertEqual(model.recording, .nextWallpaper, "still waiting for the key itself")
      }
    }
  }

  func testEscapeCancelsUnlessACommandOptionOrControlMakesItACombination() async throws {
    try await withPanel { panel in
      let model = recorder(panel)
      model.begin(.nextWallpaper)
      XCTAssertTrue(model.handle(keyCode: UInt16(kVK_Escape), modifierFlags: []))
      XCTAssertNil(model.recording)
      XCTAssertEqual(model.focus, .nextWallpaper, "focus returns to the row's button")
      model.begin(.nextWallpaper)
      XCTAssertTrue(model.handle(keyCode: UInt16(kVK_Escape), modifierFlags: [.shift]), "Shift is no modifier here")
      XCTAssertNil(model.recording)
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertNil(panel.controller.hotKeys.bindings[.nextWallpaper], "cancelling records nothing")
      XCTAssertNil(panel.controller.errors.actionError)

      // ⌘Esc is a combination, which the page refuses as a key no shortcut can use.
      model.begin(.nextWallpaper)
      XCTAssertTrue(model.handle(keyCode: UInt16(kVK_Escape), modifierFlags: [.command]))
      try await panel.waitUntil { panel.controller.errors.actionError != nil }
      XCTAssertEqual(
        panel.controller.errors.actionError,
        String(localized: "This key can’t be used for a shortcut. Try a letter, a number or a function key."))
      XCTAssertNil(panel.controller.hotKeys.bindings[.nextWallpaper])
    }
  }

  func testACombinationAnotherShortcutHoldsIsRefusedByThatShortcutsTitle() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await controller.setHotKey(.nextWallpaper, keyCode: UInt16(kVK_ANSI_N), modifierFlags: allThree)
      let model = recorder(panel)
      model.begin(.previousWallpaper)
      XCTAssertTrue(model.handle(keyCode: UInt16(kVK_ANSI_N), modifierFlags: allThree))
      try await panel.waitUntil { controller.errors.actionError != nil }
      XCTAssertTrue(
        controller.errors.actionError?.contains(HotKeyAction.nextWallpaper.title) == true,
        controller.errors.actionError ?? "")
      XCTAssertNil(controller.hotKeys.bindings[.previousWallpaper])
      XCTAssertNotNil(controller.hotKeys.bindings[.nextWallpaper], "the old binding stays")
    }
  }

  func testAFunctionKeyFromF13OnMayStandAloneAndOneBelowItMayNot() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let model = recorder(panel)
      model.begin(.toggleMute)
      XCTAssertTrue(model.handle(keyCode: UInt16(kVK_F13), modifierFlags: []))
      try await panel.waitUntil { controller.hotKeys.bindings[.toggleMute] != nil }
      XCTAssertEqual(controller.hotKeys.bindings[.toggleMute]?.label, "F13")
      model.begin(.randomWallpaper)
      XCTAssertTrue(model.handle(keyCode: UInt16(kVK_F5), modifierFlags: []))
      try await panel.waitUntil { controller.errors.actionError != nil }
      XCTAssertNil(controller.hotKeys.bindings[.randomWallpaper])
    }
  }

  func testBeginningAnotherRowGivesWayAndEndingStopsRecording() async throws {
    try await withPanel { panel in
      let model = recorder(panel)
      model.begin(.togglePlayback)
      model.begin(.toggleMute)
      XCTAssertEqual(model.recording, .toggleMute, "one row records at a time")
      model.cancel()
      XCTAssertNil(model.recording)
      XCTAssertEqual(model.focus, .toggleMute)
      model.consumeFocus()
      model.begin(.toggleMute)
      model.end()
      XCTAssertNil(model.recording, "the page left, or the window lost focus")
      XCTAssertEqual(model.focus, .toggleMute, "ending without choosing moves nothing more")
    }
  }

  func testAPressOfARegisteredShortcutIsReadAsItsCombinationAndNeverRunsItsAction() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await controller.setHotKey(.nextWallpaper, keyCode: UInt16(kVK_ANSI_N), modifierFlags: allThree)
      let model = recorder(panel)
      // Recording Previous, the user presses what Next already holds: the system hands that press
      // over as Next's shortcut, which the recorder reads as the keys, and the page refuses.
      model.begin(.previousWallpaper)
      model.handleRegisteredPress(of: .nextWallpaper)
      XCTAssertNil(model.recording)
      try await panel.waitUntil { controller.errors.actionError != nil }
      XCTAssertTrue(controller.errors.actionError?.contains(HotKeyAction.nextWallpaper.title) == true)

      // Recording Next again with its own keys is the same combination: no change, no error.
      controller.errors.clearAction()
      model.begin(.nextWallpaper)
      model.handleRegisteredPress(of: .nextWallpaper)
      try await Task.sleep(for: .milliseconds(60))
      XCTAssertNil(controller.errors.actionError)
      XCTAssertEqual(controller.hotKeys.bindings[.nextWallpaper]?.label, "⌃⌥⌘N")

      // A shortcut that is not registered cannot be handed over.
      model.begin(.randomWallpaper)
      model.handleRegisteredPress(of: .openControlPanel)
      XCTAssertEqual(model.recording, .randomWallpaper, "nothing to read")
    }
  }

  func testCarbonModifiersBecomeTheMatchingFlags() {
    typealias Model = ShortcutsRecorderModel
    XCTAssertEqual(Model.modifierFlags(carbon: 0), [])
    XCTAssertEqual(Model.modifierFlags(carbon: UInt32(cmdKey)), [.command])
    XCTAssertEqual(
      Model.modifierFlags(carbon: UInt32(controlKey | optionKey | cmdKey | shiftKey)),
      [.command, .option, .control, .shift])
    XCTAssertEqual(Model.modifierFlags(carbon: UInt32(optionKey | shiftKey)), [.option, .shift])
  }

  func testEveryActionHasARowItem() {
    for action in HotKeyAction.allCases {
      XCTAssertTrue(
        ShortcutsSettingsSection.items.contains { $0.id == ShortcutsSettingsSection.item(for: action).id }, "\(action)")
    }
    XCTAssertEqual(
      Set(HotKeyAction.allCases.map { ShortcutsSettingsSection.item(for: $0).id }).count, HotKeyAction.allCases.count)
  }
}
