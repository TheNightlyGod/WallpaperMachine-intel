import XCTest

@testable import WallpaperMachine

final class LockScreenFirstFrameTimingTests: XCTestCase {
  func testClassificationThresholds() {
    typealias Timing = LockScreenFirstFrameTiming
    XCTAssertEqual(Timing.classify(.zero), .normal)
    XCTAssertEqual(Timing.classify(.milliseconds(9_900)), .normal)
    XCTAssertEqual(Timing.classify(.seconds(10)), .slow)
    XCTAssertEqual(Timing.classify(.milliseconds(19_900)), .slow)
    XCTAssertEqual(Timing.classify(.seconds(20)), .nearLimit)
    XCTAssertEqual(Timing.classify(.seconds(45)), .nearLimit)
  }

  /// The warning is only useful while there is still time before WallpaperAgent gives up.
  func testTheNearLimitWarningComesBeforeTheAgentGivesUp() {
    typealias Timing = LockScreenFirstFrameTiming
    XCTAssertLessThan(Timing.slowThreshold, Timing.nearLimitThreshold)
    XCTAssertLessThan(Timing.nearLimitThreshold, Timing.agentPatience)
  }

  func testSecondsAreLoggedWithOneDecimalAndNoUnit() {
    typealias Timing = LockScreenFirstFrameTiming
    XCTAssertEqual(Timing.seconds(.zero), "0.0")
    XCTAssertEqual(Timing.seconds(.milliseconds(40)), "0.0")
    XCTAssertEqual(Timing.seconds(.milliseconds(12_340)), "12.3")
    XCTAssertEqual(Timing.seconds(.seconds(31)), "31.0")
  }
}
