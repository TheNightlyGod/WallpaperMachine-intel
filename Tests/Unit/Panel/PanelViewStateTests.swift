import XCTest

@testable import WallpaperMachine

/// The panel's view state is stored from what a page posts, so every limit on it is a limit on
/// what a misbehaving page can park in memory or hand back to the next one.
final class PanelViewStateTests: XCTestCase {
  private func report(
    text: String = "", sort: String = "title", descending: Any = false, tags: Any = [String](),
    excludedTags: Any = [String](), scroll: Any? = [String: Any]()
  ) -> [String: Any] {
    var body: [String: Any] = [
      "installed": [
        "text": text, "sort": sort, "descending": descending, "tags": tags,
        "excludedTags": excludedTags,
      ] as [String: Any]
    ]
    if let scroll { body["scroll"] = scroll }
    return body
  }

  func testAFullReportSurvivesEncodingAndTheFormTheNextPageReceives() throws {
    let state = try XCTUnwrap(
      PanelViewState(
        validating: report(
          text: "夜景 night", sort: "added", descending: true, tags: ["Favorite", "Approved"],
          excludedTags: ["Mature", "Web"], scroll: ["installed": 1_240.5, "discover": 0])))
    XCTAssertEqual(state.installed.text, "夜景 night")
    XCTAssertEqual(state.installed.sort, "added")
    XCTAssertTrue(state.installed.descending)
    XCTAssertEqual(state.installed.tags, ["Favorite", "Approved"])
    XCTAssertEqual(state.installed.excludedTags, ["Mature", "Web"])
    XCTAssertEqual(state.scroll, ["installed": 1_240.5, "discover": 0])

    let decoded = try JSONDecoder().decode(PanelViewState.self, from: JSONEncoder().encode(state))
    XCTAssertEqual(decoded, state)
    // The page gets back the same report it posted.
    XCTAssertEqual(PanelViewState(validating: state.payload), state)
  }

  func testAReportWithoutScrollOffsetsIsAccepted() throws {
    let state = try XCTUnwrap(PanelViewState(validating: report(scroll: nil)))
    XCTAssertEqual(state, PanelViewState())
  }

  func testAnUnknownSortIsRefused() {
    XCTAssertNil(PanelViewState(validating: report(sort: "random")))
    XCTAssertNil(PanelViewState(validating: report(sort: "")))
  }

  func testTextLongerThanTheSearchFieldAllowsIsRefused() {
    XCTAssertNotNil(PanelViewState(validating: report(text: String(repeating: "a", count: 200))))
    XCTAssertNil(PanelViewState(validating: report(text: String(repeating: "a", count: 201))))
  }

  func testMoreThanThirtyTwoTagsOrAnOverlongTagIsRefused() {
    let limit = (0..<32).map { "tag\($0)" }
    XCTAssertNotNil(PanelViewState(validating: report(tags: limit, excludedTags: limit)))
    XCTAssertNil(PanelViewState(validating: report(tags: limit + ["one more"])))
    XCTAssertNil(PanelViewState(validating: report(excludedTags: limit + ["one more"])))
    XCTAssertNil(PanelViewState(validating: report(tags: [String(repeating: "t", count: 129)])))
  }

  func testNonNumericNegativeAndMistypedScrollOffsetsAreRefused() {
    XCTAssertNil(PanelViewState(validating: report(scroll: ["installed": Double.nan])))
    XCTAssertNil(PanelViewState(validating: report(scroll: ["installed": Double.infinity])))
    XCTAssertNil(PanelViewState(validating: report(scroll: ["installed": -1])))
    XCTAssertNil(PanelViewState(validating: report(scroll: ["installed": "12"])))
    XCTAssertNil(PanelViewState(validating: report(scroll: ["installed": true])))
    XCTAssertNil(PanelViewState(validating: report(scroll: [12, 14])))
  }

  func testFieldsOfTheWrongTypeAreRefused() {
    XCTAssertNil(PanelViewState(validating: [:]))
    XCTAssertNil(PanelViewState(validating: report(descending: "yes")))
    XCTAssertNil(PanelViewState(validating: report(descending: 1)))
    XCTAssertNil(PanelViewState(validating: report(tags: "Favorite")))
    XCTAssertNil(PanelViewState(validating: report(tags: [1, 2])))
    XCTAssertNil(PanelViewState(validating: ["installed": "title"]))
  }

  func testOffsetsBeyondTheLimitAreClampedAndUnknownPagesAreDropped() throws {
    let state = try XCTUnwrap(
      PanelViewState(
        validating: report(scroll: [
          "installed": 5_000_000, "pixiv": 80, "settings": 12, "favorites": -4,
        ])))
    XCTAssertEqual(state.scroll, ["installed": 1_000_000, "pixiv": 80])
  }

  func testAReportThatEncodesToMoreThanEightKilobytesIsRefused() {
    // Every field is within its own limit. One list of 32 tags of 128 characters is about
    // 4 KB; two of them, the text and the keys together pass 8 KB.
    let tags = (0..<32).map { String(repeating: Character(UnicodeScalar(65 + $0 % 26)!), count: 128) }
    let body = report(
      text: String(repeating: "x", count: 200), tags: tags, excludedTags: tags)
    XCTAssertNil(PanelViewState(validating: body))
    XCTAssertNotNil(
      PanelViewState(validating: report(text: String(repeating: "x", count: 200), tags: tags)),
      "One full list and the text stay under the cap")
  }
}
