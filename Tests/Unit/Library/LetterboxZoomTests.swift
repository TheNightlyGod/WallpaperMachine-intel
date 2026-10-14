import XCTest

@testable import WallpaperMachine

/// The scale factor that makes Fill crop baked-in bars off a given display. The engine's Fill
/// layout shows `min(1, displayAspect / videoAspect)` of the width and
/// `min(1, videoAspect / displayAspect)` of the height at factor 1; the expected values below
/// are worked from that, not read back from the function.
final class LetterboxZoomTests: XCTestCase {
  private let video = 16.0 / 9.0
  private let display1080 = CGSize(width: 1920, height: 1080)
  private let display1200 = CGSize(width: 1920, height: 1200)
  private let ultrawide = CGSize(width: 2560, height: 1080)

  private func bars(top: Double = 0, bottom: Double = 0, left: Double = 0, right: Double = 0) -> LetterboxDetector.Bars {
    .init(top: top, bottom: bottom, left: left, right: right)
  }

  func testCinemaBarsNeedTheSameZoomOn16x9And16x10Displays() {
    // 12.5% above and below leaves 75% of the height: 1 / 0.75 = 1.3333, plus half a percent.
    let letterboxed = bars(top: 0.125, bottom: 0.125)
    XCTAssertEqual(LetterboxZoom.outcome(bars: letterboxed, aspect: video, viewport: display1080), .factor(1.34))
    // A 16:10 display already crops a tenth of the width, which does not touch the bars.
    XCTAssertEqual(LetterboxZoom.outcome(bars: letterboxed, aspect: video, viewport: display1200), .factor(1.34))
  }

  func testUltrawideDisplayAlreadyCropsTheBarsOut() {
    // Fill on 64:27 shows 75% of a 16:9 video's height at factor 1: the 12.5% bars are gone.
    XCTAssertEqual(LetterboxZoom.outcome(bars: bars(top: 0.125, bottom: 0.125), aspect: video, viewport: ultrawide), .alreadyHidden)
    // Slightly deeper bars leave a sliver; that earns a small factor, not silence.
    XCTAssertEqual(LetterboxZoom.outcome(bars: bars(top: 0.14, bottom: 0.14), aspect: video, viewport: ultrawide), .factor(1.05))
  }

  func testPillarboxNeedsTheWidthZoomOnTheDisplayThatShowsTheWholeWidth() {
    // A 4:3 picture inside 16:9 leaves 75% of the width.
    let pillarboxed = bars(left: 0.125, right: 0.125)
    XCTAssertEqual(LetterboxZoom.outcome(bars: pillarboxed, aspect: video, viewport: display1080), .factor(1.34))
    // 16:10 shows 90% of the width at factor 1: 0.9 / 0.75 = 1.2, plus half a percent.
    XCTAssertEqual(LetterboxZoom.outcome(bars: pillarboxed, aspect: video, viewport: display1200), .factor(1.21))
    // A 4:3 display shows exactly the picture.
    XCTAssertEqual(LetterboxZoom.outcome(bars: pillarboxed, aspect: video, viewport: CGSize(width: 1600, height: 1200)), .alreadyHidden)
  }

  func testWindowboxTakesTheLargerAxisAndLopsidedBarsTheLargerSide() {
    // 5% above and below leaves 90%, 10% at the sides leaves 80%: the width decides.
    XCTAssertEqual(LetterboxZoom.outcome(bars: bars(top: 0.05, bottom: 0.05, left: 0.1, right: 0.1), aspect: video, viewport: display1080), .factor(1.26))
    // 10% above and 14% below is cut as 14% from both ends: 1 / 0.72 = 1.3889.
    XCTAssertEqual(LetterboxZoom.outcome(bars: bars(top: 0.10, bottom: 0.14), aspect: video, viewport: display1080), .factor(1.40))
  }

  func testHugeOrNonsenseRequirementsAreImplausible() {
    XCTAssertEqual(LetterboxZoom.outcome(bars: bars(top: 0.35, bottom: 0.35), aspect: video, viewport: display1080), .implausible)
    XCTAssertEqual(LetterboxZoom.outcome(bars: bars(top: 0.5, bottom: 0.5), aspect: video, viewport: display1080), .implausible)
    XCTAssertEqual(LetterboxZoom.outcome(bars: bars(top: 0.1, bottom: 0.1), aspect: 0, viewport: display1080), .implausible)
    XCTAssertEqual(LetterboxZoom.outcome(bars: bars(top: 0.1, bottom: 0.1), aspect: video, viewport: .zero), .implausible)
    XCTAssertEqual(LetterboxZoom.outcome(bars: bars(top: 0.1, bottom: 0.1), aspect: .infinity, viewport: display1080), .implausible)
  }

  func testFactorsGrowWithTheBarsAndAreAlwaysRoundedUpToTwoDecimals() {
    var previous = 1.0
    for hundredths in 2...30 {
      let size = Double(hundredths) / 100
      let outcome = LetterboxZoom.outcome(bars: bars(top: size, bottom: size), aspect: video, viewport: display1080)
      guard case .factor(let factor) = outcome else {
        XCTFail("\(size) of bar should need a factor, got \(outcome)")
        continue
      }
      XCTAssertGreaterThanOrEqual(factor, previous, "bigger bars never need a smaller factor")
      previous = factor
      XCTAssertEqual(factor * 100, (factor * 100).rounded(), accuracy: 1e-9, "two decimals")
      // Never short of what hides the bars, and never a hundredth more than needed after overscan.
      let needed = 1 / (1 - 2 * size) * LetterboxZoom.overscan
      XCTAssertGreaterThanOrEqual(factor, needed - 1e-9)
      XCTAssertLessThan(factor, needed + 0.01 + 1e-9)
    }
  }
}
