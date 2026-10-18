import XCTest

@testable import WallpaperMachine

/// The queue behind the Position on screen frame, ported from `placement.js`: one request in flight
/// for each wallpaper and display, the newest values replacing anything waiting, a draft that
/// outlives every published state until its own final request has returned, and the sends that a
/// change of target or a pause in the arrow keys cause.
@MainActor
final class PlacementDraftsTests: XCTestCase {
  private func state(
    _ id: String = "image-a", display: String = "primary", x: Double = 0.5, y: Double = 0.5,
    zoom: Double = 1, customized: Bool = false, fit: StillImageWallpaper.Fit? = .fill
  ) -> ImagePlacementState {
    ImagePlacementState(
      wallpaperID: id, displayID: display, displayTitle: "Studio", isSupported: true, reason: nil,
      x: x, y: y, zoom: zoom, isCustomized: customized, fit: fit, imagePixelSize: nil,
      imageAspectRatio: 2, displayAspectRatio: 1.6, displayViewportSize: nil, displayPixelSize: nil)
  }

  /// A queue whose sends are recorded and answered by the test.
  @MainActor
  private final class Harness {
    var current: ImagePlacementState?
    var sent: [PlacementDrafts.Request] = []
    var resets: [PlacementDrafts.Target] = []
    var succeeds = true
    /// While set, a send waits for `gate.open()`.
    var gate: AsyncGate?
    let sleeper = ManualSleeper()
    lazy var drafts = PlacementDrafts(
      current: { [unowned self] in self.current },
      send: { [unowned self] request in
        self.sent.append(request)
        if let gate = self.gate { await gate.wait() }
        return self.succeeds
      },
      reset: { [unowned self] target in
        self.resets.append(target)
        if let gate = self.gate { await gate.wait() }
        return self.succeeds
      },
      sleep: sleeper.closure)

    init(_ state: ImagePlacementState?) { current = state }
  }

  // MARK: Reading

  func testTheValuesAreTheSavedPlacementOverriddenByTheDraftAxisByAxis() {
    let harness = Harness(state())
    let saved = state(x: 0.3, y: 0.6, zoom: 1.5)
    XCTAssertEqual(harness.drafts.values(for: saved), .init(x: 0.3, y: 0.6, zoom: 1.5))
    harness.drafts.update(y: 0.9)
    XCTAssertEqual(harness.drafts.values(for: saved), .init(x: 0.3, y: 0.9, zoom: 1.5), "an axis not touched keeps its value")
    harness.drafts.update(zoom: 9)
    XCTAssertEqual(harness.drafts.values(for: saved).zoom, 3, "held to the range")
  }

  func testFillKeepingTheTopStartsAtTheTopUntilTheUserMovesIt() {
    let harness = Harness(nil)
    let top = state(y: .nan, fit: .fillTop)
    XCTAssertEqual(harness.drafts.values(for: top).y, 0)
    XCTAssertEqual(harness.drafts.values(for: state(y: .nan, fit: .fill)).y, 0.5)
  }

  func testResetIsOfferedOnceThePictureWasMovedAndNotWhileOneIsOnItsWay() async {
    let harness = Harness(state())
    XCTAssertFalse(harness.drafts.canReset(state()), "nothing moved")
    XCTAssertTrue(harness.drafts.canReset(state(customized: true)))
    harness.drafts.update(x: 0.8)
    XCTAssertTrue(harness.drafts.canReset(state()), "a draft counts")
    let gate = AsyncGate()
    harness.gate = gate
    let reset = harness.drafts.reset(state(customized: true))
    XCTAssertTrue(harness.drafts.isResetting)
    XCTAssertFalse(harness.drafts.canReset(state(customized: true)))
    gate.open()
    await reset.value
    XCTAssertFalse(harness.drafts.isResetting)
    XCTAssertNil(harness.drafts.draft, "a reset takes the draft with it")
    XCTAssertEqual(harness.resets, [.init(state())])
  }

  func testARefusedResetKeepsTheDraft() async {
    let harness = Harness(state())
    harness.succeeds = false
    harness.drafts.update(x: 0.8)
    await harness.drafts.reset(state()).value
    XCTAssertEqual(harness.drafts.draft?.x, 0.8)
    XCTAssertFalse(harness.drafts.isResetting)
  }

  // MARK: Sending

  func testAnUnchangedPlacementSendsNothing() {
    let harness = Harness(state())
    XCTAssertNil(harness.drafts.commit(from: state()))
    XCTAssertTrue(harness.sent.isEmpty)
  }

  func testTheSettledValuesAreSentRoundedAndTheDraftEndsWhenTheyHaveBeenTaken() async {
    let harness = Harness(state())
    harness.drafts.update(x: 0.123456, y: 0.987654, zoom: 1.23456)
    await harness.drafts.commit(from: state())?.value
    XCTAssertEqual(
      harness.sent.map { [$0.x, $0.y, $0.zoom] }, [[0.123, 0.988, 1.235]])
    XCTAssertEqual(harness.sent.first?.target, .init(state()))
    XCTAssertNil(harness.drafts.draft, "the model has the final numbers now")
  }

