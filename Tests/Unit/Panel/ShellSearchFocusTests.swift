import AppKit
import XCTest

@testable import WallpaperMachine

/// Command-F: finding the page's search field in the window and giving it the keyboard.
@MainActor
final class ShellSearchFocusTests: PanelTestCase {
  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    return window
  }

  func testAVisibleSearchFieldInTheContentTakesTheKeyboardAndAHiddenOneIsSkipped() throws {
    let window = makeWindow()
    defer { window.close() }
    let hidden = NSSearchField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
    hidden.isHidden = true
    let field = NSSearchField(frame: NSRect(x: 0, y: 40, width: 200, height: 22))
    let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    wrapper.addSubview(hidden)
    wrapper.addSubview(field)
    window.contentView?.addSubview(wrapper)

    XCTAssertTrue(PanelSearchFocus.field(in: window) === field)
    XCTAssertTrue(PanelSearchFocus.focus(in: window))
    XCTAssertTrue(
      (window.firstResponder as? NSText)?.delegate === field,
      "the field is being edited")
  }

  func testAWindowWithoutASearchFieldTakesNothing() {
    let window = makeWindow()
    defer { window.close() }
    window.contentView?.addSubview(NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22)))
    XCTAssertNil(PanelSearchFocus.field(in: window))
    XCTAssertFalse(PanelSearchFocus.focus(in: window))
  }

  func testTheShellReportsNoFieldWithoutAWindow() async throws {
    try await withPanel { panel in
      XCTAssertFalse(panel.controller.shell.focusSearch(), "the panel has no window yet")
    }
  }
}
