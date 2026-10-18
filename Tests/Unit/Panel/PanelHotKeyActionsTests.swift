import AppKit
import Carbon
import os
import XCTest

@testable import WallpaperMachine

/// The Keyboard shortcuts page: recording a shortcut from a key-down, clearing it, and the rows the
/// page lists.
@MainActor
final class PanelHotKeyActionsTests: PanelTestCase {
  private let allThree: NSEvent.ModifierFlags = [.command, .option, .control]

  func testTheRandomWallpaperShortcutIsListedRecordedAndCleared() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let ids = controller.hotKeyRows.map(\.id)
    let next = try XCTUnwrap(ids.firstIndex(of: "nextWallpaper"))
    XCTAssertEqual(ids.firstIndex(of: "randomWallpaper"), next + 1, "it is listed after Next wallpaper")
    XCTAssertEqual(
      ids, HotKeyAction.allCases.map(\.rawValue), "one row per action, in the order the actions are declared")
    func random() -> HotKeyRow? { controller.hotKeyRows.first { $0.action == .randomWallpaper } }
    XCTAssertNil(random()?.shortcut, "no shortcut is taken until one is recorded")

    try await controller.setHotKey(.randomWallpaper, keyCode: UInt16(kVK_ANSI_R), modifierFlags: allThree)
    XCTAssertEqual(random()?.shortcut, controller.hotKeys.bindings[.randomWallpaper]?.label)
    XCTAssertEqual(random()?.shortcut, "⌃⌥⌘R")
    XCTAssertEqual(
      HotKeyPreferences(defaults: panel.defaults).bindings[.randomWallpaper], controller.hotKeys.bindings[.randomWallpaper],
      "it outlives the app")

