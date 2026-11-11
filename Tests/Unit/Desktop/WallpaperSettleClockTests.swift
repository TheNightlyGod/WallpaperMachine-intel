import XCTest

@testable import WallpaperMachine

/// How long a display's wallpaper has played where it can be seen: only presenting time counts, and
/// a new wallpaper, window or files start the count again.
@MainActor
final class WallpaperSettleClockTests: XCTestCase {
  private var time = ContinuousClock.now
  private let sleeper = ManualSleeper()
  private lazy var clock = WallpaperSettleClock(now: { [unowned self] in self.time }, sleep: sleeper.closure)
  private let lake = WallpaperSettleClock.Identity(wallpaperID: "lake", window: 10, contentRevision: 1)

  private func show(_ identity: WallpaperSettleClock.Identity?, presenting: Bool, on display: UInt32 = 1) {
    clock.observe(identity.map { [display: .init(identity: $0, presenting: presenting)] } ?? [:])
  }

  func testAWallpaperSettlesAfterPlayingAWholeWindowWhereItCanBeSeen() {
    XCTAssertNil(clock.played(1))
    XCTAssertFalse(clock.isSettled(1))
    show(lake, presenting: true)
    time += .seconds(10)
    XCTAssertFalse(clock.isSettled(1))
    XCTAssertEqual(clock.remaining(1), WallpaperSettleClock.window - .seconds(10))
    time += .seconds(5)
    XCTAssertTrue(clock.isSettled(1))
    XCTAssertNil(clock.remaining(1), "nothing to wait for")
  }

  func testTimeWhileCoveredOrPausedDoesNotCountAndPlayingOnResumesTheCount() {
    show(lake, presenting: true)
    time += .seconds(2)
    show(lake, presenting: false)
    time += .seconds(600)
    XCTAssertEqual(clock.played(1), .seconds(2), "a covered wallpaper does not move on")
    XCTAssertFalse(clock.isSettled(1))
    XCTAssertNil(clock.remaining(1), "waiting changes nothing while it does not play")

    show(lake, presenting: true)
    time += .seconds(13)
    XCTAssertEqual(clock.played(1), .seconds(15))
    XCTAssertTrue(clock.isSettled(1))

    // Reported again with nothing changed: the count goes on.
    show(lake, presenting: true)
    time += .seconds(1)
    XCTAssertEqual(clock.played(1), .seconds(16))
  }

  func testANewWallpaperWindowOrFilesStartTheCountAgain() {
    for next in [
      WallpaperSettleClock.Identity(wallpaperID: "rain", window: 10, contentRevision: 1),
      WallpaperSettleClock.Identity(wallpaperID: "lake", window: 11, contentRevision: 1),
      WallpaperSettleClock.Identity(wallpaperID: "lake", window: 10, contentRevision: 2),
    ] {
      show(lake, presenting: true)
      time += .seconds(60)
      XCTAssertTrue(clock.isSettled(1))
      show(next, presenting: true)
      XCTAssertEqual(clock.played(1), .zero, "\(next)")
      show(nil, presenting: false)
    }
  }

  func testADisplayWithoutAWallpaperWindowIsForgotten() {
    show(lake, presenting: true)
    time += .seconds(60)
    show(lake, presenting: true, on: 2)
    XCTAssertNil(clock.played(1))
    XCTAssertFalse(clock.isSettled(1))
    XCTAssertEqual(clock.played(2), .zero, "the other display counts on its own")
  }

  /// A wallpaper the panel covers does not move on, so the preview waits for it to play: the wait
  /// ends when it plays again, and again when it has played the rest of the window.
  func testAWaitEndsWhenTheWallpaperPlaysAgainAndWhenItSettles() async {
    show(lake, presenting: true)
    time += .seconds(2)
    show(lake, presenting: false)

    let resumed = Task { await clock.nextChange(of: 1) }
    while clock.waiting == 0 { await Task.yield() }
    XCTAssertEqual(sleeper.pendingCount, 0, "no alarm while it does not play")
    show(lake, presenting: true)
    await resumed.value

    let settled = Task { await clock.nextChange(of: 1) }
    await sleeper.waitUntilPending()
    XCTAssertEqual(sleeper.requested.last, WallpaperSettleClock.window - .seconds(2), "the rest of the window")
    time += .seconds(13)
    sleeper.fireNext()
    await settled.value
    XCTAssertTrue(clock.isSettled(1))
  }

  func testAWaitEndsWhenTheWallpaperIsReplacedOrTheTaskIsCancelled() async {
    show(lake, presenting: false)
    let replaced = Task { await clock.nextChange(of: 1) }
    while clock.waiting == 0 { await Task.yield() }
    show(.init(wallpaperID: "rain", window: 10, contentRevision: 1), presenting: false)
    await replaced.value

    let cancelled = Task { await clock.nextChange(of: 1) }
    while clock.waiting == 0 { await Task.yield() }
    cancelled.cancel()
    await cancelled.value
    while clock.waiting > 0 { await Task.yield() }
  }
}
