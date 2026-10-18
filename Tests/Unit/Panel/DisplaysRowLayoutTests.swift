import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The row layout of Settings › Displays: text and control side by side while they fit, the control
/// under the text when they do not, and a minimum width that never exceeds the control's.
@MainActor
final class DisplaysRowLayoutTests: XCTestCase {
  private let longText =
    "A change that falls due while they are paused, the screen is locked or the displays sleep happens once they play again."

  private func size<V: View>(_ view: V, width: CGFloat) -> CGSize {
    NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: width, height: 4000))
  }

  private func row(forcesStack: Bool = false, fillsControl: Bool = false, controlWidth: CGFloat = 200)
    -> some View
  {
    DisplaysRowLayout(forcesStack: forcesStack, fillsControl: fillsControl) {
      Text(verbatim: longText).font(.system(size: 13))
      Color.clear.frame(width: controlWidth, height: 24)
    }
  }

  func testWithRoomTheControlSitsBesideTheTextAndTheRowIsAsTallAsTheTaller() {
    let wide = size(row(), width: 600)
    XCTAssertEqual(wide.width, 600, accuracy: 1, "the row takes the width it is given")
    XCTAssertLessThan(wide.height, 60, "a few lines of text, the control beside them")
    let text = size(Text(verbatim: longText).font(.system(size: 13)), width: 600 - 212)
    XCTAssertEqual(wide.height, max(text.height, 24), accuracy: 1)
  }

  func testWithoutRoomTheControlGoesUnderTheText() {
    let narrow = size(row(), width: 230)
    let text = size(Text(verbatim: longText).font(.system(size: 13)), width: 230)
    XCTAssertEqual(narrow.width, 230, accuracy: 1)
    XCTAssertEqual(narrow.height, text.height + 8 + 24, accuracy: 1, "text, a gap, then the control")
  }

  func testTheMinimumWidthIsTheControlsAndNeverTheTextsOrTheSum() {
    let minimum = size(row(), width: 1).width
    XCTAssertEqual(minimum, 200, accuracy: 1, "a control of 200 points under the longest word")
    XCTAssertEqual(size(row(controlWidth: 120), width: 1).width, 120, accuracy: 40, "a word wider than the control sets it")
    XCTAssertLessThan(size(row(), width: 1).width, 12 + 200 + 40, "not the text plus the control")
  }

  func testAForcedStackStaysStackedWhateverTheWidth() {
    let stacked = size(row(forcesStack: true), width: 800)
    let side = size(row(), width: 800)
    XCTAssertGreaterThan(stacked.height, side.height, "a control under the text is taller than one beside it")
  }

  func testAControlThatFillsTakesTheWidthThatIsLeft() {
    let fixed = DisplaysRowLayout(fillsControl: true) {
      Text(verbatim: "Label").frame(width: 100, alignment: .leading)
      Color.clear.frame(minWidth: 40, maxWidth: .infinity, minHeight: 20, maxHeight: 20)
    }
    XCTAssertEqual(size(fixed, width: 500).width, 500, accuracy: 1)
    XCTAssertEqual(size(fixed, width: 1).width, 100, accuracy: 1, "the label is the widest of the two minimums")
  }

  func testARowWithoutAControlStillDrawsItsText() {
    let textOnly = DisplaysRowLayout {
      Text(verbatim: longText).font(.system(size: 13))
      ZStack {}
    }
    let measured = size(textOnly, width: 400)
    XCTAssertGreaterThan(measured.height, 20)
    XCTAssertEqual(measured.width, 400, accuracy: 1)
  }
}
