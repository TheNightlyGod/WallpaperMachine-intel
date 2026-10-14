import XCTest

@testable import WallpaperMachine

/// The black-bar decision over synthetic luma frames: what is measured in one frame and what
/// survives across several. Pure arithmetic; no file, no decoder.
final class LetterboxDetectorTests: XCTestCase {
  private typealias Canvas = LetterboxFixtures.Canvas

  private func verdict(_ canvases: [Canvas]) -> LetterboxDetector.Verdict {
    LetterboxDetector.verdict(frames: canvases.map(\.frame))
  }

  /// Nearly every pixel is black but a diagonal speckle keeps every row and column out of a bar:
  /// a dark scene, which looks like bars to a naive scan.
  private func darkScene() -> Canvas {
    var scene = Canvas()
    for index in scene.luma.indices { scene.luma[index] = (index % 320 + index / 320) % 16 == 0 ? 40 : 12 }
    return scene
  }

  private func repeated(_ count: Int = 5, _ make: (Int) -> Canvas) -> [Canvas] {
    (0..<count).map(make)
  }

  private func expectBars(_ verdict: LetterboxDetector.Verdict, file: StaticString = #filePath,
                          line: UInt = #line) -> LetterboxDetector.Bars? {
    guard case .bars(let bars) = verdict else {
      XCTFail("Expected bars, got \(verdict)", file: file, line: line)
      return nil
    }
    return bars
  }

  // MARK: - One frame

  func testCinemaLetterboxIsMeasuredWithinOneRowAndLeavesTheSidesAtZero() throws {
    // A 2.39:1 picture in a 16:9 frame: (180 - 320 / 2.39) / 2 is about 23 rows a side.
    let bars = try XCTUnwrap(LetterboxDetector.edges(of: Canvas(top: 23, bottom: 23).frame))
    XCTAssertEqual(bars.top, 23.0 / 180, accuracy: 1.0 / 180)
    XCTAssertEqual(bars.bottom, 23.0 / 180, accuracy: 1.0 / 180)
    XCTAssertEqual(bars.left, 0)
    XCTAssertEqual(bars.right, 0)
  }

  func testPillarboxIsMeasuredAsLeftAndRight() throws {
    let bars = try XCTUnwrap(LetterboxDetector.edges(of: Canvas(left: 40, right: 40).frame))
    XCTAssertEqual(bars.left, 0.125, accuracy: 1.0 / 320)
    XCTAssertEqual(bars.right, 0.125, accuracy: 1.0 / 320)
    XCTAssertEqual(bars.top, 0)
    XCTAssertEqual(bars.bottom, 0)
  }

  func testWindowboxIsMeasuredOnAllFourEdges() throws {
    // The columns are judged over the picture rows only, so the bars above and below do not
    // make the side bars look shorter than they are.
    let bars = try XCTUnwrap(LetterboxDetector.edges(of: Canvas(top: 18, bottom: 18, left: 32, right: 32).frame))
    XCTAssertEqual(bars.top, 0.1, accuracy: 1.0 / 180)
    XCTAssertEqual(bars.bottom, 0.1, accuracy: 1.0 / 180)
    XCTAssertEqual(bars.left, 0.1, accuracy: 1.0 / 320)
    XCTAssertEqual(bars.right, 0.1, accuracy: 1.0 / 320)
  }

  func testFramesThatCannotBeJudgedAreSkipped() {
    XCTAssertNil(LetterboxDetector.edges(of: Canvas(top: 90, bottom: 90).frame), "an all-black frame is a fade")
    XCTAssertNil(LetterboxDetector.edges(of: LetterboxDetector.Frame(width: 4, height: 4, luma: [0, 1, 2])), "luma that does not fit")
    XCTAssertNil(LetterboxDetector.edges(of: LetterboxDetector.Frame(width: 0, height: 0, luma: [])))
    XCTAssertNil(LetterboxDetector.edges(of: darkScene().frame), "a picture area that averages this dark is not evidence")
  }

  // MARK: - Across frames

  func testFullBleedPictureAndHairlineEdgesAreNotBars() {
    XCTAssertEqual(verdict(repeated { Canvas(seed: $0) }), .none)
    // Half a percent of the frame, a pixel or two, is under the minimum edge.
    XCTAssertEqual(verdict(repeated { Canvas(top: 1, bottom: 1, left: 2, right: 2, seed: $0) }), .none)
  }

  func testLetterboxedFramesGiveBarsOnTheTopAndBottomOnly() throws {
    let bars = try XCTUnwrap(expectBars(verdict(repeated { Canvas(top: 23, bottom: 23, seed: $0) })))
    XCTAssertEqual(bars.top, 23.0 / 180, accuracy: 1.0 / 180)
    XCTAssertEqual(bars.bottom, 23.0 / 180, accuracy: 1.0 / 180)
    XCTAssertEqual(bars.left, 0)
    XCTAssertEqual(bars.right, 0)
  }

  func testPillarboxAndWindowboxGiveBars() throws {
    let pillar = try XCTUnwrap(expectBars(verdict(repeated { Canvas(left: 40, right: 40, seed: $0) })))
    XCTAssertEqual(pillar.left, 0.125, accuracy: 1.0 / 320)
    XCTAssertEqual(pillar.top, 0)
    let window = try XCTUnwrap(expectBars(verdict(repeated { Canvas(top: 18, bottom: 18, left: 32, right: 32, seed: $0) })))
    XCTAssertGreaterThan(window.top, 0.05)
    XCTAssertGreaterThan(window.left, 0.05)
  }

