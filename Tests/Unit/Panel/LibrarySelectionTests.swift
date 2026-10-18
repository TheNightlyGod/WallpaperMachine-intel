import CoreGraphics
import XCTest

@testable import WallpaperMachine

/// The ticks for a batch action, and the press-and-sweep gesture that makes many at once.
@MainActor
final class LibrarySelectionTests: XCTestCase {
  private let ids = ["a", "b", "c", "d", "e", "f"]

  // MARK: Ticks

  func testTickingKeepsTheOrderAndTheAnchorMovesToWhatWasTicked() {
    var selection = LibrarySelection()
    selection.toggle("c")
    selection.toggle("a")
    XCTAssertEqual(selection.ids, ["c", "a"], "a batch is sent in the order it was ticked")
    XCTAssertEqual(selection.anchor, "a")
    selection.toggle("a")
    XCTAssertEqual(selection.ids, ["c"])
    XCTAssertEqual(selection.anchor, "a", "unticking leaves the anchor where it was")
  }

  func testShiftExtendsFromTheAnchorInTheOrderShownAndNeverRemoves() {
    var selection = LibrarySelection()
    selection.toggle("b")
    selection.toggle("e", range: true, visible: ids)
    XCTAssertEqual(selection.ids, ["b", "c", "d", "e"])
    XCTAssertEqual(selection.anchor, "b", "the anchor does not move")
    selection.toggle("a", range: true, visible: ids)
    XCTAssertEqual(Set(selection.ids), ["a", "b", "c", "d", "e"], "backwards too, and additive")
    selection.toggle("b", range: true, visible: ids)
    XCTAssertTrue(selection.contains("b"), "a range never unticks")
  }

  func testShiftWithoutAnAnchorOnScreenTicksJustTheTile() {
    var selection = LibrarySelection()
    selection.toggle("z")
    selection.toggle("b", range: true, visible: ids)
    XCTAssertEqual(selection.ids, ["z", "b"], "the anchor is hidden, so this is a plain tick")
    var fresh = LibrarySelection()
    fresh.toggle("c", range: true, visible: ids)
    XCTAssertEqual(fresh.ids, ["c"])
  }

  func testSelectAllTicksOnlyWhatIsOnScreenAndAnchorsOnTheFirstTicked() {
    var selection = LibrarySelection()
    selection.toggle("z")
    selection.selectAll(visible: ["a", "b"])
    XCTAssertEqual(selection.ids, ["z", "a", "b"])
    XCTAssertEqual(selection.anchor, "z")
    XCTAssertTrue(selection.containsAll(of: ["a", "b"]))
    XCTAssertFalse(selection.containsAll(of: ["a", "q"]))
    var empty = LibrarySelection()
    empty.selectAll(visible: ["a", "b"])
    XCTAssertEqual(empty.anchor, "a")
  }

  func testClearEmptiesTheSetAndTheAnchor() {
    var selection = LibrarySelection()
    selection.selectAll(visible: ids)
    selection.clear()
    XCTAssertTrue(selection.isEmpty)
    XCTAssertNil(selection.anchor)
  }

  func testPruningDropsWhatLeftTheLibraryAndTheAnchorWithIt() {
    var selection = LibrarySelection()
    selection.selectAll(visible: ["a", "b", "c"])
    selection.toggle("c")
    selection.toggle("c")
    XCTAssertEqual(selection.anchor, "c")
    selection.prune { $0 != "c" && $0 != "a" }
    XCTAssertEqual(selection.ids, ["b"])
    XCTAssertNil(selection.anchor)
    selection.prune { _ in true }
    XCTAssertEqual(selection.ids, ["b"], "nothing to prune changes nothing")
  }

  // MARK: Sweep

  private func start(
    _ id: String, eager: Bool = false, at point: CGPoint = CGPoint(x: 10, y: 10)
  ) -> SweepSelection {
    SweepSelection(startID: id, at: point, isEager: eager)
  }

  func testAQuickDragOutsideASelectionIsLeftAlone() {
    var selection = LibrarySelection()
    var sweep = start("a")
    XCTAssertTrue(sweep.isArming, "the pressed tile shows the hold in progress")
    let outcome = sweep.move(
      to: CGPoint(x: 200, y: 10), over: "d", selection: &selection, visible: ids)
    XCTAssertEqual(outcome, .cancelled)
    XCTAssertTrue(selection.isEmpty)
  }

  func testHoldingStillTicksThePressedTileAndASmallDriftDoesNotSpoilIt() {
    var selection = LibrarySelection()
    var sweep = start("a")
    let drift = sweep.move(to: CGPoint(x: 12, y: 10), over: "a", selection: &selection, visible: ids)
    XCTAssertEqual(drift, .continues, "within the slop")
    XCTAssertTrue(sweep.isArming)
    sweep.holdElapsed(selection: &selection, visible: ids)
    XCTAssertEqual(selection.ids, ["a"])
    XCTAssertTrue(sweep.isPainting)
    XCTAssertFalse(sweep.isArming)
  }

