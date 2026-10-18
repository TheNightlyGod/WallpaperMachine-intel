import AppKit
import XCTest

@testable import WallpaperMachine

/// Whether the panel can be seen and has the keyboard, which gates every piece of work nobody
/// would see the result of.
@MainActor
final class PanelPresentationTests: XCTestCase {
  /// A titled window that is never ordered onto the screen.
  private func unorderedWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  func testInjectionDrivesVisibilityAndTheKeyHook() {
    let presentation = PanelPresentation()
    XCTAssertFalse(presentation.isVisible, "a panel with no window is not on screen")
    XCTAssertFalse(presentation.isKey)
    var keyed = 0
    presentation.onBecameKey = { keyed += 1 }

    presentation.show()
    XCTAssertTrue(presentation.isVisible)
    presentation.becomeKey()
    XCTAssertTrue(presentation.isKey)
    XCTAssertEqual(keyed, 1)
    presentation.resignKey()
    XCTAssertFalse(presentation.isKey)
    presentation.hide()
    XCTAssertFalse(presentation.isVisible)
    XCTAssertEqual(keyed, 1, "only becoming key runs the hook")
  }

  func testAWindowThatIsNotOnScreenIsNotVisible() {
    let presentation = PanelPresentation(isVisible: true)
    let window = unorderedWindow()
    presentation.attach(to: window)
    XCTAssertTrue(presentation.window === window)
    XCTAssertFalse(presentation.isVisible, "an unordered window cannot be seen, whatever it was told before")
    XCTAssertFalse(presentation.isKey)
    presentation.attach(to: nil)
  }

  func testTheWindowsNotificationsDriveTheKeyHookAndTheCloseHook() {
    let presentation = PanelPresentation()
    var keyed = 0
    var closed = 0
    presentation.onBecameKey = { keyed += 1 }
    presentation.onClose = { closed += 1 }
    let window = unorderedWindow()
    presentation.attach(to: window)

    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    XCTAssertEqual(keyed, 1)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: unorderedWindow())
    XCTAssertEqual(keyed, 1, "another window's notifications are not ours")

    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    XCTAssertEqual(closed, 1)
    XCTAssertNil(presentation.window)
    XCTAssertFalse(presentation.isVisible)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    XCTAssertEqual(keyed, 1, "a closed window is no longer followed")
    presentation.attach(to: nil)
    XCTAssertEqual(closed, 1, "losing a window that already closed does not close twice")
  }

  func testTheViewLosingItsWindowCountsAsClosing() {
    let presentation = PanelPresentation()
    var closed = 0
    presentation.onClose = { closed += 1 }
    presentation.attach(to: nil)
    XCTAssertEqual(closed, 0, "nothing was attached")
    presentation.attach(to: unorderedWindow())
    presentation.attach(to: nil)
    XCTAssertEqual(closed, 1)
  }

  func testSwitchingWindowsStopsListeningToTheOldOne() {
    let presentation = PanelPresentation()
    var keyed = 0
    presentation.onBecameKey = { keyed += 1 }
    let first = unorderedWindow()
    let second = unorderedWindow()
    presentation.attach(to: first)
    presentation.attach(to: second)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: first)
    XCTAssertEqual(keyed, 0)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: second)
    XCTAssertEqual(keyed, 1)
    presentation.attach(to: nil)
  }
}
