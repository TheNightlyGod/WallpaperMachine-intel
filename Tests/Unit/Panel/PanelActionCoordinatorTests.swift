import XCTest

@testable import WallpaperMachine

/// What a view's action does when it is started: the key's busy state, what a repeat means, and
/// where a failure goes.
@MainActor
final class PanelActionCoordinatorTests: XCTestCase {
  private struct Failure: Error, Equatable { let name: String }

  /// A held task: `wait()` suspends until the test calls `open()`. Main-actor isolated, so a
  /// waiter is always registered before or after `open()` runs, never between its two steps.
  @MainActor private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
      isOpen = true
      let waiting = waiters
      waiters = []
      for waiter in waiting { waiter.resume() }
    }
  }

  private final class Recorder {
    var reported: [Error] = []
    var successes = 0
    var log: [String] = []
  }

  private func makeCoordinator() -> (PanelActionCoordinator, Recorder) {
    let recorder = Recorder()
    let coordinator = PanelActionCoordinator(
      report: { recorder.reported.append($0) }, succeeded: { recorder.successes += 1 })
    return (coordinator, recorder)
  }

  func testAKeyIsBusyWhileItsActionRunsAndFreeAfterwards() async {
    let (coordinator, _) = makeCoordinator()
    let gate = Gate()
    let key = PanelActionCoordinator.key("activate", id: "a")
    let task = coordinator.launch(key) { await gate.wait() }
    XCTAssertTrue(coordinator.isBusy(key))
    XCTAssertTrue(coordinator.hasPending)
    XCTAssertFalse(coordinator.isBusy(PanelActionCoordinator.key("activate", id: "b")))
    gate.open()
    await task.value
    XCTAssertFalse(coordinator.isBusy(key))
    XCTAssertFalse(coordinator.hasPending)
  }

  func testARepeatWhileThePendingActionRunsIsDroppedAndHandsBackTheOriginal() async {
    let (coordinator, recorder) = makeCoordinator()
    let gate = Gate()
    let first = coordinator.launch("delete:a") {
      recorder.log.append("first")
      await gate.wait()
    }
    let second = coordinator.launch("delete:a") { recorder.log.append("second") }
    XCTAssertEqual(first, second, "a dropped repeat returns the task that is already running")
    gate.open()
    await second.value
    XCTAssertEqual(recorder.log, ["first"])
    let again = coordinator.launch("delete:a") { recorder.log.append("again") }
    await again.value
    XCTAssertEqual(recorder.log, ["first", "again"], "the key is free once the action ended")
  }

  func testLatestWinsRunsEveryValueInOrderAndAFailureDoesNotStopTheNextOne() async {
    let (coordinator, recorder) = makeCoordinator()
    let gate = Gate()
    let key = PanelActionCoordinator.key("property", id: "w", detail: "speed")
    coordinator.launch(key, policy: .latestWins) {
      recorder.log.append("1 start")
      await gate.wait()
      recorder.log.append("1 fail")
      throw Failure(name: "1")
    }
    coordinator.launch(key, policy: .latestWins) { recorder.log.append("2") }
    let last = coordinator.launch(key, policy: .latestWins) { recorder.log.append("3") }
    XCTAssertEqual(recorder.log, [], "nothing has run yet: the tasks start on the next turn")
    await Task.yield()
    XCTAssertEqual(recorder.log, ["1 start"], "the newer values wait for the pending one")
    XCTAssertTrue(coordinator.isBusy(key))
    gate.open()
    await last.value
    XCTAssertEqual(recorder.log, ["1 start", "1 fail", "2", "3"], "the newest value lands last")
    XCTAssertEqual(recorder.reported as? [Failure], [Failure(name: "1")], "the earlier failure is reported once")
    XCTAssertFalse(coordinator.isBusy(key))
  }

  func testAFailureIsReportedAndStillReleasesTheKey() async {
    let (coordinator, recorder) = makeCoordinator()
    await coordinator.launch("apply:a") { throw Failure(name: "no") }.value
    XCTAssertEqual(recorder.reported as? [Failure], [Failure(name: "no")])
    XCTAssertEqual(recorder.successes, 0)
    XCTAssertFalse(coordinator.isBusy("apply:a"))
    await coordinator.launch("apply:a") {}.value
    XCTAssertEqual(recorder.successes, 1, "a retry after a failure runs")
  }

  func testDifferentKeysDoNotWaitForEachOther() async {
    let (coordinator, recorder) = makeCoordinator()
    let gate = Gate()
    let held = coordinator.launch("a:", policy: .latestWins) { await gate.wait() }
    await coordinator.launch("b:", policy: .latestWins) { recorder.log.append("b") }.value
    XCTAssertEqual(recorder.log, ["b"])
    XCTAssertTrue(coordinator.isBusy("a:"))
    gate.open()
    await held.value
  }

  func testWorkWithoutAKeyRunsAtOnceAndIsNotTracked() async {
    let (coordinator, recorder) = makeCoordinator()
    let gate = Gate()
    let first = coordinator.launch { await gate.wait() }
    await coordinator.launch { recorder.log.append("second") }.value
    XCTAssertEqual(recorder.log, ["second"], "an unkeyed action never waits for another")
    XCTAssertFalse(coordinator.hasPending)
    gate.open()
    await first.value
  }

  func testEveryThrownErrorIsHandedToTheReporterEvenACancellation() async {
    let (coordinator, recorder) = makeCoordinator()
    await coordinator.launch("x:") { throw CancellationError() }.value
    XCTAssertEqual(recorder.reported.count, 1, "the coordinator hands every error on; the banner decides")
  }

  func testTheKeyNamesTheActionTheWallpaperTheDisplayAndThePropertyInOrder() {
    XCTAssertEqual(PanelActionCoordinator.key("property", id: "w", detail: "speed"), "property:w::speed")
    XCTAssertEqual(PanelActionCoordinator.key("target"), "target:::")
    XCTAssertNotEqual(
      PanelActionCoordinator.key("displayConfig", id: "w", displayID: "primary", detail: "fps"),
      PanelActionCoordinator.key("displayConfig", id: "w", displayID: "secondary", detail: "fps"))
  }
}