  func testARefusedSendKeepsTheDraftOnShow() async {
    let harness = Harness(state())
    harness.succeeds = false
    harness.drafts.update(x: 0.7)
    await harness.drafts.commit(from: state())?.value
    XCTAssertEqual(harness.drafts.draft?.x, 0.7, "the picture stays where the person put it")
  }

  func testValuesChangedWhileARequestIsOnItsWayReplaceWhatWaitsAndGoOutWhenItReturns() async {
    let harness = Harness(state())
    let gate = AsyncGate()
    harness.gate = gate
    harness.drafts.update(x: 0.2)
    let task = harness.drafts.commit(from: state())
    await gate.waitUntilWaiting(1)
    XCTAssertEqual(harness.sent.count, 1)

    // Two more settle while the first is on its way: only the newest is sent after it.
    harness.drafts.update(x: 0.3)
    harness.drafts.commit(from: state())
    harness.drafts.update(x: 0.4)
    harness.drafts.commit(from: state())
    XCTAssertEqual(harness.sent.count, 1, "one request at a time")

    gate.open()
    await task?.value
    XCTAssertEqual(harness.sent.map(\.x), [0.2, 0.4], "the middle value was replaced, never sent")
    XCTAssertNil(harness.drafts.draft)
  }

  func testANewerDraftSurvivesTheReturnOfTheRequestThatCarriedAnOlderOne() async {
    let harness = Harness(state())
    let gate = AsyncGate()
    harness.gate = gate
    harness.drafts.update(x: 0.2)
    let task = harness.drafts.commit(from: state())
    await gate.waitUntilWaiting(1)
    harness.drafts.update(x: 0.9)  // moved on, and not yet settled
    gate.open()
    await task?.value
    XCTAssertEqual(harness.drafts.draft?.x, 0.9, "the draft is kept until the request with its numbers returns")
  }

  func testTheDraftIsKeptWhenTheStateNowShownIsForAnotherWallpaper() async {
    let harness = Harness(state("image-b"))
    harness.drafts.update(x: 0.2)
    await harness.drafts.commit(from: state("image-a"))?.value
    XCTAssertEqual(harness.drafts.draft?.x, 0.2, "the request for the old wallpaper is not the one this draft awaits")
  }

  // MARK: Following the state

  func testChangingTheDisplayUnderAnUnsentDraftSendsItForTheOldOneAndDropsIt() async {
    let harness = Harness(state(display: "primary"))
    harness.drafts.observe(state(display: "primary"))
    harness.drafts.update(x: 0.25)
    harness.current = state(display: "second")
    harness.drafts.observe(state(display: "second"))
    XCTAssertNil(harness.drafts.draft, "it belonged to the other display")
    await harness.drafts.commit(from: nil)?.value
    XCTAssertEqual(harness.sent.count, 1)
    XCTAssertEqual(harness.sent.first?.target, .init(state(display: "primary")))
    XCTAssertEqual(harness.sent.first?.x, 0.25)
  }

  func testADraftAlreadyQueuedIsNotSentAgainWhenTheTargetChanges() async {
    let harness = Harness(state())
    let gate = AsyncGate()
    harness.gate = gate
    harness.drafts.observe(state())
    harness.drafts.update(x: 0.25)
    let task = harness.drafts.commit(from: state())
    await gate.waitUntilWaiting(1)
    harness.current = state("image-b")
    harness.drafts.observe(state("image-b"))
    gate.open()
    await task?.value
    XCTAssertEqual(harness.sent.count, 1)
  }

  func testAnotherWallpaperWithNothingUnsentJustDropsTheDraft() {
    let harness = Harness(state())
    harness.drafts.observe(state())
    harness.drafts.observe(state("image-b"))
    XCTAssertNil(harness.drafts.draft)
    XCTAssertTrue(harness.sent.isEmpty)
  }

  // MARK: Keys and clicks

  func testAnArrowKeyMovesThePictureAndIsSavedOnceTheKeysHavePaused() async {
    let harness = Harness(state(x: 0.5, y: 0.5))
    harness.drafts.nudge(dx: 1, dy: 0, large: false, state: state())
    harness.drafts.nudge(dx: 1, dy: 0, large: true, state: state())
    XCTAssertEqual(harness.drafts.values(for: state()).x, 0.56, accuracy: 1e-9, "a hundredth, then five hundredths")
    XCTAssertTrue(harness.sent.isEmpty, "nothing is sent while the keys are still coming")
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(harness.sleeper.requested, [.milliseconds(400), .milliseconds(400)])
    XCTAssertEqual(harness.sleeper.cancelledCount, 1, "the second press started the pause over")

    await harness.sleeper.waitUntilPending()
    harness.sleeper.fireNext()
    for _ in 0..<60 where harness.sent.isEmpty { await Task.yield() }
    XCTAssertEqual(harness.sent.count, 1)
    XCTAssertEqual(try XCTUnwrap(harness.sent.first).x, 0.56, accuracy: 1e-9)
  }

  func testAClickThatDidNotMoveRestoresWhatTheDragStartedFrom() {
    let harness = Harness(state())
    harness.drafts.update(x: 0.7)
    let before = harness.drafts.draft
    harness.drafts.update(x: 0.9)
    harness.drafts.restore(before)
    XCTAssertEqual(harness.drafts.draft?.x, 0.7)
    harness.drafts.restore(nil)
    XCTAssertNil(harness.drafts.draft)
  }
}
