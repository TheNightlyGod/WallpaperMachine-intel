import XCTest

@testable import WallpaperMachine

/// Showing the wallpaper at the thumb while a slider is dragged: at most one step in flight, no
/// more often than every 100 ms, the newest value, and a release that waits for the step on its
/// way and always saves.
@MainActor
final class DragStepPumpTests: XCTestCase {
  private final class Probe {
    var shown: [Double] = []
    var saved: [Double] = []
    /// While set, a step does not finish until released.
    var holdSteps = false
    var held: [CheckedContinuation<Void, Never>] = []
    func releaseStep() { held.removeFirst().resume() }
  }

  private func makePump(_ probe: Probe, _ clock: ManualSleeper) -> DragStepPump<Double> {
    DragStepPump<Double>(sleep: clock.closure) { value in
      probe.shown.append(value)
      if probe.holdSteps { await withCheckedContinuation { probe.held.append($0) } }
    }
  }

  /// Lets the tasks the pump started run until nothing more happens.
  private func settle() async {
    for _ in 0..<10 { await Task.yield() }
  }

  func testTheFirstValueIsShownAtOnceAndLaterOnesWaitForTheHundredMilliseconds() async {
    let probe = Probe()
    let clock = ManualSleeper()
    let pump = makePump(probe, clock)
    pump.update(1)
    await settle()
    XCTAssertEqual(probe.shown, [1])
    XCTAssertEqual(clock.requested, [.milliseconds(100)])

    pump.update(2)
    pump.update(3)
    pump.update(4)
    await settle()
    XCTAssertEqual(probe.shown, [1], "values inside the interval wait")
    clock.fireNext()
    await settle()
    XCTAssertEqual(probe.shown, [1, 4], "one step with the newest value; 2 and 3 are never shown")
    XCTAssertEqual(pump.lastShown, 4)
  }

  func testNoSecondStepStartsWhileOneIsStillInFlight() async {
    let probe = Probe()
    let clock = ManualSleeper()
    probe.holdSteps = true
    let pump = makePump(probe, clock)
    pump.update(1)
    await settle()
    pump.update(2)
    clock.fireNext()
    await settle()
    XCTAssertEqual(probe.shown, [1], "the interval passed but the first step has not been answered")
    probe.holdSteps = false
    probe.releaseStep()
    await settle()
    XCTAssertEqual(probe.shown, [1, 2], "the step that waited goes as soon as the one in flight ends")
  }

  func testTheSameValueIsNotShownTwice() async {
    let probe = Probe()
    let clock = ManualSleeper()
    let pump = makePump(probe, clock)
    pump.update(5)
    await settle()
    pump.update(5)
    clock.fireNext()
    await settle()
    XCTAssertEqual(probe.shown, [5])
  }

  func testReleaseWaitsForTheStepOnItsWayDropsAWaitingOneAndSavesTheFinalValue() async {
    let probe = Probe()
    let clock = ManualSleeper()
    probe.holdSteps = true
    let pump = makePump(probe, clock)
    pump.update(1)
    await settle()
    pump.update(2)

    let released = expectation(description: "release returns")
    Task { @MainActor in
      await pump.release(3) { probe.saved.append($0) }
      released.fulfill()
    }
    await settle()
    XCTAssertEqual(probe.saved, [], "the save waits for the step already sent to be answered")
    XCTAssertFalse(pump.isDragging)
    probe.releaseStep()
    await fulfillment(of: [released], timeout: 2)
    XCTAssertEqual(probe.saved, [3])
    XCTAssertEqual(probe.shown, [1], "the step that was waiting for its turn is cancelled, not sent late")
    XCTAssertEqual(clock.cancelledCount, 1, "and so is the interval timer")
  }

  func testADragThatEndsWhereItBeganStillSaves() async {
    let probe = Probe()
    let clock = ManualSleeper()
    let pump = makePump(probe, clock)
    pump.update(0.5)
    await settle()
    await pump.release(0.5) { probe.saved.append($0) }
    XCTAssertEqual(probe.saved, [0.5])
  }

  func testAReleaseWithoutADragSavesToo() async {
    let probe = Probe()
    let pump = makePump(probe, ManualSleeper())
    await pump.release(7) { probe.saved.append($0) }
    XCTAssertEqual(probe.saved, [7], "a key press or VoiceOver change has no drag and saves at once")
    XCTAssertTrue(probe.shown.isEmpty)
  }

  func testACommitThatThrowsReachesTheCaller() async {
    struct Refused: Error {}
    let pump = makePump(Probe(), ManualSleeper())
    do {
      try await pump.release(1) { _ in throw Refused() }
      XCTFail("the save's refusal is the caller's to report")
    } catch { XCTAssertTrue(error is Refused) }
  }

  func testADeferredFirstStepShowsNothingWhenTheSaveFollowsAtOnce() async {
    let probe = Probe()
    let pump = makePump(probe, ManualSleeper())
    pump.update(0.3, deferFirstStep: true)
    await pump.release(0.3) { probe.saved.append($0) }
    await settle()
    XCTAssertTrue(probe.shown.isEmpty, "a single colour pick previews nothing before it is saved")
    XCTAssertEqual(probe.saved, [0.3])
  }

  func testADeferredFirstStepIsShownOnceTheDragOutlivesTheTurn() async {
    let probe = Probe()
    let pump = makePump(probe, ManualSleeper())
    pump.update(0.3, deferFirstStep: true)
    pump.update(0.4, deferFirstStep: true)
    XCTAssertTrue(probe.shown.isEmpty)
    await settle()
    XCTAssertEqual(probe.shown, [0.4], "the first step carries the newest value")
  }

  func testTheNewestValueIsWhatABlurSettlesWith() async {
    let pump = makePump(Probe(), ManualSleeper())
    XCTAssertNil(pump.newestValue)
    pump.update(1)
    pump.update(2)
    XCTAssertEqual(pump.newestValue, 2)
    await pump.release(2) { _ in }
    XCTAssertNil(pump.newestValue)
  }
}
