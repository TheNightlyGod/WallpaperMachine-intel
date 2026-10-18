import XCTest

@testable import WallpaperMachine

/// When Discover's animated previews load: after every still has settled, only for tiles on screen
/// whose still arrived, six at a time in grid order, released when hidden or scrolled away, and
/// never retried once one failed.
final class LivePreviewSchedulerTests: XCTestCase {
  private func tile(
    _ id: String, onScreen: Bool = true, animation: Bool = true, still: Bool = true
  ) -> LivePreviewScheduler.Tile {
    .init(id: id, isOnScreen: onScreen, hasAnimation: animation, hasStill: still)
  }

  func testNothingLoadsUntilEveryStillOnThePageHasSettled() {
    var scheduler = LivePreviewScheduler()
    let tiles = [tile("a"), tile("b")]
    scheduler.update(tiles: tiles, stillsSettled: false, isHidden: false)
    XCTAssertTrue(scheduler.states.isEmpty, "no animation is wanted while a still is still arriving")
    scheduler.update(tiles: tiles, stillsSettled: true, isHidden: false)
    XCTAssertTrue(scheduler.isAttached("a"))
    XCTAssertTrue(scheduler.isAttached("b"))
    XCTAssertFalse(scheduler.isPlaying("a"), "loading is not playing")
    scheduler.finish("a", loaded: true)
    XCTAssertTrue(scheduler.isPlaying("a"))
  }

  func testOnlyATileThatIsOnScreenWithAnAnimationAndAStillIsWanted() {
    var scheduler = LivePreviewScheduler()
    scheduler.update(
      tiles: [
        tile("far", onScreen: false), tile("plain", animation: false), tile("blank", still: false),
        tile("ok"),
      ], stillsSettled: true, isHidden: false)
    XCTAssertEqual(Set(scheduler.states.keys), ["ok"])
  }

  func testAtMostSixLoadAtOnceInGridOrderAndAFinishedOneFreesAPlace() {
    var scheduler = LivePreviewScheduler()
    let tiles = (0..<9).map { tile("t\($0)") }
    scheduler.update(tiles: tiles, stillsSettled: true, isHidden: false)
    XCTAssertEqual(scheduler.states.values.filter { $0 == .loading }.count, LivePreviewScheduler.concurrency)
    for index in 0..<6 { XCTAssertTrue(scheduler.isAttached("t\(index)"), "t\(index)") }
    XCTAssertFalse(scheduler.isAttached("t6"))
    scheduler.finish("t0", loaded: true)
    XCTAssertTrue(scheduler.isAttached("t6"), "the next tile in grid order takes the free place")
    XCTAssertFalse(scheduler.isAttached("t7"))
    scheduler.finish("t1", loaded: false)
    XCTAssertTrue(scheduler.isAttached("t7"))
  }

  func testAFailedAnimationKeepsItsStillAndIsNotRetriedByScrolling() {
    var scheduler = LivePreviewScheduler()
    scheduler.update(tiles: [tile("single")], stillsSettled: true, isHidden: false)
    scheduler.finish("single", loaded: false)
    XCTAssertEqual(scheduler.states["single"], .failed)
    XCTAssertFalse(scheduler.isAttached("single"))
    scheduler.update(tiles: [tile("single", onScreen: false)], stillsSettled: true, isHidden: false)
    scheduler.update(tiles: [tile("single")], stillsSettled: true, isHidden: false)
    XCTAssertEqual(scheduler.states["single"], .failed, "scrolling away and back does not retry it")
  }

  func testScrollingAwayHidingAndLeavingReleaseTheAnimationsTheStillStaysAndComingBackReloads() {
    var scheduler = LivePreviewScheduler()
    let on = [tile("a"), tile("b")]
    scheduler.update(tiles: on, stillsSettled: true, isHidden: false)
    scheduler.finish("a", loaded: true)

    scheduler.update(tiles: [tile("a", onScreen: false), tile("b")], stillsSettled: true, isHidden: false)
    XCTAssertFalse(scheduler.isAttached("a"), "scrolled out of view: released")
    XCTAssertTrue(scheduler.isAttached("b"))
    scheduler.update(tiles: on, stillsSettled: true, isHidden: false)
    XCTAssertTrue(scheduler.isAttached("a"), "back in view: loads again from the disk cache")

    scheduler.update(tiles: on, stillsSettled: true, isHidden: true)
    XCTAssertFalse(scheduler.isAttached("a"))
    XCTAssertFalse(scheduler.isAttached("b"))
    scheduler.update(tiles: on, stillsSettled: true, isHidden: false)
    XCTAssertTrue(scheduler.isAttached("a"))

    scheduler.releaseAll()
    XCTAssertTrue(scheduler.states.isEmpty)
  }

  func testTilesThatLeaveThePageAreForgottenAndOnlyAnAttachedAnimationCanSettle() {
    var scheduler = LivePreviewScheduler()
    scheduler.update(tiles: [tile("a"), tile("b")], stillsSettled: true, isHidden: false)
    scheduler.retire(keeping: ["b"])
    XCTAssertNil(scheduler.states["a"])
    scheduler.finish("a", loaded: true)
    XCTAssertNil(scheduler.states["a"], "a result for a forgotten tile changes nothing")
    scheduler.finish("b", loaded: true)
    scheduler.finish("b", loaded: false)
    XCTAssertEqual(scheduler.states["b"], .failed, "a loaded animation can still fail and hand back its still")
  }
}
