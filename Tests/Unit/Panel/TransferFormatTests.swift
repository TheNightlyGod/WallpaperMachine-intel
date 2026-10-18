import XCTest

@testable import WallpaperMachine

/// The wording of a transfer: sizes in base 1024, speeds in base 1000, one fraction digit that
/// rounds half away from zero, and the pieces joined only where they are known.
@MainActor
final class TransferFormatTests: XCTestCase {
  private let english = Locale(identifier: "en_US")

  func testSizesCountInBase1024AndStopAtGigabytes() {
    XCTAssertEqual(TransferFormat.bytes(1, locale: english), "1 B")
    XCTAssertEqual(TransferFormat.bytes(1_023, locale: english), "1,023 B")
    XCTAssertEqual(TransferFormat.bytes(1_024, locale: english), "1 KB")
    XCTAssertEqual(TransferFormat.bytes(1_536, locale: english), "1.5 KB")
    XCTAssertEqual(TransferFormat.bytes(1_048_576, locale: english), "1 MB")
    XCTAssertEqual(TransferFormat.bytes(3.5 * 1_073_741_824, locale: english), "3.5 GB")
    XCTAssertEqual(
      TransferFormat.bytes(5_000 * 1_073_741_824, locale: english), "5,000 GB",
      "nothing larger than a gigabyte has a unit of its own")
  }

  func testASizeThatIsNotPositiveOrNotANumberIsEmpty() {
    for value in [nil, 0, -1, .nan, .infinity] as [Double?] {
      XCTAssertEqual(TransferFormat.bytes(value, locale: english), "", "\(String(describing: value))")
    }
  }

  func testRoundingIsHalfAwayFromZeroLikeTheWebPanelsNumberFormatting() {
    // 1.25 and 2.25 are exact in binary, so half-even rounding would give 1.2 and 2.2.
    XCTAssertEqual(TransferFormat.bytes(1.25 * 1_024, locale: english), "1.3 KB")
    XCTAssertEqual(TransferFormat.bytes(2.25 * 1_024, locale: english), "2.3 KB")
    XCTAssertEqual(TransferFormat.bytes(1.04 * 1_024, locale: english), "1 KB")
  }

  func testSpeedsCountInBase1000AndZeroIsASpeed() {
    XCTAssertEqual(TransferFormat.speed(0, locale: english), "0 B/s")
    XCTAssertEqual(TransferFormat.speed(999, locale: english), "999 B/s")
    XCTAssertEqual(TransferFormat.speed(1_000, locale: english), "1 KB/s")
    XCTAssertEqual(TransferFormat.speed(600_000, locale: english), "600 KB/s")
    XCTAssertEqual(TransferFormat.speed(2_500_000, locale: english), "2.5 MB/s")
    XCTAssertEqual(TransferFormat.speed(4_000_000_000, locale: english), "4 GB/s")
    XCTAssertEqual(TransferFormat.speed(-1, locale: english), "")
    XCTAssertEqual(TransferFormat.speed(nil, locale: english), "")
    XCTAssertEqual(TransferFormat.speed(.nan, locale: english), "")
  }

  func testDurationsPickTheirUnitAtOneAndAHalfMinutesAndHours() {
    XCTAssertEqual(TransferFormat.duration(45, locale: english), "45 sec")
    XCTAssertEqual(TransferFormat.duration(89, locale: english), "89 sec", "still seconds under a minute and a half")
    XCTAssertEqual(TransferFormat.duration(90, locale: english), "2 min")
    XCTAssertEqual(TransferFormat.duration(300, locale: english), "5 min")
    XCTAssertEqual(TransferFormat.duration(5_399, locale: english), "90 min")
    XCTAssertEqual(TransferFormat.duration(5_400, locale: english), "1.5 hr")
    XCTAssertEqual(TransferFormat.duration(7_200, locale: english), "2 hr")
    for value in [nil, 0, -5, .nan] as [Double?] {
      XCTAssertEqual(TransferFormat.duration(value, locale: english), "")
    }
  }

  func testDurationFollowsTheLocale() {
    XCTAssertNotEqual(
      TransferFormat.duration(300, locale: Locale(identifier: "ja_JP")),
      TransferFormat.duration(300, locale: english))
  }

  func testPercentIsClampedRoundedAndEmptyWhenUnknown() {
    XCTAssertEqual(TransferFormat.percent(0), "0%")
    XCTAssertEqual(TransferFormat.percent(0.424), "42%")
    XCTAssertEqual(TransferFormat.percent(0.425), "43%")
    XCTAssertEqual(TransferFormat.percent(1.7), "100%")
    XCTAssertEqual(TransferFormat.percent(-0.2), "0%")
    XCTAssertEqual(TransferFormat.percent(nil), "")
    XCTAssertEqual(TransferFormat.percent(.nan), "")
  }

  func testTheTransferLineJoinsOnlyWhatIsKnown() {
    let full = TransferFormat.Progress(
      progress: 0.42, bytesReceived: 860, bytesExpected: 2_048, bytesPerSecond: 600_000,
      secondsRemaining: 300)
    XCTAssertEqual(
      TransferFormat.transfer(full, locale: english),
      "42% · 860 B of 2 KB · Network speed: 600 KB/s · 5 min left")
    XCTAssertEqual(
      TransferFormat.transfer(full, includePercent: false, locale: english),
      "860 B of 2 KB · Network speed: 600 KB/s · 5 min left")
    XCTAssertEqual(
      TransferFormat.transfer(.init(progress: 0.5), locale: english), "50%")
    XCTAssertEqual(
      TransferFormat.transfer(.init(bytesReceived: 1_024), locale: english), "1 KB",
      "without a total there is no \"of\"")
    XCTAssertEqual(TransferFormat.transfer(.init(), locale: english), "")
  }

  func testRateAndTimeLeftAreEmptyWithoutTheirNumber() {
    XCTAssertEqual(TransferFormat.rate(nil, locale: english), "")
    XCTAssertEqual(TransferFormat.rate(-3, locale: english), "")
    XCTAssertEqual(TransferFormat.rate(1_500, locale: english), "Network speed: 1.5 KB/s")
    XCTAssertEqual(TransferFormat.timeLeft(0, locale: english), "")
    XCTAssertEqual(TransferFormat.timeLeft(120, locale: english), "2 min left")
  }
}
