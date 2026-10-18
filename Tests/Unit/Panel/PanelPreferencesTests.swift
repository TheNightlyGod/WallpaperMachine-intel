import XCTest

@testable import WallpaperMachine

/// The panel's persisted choices keep the keys earlier builds wrote, so an existing user keeps the
/// favorites they marked and does not meet the welcome guide again.
final class PanelPreferencesTests: XCTestCase {
  private func defaults() throws -> UserDefaults { try TemporaryDefaults.make(for: self).defaults }

  func testTheKeysAreWhatEarlierBuildsWrote() {
    XCTAssertEqual(PanelPreferences.welcomeSeenKey, "WallpaperMachine.welcomeSeen")
    XCTAssertEqual(PanelPreferences.favoritesKey, "WallpaperMachine.favoriteWallpaperIDs")
    XCTAssertEqual(PanelPreferences.dragSelectLearnedKey, "WallpaperMachine.dragSelectLearned")
    XCTAssertEqual(PanelPreferences.hideAfterActivatingKey, "WallpaperMachine.hideAfterActivating")
    XCTAssertEqual(PanelPreferences.legacyInspectorWidthKey, "WallpaperMachine.inspectorWidth")
  }

  func testFlagsStartOffAndStayOnOnceSet() throws {
    let defaults = try defaults()
    XCTAssertFalse(PanelPreferences.welcomeSeen(in: defaults))
    XCTAssertFalse(PanelPreferences.dragSelectLearned(in: defaults))
    XCTAssertFalse(PanelPreferences.hidesAfterActivating(in: defaults), "the panel stays open unless turned on")
    PanelPreferences.markWelcomeSeen(in: defaults)
    PanelPreferences.markDragSelectLearned(in: defaults)
    XCTAssertTrue(PanelPreferences.welcomeSeen(in: defaults))
    XCTAssertTrue(PanelPreferences.dragSelectLearned(in: defaults))
    XCTAssertTrue(defaults.bool(forKey: "WallpaperMachine.welcomeSeen"), "the launch rule reads the same key")
    defaults.set(true, forKey: PanelPreferences.hideAfterActivatingKey)
    XCTAssertTrue(PanelPreferences.hidesAfterActivating(in: defaults))
  }

  func testFavoritesAreTheJSONOfTheSortedArrayAndRoundTrip() throws {
    let defaults = try defaults()
    XCTAssertEqual(PanelPreferences.favorites(in: defaults), [])
    try PanelPreferences.saveFavorites(["b", "a", "c"], in: defaults)
    let data = try XCTUnwrap(defaults.data(forKey: "WallpaperMachine.favoriteWallpaperIDs"))
    XCTAssertEqual(try JSONDecoder().decode([String].self, from: data), ["a", "b", "c"])
    XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["a","b","c"]"#)
    XCTAssertEqual(PanelPreferences.favorites(in: defaults), ["a", "b", "c"])
  }

  func testUnreadableFavoritesAreEmptyNotAFailure() throws {
    let defaults = try defaults()
    defaults.set(["a"], forKey: PanelPreferences.favoritesKey)
    XCTAssertEqual(PanelPreferences.favorites(in: defaults), [], "a property-list array is not the stored form")
    defaults.set(Data("not json".utf8), forKey: PanelPreferences.favoritesKey)
    XCTAssertEqual(PanelPreferences.favorites(in: defaults), [])
  }

  func testTheLegacyInspectorWidthIsRemovedAndNothingElse() throws {
    let defaults = try defaults()
    defaults.set(412, forKey: PanelPreferences.legacyInspectorWidthKey)
    PanelPreferences.markWelcomeSeen(in: defaults)
    PanelPreferences.removeLegacyKeys(from: defaults)
    XCTAssertNil(defaults.object(forKey: PanelPreferences.legacyInspectorWidthKey))
    XCTAssertTrue(PanelPreferences.welcomeSeen(in: defaults))
  }
}
