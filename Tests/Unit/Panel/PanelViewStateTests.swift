import XCTest

@testable import WallpaperMachine

/// What the panel remembers when its window closes is kept in memory and restored once, so every
/// limit on it is a limit on what a runaway filter can park there or hand back to the next window.
final class PanelViewStateTests: XCTestCase {
  private func state(
    text: String = "", sort: String = "title", descending: Bool = false, tags: [String] = [],
    excludedTags: [String] = [], scroll: [String: Double] = [:]
  ) -> PanelViewState {
    PanelViewState(
      installed: .init(
        text: text, sort: sort, descending: descending, tags: tags, excludedTags: excludedTags),
      scroll: scroll)
  }

  func testAFullStateSurvivesNormalizingAndEncoding() throws {
    let full = state(
      text: "夜景 night", sort: "added", descending: true, tags: ["Favorite", "Approved"],
      excludedTags: ["Mature", "Web"], scroll: ["installed": 1_240.5, "discover": 0])
    let kept = try XCTUnwrap(full.normalized())
    XCTAssertEqual(kept, full, "non-ASCII text, a fractional offset and a zero offset stay as they were")
    let decoded = try JSONDecoder().decode(PanelViewState.self, from: JSONEncoder().encode(kept))
    XCTAssertEqual(decoded, kept)
  }

  func testAnEmptyStateIsTheDefaultAndIsAccepted() {
    XCTAssertEqual(PanelViewState().normalized(), PanelViewState())
  }

  func testAnUnknownSortIsRefused() {
    XCTAssertNil(state(sort: "random").normalized())
    XCTAssertNil(state(sort: "").normalized())
    for sort in PanelViewState.sorts { XCTAssertNotNil(state(sort: sort).normalized(), sort) }
  }

  func testTextLongerThanTheSearchFieldAllowsIsRefused() {
    XCTAssertNotNil(state(text: String(repeating: "a", count: 200)).normalized())
    XCTAssertNil(state(text: String(repeating: "a", count: 201)).normalized())
  }

  func testMoreThanThirtyTwoTagsOrAnOverlongTagIsRefused() {
    let limit = (0..<32).map { "tag\($0)" }
    XCTAssertNotNil(state(tags: limit, excludedTags: limit).normalized())
    XCTAssertNil(state(tags: limit + ["one more"]).normalized())
    XCTAssertNil(state(excludedTags: limit + ["one more"]).normalized())
    XCTAssertNil(state(tags: [String(repeating: "t", count: 129)]).normalized())
  }

  func testNonNumericAndNegativeScrollOffsetsAreRefused() {
    XCTAssertNil(state(scroll: ["installed": .nan]).normalized())
    XCTAssertNil(state(scroll: ["installed": .infinity]).normalized())
    XCTAssertNil(state(scroll: ["installed": -1]).normalized())
  }

  func testOffsetsBeyondTheLimitAreClampedAndOtherPagesAreDropped() throws {
    let kept = try XCTUnwrap(
      state(scroll: ["installed": 5_000_000, "pixiv": 80, "settings": 12, "favorites": -4]).normalized())
    XCTAssertEqual(kept.scroll, ["installed": 1_000_000, "pixiv": 80])
  }

  func testAStateThatEncodesToMoreThanEightKilobytesIsRefused() {
    // Every field is within its own limit. One list of 32 tags of 128 characters is about
    // 4 KB; two of them, the text and the keys together pass 8 KB.
    let tags = (0..<32).map { String(repeating: Character(UnicodeScalar(65 + $0 % 26)!), count: 128) }
    XCTAssertNil(state(text: String(repeating: "x", count: 200), tags: tags, excludedTags: tags).normalized())
    XCTAssertNotNil(
      state(text: String(repeating: "x", count: 200), tags: tags).normalized(),
      "One full list and the text stay under the cap")
  }
}
