import XCTest

@testable import WallpaperMachine

final class ResultPagerTests: XCTestCase {
  private func pager(
    page: Int = 5, total: Int = 1000, loading: Bool = false, max: Int = 1000
  ) -> ResultPager {
    ResultPager(page: page, totalPages: total, isLoading: loading, maxPages: max)
  }

  /// Steam clamps every query to 1,000 pages of 30, so typed numbers clamp to that range instead of
  /// pretending millions of results are reachable.
  func testATypedPageIsRoundedAndClampedIntoThePagesTheSourceServes() {
    let pager = pager()
    XCTAssertEqual(pager.jumpTarget(typed: "5000"), 1000)
    XCTAssertEqual(pager.jumpTarget(typed: "1e999"), 1000, "an absurd number must not trap")
    XCTAssertEqual(pager.jumpTarget(typed: "-3"), 1)
    XCTAssertEqual(pager.jumpTarget(typed: "0"), 1)
    XCTAssertEqual(pager.jumpTarget(typed: ""), 1, "an empty field asks for the first page")
    XCTAssertEqual(pager.jumpTarget(typed: "page two"), 1, "text that is no number does too")
    XCTAssertEqual(pager.jumpTarget(typed: " 12 "), 12)
    XCTAssertEqual(pager.jumpTarget(typed: "7.5"), 8, "half rounds away from zero")
    XCTAssertEqual(pager.jumpTarget(to: .nan), 1)
    XCTAssertEqual(pager.jumpTarget(to: nil), 1)
  }

  func testTheShownPageAndAnyPageWhileLoadingAskForNothing() {
    XCTAssertNil(pager().jumpTarget(typed: "5"), "the page on show is not a request")
    XCTAssertNil(pager().jumpTarget(typed: "5.2"), "it rounds to the page on show")
    XCTAssertNil(pager(loading: true).jumpTarget(typed: "9"))
    XCTAssertNil(pager(page: 1).jumpTarget(typed: ""), "an empty field on page 1 asks for page 1 again")
  }

  func testASourceThatCountsNoPagesStillHasOneAndNeverMoreThanItServes() {
    let empty = pager(page: 1, total: 0)
    XCTAssertEqual(empty.pages, 1)
    XCTAssertFalse(empty.canJump)
    XCTAssertFalse(empty.canGoForward)
    XCTAssertEqual(pager(total: 5000).pages, 1000)
    XCTAssertEqual(pager(page: 7, total: 3, max: 3).clamped(99), 3)
  }

  func testPagingControlsWaitWhileAPageLoadsAndStopAtTheEnds() {
    XCTAssertTrue(pager().canGoBack)
    XCTAssertTrue(pager().canGoForward)
    XCTAssertEqual(pager().previousPage, 4)
    XCTAssertEqual(pager().nextPage, 6)
    XCTAssertFalse(pager(page: 1).canGoBack)
    XCTAssertEqual(pager(page: 1).previousPage, 1)
    XCTAssertFalse(pager(page: 1000).canGoForward)
    XCTAssertEqual(pager(page: 1000).nextPage, 1000)
    let loading = pager(loading: true)
    XCTAssertFalse(loading.canGoBack)
    XCTAssertFalse(loading.canGoForward)
    XCTAssertFalse(loading.canJump)
  }
}
