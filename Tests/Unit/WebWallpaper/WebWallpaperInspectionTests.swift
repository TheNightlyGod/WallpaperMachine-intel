import WebKit
import XCTest

@testable import WallpaperMachine

/// Whether Safari's Web Inspector may attach to a web wallpaper. Nothing here
/// opens Safari or a window: the tests read the web view's own flag. That
/// Safari's Develop menu really lists the page and attaches in a release build
/// is the one thing only a desktop run can show.
@MainActor
final class WebWallpaperInspectionTests: XCTestCase {
  func testExplicitValueWinsOverTheBuildDefault() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let center = NotificationCenter()
    var posts = 0
    let observer = center.addObserver(forName: WebWallpaperInspection.didChange, object: nil, queue: nil) { _ in
      posts += 1
    }
    defer { center.removeObserver(observer) }

    // A debug build starts on and a release build off; either way the user's
    // choice must beat that, in both directions.
    WebWallpaperInspection.setEnabled(false, defaults: defaults, center: center)
    XCTAssertFalse(WebWallpaperInspection.isEnabled(defaults: defaults))
    XCTAssertEqual(posts, 1, "running pages are told about the change")
    WebWallpaperInspection.setEnabled(true, defaults: defaults, center: center)
    XCTAssertTrue(WebWallpaperInspection.isEnabled(defaults: defaults))
    XCTAssertEqual(posts, 2)
    WebWallpaperInspection.setEnabled(false, defaults: defaults, center: center)
    XCTAssertFalse(WebWallpaperInspection.isEnabled(defaults: defaults))
    XCTAssertEqual(posts, 3)
  }

  func testTheChoiceIsKeptPerPreferenceDomain() throws {
    let first = try TemporaryDefaults.make(for: self).defaults
    let second = try TemporaryDefaults.make(for: self).defaults
    let center = NotificationCenter()
    WebWallpaperInspection.setEnabled(true, defaults: first, center: center)
    WebWallpaperInspection.setEnabled(false, defaults: second, center: center)
    XCTAssertTrue(WebWallpaperInspection.isEnabled(defaults: first))
    XCTAssertFalse(WebWallpaperInspection.isEnabled(defaults: second))
  }

  /// Diagnostic state must not move to another Mac with a backup.
  func testTheChoiceDoesNotTravelInABackup() throws {
    let (defaults, suite) = try TemporaryDefaults.make(for: self)
    WebWallpaperInspection.setEnabled(true, defaults: defaults, center: NotificationCenter())
    defaults.set(true, forKey: "WallpaperMachine.hideAfterActivating")

    let preferences = try WallpaperBackupPreferences(defaults: defaults, domainName: suite)
    XCTAssertNotNil(
      preferences.values["WallpaperMachine.hideAfterActivating"],
      "the capture reads this suite, so the missing key below is meaningful")
    XCTAssertNil(preferences.values[WebWallpaperInspection.defaultsKey])
  }

  func testAPageIsInspectableOnlyWhenAskedAndChangesLive() throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-inspection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }

    // Even a debug build keeps a page closed unless its owner opens it.
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    XCTAssertFalse(page.webView.isInspectable)
    page.setInspectable(true)
    XCTAssertTrue(page.webView.isInspectable)
    XCTAssertTrue(page.isInspectable)
    page.setInspectable(false)
    XCTAssertFalse(page.webView.isInspectable)
    XCTAssertFalse(page.isInspectable)

    let open = WebWallpaperPage(projectURL: project, entryFile: "index.html", inspectable: true)
    XCTAssertTrue(open.webView.isInspectable)
  }
}