    try await controller.clearHotKey(.randomWallpaper)
    XCTAssertNil(random()?.shortcut)
    XCTAssertNil(controller.hotKeys.bindings[.randomWallpaper])
    XCTAssertNil(HotKeyPreferences(defaults: panel.defaults).bindings[.randomWallpaper])
  }

  func testEveryActionIsNamedInThePanelsLanguage() throws {
    let panel = try makeController()
    let titles = panel.controller.hotKeyRows.map(\.title)
    XCTAssertEqual(
      titles,
      [
        L("Play or pause wallpapers"), L("Mute or unmute wallpapers"), L("Previous wallpaper"), L("Next wallpaper"),
        L("Random wallpaper"), L("Open the control panel"),
      ])
    XCTAssertEqual(Set(titles).count, HotKeyAction.allCases.count)
  }

  func testAKeyThatCannotBeAShortcutOrNeedsAModifierIsRefusedWithTheReasonAndNothingChanges() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let unusable = String(localized: "This key can’t be used for a shortcut. Try a letter, a number or a function key.")
    let needsModifier = String(localized: "Hold ⌘, ⌥ or ⌃ with the key, so the shortcut doesn’t take it away from typing.")
    let attempts: [(UInt16, NSEvent.ModifierFlags, String)] = [
      (UInt16(kVK_Escape), [.command], unusable), (UInt16(kVK_Tab), allThree, unusable),
      (UInt16(kVK_Delete), [.command], unusable), (UInt16(kVK_ANSI_Keypad5), [.command], unusable),
      (UInt16(kVK_ANSI_P), [], needsModifier), (UInt16(kVK_ANSI_P), [.shift], needsModifier),
      (UInt16(kVK_F5), [.shift], needsModifier),
    ]
    for (keyCode, flags, reason) in attempts {
      do {
        try await controller.setHotKey(.togglePlayback, keyCode: keyCode, modifierFlags: flags)
        XCTFail("recorded key \(keyCode) with \(flags)")
      } catch { XCTAssertEqual(error.localizedDescription, reason, "key \(keyCode)") }
    }
    XCTAssertTrue(controller.hotKeys.bindings.isEmpty)
    try await controller.setHotKey(.togglePlayback, keyCode: UInt16(kVK_F15), modifierFlags: [])
    XCTAssertEqual(controller.hotKeys.bindings[.togglePlayback]?.label, "F15", "F13 to F20 stand alone")
  }

  func testACombinationAnotherActionUsesIsRefusedByItsTitleAndTheOldBindingStays() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.setHotKey(.togglePlayback, keyCode: UInt16(kVK_ANSI_P), modifierFlags: allThree)
    do {
      try await controller.setHotKey(.nextWallpaper, keyCode: UInt16(kVK_ANSI_P), modifierFlags: allThree)
      XCTFail("one combination serves one action only")
    } catch {
      XCTAssertEqual(
        error.localizedDescription, String(localized: "That shortcut is already used for “\(HotKeyAction.togglePlayback.title)”."))
    }
    XCTAssertNil(controller.hotKeys.bindings[.nextWallpaper])
    XCTAssertEqual(controller.hotKeys.bindings[.togglePlayback]?.label, "⌃⌥⌘P")
    try await controller.setHotKey(.togglePlayback, keyCode: UInt16(kVK_ANSI_P), modifierFlags: allThree)
    try await controller.setHotKey(.nextWallpaper, keyCode: UInt16(kVK_ANSI_P), modifierFlags: [.command, .option])
    XCTAssertEqual(controller.hotKeys.bindings[.nextWallpaper]?.label, "⌥⌘P", "a different modifier set is another shortcut")
  }

  func testARefusalMacOSMadeIsShownOnTheRowAndForgottenWhenTheShortcutChanges() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await panel.start()
    try await controller.setHotKey(.openControlPanel, keyCode: UInt16(kVK_ANSI_O), modifierFlags: allThree)
    controller.hotKeys.recordFailure("Another app already uses this shortcut. Record a different one.", for: .openControlPanel)
    let row = try XCTUnwrap(controller.hotKeyRows.first { $0.action == .openControlPanel })
    XCTAssertEqual(row.shortcut, "⌃⌥⌘O", "the shortcut stays listed")
    XCTAssertEqual(row.error, "Another app already uses this shortcut. Record a different one.")
    try await controller.setHotKey(.openControlPanel, keyCode: UInt16(kVK_ANSI_K), modifierFlags: allThree)
    XCTAssertNil(controller.hotKeyRows.first { $0.action == .openControlPanel }?.error)
  }

  func testTheRowsFollowTheStoreWithoutAnyOtherChange() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await panel.start()
    let changes = OSAllocatedUnfairLock(initialState: 0)
    withObservationTracking {
      _ = controller.hotKeyRows
    } onChange: {
      changes.withLock { $0 += 1 }
    }
    try controller.hotKeys.set(HotKey(keyCode: 35, modifiers: 6400, label: "⌃⌥⌘P"), for: .togglePlayback)
    try await panel.waitUntil { changes.withLock { $0 } == 1 }
    XCTAssertEqual(controller.hotKeyRows.first?.shortcut, "⌃⌥⌘P")
  }

  func testAShortcutActionLeavesTheBannerAndNeverWaitsForTheQueue() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    struct Refused: LocalizedError { var errorDescription: String? { "Refused" } }
    controller.errors.report(Refused())
    let gate = QueueGate()
    let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
    try await panel.waitUntil { panel.store.commands.isBusy }
    try await controller.setHotKey(.toggleMute, keyCode: UInt16(kVK_ANSI_M), modifierFlags: allThree)
    XCTAssertNotNil(controller.hotKeys.bindings[.toggleMute])
    XCTAssertEqual(controller.errors.message, "Refused")
    gate.open()
    _ = await running.value
  }

  // MARK: Recording

  func testAModifierKeyOnItsOwnKeepsTheRecorderWaiting() {
    let modifierKeys = [
      kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption, kVK_Control,
      kVK_RightControl, kVK_CapsLock, kVK_Function,
    ]
    for key in modifierKeys {
      XCTAssertEqual(HotKeyRecording.press(keyCode: UInt16(key), modifierFlags: [.command]), .ignored, "key \(key)")
    }
  }

  func testEscapeCancelsUnlessAModifierMakesItACombinationTheRecorderRefuses() {
    let escape = UInt16(kVK_Escape)
    XCTAssertEqual(HotKeyRecording.press(keyCode: escape, modifierFlags: []), .cancelled)
    XCTAssertEqual(HotKeyRecording.press(keyCode: escape, modifierFlags: [.shift]), .cancelled, "Shift alone counts as none")
    XCTAssertEqual(HotKeyRecording.press(keyCode: escape, modifierFlags: [.capsLock, .function]), .cancelled)
    for flag in [NSEvent.ModifierFlags.command, .control, .option] {
      XCTAssertEqual(
        HotKeyRecording.press(keyCode: escape, modifierFlags: [flag]), .recorded,
        "⌘Esc is sent on, and refused as a key a shortcut cannot use")
    }
    XCTAssertEqual(HotKeyRecording.press(keyCode: UInt16(kVK_ANSI_A), modifierFlags: []), .recorded)
    XCTAssertEqual(HotKeyRecording.press(keyCode: UInt16(kVK_Space), modifierFlags: [.command]), .recorded)
  }
}