  func testSweepingCoversTheRunInGridOrderAndSweepingBackGivesTheOvershootBack() {
    var selection = LibrarySelection()
    var sweep = start("a")
    sweep.holdElapsed(selection: &selection, visible: ids)
    _ = sweep.move(to: .zero, over: "d", selection: &selection, visible: ids)
    XCTAssertEqual(Set(selection.ids), ["a", "b", "c", "d"])
    _ = sweep.move(to: .zero, over: "b", selection: &selection, visible: ids)
    XCTAssertEqual(Set(selection.ids), ["a", "b"])
    _ = sweep.move(to: .zero, over: nil, selection: &selection, visible: ids)
    XCTAssertEqual(Set(selection.ids), ["a", "b"], "between tiles changes nothing")
    XCTAssertTrue(sweep.hasLearned)
    XCTAssertEqual(selection.anchor, "a", "a sweep that adds anchors where it began")
  }

  func testSweepingAcrossAFastPointerNeverSkipsATile() {
    var selection = LibrarySelection()
    var sweep = start("b")
    sweep.holdElapsed(selection: &selection, visible: ids)
    _ = sweep.move(to: .zero, over: "f", selection: &selection, visible: ids)
    XCTAssertEqual(Set(selection.ids), ["b", "c", "d", "e", "f"], "the run, not just the tile")
    _ = sweep.move(to: .zero, over: "a", selection: &selection, visible: ids)
    XCTAssertEqual(Set(selection.ids), ["a", "b"], "and past the start the other way")
  }

  func testASweepKeepsWhatWasTickedBeforeIt() {
    var selection = LibrarySelection()
    selection.toggle("f")
    var sweep = start("a", eager: true)
    sweep.holdElapsed(selection: &selection, visible: ids)
    _ = sweep.move(to: .zero, over: "c", selection: &selection, visible: ids)
    XCTAssertEqual(Set(selection.ids), ["f", "a", "b", "c"])
    _ = sweep.move(to: .zero, over: "a", selection: &selection, visible: ids)
    XCTAssertEqual(Set(selection.ids), ["f", "a"])
  }

  func testWithASelectionUnderWayMovingOntoAnotherTileSweepsAtOnceAndFromATickedTileItClears() {
    var selection = LibrarySelection()
    selection.selectAll(visible: ["a", "b"])
    var sweep = start("a", eager: true)
    let outcome = sweep.move(
      to: CGPoint(x: 60, y: 10), over: "b", selection: &selection, visible: ids)
    XCTAssertEqual(outcome, .continues)
    XCTAssertTrue(selection.isEmpty, "pressing a ticked tile sweeps to untick")
    XCTAssertTrue(sweep.isPainting)
  }

  func testAnEagerPressThatMovedButFoundNoOtherTileWaitsAndTheHoldNoLongerTicks() {
    var selection = LibrarySelection()
    selection.toggle("z")
    var sweep = start("a", eager: true)
    _ = sweep.move(to: CGPoint(x: 30, y: 10), over: "a", selection: &selection, visible: ids)
    XCTAssertFalse(sweep.isArming, "the move gave up the hold")
    sweep.holdElapsed(selection: &selection, visible: ids)
    XCTAssertEqual(selection.ids, ["z"], "a hold that was given up ticks nothing")
    _ = sweep.move(to: CGPoint(x: 90, y: 10), over: "b", selection: &selection, visible: ids)
    XCTAssertEqual(Set(selection.ids), ["z", "a", "b"])
  }

  func testASweepOverASingleTileHasNotTaughtTheGesture() {
    var selection = LibrarySelection()
    var sweep = start("a")
    sweep.holdElapsed(selection: &selection, visible: ids)
    XCTAssertFalse(sweep.hasLearned)
  }

  func testAPressOnATileThatIsNotInTheGridPaintsNothing() {
    var selection = LibrarySelection()
    var sweep = start("gone")
    sweep.holdElapsed(selection: &selection, visible: ids)
    XCTAssertTrue(selection.isEmpty)
  }

  // MARK: Scrolling under the pointer

  func testTheGridScrollsOnlyInTheBandsAtItsEdgesAndFasterTheDeeperIn() {
    let height: CGFloat = 600
    XCTAssertEqual(SweepSelection.scrollStep(pointerY: 300, viewportHeight: height), 0)
    XCTAssertEqual(SweepSelection.scrollStep(pointerY: 552, viewportHeight: height), 0, "the band begins 48 in")
    let shallow = SweepSelection.scrollStep(pointerY: 570, viewportHeight: height)
    let deep = SweepSelection.scrollStep(pointerY: 598, viewportHeight: height)
    XCTAssertGreaterThan(shallow, 0)
    XCTAssertGreaterThan(deep, shallow)
    XCTAssertEqual(
      SweepSelection.scrollStep(pointerY: 2000, viewportHeight: height), 32,
      "no faster than a third of the band's double width")
    XCTAssertLessThan(SweepSelection.scrollStep(pointerY: 10, viewportHeight: height), 0, "up at the top")
    XCTAssertEqual(SweepSelection.scrollStep(pointerY: -500, viewportHeight: height), -32)
  }

  func testThePointerThatScrolledTilesBeneathItIsLookedForInsideTheGrid() {
    let size = CGSize(width: 400, height: 300)
    XCTAssertEqual(SweepSelection.clamped(CGPoint(x: -50, y: 900), in: size), CGPoint(x: 16, y: 284))
    XCTAssertEqual(SweepSelection.clamped(CGPoint(x: 200, y: 100), in: size), CGPoint(x: 200, y: 100))
    XCTAssertEqual(SweepSelection.clamped(CGPoint(x: 999, y: -4), in: size), CGPoint(x: 384, y: 16))
  }
}
