import AppKit
import XCTest

@testable import WallpaperMachine

final class AppIconImageTests: XCTestCase {
  func testEveryDockIconLoadsFromTheAppBundleAtFullSize() throws {
    var artwork: [Data] = []
    for icon in AppThemePreferences.Icon.allCases {
      let image = try icon.image()
      XCTAssertTrue(image.isValid, icon.rawValue)
      XCTAssertEqual(image.size, NSSize(width: 512, height: 512), icon.rawValue)
      let pixels = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
      XCTAssertGreaterThanOrEqual(pixels, 1024, "\(icon.rawValue) must stay sharp on a Retina Dock")
      artwork.append(try XCTUnwrap(image.tiffRepresentation, icon.rawValue))
    }
    XCTAssertEqual(AppThemePreferences.Icon.allCases.count, 3)
    XCTAssertEqual(Set(artwork).count, artwork.count, "Each icon is its own artwork")
  }

  func testTheHalloweenDockIconLoadsAtFullSizeAndIsItsOwnArtwork() throws {
    let halloween = try AppThemePreferences.dockImage(named: Season.halloween.dockImageName)
    XCTAssertEqual(halloween.size, NSSize(width: 512, height: 512))
    let pixels = halloween.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
    XCTAssertGreaterThanOrEqual(pixels, 1024)
    let artwork = try XCTUnwrap(halloween.tiffRepresentation)
    for icon in AppThemePreferences.Icon.allCases {
      XCTAssertNotEqual(try icon.image().tiffRepresentation, artwork, icon.rawValue)
    }
    XCTAssertThrowsError(
      try AppThemePreferences.dockImage(named: Season.halloween.dockImageName, in: Bundle(for: Self.self)))
  }

  func testLoadingTwiceHandsOutIndependentImages() throws {
    let first = try AppThemePreferences.Icon.day.image()
    first.size = NSSize(width: 16, height: 16)
    XCTAssertEqual(try AppThemePreferences.Icon.day.image().size, NSSize(width: 512, height: 512))
  }

  func testBundleWithoutTheArtworkThrowsInsteadOfReturningABlankIcon() {
    let empty = Bundle(for: Self.self)
    for icon in AppThemePreferences.Icon.allCases {
      XCTAssertThrowsError(try icon.image(in: empty), icon.rawValue)
    }
  }
}
