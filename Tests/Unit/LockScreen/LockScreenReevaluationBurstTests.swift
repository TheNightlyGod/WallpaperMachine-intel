import XCTest

@testable import WallpaperMachine

@MainActor
final class LockScreenReevaluationBurstTests: XCTestCase {
  /// A schedule that records what was asked for and lets the test decide when, and
  /// whether, each check runs.
  @MainActor
  private final class ManualSchedule {
    struct Entry {
      let delay: Duration
      let work: @MainActor () -> Void
      var cancelled = false
    }
    private(set) var entries: [Entry] = []

    var schedule: LockScreenReevaluationBurst.Schedule {
      { [self] delay, work in
        let index = entries.count
        entries.append(Entry(delay: delay, work: work))
        return { [self] in entries[index].cancelled = true }
      }
    }

    func run(_ range: Range<Int>) {
      for index in range { entries[index].work() }
    }
  }

  private let manual = ManualSchedule()
  private var performed = 0

  private func makeBurst() -> LockScreenReevaluationBurst {
    LockScreenReevaluationBurst(
      schedule: manual.schedule, perform: { [unowned self] in performed += 1 })
  }

  func testTriggerChecksNowAndAgainAtEachOffset() {
    let burst = makeBurst()
    burst.trigger()

    XCTAssertEqual(performed, 1, "The first check does not wait.")
    XCTAssertEqual(manual.entries.map(\.delay), [.milliseconds(250), .milliseconds(750), .seconds(2)])

    manual.run(0..<1)
    XCTAssertEqual(performed, 2)
    manual.run(1..<3)
    XCTAssertEqual(performed, 4)
  }

  func testANewTriggerRetiresTheEarlierBurstEvenIfCancellationRaces() {
    let burst = makeBurst()
    burst.trigger()
    burst.trigger()
    XCTAssertEqual(performed, 2)
    XCTAssertEqual(manual.entries.count, 6)
    XCTAssertTrue(manual.entries[0..<3].allSatisfy(\.cancelled))
    XCTAssertTrue(manual.entries[3..<6].allSatisfy { !$0.cancelled })

    // A check that was already on its way when the newer trigger arrived.
    manual.run(0..<3)
    XCTAssertEqual(performed, 2, "A stale check must not run on behalf of the newer trigger.")

    manual.run(3..<6)
    XCTAssertEqual(performed, 5)
  }

  func testCancelStopsPendingChecks() {
    let burst = makeBurst()
    burst.trigger()
    burst.cancel()
    XCTAssertTrue(manual.entries.allSatisfy(\.cancelled))

    manual.run(0..<3)
    XCTAssertEqual(performed, 1)

    burst.trigger()
    manual.run(3..<6)
    XCTAssertEqual(performed, 5, "A burst started after a cancel runs in full.")
  }

  func testTheSleepingScheduleRunsEveryCheckOnce() async {
    let finished = expectation(description: "the immediate check and both delayed ones ran")
    var count = 0
    let burst = LockScreenReevaluationBurst(
      offsets: [.milliseconds(5), .milliseconds(10)],
      perform: {
        count += 1
        if count == 3 { finished.fulfill() }
      })
    // The burst holds only a weak reference from its pending checks.
    defer { withExtendedLifetime(burst) {} }
    burst.trigger()
    await fulfillment(of: [finished], timeout: 10)
    XCTAssertEqual(count, 3)
  }

  /// The cancelled burst's check was due well before the second burst's, so the second
  /// finishing without it having run shows a cancelled check does not run.
  func testTheSleepingScheduleDoesNotRunACancelledCheck() async {
    var cancelled = 0
    let cancelledBurst = LockScreenReevaluationBurst(
      offsets: [.milliseconds(20)], perform: { cancelled += 1 })
    let finished = expectation(description: "the later burst ran")
    var later = 0
    let laterBurst = LockScreenReevaluationBurst(
      offsets: [.milliseconds(120)],
      perform: {
        later += 1
        if later == 2 { finished.fulfill() }
      })
    defer { withExtendedLifetime((cancelledBurst, laterBurst)) {} }
    cancelledBurst.trigger()
    cancelledBurst.cancel()
    laterBurst.trigger()
    await fulfillment(of: [finished], timeout: 10)
    XCTAssertEqual(cancelled, 1, "Only the immediate check ran; the delayed one was cancelled.")
  }
}
