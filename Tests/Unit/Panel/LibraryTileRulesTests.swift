import AppKit
import XCTest

@testable import WallpaperMachine

/// What a click, a mark, a focus and an empty grid mean.
@MainActor
final class LibraryTileRulesTests: PanelTestCase {
  // MARK: Clicks

  func testAPlainClickChoosesAndTheSecondClickOfADoubleClickApplies() {
    XCTAssertEqual(LibraryTileClick.resolve(clickCount: 1, modifiers: [], isSelecting: false), .select)
    XCTAssertEqual(LibraryTileClick.resolve(clickCount: 2, modifiers: [], isSelecting: false), .activate)
    XCTAssertEqual(
      LibraryTileClick.resolve(clickCount: 3, modifiers: [], isSelecting: false), .select,
      "a third click starts over as a plain one")
    XCTAssertEqual(
      LibraryTileClick.resolve(clickCount: 0, modifiers: [], isSelecting: false), .select,
      "Return and Space on a focused tile are a click without modifiers")
  }

  func testCommandControlOrShiftTickInsteadAndShiftExtends() {
    for modifier: NSEvent.ModifierFlags in [.command, .control] {
      XCTAssertEqual(
        LibraryTileClick.resolve(clickCount: 1, modifiers: modifier, isSelecting: false), .toggle)
    }
    XCTAssertEqual(
      LibraryTileClick.resolve(clickCount: 1, modifiers: .shift, isSelecting: false), .extendRange)
    XCTAssertEqual(
      LibraryTileClick.resolve(clickCount: 1, modifiers: [.shift, .command], isSelecting: false),
      .extendRange)
    XCTAssertEqual(
      LibraryTileClick.resolve(clickCount: 1, modifiers: .option, isSelecting: false), .select,
      "Option is not one of the keys")
  }

  func testSelectionModeTicksOnEveryClickADoubleClickIncluded() {
    XCTAssertEqual(LibraryTileClick.resolve(clickCount: 1, modifiers: [], isSelecting: true), .toggle)
    XCTAssertEqual(LibraryTileClick.resolve(clickCount: 2, modifiers: [], isSelecting: true), .toggle)
    XCTAssertEqual(LibraryTileClick.resolve(clickCount: 0, modifiers: [], isSelecting: true), .toggle)
  }

  // MARK: Marks

  func testMarksStackTrophyHeartArrowAndAreReadOutWithTheTile() {
    let marks = LibraryTileMarks(
      LibraryRows.row("a", approved: true, update: true), isFavorite: true)
    XCTAssertEqual(
      marks.names, ["Approved by Wallpaper Engine", "Favorite", "Update available"],
      "in the order they stack, in the panel's language (English here)")
    XCTAssertEqual(
      LibraryTileMarks(LibraryRows.row("b", approved: true), isFavorite: false).names,
      ["Approved by Wallpaper Engine"])
    XCTAssertTrue(LibraryTileMarks(LibraryRows.row("c"), isFavorite: false).isEmpty)
    XCTAssertEqual(LibraryTileMarks(LibraryRows.row("c"), isFavorite: false).names, [])
  }

  // MARK: Controls, pill and emphasis

  private func chrome(
    checked: Bool = false, chosen: Bool = false, favorite: Bool = false, hovering: Bool = false,
    focused: Bool = false, arming: Bool = false, selecting: Bool = false, selection: Bool = false
  ) -> LibraryTileChrome {
    LibraryTileChrome(
      isChecked: checked, isChosen: chosen, isFavorite: favorite, isHovering: hovering,
      isFocused: focused, isArming: arming, isSelecting: selecting, hasSelection: selection)
  }

  func testAtRestATileShowsNoControlsAndItsPillSitsInTheCorner() {
    let rest = chrome()
    XCTAssertFalse(rest.showsCheck)
    XCTAssertFalse(rest.showsHeart)
    XCTAssertEqual(rest.pillLeadingInset, 0, "nothing hidden takes the corner's room")
    XCTAssertEqual(rest.emphasis, .none)
  }