  func testCodecNoiseAndALogoInsideABarStillDetect() throws {
    let frames = repeated { index -> Canvas in
      var canvas = Canvas(top: 23, bottom: 23, seed: index)
      // Black that is not quite black (16 plus or minus 3), and a small bright mark in the bar.
      for position in canvas.luma.indices where canvas.luma[position] == 0 {
        canvas.luma[position] = UInt8(13 + (position &* 2_654_435_761) % 7)
      }
      canvas.fill(x: 20, y: 6, width: 3, height: 3, luma: 235)
      return canvas
    }
    let bars = try XCTUnwrap(expectBars(verdict(frames)))
    XCTAssertEqual(bars.top, 23.0 / 180, accuracy: 1.0 / 180)
    XCTAssertEqual(bars.bottom, 23.0 / 180, accuracy: 1.0 / 180)
  }

  func testSubtitleInTheLowerBarInSomeFramesDoesNotChangeTheAnswer() throws {
    let frames = repeated { index -> Canvas in
      var canvas = Canvas(top: 23, bottom: 23, seed: index)
      // Burnt-in text 4 to 12 rows above the bottom edge in two of the five frames.
      if index < 2 { canvas.fill(x: 90, y: 160, width: 140, height: 8, luma: 230) }
      return canvas
    }
    // Measured alone, those frames' lower bars are shorter.
    XCTAssertEqual(try XCTUnwrap(LetterboxDetector.edges(of: frames[0].frame)).bottom, 12.0 / 180, accuracy: 1.0 / 180)
    let bars = try XCTUnwrap(expectBars(verdict(frames)))
    XCTAssertEqual(bars.bottom, 23.0 / 180, accuracy: 1.0 / 180)
  }

  func testFadeAndDarkSceneFramesAreSkippedNotCounted() throws {
    var frames = repeated(4) { Canvas(top: 23, bottom: 23, seed: $0) }
    frames.append(Canvas(top: 90, bottom: 90))
    XCTAssertNotNil(expectBars(verdict(frames)))
    frames[4] = darkScene()
    XCTAssertNotNil(expectBars(verdict(frames)))
  }

  func testMostlyDarkFramesAreTooDarkAndTwoUsableFramesAreTooFew() {
    XCTAssertEqual(verdict(repeated { _ in Canvas(top: 90, bottom: 90) }), .indeterminate(.tooDark))
    XCTAssertEqual(verdict(repeated(4) { index in index < 3 ? Canvas(top: 90, bottom: 90) : Canvas(top: 23, bottom: 23) }),
                   .indeterminate(.tooDark))
    XCTAssertEqual(verdict(repeated(2) { Canvas(top: 23, bottom: 23, seed: $0) }), .indeterminate(.tooFewFrames))
    XCTAssertEqual(verdict([]), .indeterminate(.tooFewFrames))
    // Two usable frames and one fade is still too few, and not the fade's fault.
    XCTAssertEqual(verdict(repeated(3) { $0 == 2 ? Canvas(top: 90, bottom: 90) : Canvas(top: 23, bottom: 23) }),
                   .indeterminate(.tooFewFrames))
  }

  func testFramesThatDisagreeAboutTheBarsAreIndeterminate() {
    // 12%, 9%, 6%, 3% and 1.6% of the height: no two within a point and a half of each other.
    let rows = [22, 16, 11, 5, 3]
    XCTAssertEqual(verdict(rows.enumerated().map { Canvas(top: $1, bottom: $1, seed: $0) }), .indeterminate(.disagree))
  }

  func testOneSidedAndLopsidedBarsAreUneven() throws {
    guard case .uneven(let lopsided) = verdict(repeated { Canvas(top: 22, bottom: 5, seed: $0) }) else {
      return XCTFail("12% on top with 3% below cannot be hidden by a centred zoom")
    }
    XCTAssertGreaterThan(lopsided.top, lopsided.bottom)
    guard case .uneven(let single) = verdict(repeated { Canvas(top: 22, seed: $0) }) else {
      return XCTFail("a bar on one side only is uneven")
    }
    XCTAssertEqual(single.bottom, 0)
    // Close bars are one bar to the eye: 22 and 20 rows differ by a point.
    XCTAssertNotNil(expectBars(verdict(repeated { Canvas(top: 22, bottom: 20, seed: $0) })))
  }

  func testBarsAddingUpToMoreThan45PercentOfAnAxisAreNotTrusted() {
    XCTAssertEqual(verdict(repeated { Canvas(top: 44, bottom: 44, seed: $0) }), .indeterminate(.implausible))
    XCTAssertEqual(verdict(repeated { Canvas(left: 80, right: 80, seed: $0) }), .indeterminate(.implausible))
  }

  func testFramesSplitEvenlyDisagreeButThreeOfFourAgree() throws {
    // Four usable frames split between two bar sizes further apart than the tolerance: the lower
    // median is 11 rows, and only half of the frames agree with it.
    let frames = [11, 11, 22, 22].enumerated().map { Canvas(top: $1, bottom: $1, seed: $0) }
    XCTAssertEqual(verdict(frames), .indeterminate(.disagree))
    // Three of four agreeing is enough, and the answer is the agreeing size.
    let mostly = [22, 22, 22, 11].enumerated().map { Canvas(top: $1, bottom: $1, seed: $0) }
    XCTAssertEqual(try XCTUnwrap(expectBars(verdict(mostly))).top, 22.0 / 180, accuracy: 1.0 / 180)
  }
}
