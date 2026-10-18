import SwiftUI
import XCTest

@testable import WallpaperMachine

/// Which tile a point is on, without asking the views.
@MainActor
final class LibraryGridGeometryTests: XCTestCase {
  /// 4 columns at 760 points wide: (760 - 40 + 14) / (140 + 14) = 4.
  private var geometry: LibraryGridGeometry {
    var geometry = LibraryGridGeometry()
    geometry.viewport = CGSize(width: 760, height: 500)
    geometry.cellSize = CGSize(width: 165, height: 200)
    geometry.contentHeight = 2_000
    return geometry
  }

  func testTheColumnCountIsTheGridsOwnRule() {
    XCTAssertEqual(geometry.columns, 4)
    var narrow = geometry
    narrow.viewport.width = 260
    XCTAssertEqual(narrow.columns, 3, "never fewer than three")
  }

  func testPointsMapToTilesInRowMajorOrder() {
    let geometry = geometry
    XCTAssertEqual(geometry.index(at: CGPoint(x: 30, y: 30), count: 20), 0)
    XCTAssertEqual(geometry.index(at: CGPoint(x: 20 + 179 + 5, y: 30), count: 20), 1)
    XCTAssertEqual(geometry.index(at: CGPoint(x: 30, y: 12 + 214 + 5), count: 20), 4)
    XCTAssertEqual(geometry.index(at: CGPoint(x: 600, y: 30), count: 20), 3)
  }

  func testGapsMarginsAndPointsPastTheLastTileAreNoTile() {
    let geometry = geometry
    XCTAssertNil(geometry.index(at: CGPoint(x: 10, y: 30), count: 20), "the margin")
    XCTAssertNil(geometry.index(at: CGPoint(x: 20 + 165 + 7, y: 30), count: 20), "the gap between columns")
    XCTAssertNil(geometry.index(at: CGPoint(x: 30, y: 12 + 200 + 7), count: 20), "the gap between rows")
    XCTAssertNil(geometry.index(at: CGPoint(x: 30, y: 4), count: 20), "above the first row")
    XCTAssertNil(geometry.index(at: CGPoint(x: 30 + 3 * 179, y: 12 + 214 + 30), count: 6), "past the last tile")
    XCTAssertNil(LibraryGridGeometry().index(at: CGPoint(x: 30, y: 30), count: 5), "not measured yet")
  }

  func testScrollingMovesTheTilesUnderThePointer() {
    var scrolled = geometry
    scrolled.offsetY = 214
    XCTAssertEqual(scrolled.index(at: CGPoint(x: 30, y: 30), count: 20), 4)
    XCTAssertEqual(scrolled.frame(ofIndex: 4).minY, 12, accuracy: 0.001)
    XCTAssertEqual(scrolled.maxOffset, 1_500)
  }

  func testAFractionalTileWidthStillFindsTheLastColumn() {
    var fractional = geometry
    fractional.viewport.width = 775
    fractional.cellSize = CGSize(width: 168.25, height: 196.5)
    let frame = fractional.frame(ofIndex: 3)
    XCTAssertEqual(
      fractional.index(at: CGPoint(x: frame.midX, y: frame.midY), count: 20), 3,
      "a tile's own middle always finds the tile")
  }

  func testThePressOnAHeartIsNotASweepAndOnACheckItIs() {
    let geometry = geometry
    let frame = geometry.frame(ofIndex: 1)
    XCTAssertTrue(geometry.isOnHeart(CGPoint(x: frame.maxX - 12, y: frame.minY + 12), tileIndex: 1))
    XCTAssertFalse(geometry.isOnHeart(CGPoint(x: frame.minX + 12, y: frame.minY + 12), tileIndex: 1))
    XCTAssertFalse(geometry.isOnHeart(CGPoint(x: frame.maxX - 12, y: frame.midY), tileIndex: 1))
    XCTAssertTrue(geometry.isOnCheck(CGPoint(x: frame.minX + 12, y: frame.minY + 12), tileIndex: 1))
    XCTAssertFalse(geometry.isOnCheck(CGPoint(x: frame.midX, y: frame.midY), tileIndex: 1))
  }
}
