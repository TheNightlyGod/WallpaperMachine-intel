import XCTest

@testable import WallpaperMachine

/// How many columns a grid of tiles takes, and how a flow of chips wraps: the layout rules the
/// library, Workshop and pixiv pages share.
final class TileGridLayoutTests: XCTestCase {
  func testAsManyColumnsAsFitTheWidthAtTheTilesPreferredSize() {
    let gap: CGFloat = 14
    // Three 140-point tiles and their two gaps are exactly 448 points.
    XCTAssertEqual(TileGridLayout.columnCount(forWidth: 448, spacing: gap), 3)
    XCTAssertEqual(
      TileGridLayout.columnCount(forWidth: 447, spacing: gap), 3, "Never fewer than three")
    // A fourth tile needs 154 more.
    XCTAssertEqual(TileGridLayout.columnCount(forWidth: 601, spacing: gap), 3)
    XCTAssertEqual(TileGridLayout.columnCount(forWidth: 602, spacing: gap), 4)
    XCTAssertEqual(TileGridLayout.columnCount(forWidth: 1000, spacing: gap), 6)
    XCTAssertEqual(TileGridLayout.columnCount(forWidth: 2000, spacing: gap), 13)
  }

  func testANarrowOrUnmeasuredGridKeepsThreeColumns() {
    for width in [CGFloat(0), 60, 240, -20, .nan, .infinity] {
      XCTAssertEqual(TileGridLayout.columnCount(forWidth: width, spacing: 14), 3, "\(width)")
    }
  }

  func testZoomStepsChangeThePreferredWidthAndStopAtTheEnds() {
    XCTAssertEqual(TileGridLayout.preferredWidth(zoom: 0), TileGridLayout.preferredTileWidth)
    XCTAssertLessThan(TileGridLayout.preferredWidth(zoom: -1), TileGridLayout.preferredWidth(zoom: 0))
    XCTAssertGreaterThan(TileGridLayout.preferredWidth(zoom: 2), TileGridLayout.preferredWidth(zoom: 1))
    XCTAssertEqual(TileGridLayout.preferredWidth(zoom: -9), TileGridLayout.zoomWidths.first)
    XCTAssertEqual(TileGridLayout.preferredWidth(zoom: 9), TileGridLayout.zoomWidths.last)
    let wide = TileGridLayout.preferredWidth(zoom: 2)
    XCTAssertLessThan(
      TileGridLayout.columnCount(forWidth: 1000, spacing: 14, preferredWidth: wide),
      TileGridLayout.columnCount(forWidth: 1000, spacing: 14), "larger tiles fit fewer columns")
    XCTAssertEqual(
      TileGridLayout.columnCount(forWidth: 300, spacing: 14, preferredWidth: wide), 3, "never fewer than three")
  }

  func testAWiderGapFitsFewerTiles() {
    XCTAssertEqual(TileGridLayout.columnCount(forWidth: 1000, spacing: 12), 6)
    XCTAssertEqual(TileGridLayout.columnCount(forWidth: 1000, spacing: 40), 5)
  }

  func testArrowKeysMoveByCellAndRowAndAreHeldAtTheEnds() {
    func go(_ from: Int, _ move: TileGridLayout.Move) -> Int? {
      TileGridLayout.destination(from: from, move, columns: 4, count: 10)
    }
    XCTAssertEqual(go(5, .right), 6)
    XCTAssertEqual(go(5, .left), 4)
    XCTAssertEqual(go(5, .down), 9, "Down moves a whole row")
    XCTAssertEqual(go(5, .up), 1)
    XCTAssertEqual(go(5, .first), 0)
    XCTAssertEqual(go(5, .last), 9)
    XCTAssertNil(go(0, .left), "Focus does not wrap to the end")
    XCTAssertNil(go(9, .right))
    XCTAssertNil(go(2, .up), "or climb out of the first row")
    XCTAssertNil(go(7, .down), "Nothing below the short last row")
    XCTAssertNil(TileGridLayout.destination(from: 0, .last, columns: 3, count: 0))
  }

  func testChipsWrapOntoNewLinesAtTheWidthAndKeepTheirOrder() {
    let sizes = [
      CGSize(width: 50, height: 20), CGSize(width: 50, height: 22), CGSize(width: 50, height: 20),
    ]
    let arranged = TagFlow.arrange(sizes, width: 120, spacing: 10)
    XCTAssertEqual(
      arranged.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0), CGPoint(x: 0, y: 32)])
    XCTAssertEqual(arranged.size, CGSize(width: 110, height: 52))
  }

  func testAChipWiderThanTheLineSitsAloneAndNoWidthMeansOneLine() {
    let wide = [
      CGSize(width: 40, height: 20), CGSize(width: 200, height: 20), CGSize(width: 30, height: 20),
    ]
    let wrapped = TagFlow.arrange(wide, width: 100, spacing: 6)
    XCTAssertEqual(wrapped.origins.map(\.y), [0, 26, 52])
    XCTAssertEqual(wrapped.size.width, 200)
    let single = TagFlow.arrange(wide, width: nil, spacing: 6)
    XCTAssertEqual(single.origins.map(\.y), [0, 0, 0])
    XCTAssertEqual(single.size, CGSize(width: 40 + 6 + 200 + 6 + 30, height: 20))
    XCTAssertEqual(TagFlow.arrange([], width: 100, spacing: 6).size, .zero)
  }

  /// Controls of different heights in one row (the accent swatches, the colour well and the hex)
  /// share the row's centre line, each line by its own tallest child; the rows take the same room
  /// as they do top-aligned.
  func testCentredRowsSetEachChildOnItsOwnRowsCentreLine() {
    let sizes = [
      CGSize(width: 26, height: 26), CGSize(width: 38, height: 22), CGSize(width: 60, height: 14),
      CGSize(width: 26, height: 26), CGSize(width: 60, height: 14),
    ]
    let centred = TagFlow.arrange(sizes, width: 140, spacing: 4, centersRows: true)
    let top = TagFlow.arrange(sizes, width: 140, spacing: 4)
    XCTAssertEqual(centred.size, top.size)
    XCTAssertEqual(centred.origins.map(\.x), top.origins.map(\.x))
    let middles = zip(centred.origins, sizes).map { $0.y + $1.height / 2 }
    XCTAssertEqual(middles, [13, 13, 13, 43, 43], "26-point rows, 4 points apart")
    XCTAssertEqual(top.origins.map(\.y), [0, 0, 0, 30, 30], "Top-aligned unless asked")
  }
}
