import XCTest

@testable import WallpaperMachine

final class LockScreenConnectionTraceTests: XCTestCase {
  func testAConnectionThatServedNothingReportsZero() {
    XCTAssertEqual(LockScreenConnectionTrace().served, 0)
  }

  func testServedCountIsExactUnderConcurrentCalls() {
    let trace = LockScreenConnectionTrace()
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
      for _ in 0..<2_000 { trace.noteServed() }
    }
    XCTAssertEqual(trace.served, 32_000)
  }

  func testEachConnectionCountsOnlyItsOwnRequests() {
    let first = LockScreenConnectionTrace()
    let second = LockScreenConnectionTrace()
    first.noteServed()
    first.noteServed()
    second.noteServed()
    XCTAssertEqual(first.served, 2)
    XCTAssertEqual(second.served, 1)
  }
}
