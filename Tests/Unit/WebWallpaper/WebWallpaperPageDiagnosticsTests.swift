import WebKit
import XCTest

@testable import WallpaperMachine

/// A web wallpaper's own errors and warnings reach the app's log: the host script reports
/// them, throttled, and `WebWallpaperPageDiagnostics` turns each into one bounded line, at
/// most `maximumLines` per document. The page runs in a real offscreen `WKWebView`.
@MainActor
final class WebWallpaperPageDiagnosticsTests: XCTestCase {
  private var project: URL!

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-page-diagnostics-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  func testEachKindOfReportBecomesOneLineAtItsLevel() {
    var diagnostics = WebWallpaperPageDiagnostics()
    let warning = diagnostics.line(project: "clock", payload: ["kind": "warning", "text": "slow\nframe"])
    XCTAssertEqual(warning?.level, .info)
    XCTAssertEqual(warning?.text, "web wallpaper clock: page warning: slow frame")
    for kind in ["error", "uncaught", "rejection", "resource"] {
      XCTAssertEqual(diagnostics.line(project: "clock", payload: ["kind": kind, "text": "x"])?.level, .warn, kind)
    }
    XCTAssertEqual(diagnostics.logged, 5)
  }

  func testAMalformedOrUnknownReportIsDroppedAndNotCounted() {
    var diagnostics = WebWallpaperPageDiagnostics()
    XCTAssertNil(diagnostics.line(project: "p", payload: ["kind": "debug", "text": "x"]))
    XCTAssertNil(diagnostics.line(project: "p", payload: ["kind": "error", "text": 7]))
    XCTAssertNil(diagnostics.line(project: "p", payload: ["text": "x"]))
    XCTAssertEqual(diagnostics.logged, 0)
  }

  func testALongReportIsCutAndADocumentStopsAtTheCap() throws {
    var diagnostics = WebWallpaperPageDiagnostics()
    let long = try XCTUnwrap(diagnostics.line(
      project: "p", payload: ["kind": "error", "text": String(repeating: "a", count: 5000)]))
    XCTAssertLessThan(long.text.count, WebWallpaperPageDiagnostics.maximumLength + 60)
    let stacked = "a" + String(repeating: "\u{301}", count: 5000)
    let marks = try XCTUnwrap(diagnostics.line(project: "p", payload: ["kind": "error", "text": stacked]))
    XCTAssertLessThan(
      marks.text.unicodeScalars.count, WebWallpaperPageDiagnostics.maximumLength + 60,
      "one character with thousands of combining marks is cut too")
    for _ in 2..<(WebWallpaperPageDiagnostics.maximumLines - 1) {
      XCTAssertNotNil(diagnostics.line(project: "p", payload: ["kind": "error", "text": "again"]))
    }
    let last = try XCTUnwrap(diagnostics.line(project: "p", payload: ["kind": "error", "text": "last"]))
    XCTAssertTrue(last.text.contains("not logged"), "the last line says that the rest is left out")
    XCTAssertNil(diagnostics.line(project: "p", payload: ["kind": "error", "text": "over"]))
    XCTAssertEqual(diagnostics.logged, WebWallpaperPageDiagnostics.maximumLines)
  }

  func testThePageReportsItsErrorsWarningsRejectionsAndFailedLoadsOnce() async throws {
    let page = try await loadedPage(script: """
      console.error("boom", { code: 7 });
      console.error("boom", { code: 7 });
      console.warn("careful");
      setTimeout(() => { throw new TypeError("thrown"); }, 0);
      Promise.reject(new Error("rejected"));
      const picture = new Image();
      document.body.appendChild(picture);
      picture.src = "missing.png";
      """)
    defer { page.stop() }
    try await poll { page.pageDiagnostics.logged >= 5 }
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(page.pageDiagnostics.logged, 5, "a repeat of the last report is not sent again")
  }

  func testAPageThatReportsInABurstSendsEightASecond() async throws {
    let page = try await loadedPage(script: "for (let i = 0; i < 100; i++) console.error('burst ' + i);")
    defer { page.stop() }
    try await poll { page.pageDiagnostics.logged >= 8 }
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(page.pageDiagnostics.logged, 8)
  }

  func testANewDocumentStartsANewCount() async throws {
    let page = try await loadedPage(script: "console.error('once');")
    defer { page.stop() }
    try await poll { page.pageDiagnostics.logged == 1 }
    page.load()
    try await waitUntilLoaded(page)
    try await poll { page.pageDiagnostics.logged == 1 }
    XCTAssertEqual(page.pageDiagnostics.logged, 1)
  }

  private func loadedPage(script: String) async throws -> WebWallpaperPage {
    try """
      <!doctype html><html><body><script>
      \(script)
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    return page
  }

  private func waitUntilLoaded(_ page: WebWallpaperPage, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)
  }

  private func poll(timeout: TimeInterval = 5, until condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}