  func testTheCheckShowsWhereItCanBeUsedAndThePillMovesPastIt() {
    for shown in [
      chrome(checked: true), chrome(hovering: true), chrome(focused: true), chrome(arming: true),
      chrome(selecting: true), chrome(selection: true),
    ] {
      XCTAssertTrue(shown.showsCheck)
      XCTAssertEqual(shown.pillLeadingInset, LibraryGridGeometry.controlSize + 4)
    }
  }

  func testTheHeartShowsOnAFavoriteAndUnderThePointerOrFocusButNotForTicking() {
    XCTAssertTrue(chrome(favorite: true).showsHeart)
    XCTAssertTrue(chrome(hovering: true).showsHeart)
    XCTAssertTrue(chrome(focused: true).showsHeart)
    XCTAssertFalse(chrome(selecting: true).showsHeart, "selection mode brings out checks only")
    XCTAssertFalse(chrome(selection: true).showsHeart)
    XCTAssertFalse(chrome(checked: true, selecting: true).showsHeart)
  }

  func testATickedTileAndTheTileOnShowNeverLookAlike() {
    XCTAssertEqual(chrome(chosen: true).emphasis, .selected, "nothing ticked: the accent ring")
    XCTAssertEqual(chrome(checked: true, selection: true).emphasis, .checked)
    XCTAssertEqual(
      chrome(checked: true, chosen: true, selection: true).emphasis, .checked,
      "ticked wins: it is what a batch action reaches")
    XCTAssertEqual(
      chrome(chosen: true, selection: true).emphasis, .quietSelection,
      "the tile on show quiets down while others are ticked")
    XCTAssertEqual(chrome(chosen: true, selecting: true).emphasis, .quietSelection)
    XCTAssertEqual(chrome(selecting: true).emphasis, .none)
  }

  func testAStatusRingReplacesThePlaceholderGlyph() {
    XCTAssertTrue(LibraryTileChrome.showsPlaceholder(hasCover: false, hasApplyState: false))
    XCTAssertFalse(LibraryTileChrome.showsPlaceholder(hasCover: false, hasApplyState: true))
    XCTAssertFalse(LibraryTileChrome.showsPlaceholder(hasCover: true, hasApplyState: false))
  }

  func testKindsReadInTheirOwnWords() {
    XCTAssertEqual(
      [LibraryRow.Kind.scene, .video, .web, .unknown].map(\.label), ["Scene", "Video", "Web", "Unknown"])
  }

  // MARK: Which tile plays

  func testThePointerWinsOverFocusAndGivesItBack() {
    var target = LivePreviewTarget()
    target.focusChanged("b", isFocused: true, byKeyboard: true)
    XCTAssertEqual(target.id, "b")
    target.pointerEntered("a", isButtonDown: false)
    XCTAssertEqual(target.id, "a", "the pointer takes over from focus")
    target.pointerLeft("a")
    XCTAssertEqual(target.id, "b", "and gives it back")
  }

  func testAHeldButtonAndAFocusThatWasNotFromTheKeyboardStartNothing() {
    var target = LivePreviewTarget()
    target.pointerEntered("a", isButtonDown: true)
    XCTAssertNil(target.id, "a selection drag starts nothing")
    target.focusChanged("b", isFocused: true, byKeyboard: false)
    XCTAssertNil(target.id, "a click's focus starts nothing")
    target.focusChanged("b", isFocused: true, byKeyboard: true)
    XCTAssertEqual(target.id, "b")
    target.focusChanged("b", isFocused: false, byKeyboard: true)
    XCTAssertNil(target.id, "moving focus away releases it")
  }

  func testLeavingATileOnlyClearsThePointerIfItIsStillTheTilesAndResetReleasesEverything() {
    var target = LivePreviewTarget()
    target.pointerEntered("a", isButtonDown: false)
    target.pointerEntered("b", isButtonDown: false)
    target.pointerLeft("a")
    XCTAssertEqual(target.id, "b", "the pointer had already moved on")
    target.focusChanged("c", isFocused: true, byKeyboard: true)
    target.reset()
    XCTAssertNil(target.id)
  }

