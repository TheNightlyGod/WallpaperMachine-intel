import AppKit
import Darwin
import Metal
import ObjectiveC
import QuartzCore
import XCTest

@testable import WallpaperMachine

/// Reads the policy accepted by WindowServer, without ordering a window or
/// pretending that JavaScript frame callbacks prove visible frame delivery.
/// The Stage Manager transitions themselves remain a manual smoke check.
@MainActor
final class WebWallpaperWindowCompositionTests: XCTestCase {
  private var project: URL!

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-window-composition-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try "<!doctype html><body></body>".write(
      to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: project)
  }

  private func makeWindow() -> WebWallpaperWindow {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    return WebWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 160, height: 120), page: page)
  }

  func testDesktopWebSurfaceOptsOutOfTransitionFlattening() async throws {
    let window = makeWindow()
    defer { window.close() }
    try await assertLiveSurfaces(window)
  }

  func testDesktopBackgroundHasASubmittedFrameRatherThanAnEmptyMetalQueue() async throws {
    let window = makeWindow()
    defer { window.close() }
    try await assertSubmittedBackground(window)
  }

  func testLiveResizePreservesTheBackgroundFrameAndFitsTheWebView() async throws {
    let window = makeWindow()
    defer { window.close() }
    try await assertSubmittedBackground(window)
    let background = try XCTUnwrap(window.contentView?.layer as? CAMetalLayer)
    let contents = try XCTUnwrap(background.contents) as AnyObject
    try invokeLiveResize("_startLiveResize", on: window)
    window.setScreenFrame(NSRect(x: 0, y: 0, width: 320, height: 240))
    try invokeLiveResize("_endLiveResize", on: window)
    try await assertLiveSurfaces(window)
    try await assertSubmittedBackground(window)
    XCTAssertTrue(window.contentView?.layer === background)
    XCTAssertTrue(background.contents as AnyObject? === contents)
    XCTAssertEqual(background.drawableSize, CGSize(width: 1, height: 1))
    XCTAssertEqual(background.bounds.size, CGSize(width: 320, height: 240))
    XCTAssertEqual(window.page.webView.frame, window.contentView?.bounds)
  }

  func testWithoutMetalTheContainerStillHostsThePageOnBlack() throws {
    let container = WebWallpaperBackgroundView(
      frame: NSRect(x: 0, y: 0, width: 160, height: 120), device: nil)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.attach(to: container)
    defer { page.stop() }
    XCTAssertTrue(page.webView.superview === container)
    XCTAssertEqual(page.webView.frame, container.bounds)
    XCTAssertEqual(container.layer?.backgroundColor, NSColor.black.cgColor)
  }

  func testSuspensionAndResumeKeepTheSubmittedBackground() async throws {
    let window = makeWindow()
    defer { window.page.stop(); window.close() }
    try await assertSubmittedBackground(window)
    let background = try XCTUnwrap(window.posterLayer)
    let contents = try XCTUnwrap(background.contents) as AnyObject
    window.page.setPresentationSuspended(true)
    let deadline = Date().addingTimeInterval(5)
    while window.page.isInWindowTree && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(window.page.isInWindowTree)
    XCTAssertTrue(window.posterLayer === background)
    try await assertSubmittedBackground(window)
    window.page.setPresentationSuspended(false)
    XCTAssertTrue(window.page.isInWindowTree)
    XCTAssertTrue(window.posterLayer === background)
    XCTAssertTrue(background.contents as AnyObject? === contents)
    try await assertSubmittedBackground(window)
  }

  private func assertSubmittedBackground(_ window: NSWindow) async throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Metal frame inspection requires a Metal device")
    }
    let background = try XCTUnwrap(window.contentView?.layer as? CAMetalLayer)
    XCTAssertEqual(background.drawableSize, CGSize(width: 1, height: 1),
      "The background must not allocate a display-sized render target")
    let contents = try XCTUnwrap(background.contents) as CFTypeRef
    typealias QueueType = @convention(c) () -> CFTypeID
    typealias LatestTime = @convention(c) (CFTypeRef) -> Double
    guard let framework = dlopen(
      "/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY)
    else { throw XCTSkip("Core Animation frame inspection is unavailable") }
    defer { dlclose(framework) }
    guard let typeSymbol = dlsym(framework, "CAImageQueueGetTypeID"),
          let timeSymbol = dlsym(framework, "CAImageQueueGetLatestTime")
    else { throw XCTSkip("Core Animation frame inspection is unavailable") }
    let queueType = unsafeBitCast(typeSymbol, to: QueueType.self)
    let latestTime = unsafeBitCast(timeSymbol, to: LatestTime.self)
    XCTAssertEqual(CFGetTypeID(contents), queueType())
    guard CFGetTypeID(contents) == queueType() else { return }
    // An empty Metal layer also has an image queue, but returns -1 here.
    // Wait for the real GPU submission; no desktop window is presented.
    let deadline = Date().addingTimeInterval(2)
    while latestTime(contents) < 0 && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThanOrEqual(latestTime(contents), 0,
      "An empty Metal layer does not prevent Stage Manager's frozen transition")
    XCTAssertFalse(window.isVisible)
  }

  func testLiveResizeDoesNotLeaveTheDesktopSurfaceFlattenable() async throws {
    let window = makeWindow()
    defer { window.close() }
    try await assertLiveSurfaces(window)
    try invokeLiveResize("_startLiveResize", on: window)
    window.setScreenFrame(NSRect(x: 0, y: 0, width: 240, height: 180))
    try invokeLiveResize("_endLiveResize", on: window)
    try await assertLiveSurfaces(window)
  }

  func testPreservingLiveSurfacesLeavesOtherWindowPoliciesIntact() async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(20))
    let before = try readTags(window)
    WebWallpaperWindowComposition.preserveLiveSurfaces(in: window)
    try await assertLiveSurfaces(window)
    let after = try readTags(window)
    XCTAssertEqual(after[0], before[0], "Input and window-management policy are preserved")
    XCTAssertEqual(after[1] & ~(1 << 23), before[1] & ~(1 << 23))
  }

  private func assertLiveSurfaces(_ window: NSWindow, file: StaticString = #filePath,
                                  line: UInt = #line) async throws {
    // WindowServer applies tag changes after AppKit flushes its transaction.
    // An immediate read can incorrectly report the original policy.
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(20))
    CATransaction.flush()
    let deadline = Date().addingTimeInterval(2)
    var tags = try readTags(window)
    while tags[1] & (1 << 23) == 0 && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
      tags = try readTags(window)
    }
    XCTAssertNotEqual(tags[1] & (1 << 23), 0,
      "WindowServer must keep the live layer surfaces during desktop transitions (tag 55)",
      file: file, line: line)
    XCTAssertFalse(window.isVisible, "This regression never presents a desktop window", file: file, line: line)
  }

  private func invokeLiveResize(_ name: String, on window: NSWindow) throws {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(NSWindow.self, selector),
          let encoding = method_getTypeEncoding(method),
          String(cString: encoding) == "v16@0:8"
    else { throw XCTSkip("AppKit live-resize test entry point is unavailable") }
    typealias Invoke = @convention(c) (AnyObject, Selector) -> Void
    unsafeBitCast(method_getImplementation(method), to: Invoke.self)(window, selector)
  }

  private func readTags(_ window: NSWindow) throws -> [UInt32] {
    typealias Connection = @convention(c) () -> Int32
    typealias Read = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt32>, Int32) -> Int32
    guard let framework = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    else { throw XCTSkip("WindowServer tag inspection is unavailable") }
    defer { dlclose(framework) }
    guard let connectionSymbol = dlsym(framework, "SLSMainConnectionID"),
          let readSymbol = dlsym(framework, "SLSGetWindowTags")
    else { throw XCTSkip("WindowServer tag inspection is unavailable") }
    let connection = unsafeBitCast(connectionSymbol, to: Connection.self)
    let read = unsafeBitCast(readSymbol, to: Read.self)
    var tags = [UInt32](repeating: 0, count: 2)
    let result = read(connection(), UInt32(window.windowNumber), &tags, 64)
    XCTAssertEqual(result, 0, "WindowServer must acknowledge the policy read")
    return tags
  }
}
