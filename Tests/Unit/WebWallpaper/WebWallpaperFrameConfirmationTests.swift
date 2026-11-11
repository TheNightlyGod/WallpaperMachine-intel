import WebKit
import XCTest

@testable import WallpaperMachine

/// `didFinish` comes before a page's first frame, so the held picture of a switch waits for
/// WebKit to commit one (`WebWallpaperPage.confirmFrame`) instead of a fixed delay. The page
/// runs in a real `WKWebView` hosted in a container view, with no desktop window: what a
/// real display shows at the moment of release only a desktop run can show.
@MainActor
final class WebWallpaperFrameConfirmationTests: XCTestCase {
  private var project: URL!
  /// The view each test's page is attached to; the page holds it only weakly.
  private var container: NSView?

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-frame-confirmation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    container = nil
    try? FileManager.default.removeItem(at: project)
  }

  func testALoadedPageConfirmsAFrame() async throws {
    let page = try await hostedPage(script: "")
    defer { page.stop() }
    let answer = await confirmation(of: page, within: .seconds(5))
    XCTAssertEqual(answer.confirmation, .committed)
  }

  func testTheAnswerWaitsForAFrameThatThePageHoldsBack() async throws {
    // The page holds its main thread right after load, as a large WebGL build does, so no
    // frame can be committed until it lets go. A fixed delay would release before that.
    let page = try await hostedPage(script: """
      addEventListener("load", () => setTimeout(() => { const end = Date.now() + 1200; while (Date.now() < end) {} }, 0));
      """)
    defer { page.stop() }
    try await Task.sleep(for: .milliseconds(100))
    let answer = await confirmation(of: page, within: .seconds(8))
    XCTAssertEqual(answer.confirmation, .committed)
    XCTAssertGreaterThan(answer.elapsed, 0.6, "the frame came after the page let go of its main thread")
  }

  func testAFrameThatNeverComesIsAnsweredAtTheLimit() async throws {
    let page = try await hostedPage(script: """
      addEventListener("load", () => setTimeout(() => { const end = Date.now() + 3000; while (Date.now() < end) {} }, 0));
      """)
    defer { page.stop() }
    try await Task.sleep(for: .milliseconds(100))
    let answer = await confirmation(of: page, within: .milliseconds(300))
    XCTAssertEqual(answer.confirmation, .timedOut)
  }

  func testAnAnswerForAReplacedDocumentIsDropped() async throws {
    let page = try await hostedPage(script: "")
    defer { page.stop() }
    var answers: [WebWallpaperPage.FrameConfirmation] = []
    page.confirmFrame(within: .milliseconds(200)) { answers.append($0) }
    page.load()
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(answers, [], "a reload makes the question about a document that is gone")
  }

  private func confirmation(
    of page: WebWallpaperPage, within limit: Duration
  ) async -> (confirmation: WebWallpaperPage.FrameConfirmation, elapsed: TimeInterval) {
    let start = Date()
    let confirmation = await withCheckedContinuation { continuation in
      page.confirmFrame(within: limit) { continuation.resume(returning: $0) }
    }
    return (confirmation, Date().timeIntervalSince(start))
  }

  private func hostedPage(script: String) async throws -> WebWallpaperPage {
    try """
      <!doctype html><html><body style="margin:0;background:#204060"><script>
      \(script)
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    container.wantsLayer = true
    self.container = container
    page.attach(to: container)
    page.load()
    let deadline = Date().addingTimeInterval(10)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)
    return page
  }
}