  // MARK: Empty grids

  func testTheEmptyStateNamesWhatHidesTheTilesInTheOrderOfTheRecovery() {
    func state(
      loading: Bool = false, empty: Bool = false, collection: (String, Int)? = nil,
      text: String = "", tags: [String] = [], collectionID: String? = nil, whole: Bool = true,
      failure: String? = nil
    ) -> LibraryEmptyState? {
      var filter = LibraryFilter(text: text, requiredTags: tags)
      filter.collectionID = collectionID
      return LibraryEmptyState.make(
        rowCount: 0, isLoading: loading, loadFailure: failure, libraryIsEmpty: empty,
        collection: collection.map { (name: $0.0, memberCount: $0.1) }, filter: filter,
        isInstalled: { $0 == "2077200001" }, textIsWhole: whole)
    }
    XCTAssertEqual(state(loading: true, empty: true), .loading)
    XCTAssertEqual(state(empty: true, text: "x"), .emptyLibrary)
    XCTAssertEqual(
      state(empty: true, text: "x", failure: "disk gone"), .failed(message: "disk gone"),
      "a library that could not be read is not an empty one, whatever the search")
    XCTAssertEqual(state(loading: true, empty: true, failure: "disk gone"), .loading, "reading again comes first")
    XCTAssertEqual(
      state(text: "x", failure: "disk gone"), .search(text: "x"),
      "wallpapers read before a failed rescan are still there to search")
    XCTAssertEqual(
      state(collection: ("Night", 0), text: "x", collectionID: "n"), .emptyCollection(name: "Night"),
      "an empty collection is empty, not filtered away")
    XCTAssertEqual(state(text: "x", tags: ["Anime"]), .searchAndFilters)
    XCTAssertEqual(state(text: "x"), .search(text: "x"))
    let link = "https://steamcommunity.com/sharedfiles/filedetails/?id=3632513108"
    XCTAssertEqual(state(text: " 3632513108"), .notInstalled(itemID: "3632513108"))
    XCTAssertEqual(
      state(text: link, tags: ["Anime"], collectionID: "n"), .notInstalled(itemID: "3632513108"),
      "a linked item that is not installed is missing whatever the filters, and Discover can show it")
    XCTAssertEqual(
      state(text: "3632513108", tags: ["Anime"]), .searchAndFilters,
      "a bare number is words too, which the filters may be hiding")
    XCTAssertEqual(
      state(text: "https://steamcommunity.com/sharedfiles/filedetails/?id=2077200001", tags: ["Anime"]),
      .searchAndFilters, "an installed item is hidden by the filters")
    XCTAssertEqual(state(text: "2077"), .search(text: "2077"), "a short number is words")
    XCTAssertEqual(
      state(text: "363251", whole: false), .search(text: "363251"),
      "an id being typed is words until it arrives whole, so its prefixes claim no item")
    XCTAssertEqual(
      state(text: link, whole: false), .notInstalled(itemID: "3632513108"),
      "a link names its item however it arrived")
    let short = "https://steamcommunity.com/sharedfiles/filedetails/?id=12345"
    XCTAssertEqual(
      state(text: short), .search(text: short),
      "Discover looks up no id this short from its search field, so none is offered")
    XCTAssertEqual(state(tags: ["Anime", "Web"]), .filters(count: 2))
    XCTAssertEqual(
      state(collection: ("Night", 3), collectionID: "n"), .filters(count: 1),
      "a collection whose members are all gone counts as the filter that hides them")
    XCTAssertNil(
      LibraryEmptyState.make(
        rowCount: 3, isLoading: false, libraryIsEmpty: false, collection: nil,
        filter: LibraryFilter(), isInstalled: { _ in false }, textIsWhole: true))
  }
}
