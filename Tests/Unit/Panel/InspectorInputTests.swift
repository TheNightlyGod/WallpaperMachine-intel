import XCTest

@testable import WallpaperMachine

/// The numbers a person types into the Displays card: parsed in the panel's locale, never read as 0
/// from an empty field, and held to the range the display offers.
@MainActor
final class InspectorInputTests: XCTestCase {
  func testAScaleFactorIsAWholeFiniteDecimalAboveZeroInTheLocalesOwnNotation() {
    let english = Locale(identifier: "en_US")
    let german = Locale(identifier: "de_DE")
    XCTAssertEqual(ScaleFactorInput.parse("1.34", locale: english), 1.34)
    XCTAssertEqual(ScaleFactorInput.parse(" 2 ", locale: english), 2)
    XCTAssertEqual(ScaleFactorInput.parse("1,34", locale: german), 1.34)
    XCTAssertEqual(ScaleFactorInput.parse("0.5", locale: english), 0.5)
    for refused in ["", "   ", "0", "-1", "1abc", "abc", "1.2.3", "1e3x", "∞", "nan"] {
      XCTAssertNil(ScaleFactorInput.parse(refused, locale: english), "\(refused) is not a scale factor")
    }
  }

  func testAFrameRateIsAWholeNumberHeldToTheDisplaysRangeAndAnEmptyFieldIsNothing() {
    XCTAssertEqual(FrameRateInput.parse("30", maximum: 60), 30)
    XCTAssertEqual(FrameRateInput.parse(" 45 ", maximum: 60), 45)
    XCTAssertEqual(FrameRateInput.parse("240", maximum: 60), 60, "held to the display's own maximum")
    XCTAssertEqual(FrameRateInput.parse("0", maximum: 60), 1, "a typed zero is the lowest rate, never sent as 0")
    XCTAssertNil(FrameRateInput.parse("", maximum: 60), "an empty field never becomes a value")
    XCTAssertNil(FrameRateInput.parse("3.5", maximum: 60))
    XCTAssertNil(FrameRateInput.parse("-5", maximum: 60))
    XCTAssertNil(FrameRateInput.parse("fast", maximum: 60))
    XCTAssertEqual(FrameRateInput.clamp(500, maximum: 0), 1, "a maximum the display did not report is never read as less than 1")
    XCTAssertEqual(FrameRateInput.clamp(-4, maximum: 30), 1)
  }

  /// Two clicks of the stepper on 30 before the first save lands ask for 31 and then 32, not 31
  /// twice; once nothing is on its way the row shows the renderer's value again.
  func testAStepMovesFromTheRateLastAskedForUntilItsSaveHasFinished() {
    var draft = FrameRateDraft()
    XCTAssertEqual(draft.shown(saved: 30), 30)
    draft.ask(draft.shown(saved: 30) + 1)
    draft.ask(draft.shown(saved: 30) + 1)
    XCTAssertEqual(draft.shown(saved: 30), 32, "the second step moves on from the first")
    draft.answered(31)
    XCTAssertTrue(draft.isWaiting, "an older save finishing leaves the newer one waiting")
    XCTAssertEqual(draft.shown(saved: 31), 32)
    draft.answered(32)
    XCTAssertFalse(draft.isWaiting)
    XCTAssertEqual(draft.shown(saved: 32), 32)

    draft.ask(33)
    draft.answered(33)
    XCTAssertEqual(draft.shown(saved: 32), 32, "a refused save shows the renderer's value again")
  }

  /// A switch, choice or colour stays beside its label while the label fits on one line; otherwise
  /// it moves under it. The hidden Modified mark counts, so changing the value never moves it.
  func testASmallControlMovesUnderItsLabelOnlyWhenTheLabelWouldNotFitBesideIt() {
    func beside(label: CGFloat, marks: CGFloat = 22, control: CGFloat = 40, width: CGFloat) -> Bool {
      PropertyTopLineLayout.fitsBeside(
        label: label, marks: marks, control: control, spacing: 8, width: width)
    }
    XCTAssertTrue(beside(label: 90, marks: 22 + 70, width: 244), "90 + 8 + 92 + 8 + 40 = 238")
    XCTAssertFalse(beside(label: 90, marks: 22 + 70, width: 204), "the narrowest column")
    XCTAssertFalse(
      beside(label: 300, marks: 22, control: 120, width: 244),
      "a long author label above a choice, rather than broken beside it")
    XCTAssertTrue(beside(label: 300, control: 0, width: 100), "nothing beside the label to move")
    XCTAssertTrue(beside(label: 100, marks: 0, control: 40, width: 148), "no marks, one gap")
    XCTAssertFalse(beside(label: 100, marks: 0, control: 40, width: 147))
  }
}
