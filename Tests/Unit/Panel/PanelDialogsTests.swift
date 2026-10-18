import AppKit
import XCTest

@testable import WallpaperMachine

/// Where the panel's alerts and file panels attach. Nothing here is presented: the windows are
/// never shown and only the choice of parent is asked.
@MainActor
final class PanelDialogsTests: XCTestCase {
  /// A window that reports the sheet a test gives it, as a window in front of the person reports
  /// the one it shows. An unshown window never attaches a real sheet.
  private final class SheetWindow: NSWindow {
    var shownSheet: NSWindow?
    override var attachedSheet: NSWindow? { shownSheet }
  }

  private func window() -> SheetWindow {
    let window = SheetWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }

  func testAConfirmationAskedFromInsideTheDownloadDialogComesUpOnTheDialogNotBehindIt() {
    let panel = window()
    let dialogs = AppKitPanelDialogs(window: { panel })
    XCTAssertTrue(dialogs.sheetParent === panel, "with nothing on show, the panel's window")

    // The download dialog is a SwiftUI sheet, whose window is a plain window.
    let downloadDialog = window()
    panel.shownSheet = downloadDialog
    XCTAssertTrue(
      dialogs.sheetParent === downloadDialog,
      "on the dialog's own window, where AppKit shows it at once instead of queueing it")
    XCTAssertTrue(dialogs.presentingWindow === panel, "the import picker still gets the panel's window")
  }

  func testAnAlertOrAFilePanelAlreadyUpIsNeverAParentAndTheNextOneWaitsBehindIt() {
    let panel = window()
    let downloadDialog = window()
    panel.shownSheet = downloadDialog
    downloadDialog.shownSheet = NSAlert().window
    XCTAssertTrue(
      AppKitPanelDialogs.sheetParent(for: panel) === downloadDialog,
      "a second question waits behind the alert the dialog shows")

    // An open or save panel is an NSPanel too; a bare one stands in for it, so no file panel is
    // made at all.
    panel.shownSheet = NSPanel()
    XCTAssertTrue(
      AppKitPanelDialogs.sheetParent(for: panel) === panel,
      "and behind a file panel on the window itself")
  }

  func testWithoutAWindowEveryQuestionIsRefusedSilently() async {
    let dialogs = AppKitPanelDialogs(window: { nil })
    XCTAssertNil(dialogs.sheetParent)
    let confirmed = await dialogs.confirm("Title", detail: "Detail", button: "OK")
    XCTAssertFalse(confirmed)
  }
}
