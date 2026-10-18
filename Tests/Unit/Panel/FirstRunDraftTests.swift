import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The pure rules of the first-run guide: the drafts and their commit order, the layout of the
/// card, the radio group's keys. No window, no stores.
final class FirstRunDraftTests: XCTestCase {
  // MARK: DraftList

  func testChoosingAKeyAgainReplacesItWithoutMovingIt() {
    var list = DraftList<String, Int>()
    list.set(1, for: "a")
    list.set(2, for: "b")
    list.set(3, for: "a")
    XCTAssertEqual(list.entries.map(\.key), ["a", "b"], "Order of first choice")
    XCTAssertEqual(list.value(for: "a"), 3)
    list.removeAll()
    XCTAssertTrue(list.isEmpty)
    XCTAssertNil(list.value(for: "a"))
  }

  // MARK: Performance

  /// A preset sets the limit and then the scale; the slider sets only the limit.
  func testAPresetDraftsBothAndTheSliderOnlyTheLimit() {
    var draft = WelcomePerformanceDraft()
    draft.choose(.low)
    XCTAssertEqual(draft.frameRateCap(saved: nil), 30)
    XCTAssertEqual(draft.renderScale(saved: 1), 0.5)
    XCTAssertEqual(
      draft.changes(savedCap: nil, savedScale: 1), [.frameRateCap(30), .renderScale(0.5)],
      "The limit goes first")

    draft.setFrameRateCap(24)
    XCTAssertEqual(draft.frameRateCap(saved: nil), 24)
    XCTAssertEqual(draft.renderScale(saved: 1), 0.5, "The slider leaves the scale alone")
    XCTAssertNil(draft.activePreset(savedCap: nil, savedScale: 1), "24 fps at half scale is Custom")

    draft.setFrameRateCap(30)
    XCTAssertEqual(draft.activePreset(savedCap: nil, savedScale: 1), .low)
  }

  /// A draft equal to what is saved is not a change, the scale within a thousandth, the limit
  /// exactly; "no limit" is a value of its own.
  func testChangesAreOnlyWhatDiffersFromWhatIsSaved() {
    var draft = WelcomePerformanceDraft()
    draft.choose(.high)
    XCTAssertTrue(draft.changes(savedCap: nil, savedScale: 1).isEmpty)
    XCTAssertTrue(draft.changes(savedCap: nil, savedScale: 1.0004).isEmpty)
    XCTAssertEqual(draft.changes(savedCap: nil, savedScale: 0.75), [.renderScale(1)])
    XCTAssertEqual(draft.changes(savedCap: 60, savedScale: 1), [.frameRateCap(nil)], "No limit is a change from 60")

    draft.setFrameRateCap(60)
    XCTAssertEqual(draft.changes(savedCap: 60, savedScale: 1), [])
  }

  func testWithNoDraftThePageShowsWhatIsSaved() {
    let draft = WelcomePerformanceDraft()
    XCTAssertEqual(draft.frameRateCap(saved: 45), 45)
    XCTAssertNil(draft.frameRateCap(saved: nil))
    XCTAssertEqual(draft.activePreset(savedCap: 60, savedScale: 0.75), .medium)
    XCTAssertNil(draft.activePreset(savedCap: 45, savedScale: 0.75))
  }

  // MARK: Preferences

  func testPreferenceDraftsShowOverTheSavedValuesAndListWhatChanged() {
    let saved = WelcomePreferenceValues(
      launchAtLogin: false, keepsWindowsOnWallpaperClick: false, batteryMode: .keepRunning)
    var draft = WelcomePreferenceDraft()
    draft.set(.keepsWindows(true))
    draft.set(.launchAtLogin(false))  // as saved
    draft.set(.batteryMode(.pause))
    draft.set(.keepsWindows(false))  // back to saved

    XCTAssertEqual(
      draft.values(saved: saved),
      WelcomePreferenceValues(launchAtLogin: false, keepsWindowsOnWallpaperClick: false, batteryMode: .pause))
    XCTAssertEqual(draft.changes(saved: saved), [.batteryMode(.pause)])

    draft.set(.launchAtLogin(true))
    XCTAssertEqual(
      draft.changes(saved: saved), [.launchAtLogin(true), .batteryMode(.pause)],
      "In the order each was first chosen")
  }

  // MARK: Card layout

  func testTheCardFitsTheWindowAndKeepsItsMargins() {
    XCTAssertEqual(
      WelcomeLayout.cardSize(in: CGSize(width: 760, height: 560)), CGSize(width: 640, height: 512))
    XCTAssertEqual(
      WelcomeLayout.cardSize(in: CGSize(width: 1240, height: 800)), CGSize(width: 640, height: 700))
    XCTAssertEqual(
      WelcomeLayout.cardSize(in: CGSize(width: 500, height: 400)), CGSize(width: 452, height: 352),
      "A window narrower than the card shrinks it")
    XCTAssertEqual(WelcomeLayout.cardSize(in: .zero), .zero, "Nothing proposed, nothing asked")
    XCTAssertTrue(WelcomeLayout.isCompact(cardHeight: 512))
    XCTAssertFalse(WelcomeLayout.isCompact(cardHeight: 700))
  }

  // MARK: Radio group keys

  func testTheArrowKeysMoveTheChoiceAndWrapLikeARadioGroup() {
    func go(_ index: Int?, _ key: KeyEquivalent, count: Int = 4) -> Int? {
      WelcomeChoiceGroup<EmptyView>.destination(from: index, key: key, count: count)
    }
    XCTAssertEqual(go(1, .rightArrow), 2)
    XCTAssertEqual(go(1, .downArrow), 2)
    XCTAssertEqual(go(3, .rightArrow), 0, "Past the last wraps to the first")
    XCTAssertEqual(go(0, .leftArrow), 3, "Before the first wraps to the last")
    XCTAssertEqual(go(2, .upArrow), 1)
    XCTAssertEqual(go(2, .home), 0)
    XCTAssertEqual(go(1, .end), 3)
    XCTAssertEqual(go(nil, .rightArrow), 0, "With nothing chosen the first is next")
    XCTAssertEqual(go(nil, .leftArrow), 3, "and the last is previous")
    XCTAssertNil(go(1, .return))
    XCTAssertNil(go(0, .rightArrow, count: 0))
  }

  // MARK: Steps

  func testTheStepsRunInOrderFromLanguageToStart() {
    XCTAssertEqual(WelcomeStep.allCases, [.language, .steam, .performance, .preferences, .tips, .start])
    XCTAssertNil(WelcomeStep.language.previous)
    XCTAssertNil(WelcomeStep.start.next)
    XCTAssertEqual(WelcomeStep.steam.next, .performance)
    XCTAssertTrue(WelcomeStep.language.isFirst && WelcomeStep.start.isLast)
  }
}
