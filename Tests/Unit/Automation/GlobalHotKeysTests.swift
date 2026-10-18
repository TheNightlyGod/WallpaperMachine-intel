import AppKit
import Carbon
import XCTest
@testable import WallpaperMachine

@MainActor
final class GlobalHotKeysTests: XCTestCase {
    func testAShortcutNeedsAModifierUnlessItsKeyTypesNothing() {
        XCTAssertThrowsError(try GlobalHotKeys.hotKey(keyCode: UInt16(kVK_ANSI_P), modifierFlags: [.shift]))
        XCTAssertNoThrow(try GlobalHotKeys.hotKey(keyCode: UInt16(kVK_F15), modifierFlags: []))
        XCTAssertThrowsError(try GlobalHotKeys.hotKey(keyCode: UInt16(kVK_F5), modifierFlags: []))
        XCTAssertThrowsError(
            try GlobalHotKeys.hotKey(keyCode: UInt16(kVK_Escape), modifierFlags: [.command]),
            "a key the table does not know is refused")
        XCTAssertThrowsError(
            try GlobalHotKeys.hotKey(keyCode: UInt16(kVK_ANSI_KeypadEnter), modifierFlags: [.command]),
            "Return is a shortcut key, the keypad's Enter is not")
    }

    func testEveryF13ToF20StandsAloneAndNoOtherKeyDoes() throws {
        for key in [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20] {
            XCTAssertNoThrow(try GlobalHotKeys.hotKey(keyCode: UInt16(key), modifierFlags: []), "key \(key)")
        }
        for key in [kVK_F1, kVK_F12, kVK_Space, kVK_LeftArrow, kVK_ANSI_0] {
            XCTAssertThrowsError(try GlobalHotKeys.hotKey(keyCode: UInt16(key), modifierFlags: [.shift]), "key \(key)")
        }
    }

    func testAShortcutIsTheKeysPositionWithItsModifiersInMenuOrder() throws {
        let hotKey = try GlobalHotKeys.hotKey(
            keyCode: UInt16(kVK_ANSI_P), modifierFlags: [.command, .option, .control, .shift])
        XCTAssertEqual(hotKey.keyCode, UInt32(kVK_ANSI_P))
        XCTAssertEqual(hotKey.modifiers, UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(hotKey.label, "⌃⌥⇧⌘P")
    }

    func testOnlyTheFourModifiersCountAndTheLabelsNameTheNonLetterKeys() throws {
        let arrow = try GlobalHotKeys.hotKey(
            keyCode: UInt16(kVK_LeftArrow), modifierFlags: [.command, .numericPad, .function, .capsLock])
        XCTAssertEqual(arrow.modifiers, UInt32(cmdKey), "an arrow key also reports the numeric-pad and function flags")
        XCTAssertEqual(arrow.label, "⌘←")
        let labels = try [kVK_Space, kVK_Return, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ANSI_Backslash]
            .map { try GlobalHotKeys.hotKey(keyCode: UInt16($0), modifierFlags: [.control]).label }
        XCTAssertEqual(labels, ["⌃Space", "⌃↩", "⌃↖", "⌃↘", "⌃⇞", "⌃⇟", "⌃\\"])
    }
}
