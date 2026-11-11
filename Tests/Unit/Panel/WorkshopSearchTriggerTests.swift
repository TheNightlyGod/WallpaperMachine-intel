import SwiftUI
import XCTest

@testable import WallpaperMachine

/// When an edit of the Workshop search field becomes a search: the pause, the link pasted whole and
/// the item id that waits for Return (the rules the page's input handler kept).
final class WorkshopSearchTriggerTests: XCTestCase {
  func testALinkPastedWholeSearchesAtOnceButOnlyIfItWasPasted() {
    for link in [
      "https://steamcommunity.com/sharedfiles/filedetails/?id=3632513108",
      "http://steamcommunity.com/sharedfiles/filedetails/?id=3632513108",
      "steam://url/CommunityFilePage/3632513108", "  HTTPS://steamcommunity.com/x  ",
    ] {
      XCTAssertEqual(WorkshopSearchTrigger.classify(link, isPasteOrDrop: true), .now, link)
      XCTAssertEqual(
        WorkshopSearchTrigger.classify(link, isPasteOrDrop: false), .afterPause,
        "a link typed by hand is complete only when its last letter arrives: \(link)")
    }
  }

  func testPastedWordsAndAScrapOfALinkStillWaitForThePause() {
    for text in ["night sky", "https://", "steam://", "https://two words", "see https://a.b/c"] {
      XCTAssertEqual(WorkshopSearchTrigger.classify(text, isPasteOrDrop: true), .afterPause, text)
    }
  }

  func testABareItemIdWaitsForReturnWhetherTypedOrPasted() {
    for text in ["3632513108", "123456", " 123456 "] {
      for pasted in [false, true] {
        XCTAssertEqual(
          WorkshopSearchTrigger.classify(text, isPasteOrDrop: pasted), .onReturn,
          "\(text) pasted: \(pasted): typing it must not look up its prefixes")
      }
    }
  }

  func testShortNumbersAndEverythingElseGetThePauseAndClearingSearches() {
    for text in ["12345", "2024", "nature", "id 3632513108", "3632513108a", "", "   "] {
      XCTAssertEqual(WorkshopSearchTrigger.classify(text, isPasteOrDrop: false), .afterPause, text)
    }
    XCTAssertEqual(WorkshopSearchTrigger.pause, .milliseconds(450))
  }

  func testOnlyAnEditThatInsertsMoreThanOneCharacterIsAPasteOrDrop() {
    func pasted(_ old: String, _ new: String) -> Bool {
      WorkshopSearchTrigger.isPasteOrDrop(from: old, to: new)
    }
    XCTAssertFalse(pasted("", "a"), "a typed letter")
    XCTAssertFalse(pasted("abc", "abcd"), "a letter appended")
    XCTAssertFalse(pasted("abc", "abXc"), "a letter in the middle")
    XCTAssertFalse(pasted("abc", "ab"), "a deletion")
    XCTAssertFalse(pasted("abc", "X"), "a typed letter over a selection")
    XCTAssertFalse(pasted("abc", ""), "a clear")
    XCTAssertFalse(pasted("same", "same"))
    XCTAssertTrue(pasted("", "https://a.b"), "a paste into an empty field")
    XCTAssertTrue(pasted("abc", "abcdef"), "a paste at the end")
    XCTAssertTrue(pasted("a long search that was there", "https://a.b/c"), "a paste over everything")
    XCTAssertTrue(pasted("ac", "aXYZc"), "a paste in the middle")
  }

  func testTypingALinkOneLetterAtATimeNeverSearchesBeforeThePause() {
    let link = "https://steamcommunity.com/sharedfiles/filedetails/?id=3632513108"
    var text = ""
    for letter in link {
      let next = text + String(letter)
      let trigger = WorkshopSearchTrigger.classify(
        next, isPasteOrDrop: WorkshopSearchTrigger.isPasteOrDrop(from: text, to: next))
      XCTAssertNotEqual(trigger, .now, "after \(next)")
      text = next
    }
  }

  func testTheSearchFieldInvitesALinkOnlyOnTheWallpapersList() {
    XCTAssertTrue(WorkshopSearchTrigger.invitesLink(for: .browse))
    XCTAssertFalse(WorkshopSearchTrigger.invitesLink(for: .collections))
  }

  func testTheTabsMoveFocusWithTheArrowsHomeAndEndAndNeverChooseOne() {
    let all = WorkshopList.allCases
    XCTAssertEqual(all, [.browse, .collections, .subscriptions, .favorites])
    XCTAssertEqual(WorkshopSourceTabs.destination(from: .browse, key: .rightArrow), .collections)
    XCTAssertEqual(WorkshopSourceTabs.destination(from: .subscriptions, key: .rightArrow), .favorites)
    XCTAssertEqual(WorkshopSourceTabs.destination(from: .favorites, key: .rightArrow), .browse, "wraps")
    XCTAssertEqual(WorkshopSourceTabs.destination(from: .browse, key: .leftArrow), .favorites, "wraps")
    XCTAssertEqual(WorkshopSourceTabs.destination(from: .collections, key: .home), .browse)
    XCTAssertEqual(WorkshopSourceTabs.destination(from: .collections, key: .end), .favorites)
    XCTAssertNil(WorkshopSourceTabs.destination(from: .collections, key: .upArrow))
  }
}
