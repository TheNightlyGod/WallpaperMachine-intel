import WebKit
import XCTest

@testable import WallpaperMachine

/// Host-side suspension for pages that do not cooperate. The Wallpaper Engine
/// `setPaused` callback is optional, so a page can ignore it and keep its
/// timers, workers and media running; what the host controls instead is media
/// playback and whether the web view is in the window tree at all. Both
/// presentation suspension and a paused wallpaper (user Play/Pause or battery
/// Pause) take that path, the latter once the page has had its first-frame grace.
///
/// The page used here deliberately implements no `wallpaperPropertyListener`.
@MainActor
final class WebWallpaperSuspensionTests: XCTestCase {
  private var project: URL!

  /// Lets a test decide when the first-frame grace elapses, and counts the
  /// graces that began.
  private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0

    func pass() async {
      started += 1
      guard !isOpen else { return }
      await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
      isOpen = true
      for continuation in waiting { continuation.resume() }
      waiting.removeAll()
    }
  }

  /// Hands the graces a page starts to a test one gate at a time, in order, so
  /// the first can end while the second is held open.
  private actor GraceSequence {
    private let gates: [Gate]
    private var next = 0

    init(_ gates: [Gate]) { self.gates = gates }

    func pass() async {
      let gate = gates[min(next, gates.count - 1)]
      next += 1
      await gate.pass()
    }
  }

  private static let noGrace = WebWallpaperPage.Timing(firstFrameGrace: .zero)

  /// Supplies WebKit's visibility input without ordering a desktop window.
  private final class VisibilityWindow: NSWindow {
    var covered = false {
      didSet {
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
      }
    }
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { covered ? [] : .visible }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-suspension-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    // No pause listener at all: rAF, interval and CSS keep advancing until the
    // host stops them from the outside.
    try """
      <!doctype html><html><head><style>
      @keyframes spin { from { opacity: 0 } to { opacity: 1 } }
      #anim { animation: spin 100ms infinite; width: 10px; height: 10px; background: red }
      </style></head>
      <body style="margin:0;background:#123456"><div id="anim"></div>
      <script>
      // Every event also records its wall-clock time, so a test can count only
      // what ran while the web view was out of the window.
      window.__ticks = { frames: 0, intervals: 0, iterations: 0, at: { frames: [], intervals: [], iterations: [] } };
      const note = kind => {
        window.__ticks[kind]++;
        if (window.__ticks.at[kind].length < 4000) window.__ticks.at[kind].push(Date.now());
      };
      const step = () => { note('frames'); requestAnimationFrame(step); };
      requestAnimationFrame(step);
      setInterval(() => note('intervals'), 10);
      document.getElementById('anim').addEventListener('animationiteration', () => note('iterations'));
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  /// A page hosted in a container view the way `WebWallpaperWindow` does, but
  /// without opening a desktop window.
  private func hostedPage(
    counters: RuntimeCounters? = nil, timing: WebWallpaperPage.Timing = WebWallpaperPage.Timing(),
    wait: (@Sendable (Duration) async throws -> Void)? = nil
  ) -> (WebWallpaperPage, NSView) {
    let page = WebWallpaperPage(
      projectURL: project, entryFile: "index.html",
      surface: RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4), counters: counters,
      timing: timing, wait: wait)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    container.wantsLayer = true
    page.attach(to: container)
    return (page, container)
  }

  func testSuspensionTakesTheWebViewOutOfTheViewTreeAndBringsItBack() async throws {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let (page, container) = hostedPage(counters: counters)
    page.load()
    try await waitUntilLoaded(page)
    XCTAssertTrue(page.isInWindowTree)

    page.setPresentationSuspended(true)
    try await poll { !page.isInWindowTree }
    XCTAssertFalse(
      page.isInWindowTree,
      "WebKit's inactive scheduling policy keys off not being in a window")
    XCTAssertTrue(
      container.subviews.contains { $0 is NSImageView },
      "a placeholder keeps the last frame on screen while the page is detached")
    XCTAssertNotNil(container.layer, "the poster sync identifies this surface by the container layer")

    let generation = page.documentGeneration
    page.setPresentationSuspended(false)
    XCTAssertTrue(page.isInWindowTree)
    XCTAssertFalse(container.subviews.contains { $0 is NSImageView })
    XCTAssertEqual(
      page.documentGeneration, generation,
      "suspension must not reload the document, which would lose its JS state")
    XCTAssertTrue(page.isLoaded, "the same document is still the loaded one")

    let snapshot = counters.snapshot()
    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4)
    XCTAssertEqual(snapshot.value(.webMediaSuspended, for: surface), 1)
    XCTAssertEqual(snapshot.value(.webMediaResumed, for: surface), 1)
    XCTAssertEqual(snapshot.value(.webDetached, for: surface), 1)
    XCTAssertEqual(snapshot.value(.webAttached, for: surface), 1)
  }

  func testTransientOcclusionDoesNotInterruptAnUnsuspendedPage() async throws {
    let (page, container) = hostedPage()
    let window = VisibilityWindow(
      contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer {
      page.stop()
      window.contentView = nil
      window.close()
    }
    page.load()
    try await waitUntilLoaded(page)
    try await poll { (try? await self.frames(page)) ?? 0 > 2 }
    let running = try await frames(page)
    XCTAssertGreaterThan(running, 2, "the fixture must be animating before its window is covered")
    let generation = page.documentGeneration

    // A Space transition can briefly occlude the window without the host ever
    // suspending it. WebKit must not make an independent pause decision.
    window.covered = true
    try await Task.sleep(for: .milliseconds(100))
    let coveredStart = try await frames(page)
    try await Task.sleep(for: .milliseconds(300))
    let coveredEnd = try await frames(page)
    XCTAssertGreaterThan(coveredEnd, coveredStart + 1, "the host still permits this page to animate")

    window.covered = false
    try await Task.sleep(for: .milliseconds(150))
    let revealed = try await frames(page)
    XCTAssertGreaterThan(revealed, coveredEnd)
    XCTAssertEqual(page.documentGeneration, generation)
  }

  // A page that implements no pause listener cannot be asked to stop, and once
  // its web view leaves the window tree WebKit stops running its script — so a
  // detached page cannot be asked anything either. The measured test below
  // counts what the page's own work does while the view is out of the window.

  // MARK: - pause (user Play/Pause, battery Pause)

  func testUserPauseSuspendsAPageWithoutAListenerAndResumeRestoresIt() async throws {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let (page, container) = hostedPage(counters: counters, timing: Self.noGrace)
    page.load()
    try await waitUntilLoaded(page)
    XCTAssertTrue(page.isInWindowTree)
    let generation = page.documentGeneration

    page.setPaused(true)
    XCTAssertTrue(page.hostSuspended, "a page that ignores setPaused still has to stop")
    try await poll { !page.isInWindowTree && page.suspensionPoster != nil }
    XCTAssertFalse(page.isInWindowTree)
    XCTAssertTrue(
      container.subviews.contains { $0 is NSImageView },
      "a placeholder keeps the last frame on screen while the page is detached")
    XCTAssertNotNil(page.suspensionPoster, "the detach frame is kept for the desktop poster sync")
    XCTAssertEqual(page.documentGeneration, generation)

    page.setPaused(false)
    XCTAssertFalse(page.hostSuspended)
    XCTAssertTrue(page.isInWindowTree)
    XCTAssertFalse(container.subviews.contains { $0 is NSImageView })
    XCTAssertNil(page.suspensionPoster, "an attached page owes nobody a stale poster")
    XCTAssertEqual(page.documentGeneration, generation, "pausing must not reload the document")

    let snapshot = counters.snapshot()
    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4)
    XCTAssertEqual(snapshot.value(.webMediaSuspended, for: surface), 1)
    XCTAssertEqual(snapshot.value(.webMediaResumed, for: surface), 1)
    XCTAssertEqual(snapshot.value(.webDetached, for: surface), 1)
    XCTAssertEqual(snapshot.value(.webAttached, for: surface), 1)
  }

  func testUserPauseWaitsForTheFirstFrameWindow() async throws {
    let gate = Gate()
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let (page, container) = hostedPage(
      counters: counters, timing: WebWallpaperPage.Timing(firstFrameGrace: .seconds(3)),
      wait: { _ in await gate.pass() })
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    page.load()
    try await waitUntilLoaded(page)

    page.setPaused(true)
    XCTAssertFalse(page.hostSuspended, "didFinish precedes the first paint, so a fresh page keeps running")
    XCTAssertTrue(page.isInWindowTree)

    await gate.open()
    try await poll { page.hostSuspended }
    XCTAssertTrue(page.hostSuspended, "the grace expiring suspends a page that is still paused")
    try await poll { !page.isInWindowTree }
    XCTAssertFalse(page.isInWindowTree)
    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4)
    XCTAssertEqual(counters.snapshot().value(.webMediaSuspended, for: surface), 1)
  }

  func testAPauseThatEndsBeforeTheFirstFrameWindowNeverDetaches() async throws {
    let gate = Gate()
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let (page, container) = hostedPage(
      counters: counters, timing: WebWallpaperPage.Timing(firstFrameGrace: .seconds(3)),
      wait: { _ in await gate.pass() })
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    page.load()
    try await waitUntilLoaded(page)

    page.setPaused(true)
    page.setPaused(false)
    await gate.open()
    // The grace has expired once a fresh pause suspends at once; polling asks
    // again until it does.
    try await poll {
      page.setPaused(true)
      return page.hostSuspended
    }
    XCTAssertTrue(page.hostSuspended)
    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4)
    XCTAssertEqual(
      counters.snapshot().value(.webMediaSuspended, for: surface), 1,
      "only the pause after the grace suspends; the earlier one ended first")
  }

  func testUserPauseAndPresentationSuspensionCompose() async throws {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let (page, container) = hostedPage(counters: counters, timing: Self.noGrace)
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    page.load()
    try await waitUntilLoaded(page)

    page.setPresentationSuspended(true)
    page.setPaused(true)
    page.setPresentationSuspended(false)
    XCTAssertTrue(page.hostSuspended, "the user's pause outlives the presentation resuming")
    page.setPaused(false)
    XCTAssertFalse(page.hostSuspended)

    page.setPaused(true)
    page.setPresentationSuspended(true)
    page.setPaused(false)
    XCTAssertTrue(page.hostSuspended, "a covered display stays suspended after the user plays")
    page.setPresentationSuspended(false)
    XCTAssertFalse(page.hostSuspended)

    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4)
    XCTAssertEqual(
      counters.snapshot().value(.webMediaSuspended, for: surface), 2,
      "overlapping reasons suspend media once, not once per reason")
    XCTAssertEqual(counters.snapshot().value(.webMediaResumed, for: surface), 2)
  }

  func testAPageUserPausedBeforeItsFirstLoadStillLoadsAndPaints() async throws {
    let gate = Gate()
    let (page, container) = hostedPage(
      timing: WebWallpaperPage.Timing(firstFrameGrace: .seconds(3)), wait: { _ in await gate.pass() })
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    page.setPaused(true)
    XCTAssertFalse(page.hostSuspended, "a wallpaper applied while paused still has to load")
    XCTAssertTrue(page.isInWindowTree)

    page.load()
    try await waitUntilLoaded(page)
    XCTAssertTrue(page.isInWindowTree, "the view stays in the window until the first frame has had its time")
    XCTAssertFalse(page.hostSuspended)

    await gate.open()
    try await poll { page.hostSuspended }
    XCTAssertTrue(page.hostSuspended, "and is suspended once it has drawn")
  }

  /// A page that finished loading while covered has drawn nothing, and a covered
  /// page does not draw. If the grace ran out of sight, a paused page would stay
  /// detached on a blank frame the moment it was uncovered.
  func testTheFirstFrameWindowOnlyRunsWhileThePageIsInTheWindow() async throws {
    let gate = Gate()
    await gate.open()  // any grace that starts ends at once
    let (page, container) = hostedPage(
      timing: WebWallpaperPage.Timing(firstFrameGrace: .seconds(3)), wait: { _ in await gate.pass() })
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    page.setPresentationSuspended(true)
    page.setPaused(true)
    page.load()
    try await waitUntilLoaded(page)
    // Nothing to wait for if the grace is correctly not running; give a wrongly
    // started one the turns it needs to end.
    try await Task.sleep(for: .milliseconds(100))
    let startedWhileCovered = await gate.started
    XCTAssertEqual(startedWhileCovered, 0, "no frame can be drawn while the page is out of the window")

    page.setPresentationSuspended(false)
    XCTAssertFalse(page.hostSuspended, "uncovered, the paused page still owes its first frame")
    XCTAssertTrue(page.isInWindowTree)

    try await poll { page.hostSuspended }
    XCTAssertTrue(page.hostSuspended, "and is suspended once the grace has run in the window")
    let started = await gate.started
    XCTAssertEqual(started, 1)
  }

  // MARK: - suspension of a display that is still in sight

  /// "Only play on the display I'm using" suspends a display the user can see. A
  /// page created there has painted nothing, so detaching it at once would leave
  /// the display black and the desktop picture of its Space blank.
  func testADisplaySuspendedWhileStillInSightGivesItsPageTheFirstFrameBeforeDetaching() async throws {
    let gate = Gate()
    let (page, container) = hostedPage(
      timing: WebWallpaperPage.Timing(firstFrameGrace: .seconds(3)), wait: { _ in await gate.pass() })
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    // As the host applies a wallpaper to a display that is already paused: the
    // suspension first, then the bridge's composed pause, then the load.
    page.setPresentationSuspended(true, stillVisible: true)
    page.setPaused(true)
    XCTAssertFalse(page.hostSuspended, "a display in sight is not hidden, so the page is not detached unloaded")
    XCTAssertTrue(page.isInWindowTree)

    page.load()
    try await waitUntilLoaded(page)
    XCTAssertFalse(page.hostSuspended, "didFinish precedes the first paint")
    XCTAssertTrue(page.isInWindowTree)

    await gate.open()
    try await poll { page.hostSuspended }
    XCTAssertTrue(page.hostSuspended, "and the page is suspended once it has drawn")
    XCTAssertTrue(page.isLoaded)
    try await poll { !page.isInWindowTree && page.suspensionPoster != nil }
    XCTAssertFalse(page.isInWindowTree)
    XCTAssertNotNil(page.suspensionPoster, "the frame it drew stays on the display and answers the poster sync")
  }

  /// A hidden display needs no frame: its page is detached at once, grace or not.
  func testASuspensionThatHidesTheDisplayDetachesTheUnsettledPageAtOnce() async throws {
    let gate = Gate()
    let (page, container) = hostedPage(
      timing: WebWallpaperPage.Timing(firstFrameGrace: .seconds(3)), wait: { _ in await gate.pass() })
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    page.load()
    try await waitUntilLoaded(page)

    page.setPresentationSuspended(true, stillVisible: false)
    XCTAssertTrue(page.hostSuspended, "nothing can reach the display, so the grace has nothing to wait for")
    try await poll { !page.isInWindowTree }
    XCTAssertFalse(page.isInWindowTree)
  }

  /// Walking back to the display during its grace finds a page that never left.
  func testResumingADisplayInSightDuringTheGraceNeverDetachesItsPage() async throws {
    let gate = Gate()
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let (page, container) = hostedPage(
      counters: counters, timing: WebWallpaperPage.Timing(firstFrameGrace: .seconds(3)),
      wait: { _ in await gate.pass() })
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    page.setPresentationSuspended(true, stillVisible: true)
    page.setPaused(true)
    page.load()
    try await waitUntilLoaded(page)

    page.setPresentationSuspended(false)
    page.setPaused(false)
    XCTAssertFalse(page.hostSuspended)
    XCTAssertTrue(page.isInWindowTree)

    await gate.open()
    // The grace has expired once a fresh suspension takes hold at once; polling
    // asks again until it does.
    try await poll {
      page.setPresentationSuspended(true, stillVisible: true)
      return page.hostSuspended
    }
    XCTAssertTrue(page.hostSuspended)
    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4)
    XCTAssertEqual(
      counters.snapshot().value(.webMediaSuspended, for: surface), 1,
      "only the suspension after the grace took hold; the earlier one ended first")
  }

  // MARK: - changes shown while paused

  /// The first grace ends once the test opens `first`; the one a change starts
  /// is held by `second` so the test can look at the page inside it.
  private func pausedAndDetachedPage(
    first: Gate, second: Gate, properties: String? = nil
  ) async throws -> (WebWallpaperPage, NSView) {
    let graces = GraceSequence([first, second])
    let (page, container) = hostedPage(
      timing: WebWallpaperPage.Timing(firstFrameGrace: .seconds(3)), wait: { _ in await graces.pass() })
    if let properties { page.applyUserProperties(json: properties) }
    page.load()
    try await waitUntilLoaded(page)
    page.setPaused(true)
    await first.open()
    try await poll { page.hostSuspended }
    try await poll { !page.isInWindowTree && page.suspensionPoster != nil }
    XCTAssertTrue(page.hostSuspended)
    XCTAssertFalse(page.isInWindowTree)
    XCTAssertNotNil(page.suspensionPoster)
    return (page, container)
  }

  /// A detached page cannot run what it is told, and the desktop would keep the
  /// frame from before the edit until the user plays. The change gets the grace
  /// again, in the window, and the page is detached with the frame it drew.
  func testAChangeToAPausedPageIsDrawnInTheWindowAndThePosterIsRefreshed() async throws {
    let first = Gate()
    let second = Gate()
    let (page, container) = try await pausedAndDetachedPage(first: first, second: second)
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    let earlier = try XCTUnwrap(page.suspensionPoster)
    var refreshed = 0
    page.onSuspensionPosterRefreshed = { refreshed += 1 }

    page.applyUserProperties(json: #"{"theme":{"value":"dark"}}"#)
    XCTAssertFalse(page.hostSuspended, "a change is shown, not queued behind a suspended page")
    XCTAssertTrue(page.isInWindowTree)
    XCTAssertNil(page.suspensionPoster, "an attached page owes nobody a stale poster")

    // The fixture has no listener; the host script replays what it received to
    // one that registers later, which exposes whether the call ran inside the window.
    let received = try await themeSeenByALateListener(page)
    XCTAssertEqual(received, "dark")
    XCTAssertEqual(refreshed, 0, "the frame is only read once the page has had its time")

    await second.open()
    try await poll { page.hostSuspended }
    try await poll { !page.isInWindowTree && page.suspensionPoster != nil }
    XCTAssertTrue(page.suspensionPoster !== earlier, "the page is detached with a frame taken after the change")
    try await poll { refreshed == 1 }
    XCTAssertEqual(refreshed, 1, "the host is told once, so the Space posters follow the edit")
  }

  /// The host resends a descriptor's properties on every apply that touches them;
  /// a payload the page already holds shows nothing new.
  func testAnUnchangedPayloadDoesNotWakeAPausedPage() async throws {
    let payload = #"{"theme":{"value":"dark"}}"#
    let first = Gate()
    let second = Gate()
    let (page, container) = try await pausedAndDetachedPage(first: first, second: second, properties: payload)
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly

    page.applyUserProperties(json: payload)
    XCTAssertTrue(page.hostSuspended)
    XCTAssertFalse(page.isInWindowTree)
  }

  /// The staged path of a reselected file does not change, so the payload is the
  /// same text; the new bytes are what the page has to be shown.
  func testARestagedFileWakesAPausedPageThoughItsPayloadIsUnchanged() async throws {
    let payload = #"{"cover":{"type":"file","value":"p/cover.png"}}"#
    let first = Gate()
    let second = Gate()
    let (page, container) = try await pausedAndDetachedPage(first: first, second: second, properties: payload)
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly

    page.applyUserProperties(json: payload, restaged: ["cover"])
    XCTAssertFalse(page.hostSuspended, "the new content is drawn in the window, not queued behind a suspended page")
    XCTAssertTrue(page.isInWindowTree)

    await second.open()
    try await poll { page.hostSuspended }
    XCTAssertTrue(page.hostSuspended, "and the page is suspended again with the frame it drew")
  }

  /// A covered page draws nothing, so the change is shown once the cover ends.
  func testAChangeToAPausedAndCoveredPageIsShownWhenTheCoverEnds() async throws {
    let first = Gate()
    let second = Gate()
    let (page, container) = try await pausedAndDetachedPage(first: first, second: second)
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly

    page.setPresentationSuspended(true)
    page.applyUserProperties(json: #"{"theme":{"value":"dark"}}"#)
    XCTAssertTrue(page.hostSuspended, "covered, the page stays where it is")
    XCTAssertFalse(page.isInWindowTree)

    page.setPresentationSuspended(false)
    XCTAssertFalse(page.hostSuspended, "uncovered, the change that waited is drawn")
    XCTAssertTrue(page.isInWindowTree)

    await second.open()
    try await poll { page.hostSuspended }
    XCTAssertTrue(page.hostSuspended, "and the page is suspended again after it")
  }

  /// A playing page takes its changes as it always did.
  func testAChangeToAPlayingPageNeverDetachesIt() async throws {
    let (page, container) = hostedPage(timing: Self.noGrace)
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    page.load()
    try await waitUntilLoaded(page)

    page.applyUserProperties(json: #"{"theme":{"value":"dark"}}"#)
    XCTAssertFalse(page.hostSuspended)
    XCTAssertTrue(page.isInWindowTree)
  }

  func testReloadingASuspendedPausedPageBringsItBackToLoadAndSuspendsItAgain() async throws {
    let (page, container) = hostedPage(timing: Self.noGrace)
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    page.load()
    try await waitUntilLoaded(page)
    page.setPaused(true)
    try await poll { !page.isInWindowTree }
    XCTAssertFalse(page.isInWindowTree)

    page.load()
    XCTAssertTrue(page.isInWindowTree, "a detached view cannot finish loading a document")
    XCTAssertFalse(page.hostSuspended)
    try await waitUntilLoaded(page)
    XCTAssertTrue(page.hostSuspended, "it is paused again as soon as the new document has had its frame")
    try await poll { !page.isInWindowTree }
    XCTAssertFalse(page.isInWindowTree)
  }

  func testACrashedSuspendedPageRestartsInTheWindowAndIsSuspendedAgain() async throws {
    // The wait stands in for the restart backoff; the grace is zero and never waits.
    let (page, container) = hostedPage(timing: Self.noGrace, wait: { _ in })
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    page.load()
    try await waitUntilLoaded(page)
    page.setPaused(true)
    try await poll { !page.isInWindowTree }
    XCTAssertFalse(page.isInWindowTree)

    page.webViewWebContentProcessDidTerminate(page.webView)
    XCTAssertTrue(page.isInWindowTree, "the restart loads into the window tree")
    XCTAssertFalse(page.hostSuspended)
    try await poll { page.isLoaded && page.hostSuspended }
    XCTAssertTrue(page.isLoaded)
    XCTAssertTrue(page.hostSuspended, "the paused page is suspended again after its next first frame")
  }

  /// Apply pushes new values into a paused wallpaper too; a detached page cannot
  /// run them, so they have to arrive when it comes back rather than be lost.
  func testPropertiesAppliedToAPausedDetachedPageReachItWhenItPlaysAgain() async throws {
    let (page, container) = hostedPage(timing: Self.noGrace)
    defer { withExtendedLifetime(container) {} }  // the page holds its container weakly
    page.load()
    try await waitUntilLoaded(page)
    page.setPaused(true)
    try await poll { !page.isInWindowTree }
    XCTAssertFalse(page.isInWindowTree)

    page.applyUserProperties(json: #"{"theme":{"value":"dark"}}"#)
    page.setPaused(false)
    // The fixture has no listener; the host script replays what it received to
    // one that registers later, which exposes whether the call ever ran.
    let received = try await themeSeenByALateListener(page)
    XCTAssertEqual(received, "dark")
  }

  /// The claim behind the whole feature, measured rather than assumed: with its
  /// view out of the window tree a page that implements no pause listener runs
  /// no frames, timers or CSS animation, and runs them again afterwards. The
  /// page stamps each event with wall-clock time; only events inside the
  /// detached interval count, so latency around the resume cannot colour it.
  func testUserPauseStopsFramesTimersAndCSSOfAPageWithoutAListener() async throws {
    let (page, container) = hostedPage(timing: Self.noGrace)
    let window = VisibilityWindow(
      contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer {
      page.stop()
      window.contentView = nil
      window.close()
    }
    page.load()
    try await waitUntilLoaded(page)
    try await poll {
      guard let ticks = try? await self.ticks(page) else { return false }
      return ticks.frames > 5 && ticks.intervals > 10 && ticks.iterations >= 2
    }
    let running = try await ticks(page)
    XCTAssertGreaterThan(running.frames, 5, "the fixture must be animating before it is paused")
    XCTAssertGreaterThan(running.intervals, 10)
    XCTAssertGreaterThanOrEqual(running.iterations, 2)

    page.setPaused(true)
    try await poll { !page.isInWindowTree }
    XCTAssertFalse(page.isInWindowTree)
    // Work already queued when the view left the window may still finish.
    try await Task.sleep(for: .milliseconds(100))
    let detachedFrom = Date().timeIntervalSince1970 * 1000
    try await Task.sleep(for: .milliseconds(500))
    let detachedTo = Date().timeIntervalSince1970 * 1000
    page.setPaused(false)
    XCTAssertTrue(page.isInWindowTree)

    let afterResume = try await ticks(page)
    func duringPause(_ stamps: [Double]) -> Int {
      stamps.filter { $0 > detachedFrom && $0 < detachedTo }.count
    }
    XCTAssertLessThanOrEqual(
      duringPause(afterResume.frameTimes), 3, "requestAnimationFrame kept running while paused")
    XCTAssertLessThanOrEqual(
      duringPause(afterResume.intervalTimes), 5, "a 10 ms timer kept running while paused")
    XCTAssertLessThanOrEqual(
      duringPause(afterResume.iterationTimes), 2, "a CSS animation kept running while paused")

    let resumedFrom = afterResume.frames
    try await poll {
      guard let ticks = try? await self.ticks(page) else { return false }
      return ticks.frames > resumedFrom + 3
    }
    let resumed = try await ticks(page)
    XCTAssertGreaterThan(resumed.frames, resumedFrom + 3, "the page runs again once it plays")
  }

  func testRepeatedSuspendAndResumeSettlesAttached() async throws {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let (page, container) = hostedPage(counters: counters)
    page.load()
    try await waitUntilLoaded(page)

    for _ in 0..<6 {
      page.setPresentationSuspended(true)
      page.setPresentationSuspended(false)
    }
    // The detach poster is asynchronous; a resume that overtakes it must not
    // leave the page out of the tree or leave a placeholder behind.
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(page.isInWindowTree, "flapping visibility must settle attached")
    XCTAssertFalse(container.subviews.contains { $0 is NSImageView })

    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4)
    XCTAssertEqual(counters.snapshot().value(.webMediaSuspended, for: surface), 6)
    XCTAssertEqual(counters.snapshot().value(.webMediaResumed, for: surface), 6)
  }

  func testASuspendedPageReceivesNoPointerEvents() async throws {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let (page, _) = hostedPage(counters: counters)
    page.load()
    try await waitUntilLoaded(page)

    let event = NSEvent.mouseEvent(
      with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
      eventNumber: 1, clickCount: 1, pressure: 0)!
    page.deliverMouse(event)
    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 4)
    XCTAssertEqual(counters.snapshot().value(.pointerDelivered, for: surface), 1)

    page.setPresentationSuspended(true)
    page.deliverMouse(event)
    page.deliverMouse(event)
    XCTAssertEqual(
      counters.snapshot().value(.pointerDelivered, for: surface), 1,
      "a suspended page consumes no pointer input")

    page.setPresentationSuspended(false)
    page.deliverMouse(event)
    XCTAssertEqual(counters.snapshot().value(.pointerDelivered, for: surface), 2)
  }

  func testSuspendingBeforeTheFirstLoadDoesNotAttachThePage() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.setPresentationSuspended(true)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    page.attach(to: container)
    XCTAssertFalse(
      page.isInWindowTree,
      "a surface that is already hidden must not start by rendering into a window")

    page.setPresentationSuspended(false)
    XCTAssertTrue(page.isInWindowTree)
  }

  // MARK: - helpers

  private struct Ticks {
    var frames: Int
    var intervals: Int
    var iterations: Int
    var frameTimes: [Double]
    var intervalTimes: [Double]
    var iterationTimes: [Double]
  }

  private func ticks(_ page: WebWallpaperPage) async throws -> Ticks {
    let value = try await page.webView.callAsyncJavaScript(
      "return window.__ticks", arguments: [:], in: nil, contentWorld: .page)
    let ticks = try XCTUnwrap(value as? [String: Any])
    let at = try XCTUnwrap(ticks["at"] as? [String: Any])
    return Ticks(
      frames: try XCTUnwrap(ticks["frames"] as? Int),
      intervals: try XCTUnwrap(ticks["intervals"] as? Int),
      iterations: try XCTUnwrap(ticks["iterations"] as? Int),
      frameTimes: (at["frames"] as? [Double]) ?? [],
      intervalTimes: (at["intervals"] as? [Double]) ?? [],
      iterationTimes: (at["iterations"] as? [Double]) ?? [])
  }

  private func frames(_ page: WebWallpaperPage) async throws -> Int {
    let value = try await page.webView.callAsyncJavaScript(
      "return window.__ticks.frames", arguments: [:], in: nil, contentWorld: .page)
    return try XCTUnwrap(value as? Int)
  }

  /// Registers a listener once and waits for the `theme` value the host script hands it.
  private func themeSeenByALateListener(_ page: WebWallpaperPage) async throws -> String? {
    _ = try await page.webView.callAsyncJavaScript(
      "window.wallpaperPropertyListener = { applyUserProperties(p) { window.__theme = p.theme && p.theme.value; } };",
      arguments: [:], in: nil, contentWorld: .page)
    var theme: String?
    try await poll {
      theme = try? await page.webView.callAsyncJavaScript(
        "return window.__theme ?? null", arguments: [:], in: nil, contentWorld: .page) as? String
      return theme != nil
    }
    return theme
  }

  private func waitUntilLoaded(_ page: WebWallpaperPage, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)
  }

  private func poll(
    timeout: TimeInterval = 5, until condition: () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}
