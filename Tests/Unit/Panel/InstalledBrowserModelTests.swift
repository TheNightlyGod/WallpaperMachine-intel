import AppKit
import XCTest

@testable import WallpaperMachine

/// The Installed page's model: what it restores and reports, which part of the library is on
/// show, the rows it lists, the selection and its batch actions, and the import pill.
@MainActor
final class InstalledBrowserModelTests: PanelTestCase {
  /// A library of `count` wallpapers titled "w00", "w01", ... with no pictures, loaded.
  private func installNames(_ panel: PanelFixture, count: Int = 8) async throws {
    try panel.installLibrary(
      (0..<count).map { LibrarySpec(String(format: "w%02d", $0), kind: .projectScene, preview: .none) })
    try await panel.loadLibrary()
    try await panel.settleLibrary()
  }

  private func wait(
    _ panel: PanelFixture, _ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool
  ) async throws {
    do { try await panel.waitUntil(timeout: timeout, condition) } catch {
      XCTFail("Timed out waiting for \(what)")
      throw error
    }
  }

  /// Waits until the model has asked `clock` for a timer; a failure says so instead of hanging.
  private func timerRequested(_ clock: ManualSleeper, _ what: String = "a timer") async throws {
    let deadline = Date().addingTimeInterval(10)
    while clock.pendingCount == 0 {
      guard Date() < deadline else {
        XCTFail("The model never asked for \(what)")
        throw WorkshopFailure(message: "no timer")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func titles(_ model: InstalledBrowserModel) -> [String] { model.visibleRows.map(\.title) }

  // MARK: Restoring and reporting

  func testAWindowComesBackToTheFiltersTheLastOneLeftAndDropsStaleTagsOnceTheLibraryLoaded() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.navigation.viewState = PanelViewState(
      installed: .init(
        text: "cat", sort: "size", descending: false, tags: ["Approved", "Gone", "Approved"],
        excludedTags: ["Web", "Nowhere", "Web"]),
      scroll: ["installed": 321, "discover": 55])
    let model = panel.controller.library
    XCTAssertEqual(model.filter.text, "cat")
    XCTAssertEqual(model.sort, .size)
    XCTAssertFalse(model.descending, "the direction restores as it was, not as the key starts")
    XCTAssertEqual(model.filter.requiredTags, ["Approved", "Gone"], "each tag once")
    XCTAssertEqual(model.filter.excludedTags, ["Web", "Nowhere"])
    XCTAssertEqual(model.scrollOffset, 321)

    model.dropStaleRestoredTags()
    XCTAssertEqual(model.filter.requiredTags, ["Approved", "Gone"], "nothing is dropped while the library has not loaded")

    try panel.installLibrary([LibrarySpec("one", approved: true, preview: .none)])
    try await panel.loadLibrary()
    try await panel.settleLibrary()
    model.dropStaleRestoredTags()
    XCTAssertEqual(model.filter.requiredTags, ["Approved"], "a tag no wallpaper carries would empty the grid")
    XCTAssertEqual(model.filter.excludedTags, ["Web", "Nowhere"], "excluded tags only hide, so they stay")
    XCTAssertEqual(panel.navigation.viewState?.installed.tags, ["Approved"], "and the drop is reported")
  }

  func testTagsTheUserTickedAfterTheRestoreAreNeverDropped() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.navigation.viewState = PanelViewState(installed: .init(tags: ["Gone"]))
    let model = panel.controller.library
    model.setRequired("Customizable", true)
    try panel.installLibrary([LibrarySpec("one", preview: .none)])
    try await panel.loadLibrary()
    try await panel.settleLibrary()
    model.dropStaleRestoredTags()
    XCTAssertEqual(model.filter.requiredTags, ["Customizable"])
  }

  func testAReopenedPanelComesBackToWhatTheClosedOneLeft() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    model.setSort(.added)
    model.toggleSortDirection()
    model.setRequired("Approved", true)
    model.setIncluded("Questionable", false)
    model.setText("nat")
    model.scrolled(to: 480)
    model.flushViewState()

    let reopened = panel.buildController().library
    XCTAssertEqual(reopened.filter.text, "nat")
    XCTAssertEqual(reopened.sort, .added)
    XCTAssertFalse(reopened.descending)
    XCTAssertEqual(reopened.filter.requiredTags, ["Approved"])
    XCTAssertEqual(reopened.filter.excludedTags, ["Questionable"])
    XCTAssertEqual(reopened.scrollOffset, 480)
    XCTAssertTrue(reopened.selection.isEmpty, "the selection does not outlive the window")
    XCTAssertFalse(reopened.isSelecting)
  }

  func testChoicesAreReportedAtOnceTypingAndScrollingAboutEvery400msAndOtherPagesScrollStays() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.navigation.viewState = PanelViewState(scroll: ["discover": 55])
    let model = panel.controller.library
    let clock = ManualSleeper()
    model.sleep = clock.closure
    model.isMouseButtonDown = { false }
    func reported() -> PanelViewState? { panel.navigation.viewState }

    model.setSort(.size)
    XCTAssertEqual(reported()?.installed.sort, "size", "a menu choice reports at once")
    model.toggleSortDirection()
    XCTAssertEqual(reported()?.installed.descending, false)
    model.setRequired("Approved", true)
    XCTAssertEqual(reported()?.installed.tags, ["Approved"])
    XCTAssertEqual(reported()?.scroll["discover"], 55, "another page's offset is not lost")

    model.setText("a")
    model.setText("ab")
    model.setText("abc")
    XCTAssertEqual(reported()?.installed.text, "", "typing waits for a pause")
    try await timerRequested(clock)
    XCTAssertEqual(clock.requested, [.milliseconds(400)], "a burst of typing sets one timer")
    clock.fireNext()
    try await panel.waitUntil { reported()?.installed.text == "abc" }

    model.scrolled(to: 250.4)
    XCTAssertEqual(reported()?.scroll["installed"], 0)
    try await timerRequested(clock)
    clock.fireNext()
    try await panel.waitUntil { reported()?.scroll["installed"] == 250 }

    model.setText("abcd")
    model.flushViewState()
    XCTAssertEqual(reported()?.installed.text, "abcd", "hiding the window reports what waits")
    clock.fireAll()
    try await panel.quiet()
    XCTAssertEqual(reported()?.installed.text, "abcd")
  }

  func testATextOverTheLimitIsReportedEmptyAndAnOutOfRangeReportIsNotKept() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    model.setSort(.type)
    model.setText(String(repeating: "x", count: 201))
    model.reportViewState()
    XCTAssertEqual(panel.navigation.viewState?.installed.text, "", "no text is more honest than a cut one")
    XCTAssertEqual(model.filter.text.count, 201, "the field itself keeps what was typed")
  }

  // MARK: Which part of the library is on show

  func testFavoritesIsTheFavoriteFilterAndTheSearchAndSortStayWhenTheViewChanges() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 5)
    panel.controller.favoriteIDs = ["w01", "w03"]
    model.setSort(.favorites)
    model.setText("w")
    model.setRequired("Customizable", true)
    model.setRequired("Customizable", false)

    XCTAssertEqual(model.scope, .all)
    model.show(.favorites)
    XCTAssertEqual(model.scope, .favorites)
    XCTAssertTrue(model.showsFavorites)
    XCTAssertEqual(titles(model), ["w01", "w03"])
    XCTAssertEqual(model.filterCount, 1, "Favorites is the library's own Favorite filter")
    XCTAssertEqual(model.filter.text, "w")
    XCTAssertEqual(model.sort, .favorites)
    XCTAssertEqual(model.scrollToTopCount, 1, "choosing a view starts at the top")

    model.show(.all)
    XCTAssertEqual(model.scope, .all)
    XCTAssertEqual(titles(model).count, 5)
    XCTAssertEqual(model.filterCount, 0)
    XCTAssertEqual(model.filter.text, "w", "the search is not part of the view")
  }

  func testChoosingAViewStartsAtTheTopEvenForAGridThatIsNotBuiltYet() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    model.sleep = ManualSleeper().closure
    try await installNames(panel, count: 5)
    model.scrolled(to: 3000)
    model.reportViewState()
    XCTAssertEqual(panel.navigation.viewState?.scroll["installed"], 3000)

    // Chosen from another page, where no grid exists to hear `scrollToTopCount`: the grid made on
    // the way back restores `scrollOffset`, so that is where the top must be.
    model.show(.favorites)
    XCTAssertEqual(model.scrollOffset, 0, "the next grid starts at the top")
    XCTAssertEqual(
      panel.navigation.viewState?.scroll["installed"], 0, "and so does the next window")

    // The same from an empty collection, whose empty state stands where the grid would be.
    let quiet = try panel.collections.create(name: "Quiet", wallpaperIDs: [])
    model.show(.collection(quiet.id))
    XCTAssertNotNil(model.emptyState)
    model.scrolled(to: 800)
    model.show(.all)
    XCTAssertEqual(model.scrollOffset, 0)
  }

  func testTickingFavoritesInTheFiltersFlipsTheViewToo() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    model.setRequired("Favorite", true)
    XCTAssertEqual(model.scope, .favorites)
    model.setRequired("Favorite", false)
    XCTAssertEqual(model.scope, .all)
  }

  func testACollectionIsAViewToo() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 5)
    let night = try panel.collections.create(name: "Night", wallpaperIDs: ["w02", "w04", "stale"])
    model.show(.favorites)
    model.show(.collection(night.id))
    XCTAssertEqual(model.scope, .collection(night.id))
    XCTAssertFalse(model.showsFavorites)
    XCTAssertFalse(model.filter.requiredTags.contains("Favorite"), "choosing a collection leaves Favorites")
    XCTAssertEqual(titles(model), ["w02", "w04"], "stale members are not wallpapers")
    XCTAssertEqual(model.shownCollection?.name, "Night")
    XCTAssertEqual(model.filterCount, 1, "the collection counts as a filter")

    model.show(.collection("unknown"))
    XCTAssertEqual(model.scope, .collection(night.id), "a collection that is not there is ignored")

    try panel.collections.delete(night.id)
    XCTAssertEqual(model.scope, .all, "a deleted collection takes the view back to everything")
    XCTAssertEqual(model.filterCount, 0)
    XCTAssertEqual(titles(model).count, 5)
  }

  func testAnEmptyCollectionIsEmptyNotFilteredAwayAndShowAllLeavesIt() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 3)
    let empty = try panel.collections.create(name: "Quiet", wallpaperIDs: [])
    model.show(.collection(empty.id))
    XCTAssertEqual(model.emptyState, .emptyCollection(name: "Quiet"))
    model.showAllWallpapers()
    XCTAssertNil(model.emptyState)
    XCTAssertEqual(titles(model).count, 3)
  }

  // MARK: Header and summary

  func testOnlyASearchOrAFilterNarrowsTheViewTheSidebarLights() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await installNames(panel, count: 4)
    let model = panel.controller.library
    XCTAssertFalse(model.narrowsView, "All wallpapers is the whole view, which the subtitle counts")
    model.show(.favorites)
    XCTAssertFalse(model.narrowsView, "Favorites is a view of its own")
    let night = try panel.collections.create(name: "Night", wallpaperIDs: ["w01"])
    model.show(.collection(night.id))
    XCTAssertFalse(model.narrowsView, "and so is a collection")
    model.setText("w0")
    XCTAssertTrue(model.narrowsView, "a search leaves part of it")
    model.setText("")
    model.setRequired("Approved", true)
    XCTAssertTrue(model.narrowsView, "and so does a filter")
    model.show(.favorites)
    XCTAssertTrue(model.narrowsView, "also beside Favorites")
  }

  func testTheNarrowHeadersSortMenuSetsTheDirectionAndReportsIt() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    model.setSort(.title)
    XCTAssertFalse(model.descending)
    model.setDescending(true)
    XCTAssertTrue(model.descending)
    XCTAssertEqual(panel.navigation.viewState?.installed.descending, true, "a menu choice reports at once")
    model.setDescending(true)
    XCTAssertTrue(model.descending, "choosing the direction already in effect keeps it")
    model.setDescending(false)
    XCTAssertFalse(model.descending)
  }

  func testTheFilterButtonSaysHowManyFiltersApplyAndWhetherTheSidebarIsOpen() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    XCTAssertEqual(model.filterButtonValue, L("Collapsed"))
    panel.controller.shell.setFiltersShown(true)
    XCTAssertEqual(model.filterButtonValue, L("Expanded"))
    model.setRequired("Approved", true)
    model.setIncluded("Web", false)
    XCTAssertEqual(model.filterButtonValue, "\(L("2 active")), \(L("Expanded"))")
    panel.controller.shell.setFiltersShown(false)
    XCTAssertEqual(model.filterButtonValue, "\(L("2 active")), \(L("Collapsed"))")
  }

  func testTheSummaryIsSaidOnceItSettlesAsTheWebPanelsLiveRegionWas() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    panel.show()
    let model = panel.controller.library
    let clock = ManualSleeper()
    model.sleep = clock.closure
    model.isMouseButtonDown = { false }
    var spoken: [String] = []
    model.announce = { spoken.append($0) }
    try await installNames(panel, count: 4)
    XCTAssertEqual(model.summary, L("4 wallpapers"))

    // A sweep across three tiles: three changes, one announcement of where it ended.
    for id in ["w00", "w01", "w02"] {
      model.toggleChecked(id)
      model.summaryChanged()
    }
    XCTAssertEqual(model.summary, L("3 selected"))
    try await timerRequested(clock, "the settling delay")
    XCTAssertEqual(clock.requested.last, InstalledBrowserModel.summaryDelay)
    clock.fireAll()
    try await panel.waitUntil { !spoken.isEmpty }
    try await panel.quiet()
    XCTAssertEqual(spoken, [L("3 selected")], "superseded changes are never said")

    // Typing waits on the same clock to report the text: two timers, the summary's among them.
    model.clearSelection()
    model.setText("w0")
    model.summaryChanged()
    await clock.waitUntilPending(2)
    clock.fireAll()
    try await panel.waitUntil { spoken.count == 2 }
    XCTAssertEqual(spoken.last, L("4 wallpapers"), "the count of what the grid shows")

    model.setText("w01")
    XCTAssertEqual(model.summary, L("1 wallpaper"))
    model.setText("nothing")
    XCTAssertNil(model.summary, "an empty grid's own empty state says why")

    model.setText("")
    model.summaryChanged()
    await clock.waitUntilPending(2)
    panel.hide()
    clock.fireAll()
    try await panel.quiet()
    XCTAssertEqual(spoken.count, 2, "a hidden window says nothing")
  }

  // MARK: Rows

  func testRowsAreFilteredAndSortedAndFollowFavoritesAndTheLibrary() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try panel.installLibrary([
      LibrarySpec("a", "Zebra", kind: .video, tags: ["Nature"], preview: .none),
      LibrarySpec("b", "Apple", kind: .projectScene, tags: ["Anime"], approved: true, preview: .none),
      LibrarySpec("c", "Mango", kind: .webpage, preview: .none),
    ])
    try await panel.loadLibrary()
    try await panel.settleLibrary()

    XCTAssertEqual(titles(model), ["Apple", "Mango", "Zebra"])
    model.setSort(.type)
    XCTAssertEqual(titles(model), ["Apple", "Zebra", "Mango"], "Scene, Video, Web")
    model.setSort(.favorites)
    panel.controller.favoriteIDs = ["c"]
    XCTAssertEqual(titles(model), ["Mango", "Apple", "Zebra"], "a favorite made now moves up at once")
    model.setSort(.title)
    model.setRequired("Approved", true)
    XCTAssertEqual(titles(model), ["Apple"])
    model.clearFilters()
    model.setText("nature")
    XCTAssertEqual(titles(model), ["Zebra"], "the text reads the manifest's tags too")
    model.setIncluded("Nature", false)
    XCTAssertEqual(titles(model), [])
    XCTAssertEqual(model.emptyState, .searchAndFilters)
    model.clearSearchAndFilters()
    XCTAssertEqual(titles(model).count, 3)
    XCTAssertNil(model.emptyState)
  }

  func testTheSearchTextSurvivesALibraryChange() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 4)
    model.setText("w0")
    try panel.installLibrary(
      (0..<5).map { LibrarySpec(String(format: "w%02d", $0), preview: .none) })
    XCTAssertEqual(model.filter.text, "w0", "a snapshot never disturbs what is being typed")
    XCTAssertEqual(titles(model).count, 5)
  }

  func testAClearedSearchAndEachEmptyStateRecovers() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    XCTAssertEqual(model.emptyState, .loading, "nothing is known until the library has been read")
    try await installNames(panel, count: 3)
    model.setText("zzz")
    XCTAssertEqual(model.emptyState, .search(text: "zzz"))
    model.clearSearch()
    model.setRequired("Customizable", true)
    XCTAssertEqual(model.emptyState, .filters(count: 1))
    model.setIncluded("Anime", false)
    XCTAssertEqual(model.emptyState, .filters(count: 2))
    model.clearFilters()
    XCTAssertNil(model.emptyState)
    panel.store.librarySnapshot.wallpapers = []
    XCTAssertEqual(model.emptyState, .emptyLibrary)
  }

  func testSelectingAChipRequiresItsTagAndHidingItExcludesIt() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    let genre = try XCTUnwrap(LibraryFilterCatalog.section(key: "genre"))
    XCTAssertEqual(model.chipSelection("Anime"), .plain)
    model.setChip("Anime", .required)
    XCTAssertEqual(model.filter.requiredTags, ["Anime"])
    XCTAssertEqual(model.chipSelection("Anime"), .required)
    model.setChip("Anime", .excluded)
    XCTAssertEqual(model.filter.requiredTags, [], "a tag is never both required and excluded")
    XCTAssertEqual(model.filter.excludedTags, ["Anime"])
    XCTAssertFalse(model.chipsAreAtDefaults(in: genre))
    model.resetChips(in: genre)
    XCTAssertTrue(model.chipsAreAtDefaults(in: genre))
    XCTAssertFalse(model.filter.hasFilters)
  }

  func testATenThousandWallpaperLibraryFiltersAsTheUserTypes() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    panel.store.librarySnapshot.wallpapers = (0..<10_000).map {
      BridgeWallpaperEntry(
        id: "id\($0)", title: "Wallpaper \(($0 * 7919) % 10_000)", kind: .video, supported: true,
        active: false, selected: false, previewPath: nil)
    }
    XCTAssertEqual(model.visibleRows.count, 10_000)
    let started = Date()
    for text in ["W", "Wa", "Wal", "Wall", "Wallp", "Wallpaper 9"] {
      model.setText(text)
      _ = model.visibleRows
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 3, "typing filters the sorted library, which is not sorted again")
    XCTAssertEqual(model.visibleRows.count, 1_111)
  }

  // MARK: Covers

  func testATileHasNoImageUntilItsCoverStampIsReadThenOnlyTheCover() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try panel.installLibrary([
      LibrarySpec("a", "A", preview: .picture(0.2)), LibrarySpec("b", "B", preview: .none),
    ])
    let first = model.visibleRows
    XCTAssertEqual(first[0].cover, .pending)
    XCTAssertNil(first[0].coverSource, "never the full-size preview while the stamp is being read")
    XCTAssertEqual(first[1].cover, .none, "a wallpaper with no preview has no image to wait for")
    try await panel.loadLibrary()
    try await panel.settleLibrary()
    guard case .stamped = model.visibleRows[0].cover else { return XCTFail("the stamp arrived") }
    XCTAssertNotNil(model.visibleRows[0].coverSource)
  }

  func testARescanKeepsEveryCoverAndAReplacedPreviewChangesOnlyItsOwn() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try panel.installLibrary([
      LibrarySpec("a", "A", preview: .picture(0.1)), LibrarySpec("b", "B", preview: .picture(0.5)),
      LibrarySpec("c", "C", preview: .picture(0.8)),
    ])
    try await panel.loadLibrary()
    try await panel.settleLibrary()
    let covers = model.visibleRows.map(\.coverSource)
    XCTAssertFalse(covers.contains { $0 == nil })

    try await panel.loadLibrary()
    try await panel.settleLibrary()
    XCTAssertEqual(model.visibleRows.map(\.coverSource), covers, "a rescan that replaced nothing leaves every cover alone")

    // The preview of `b` is replaced by a picture of another size.
    try Self.picture(size: 300, hue: 0.9).write(
      to: panel.library.appendingPathComponent("b/preview.png"))
    try await panel.loadLibrary()
    try await panel.waitUntil(timeout: 10) { model.visibleRows[1].coverSource != covers[1] }
    XCTAssertEqual(model.visibleRows[0].coverSource, covers[0])
    XCTAssertEqual(model.visibleRows[2].coverSource, covers[2], "the others keep theirs")
  }

  /// A one-off picture of a given size, for replacing a preview.
  private static func picture(size: Int, hue: Double) -> Data { PanelFixture.picture(hue: hue, size: size) }

  // MARK: Selection and language

  func testTheSelectionSurvivesALanguageChangeARenameAndAnEqualLibraryHandedOverAgain() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 4)
    model.toggleChecked("w01")
    model.toggleChecked("w02")

    try panel.controller.appLanguage.set("ja")
    XCTAssertEqual(model.selectedIDs, ["w01", "w02"], "the language changes the words, not the selection")
    XCTAssertEqual(titles(model), ["w00", "w01", "w02", "w03"])

    panel.store.librarySnapshot.wallpapers = panel.store.librarySnapshot.wallpapers
    XCTAssertEqual(model.selectedIDs, ["w01", "w02"], "an equal library handed over again changes nothing")

    var renamed = panel.store.librarySnapshot.wallpapers
    renamed[1] = BridgeWallpaperEntry(
      id: "w01", title: "Zeta", kind: renamed[1].kind, supported: true, active: false,
      selected: false, previewPath: nil)
    panel.store.librarySnapshot.wallpapers = renamed
    XCTAssertEqual(titles(model).last, "Zeta", "the renamed wallpaper sorts by its new title")
    XCTAssertEqual(model.selectedIDs, ["w01", "w02"], "and is still ticked")
  }

  func testLeavingThePageClosesItsPopoverAndReportsWhatWaited() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    model.sleep = ManualSleeper().closure
    model.setText("abc")
    model.openImport(from: .page)
    model.leavePage()
    XCTAssertNil(model.importAnchor)
    XCTAssertFalse(panel.controller.shell.isPopoverOpen)
    XCTAssertEqual(panel.navigation.viewState?.installed.text, "abc")
  }

  // MARK: Selection

  func testTheSelectionOutlivesTheViewSearchAndFiltersAndABatchReachesHiddenMembers() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 6)
    model.toggleSelecting()
    for id in ["w01", "w02", "w03"] { model.toggleChecked(id) }
    XCTAssertEqual(model.selectedIDs, ["w01", "w02", "w03"])

    model.setText("zzz")
    model.setRequired("Customizable", true)
    model.show(.favorites)
    XCTAssertEqual(titles(model), [])
    XCTAssertEqual(model.selectedIDs, ["w01", "w02", "w03"], "what is hidden stays ticked")

    model.trashSelection()
    try await panel.waitUntil { !panel.dialogs.confirmations.isEmpty }
    XCTAssertEqual(
      panel.dialogs.confirmations.last?.title, L("Move 3 wallpapers to Trash?"),
      "the confirmation names the whole selection, hidden members included")

    model.clearFilters()
    model.clearSearch()
    model.show(.all)
    model.selectAllVisible()
    XCTAssertEqual(model.selectedIDs.count, 6, "Select all ticks what is on screen")
    model.setText("w01")
    model.clearSelection()
    model.selectAllVisible()
    XCTAssertEqual(model.selectedIDs, ["w01"], "and only that")
  }

  func testLeavingSelectionModeAndEscapePutTheSelectionAway() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 4)
    XCTAssertFalse(model.escape(), "nothing to leave: the key is not taken")
    model.toggleSelecting()
    model.toggleChecked("w00")
    model.toggleSelecting()
    XCTAssertTrue(model.selection.isEmpty, "leaving selection mode clears the selection")
    model.toggleSelecting()
    model.toggleChecked("w00")
    model.clearSelection()
    XCTAssertTrue(model.isSelecting, "Clear stays in selection mode")
    model.toggleChecked("w01")
    XCTAssertTrue(model.escape())
    XCTAssertTrue(model.selection.isEmpty)
    XCTAssertFalse(model.isSelecting, "Escape leaves selection mode too")
    model.beginNewCollection()
    XCTAssertNil(model.newCollectionName, "there is no selection to make a collection of")
  }

  func testWallpapersThatLeaveTheLibraryLeaveTheSelection() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 4)
    model.toggleChecked("w00")
    model.toggleChecked("w02")
    panel.store.librarySnapshot.wallpapers.removeAll { $0.id == "w02" }
    XCTAssertEqual(model.selectedIDs, ["w00"], "a wallpaper that left is neither counted nor sent")
    model.pruneSelection()
    XCTAssertEqual(model.selection.ids, ["w00"])
    XCTAssertNil(model.selection.anchor.flatMap { $0 == "w02" ? $0 : nil })
  }

  func testShiftExtendsInTheOrderShownAndCommandTicks() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 6)
    model.tileClicked("w01", clickCount: 1, modifiers: .command)
    model.tileClicked("w04", clickCount: 1, modifiers: .shift)
    XCTAssertEqual(Set(model.selectedIDs), ["w01", "w02", "w03", "w04"])
    model.tileClicked("w02", clickCount: 1, modifiers: .command)
    XCTAssertEqual(Set(model.selectedIDs), ["w01", "w03", "w04"])
  }

  // MARK: Clicks

  func testAPlainClickChoosesTheDoubleClickAppliesAndTheCountComesFromTheClicksBefore() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let model = panel.controller.library
      var now = Date(timeIntervalSince1970: 1_000)
      model.clock = { now }
      model.doubleClickInterval = { 0.5 }
      try await panel.settleLibrary()

      model.tileClicked("c", modifiers: [])
      try await panel.waitUntil { panel.store.appSnapshot.selectedWallpaperId == "c" }
      XCTAssertTrue(bridge.applications.isEmpty, "a plain click applies nothing")
      XCTAssertTrue(model.selection.isEmpty)

      now.addTimeInterval(0.2)
      model.tileClicked("c", modifiers: [])
      try await panel.waitUntil { bridge.applications.contains { $0.1 == "c" } }
      let applied = bridge.applications.count

      now.addTimeInterval(0.1)
      model.tileClicked("c", modifiers: [])
      try await panel.quiet()
      XCTAssertEqual(bridge.applications.count, applied, "the third click starts over as a plain one")

      now.addTimeInterval(2)
      model.tileClicked("b", modifiers: [])
      now.addTimeInterval(0.1)
      model.tileClicked("a", modifiers: [])
      try await panel.quiet()
      XCTAssertFalse(bridge.applications.contains { $0.1 == "b" }, "two clicks on two tiles are not a double click")
    }
  }

  func testClicksInSelectionModeTickAndNeverChoose() async throws {
    try await withApplyingPanel { panel, _, _ in
      let model = panel.controller.library
      try await panel.settleLibrary()
      let before = panel.store.appSnapshot.selectedWallpaperId
      model.toggleSelecting()
      model.tileClicked("b", clickCount: 1, modifiers: [])
      XCTAssertEqual(model.selectedIDs, ["b"])
      try await panel.quiet()
      XCTAssertEqual(panel.store.appSnapshot.selectedWallpaperId, before, "the inspector is untouched")
    }
  }

  func testReturnOrSpaceOnAFocusedTileIsAClickAndAFavoriteIsToggledByItsHeart() async throws {
    try await withApplyingPanel { panel, _, _ in
      let model = panel.controller.library
      try await panel.settleLibrary()
      model.tileActivated("b")
      try await panel.waitUntil { panel.store.appSnapshot.selectedWallpaperId == "b" }
      await model.toggleFavorite("b").value
      XCTAssertEqual(panel.controller.favoriteIDs, ["b"])
      XCTAssertEqual(PanelPreferences.favorites(in: panel.defaults), ["b"], "written at once")
    }
  }

  // MARK: Delete

  func testDeleteTrashesTheSelectionWhetherOrNotTheFocusedTileIsInItElseTheFocusedTile() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 4)
    model.focusedID = "w03"
    XCTAssertTrue(model.deleteSelectionOrFocused())
    try await panel.waitUntil { panel.dialogs.confirmations.count == 1 }
    XCTAssertEqual(panel.dialogs.confirmations[0].title, L("Move w03 to Trash?"), "no selection: the focused tile")
    try await panel.quiet()

    model.toggleChecked("w00")
    model.toggleChecked("w01")
    XCTAssertTrue(model.deleteSelectionOrFocused())
    try await panel.waitUntil { panel.dialogs.confirmations.count == 2 }
    XCTAssertEqual(
      panel.dialogs.confirmations[1].title, L("Move 2 wallpapers to Trash?"),
      "a selection: all of it, though the focused tile is not in it")
  }

  func testDeleteDoesNothingWithNothingToDeleteOrWhileTheRendererIsBusy() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 2)
    XCTAssertFalse(model.deleteSelectionOrFocused(), "no selection and no focus: the key is not taken")
    model.focusedID = "w00"
    let gate = AsyncGate()
    let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
    try await panel.waitUntil { panel.store.commands.isBusy }
    XCTAssertFalse(model.canTrash)
    XCTAssertFalse(model.deleteSelectionOrFocused())
    XCTAssertNil(model.trashSelection())
    gate.open()
    _ = await running.value
    XCTAssertTrue(model.canTrash)
  }

  // MARK: Batch actions

  func testAddToPlaylistAppendsTheSelectionInTheOrderTickedToTheTargetDisplay() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 4)
    XCTAssertNil(model.addSelectionToPlaylist(), "nothing is ticked")
    model.toggleChecked("w02")
    model.toggleChecked("w00")
    XCTAssertTrue(model.canAddSelectionToPlaylist)
    await model.addSelectionToPlaylist()?.value
    XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["w02", "w00"])
    XCTAssertEqual(model.selectedIDs, ["w02", "w00"], "the selection stays")
  }

  func testAddToPlaylistNeedsADisplayThatCanHaveOne() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 2)
    model.toggleChecked("w00")
    panel.store.settingsSnapshot.displays[0].enabled = false
    XCTAssertFalse(model.canAddSelectionToPlaylist, "a disabled target has no playlist to add to")
    panel.store.settingsSnapshot.displays[0].enabled = true
    panel.store.settingsSnapshot.displays[0].mode = .mirror
    XCTAssertFalse(model.canAddSelectionToPlaylist, "neither has a mirror")
  }

  func testAddingToACollectionSaysHowManyAndLeavesTheSelection() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 4)
    let night = try panel.collections.create(name: "Night", wallpaperIDs: ["w03"])
    model.toggleChecked("w00")
    await model.addSelection(to: panel.controller.collectionRows[0])?.value
    XCTAssertEqual(panel.collections.collections[0].wallpaperIDs, ["w03", "w00"])
    XCTAssertEqual(model.notice, L("Added 1 wallpaper to “Night”."))
    model.toggleChecked("w01")
    await model.addSelection(to: panel.controller.collectionRows[0])?.value
    XCTAssertEqual(model.notice, L("Added 2 wallpapers to “Night”."))
    XCTAssertEqual(model.selectedIDs, ["w00", "w01"])
    _ = night
  }

  func testTheNoticeGoesAfterFiveSeconds() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    let clock = ManualSleeper()
    model.sleep = clock.closure
    model.isMouseButtonDown = { false }
    model.say("Done.")
    XCTAssertEqual(model.notice, "Done.")
    try await timerRequested(clock)
    XCTAssertEqual(clock.requested, [.seconds(5)])
    clock.fireNext()
    try await panel.waitUntil { model.notice == nil }
  }

  func testANewCollectionFromTheSelectionIsNamedInTheBarAndIsNotShown() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 4)
    model.toggleChecked("w01")
    model.toggleChecked("w03")
    model.beginNewCollection()
    XCTAssertEqual(model.newCollectionName, "")
    XCTAssertNil(model.createCollectionFromSelection(), "a blank name does nothing, and the field stays")
    XCTAssertEqual(model.newCollectionName, "")
    model.setNewCollectionName("  Favorites of May  ")
    await model.createCollectionFromSelection()?.value
    XCTAssertEqual(panel.collections.collections.map(\.name), ["Favorites of May"])
    XCTAssertEqual(panel.collections.collections[0].wallpaperIDs, ["w01", "w03"])
    XCTAssertNil(model.newCollectionName, "the field closes once the collection exists")
    XCTAssertEqual(model.notice, L("Added 2 wallpapers to “Favorites of May”."))
    XCTAssertEqual(model.scope, .all, "a collection made from the selection is not switched to")
    model.beginNewCollection()
    model.cancelNewCollection()
    XCTAssertNil(model.newCollectionName)
  }

  func testAnInvalidCollectionNameGoesToTheBannerAndKeepsTheField() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 2)
    model.toggleChecked("w00")
    model.beginNewCollection()
    // A pasted line break is the refusal a single-line field can still be handed.
    model.setNewCollectionName("Night\nDay")
    await model.createCollectionFromSelection()?.value
    XCTAssertNotNil(panel.controller.errors.message)
    XCTAssertEqual(model.newCollectionName, "Night\nDay", "the person can correct the name")
    XCTAssertTrue(panel.collections.collections.isEmpty)
  }

  func testTheBarsCollectionNameStopsAtTheLongestNameTheStoreTakes() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 2)
    model.toggleChecked("w00")
    model.beginNewCollection()
    model.setNewCollectionName(String(repeating: "n", count: 200))
    XCTAssertEqual(model.newCollectionName?.count, 128)
    await model.createCollectionFromSelection()?.value
    XCTAssertEqual(panel.collections.collections.map(\.name.count), [128], "so it is never refused")
  }

  func testTheWindowHasOneCollectionNameFieldAtATime() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    let editor = panel.controller.shell.collectionEditor
    try await installNames(panel, count: 2)
    let night = try panel.collections.create(name: "Night", wallpaperIDs: [])
    model.toggleChecked("w00")

    editor.beginCreate()
    model.beginNewCollection()
    XCTAssertFalse(editor.isOpen, "the bar's field closes the sidebar's")
    XCTAssertEqual(model.newCollectionName, "")

    editor.beginRename(night.id)
    XCTAssertNil(model.newCollectionName, "a sidebar rename closes the bar's field")
    model.beginNewCollection()
    editor.beginCreate()
    XCTAssertNil(model.newCollectionName, "and so does the sidebar's +")
    XCTAssertTrue(editor.isOpen)
  }

  func testTheBarsCollectionToolsWaitForASidebarRenameOrDelete() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 2)
    let night = try panel.collections.create(name: "Night", wallpaperIDs: ["w00"])
    model.show(.collection(night.id))
    model.toggleChecked("w00")
    XCTAssertFalse(model.isChangingCollection)
    XCTAssertTrue(model.canRemoveSelectionFromCollection)

    // The sidebar's rename and delete run under the collection editor's keys; while one is in
    // flight (a delete waits on its confirmation sheet), the bar's tools wait too.
    for key in [CollectionEditorModel.renameKey, CollectionEditorModel.deleteKey] {
      let gate = ManualSleeper()
      let change = panel.controller.launch(key) { try await gate.sleep(.seconds(1)) }
      await gate.waitUntilPending()
      XCTAssertTrue(model.isChangingCollection, key)
      XCTAssertFalse(model.canRemoveSelectionFromCollection, key)
      gate.fireAll()
      await change.value
      XCTAssertFalse(model.isChangingCollection, key)
    }
  }

  func testRemovingFromTheShownCollectionNeedsAMemberAndSaysHowMany() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    try await installNames(panel, count: 4)
    let night = try panel.collections.create(name: "Night", wallpaperIDs: ["w00", "w01"])
    XCTAssertFalse(model.canRemoveSelectionFromCollection, "no collection is shown")
    model.show(.collection(night.id))
    model.toggleChecked("w03")
    XCTAssertFalse(model.canRemoveSelectionFromCollection, "none of the ticked is a member")
    model.toggleChecked("w00")
    model.toggleChecked("w01")
    XCTAssertTrue(model.canRemoveSelectionFromCollection)
    await model.removeSelectionFromShownCollection()?.value
    XCTAssertEqual(panel.collections.collections[0].wallpaperIDs, [])
    XCTAssertEqual(model.notice, L("Removed 3 wallpapers from “Night”."))
  }

  // MARK: The sweep, as the model drives it

  private func measure(_ model: InstalledBrowserModel) {
    model.geometry.viewport = CGSize(width: 760, height: 500)
    model.geometry.cellSize = CGSize(width: 165, height: 200)
    model.geometry.contentHeight = 1_000
  }

  /// A point in the middle of the tile at `index`, in the scroll view's coordinates.
  private func point(_ model: InstalledBrowserModel, _ index: Int) -> CGPoint {
    let frame = model.geometry.frame(ofIndex: index)
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  func testHoldingAPressTicksItsTileSweepingExtendsTheRunAndTheClickThatEndsItChangesNothing() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    let clock = ManualSleeper()
    model.sleep = clock.closure
    model.isMouseButtonDown = { false }
    try await installNames(panel, count: 8)
    measure(model)
    XCTAssertFalse(panel.controller.dragSelectLearned)

    model.sweepPressed(at: point(model, 0), modifiers: [])
    XCTAssertEqual(model.armingID, "w00", "the pressed tile shows the hold in progress")
    try await timerRequested(clock)
    XCTAssertEqual(clock.requested, [.milliseconds(350)])
    clock.fireNext()
    try await panel.waitUntil { model.selection.ids == ["w00"] }
    XCTAssertNil(model.armingID)

    model.sweepMoved(to: point(model, 3))
    XCTAssertEqual(Set(model.selectedIDs), ["w00", "w01", "w02", "w03"])
    model.sweepMoved(to: point(model, 1))
    XCTAssertEqual(Set(model.selectedIDs), ["w00", "w01"], "sweeping back gives the overshoot back")

    model.endSweep()
    XCTAssertTrue(panel.controller.dragSelectLearned, "covering two tiles teaches the gesture")
    XCTAssertTrue(PanelPreferences.dragSelectLearned(in: panel.defaults), "and it is remembered")
    model.tileClicked("w01", clickCount: 1, modifiers: [])
    XCTAssertEqual(Set(model.selectedIDs), ["w00", "w01"], "the click ending the press does not toggle")
    XCTAssertEqual(panel.store.appSnapshot.selectedWallpaperId, nil, "and does not choose")
    try await panel.waitUntil { !model.swallowsClick }
    model.tileClicked("w01", clickCount: 1, modifiers: .command)
    XCTAssertEqual(model.selectedIDs, ["w00"], "the next click counts again")
  }

  func testAQuickDragOutsideASelectionACommandPressAndAPressOnAHeartStartNoSweep() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    let clock = ManualSleeper()
    model.sleep = clock.closure
    model.isMouseButtonDown = { false }
    try await installNames(panel, count: 8)
    measure(model)

    model.sweepPressed(at: point(model, 0), modifiers: [])
    model.sweepMoved(to: point(model, 3))
    XCTAssertNil(model.sweep, "an ordinary drag is left alone")
    XCTAssertTrue(model.selection.isEmpty)
    XCTAssertNil(model.holdTask, "the hold was given up")

    model.sweepPressed(at: point(model, 0), modifiers: .command)
    XCTAssertNil(model.sweep)
    model.sweepPressed(at: point(model, 0), modifiers: .shift)
    XCTAssertNil(model.sweep)

    let frame = model.geometry.frame(ofIndex: 2)
    model.sweepPressed(at: CGPoint(x: frame.maxX - 10, y: frame.minY + 10), modifiers: [])
    XCTAssertNil(model.sweep, "a press on the heart is a click on the heart")
    model.sweepPressed(at: CGPoint(x: 5, y: 5), modifiers: [])
    XCTAssertNil(model.sweep, "off any tile")
  }

  func testWithASelectionUnderWayMovingOntoAnotherTileSweepsWithoutAHold() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    model.sleep = ManualSleeper().closure
    try await installNames(panel, count: 8)
    measure(model)
    model.toggleChecked("w00")

    model.sweepPressed(at: point(model, 1), modifiers: [])
    XCTAssertEqual(model.sweep?.isEager, true)
    model.sweepMoved(to: point(model, 3))
    XCTAssertEqual(Set(model.selectedIDs), ["w00", "w01", "w02", "w03"])
    model.endSweep()
  }

  func testPressingTheCheckOfATileStartsAnEagerSweepEvenWithNothingTicked() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    model.sleep = ManualSleeper().closure
    try await installNames(panel, count: 8)
    measure(model)
    let frame = model.geometry.frame(ofIndex: 0)
    model.sweepPressed(at: CGPoint(x: frame.minX + 12, y: frame.minY + 12), modifiers: [])
    XCTAssertEqual(model.sweep?.isEager, true)
    model.endSweep()
  }

  func testACheckHeldLongEnoughToSweepIsNotToggledAgainByItsOwnClick() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    let clock = ManualSleeper()
    model.sleep = clock.closure
    model.isMouseButtonDown = { false }
    try await installNames(panel, count: 4)
    measure(model)
    let frame = model.geometry.frame(ofIndex: 0)
    model.sweepPressed(at: CGPoint(x: frame.minX + 12, y: frame.minY + 12), modifiers: [])
    try await timerRequested(clock)
    clock.fireNext()
    try await panel.waitUntil { model.selection.ids == ["w00"] }
    model.endSweep()
    model.toggleChecked("w00")
    XCTAssertEqual(model.selectedIDs, ["w00"], "the click ending the press changes nothing")
  }

  func testTheGridScrollsUnderAPointerAtItsEdgeAndTheTileThatArrivesJoinsTheSweep() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    let clock = ManualSleeper()
    model.sleep = clock.closure
    model.isMouseButtonDown = { false }
    try await installNames(panel, count: 24)
    measure(model)
    model.geometry.contentHeight = 1_600
    var scrolled: [CGFloat] = []
    model.scrollGrid = { scrolled.append($0) }
    model.toggleChecked("w00")

    model.sweepPressed(at: point(model, 1), modifiers: [])
    model.sweepMoved(to: point(model, 2))
    // The pointer rests in the bottom band, over the tile at column 2 of the row there.
    let resting = CGPoint(x: point(model, 2).x, y: 490)
    model.sweepMoved(to: resting)
    try await timerRequested(clock)
    clock.fireNext()
    try await panel.waitUntil { !scrolled.isEmpty }
    XCTAssertGreaterThan(scrolled[0], 0, "down, by a third of how deep into the band the pointer is")
    XCTAssertEqual(model.geometry.offsetY, scrolled[0])
    XCTAssertGreaterThan(model.selection.count, 3, "tiles that scrolled under the pointer joined the run")
    model.endSweep()
    XCTAssertNil(model.autoscrollTask)
    let count = scrolled.count
    clock.fireAll()
    try await panel.quiet()
    XCTAssertEqual(scrolled.count, count, "nothing scrolls once the press is over")
  }

  // MARK: The animated preview

  func testTheOneTilePlayingIsTheOneThePointerRestedOnAndNothingElseAnimates() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    let clock = ManualSleeper()
    model.sleep = clock.closure
    model.isMouseButtonDown = { false }
    try panel.installLibrary([
      LibrarySpec("gif1", "Moving", preview: .animation),
      LibrarySpec("gif2", "Moving too", preview: .animation),
      LibrarySpec("png", "Still", preview: .picture(0.3)),
      LibrarySpec("none", "Nothing", preview: .none),
    ])
    try await panel.loadLibrary()
    try await panel.settleLibrary()
    XCTAssertNil(model.livePreview, "no tile animates at rest")

    model.pointerEntered("gif1")
    XCTAssertNil(model.livePreview, "the pointer must settle before anything loads")
    try await timerRequested(clock)
    XCTAssertEqual(clock.requested, [.milliseconds(160)])
    clock.fireNext()
    try await panel.waitUntil(timeout: 10) { model.livePreview?.id == "gif1" }

    model.pointerLeft("gif1")
    XCTAssertNil(model.livePreview, "leaving releases it at once")
    model.pointerEntered("gif2")
    try await timerRequested(clock)
    clock.fireNext()
    try await panel.waitUntil(timeout: 10) { model.livePreview?.id == "gif2" }
    model.pointerEntered("gif1")
    XCTAssertNil(model.livePreview, "moving to another tile releases the first, never two at once")

    model.pointerEntered("png")
    clock.fireAll()
    try await panel.quiet()
    XCTAssertNil(model.livePreview, "a picture has nothing to animate")
    model.pointerEntered("none")
    try await panel.quiet()
    XCTAssertNil(model.livePreview)
  }

  func testSweepingAcrossTilesWithoutStoppingAHeldButtonAndAClickFocusPlayNothing() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    let clock = ManualSleeper()
    model.sleep = clock.closure
    model.isMouseButtonDown = { false }
    try panel.installLibrary([
      LibrarySpec("gif1", "A", preview: .animation), LibrarySpec("gif2", "B", preview: .animation),
    ])
    try await panel.loadLibrary()
    try await panel.settleLibrary()

    model.pointerEntered("gif1")
    model.pointerEntered("gif2")
    model.pointerLeft("gif2")
    clock.fireAll()
    try await panel.quiet()
    XCTAssertNil(model.livePreview, "the pointer never rested")
    XCTAssertGreaterThanOrEqual(clock.cancelledCount, 2, "each change cancelled the pending dwell")

    model.focusChanged("gif1", isFocused: true, byKeyboard: false)
    clock.fireAll()
    try await panel.quiet()
    XCTAssertNil(model.livePreview, "a focus that is not keyboard focus starts nothing")
  }

  func testKeyboardFocusPlaysATileThePointerTakesOverAndGivesBackAndEverythingReleases() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    let clock = ManualSleeper()
    model.sleep = clock.closure
    model.isMouseButtonDown = { false }
    try panel.installLibrary([
      LibrarySpec("gif1", "A", preview: .animation), LibrarySpec("gif2", "B", preview: .animation),
    ])
    try await panel.loadLibrary()
    try await panel.settleLibrary()

    model.focusChanged("gif1", isFocused: true, byKeyboard: true)
    XCTAssertEqual(model.focusedID, "gif1", "the focused tile is what Delete acts on")
    try await timerRequested(clock)
    clock.fireNext()
    try await panel.waitUntil(timeout: 10) { model.livePreview?.id == "gif1" }

    model.pointerEntered("gif2")
    XCTAssertNil(model.livePreview, "the pointer takes over from focus")
    try await timerRequested(clock)
    clock.fireNext()
    try await panel.waitUntil(timeout: 10) { model.livePreview?.id == "gif2" }
    model.pointerLeft("gif2")
    try await timerRequested(clock)
    clock.fireNext()
    try await panel.waitUntil(timeout: 10) { model.livePreview?.id == "gif1" }

    model.windowWentAway()
    XCTAssertNil(model.livePreview, "a window that lost focus or was hidden plays nothing")
    model.focusChanged("gif1", isFocused: false, byKeyboard: true)
    XCTAssertNil(model.focusedID)
  }

  func testATileFilteredAwayStopsPlayingAndASweepHoldsEverythingStill() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    let clock = ManualSleeper()
    model.sleep = clock.closure
    model.isMouseButtonDown = { false }
    try panel.installLibrary([
      LibrarySpec("gif1", "Moving", preview: .animation), LibrarySpec("other", "Other", preview: .none),
    ])
    try await panel.loadLibrary()
    try await panel.settleLibrary()
    measure(model)

    model.pointerEntered("gif1")
    try await timerRequested(clock)
    clock.fireNext()
    try await wait(panel, "the first animation") { model.livePreview != nil }
    model.setText("other")
    model.releaseLivePreviewIfHidden()
    XCTAssertNil(model.livePreview, "the tile left the list")

    model.setText("")
    model.pointerLeft("gif1")
    model.pointerEntered("gif1")
    model.sweepPressed(at: point(model, 0), modifiers: [])
    clock.fireAll()
    try await panel.quiet()
    XCTAssertNil(model.livePreview, "nothing plays while a sweep is under way")
    model.endSweep()
    // The report of the search text waits on the same clock; every timer is let go until the
    // dwell has been.
    try await wait(panel, "the animation after the sweep") {
      clock.fireAll()
      return model.livePreview?.id == "gif1"
    }
  }

  // MARK: Import

  func testTheImportPopoverStartsAtSkipAndOpensFromOneAnchorAtATime() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.library
    XCTAssertEqual(model.importDuplicates, .skip, "keep what the library holds")
    panel.controller.shell.setFiltersShown(true)
    XCTAssertFalse(panel.controller.shell.isPopoverOpen, "the Filters sidebar is not a popover")
    model.openImport(from: .page)
    XCTAssertTrue(panel.controller.shell.areFiltersShown, "and stays open beside it")
    XCTAssertEqual(model.importAnchor, .page)
    XCTAssertTrue(panel.controller.shell.isPopoverOpen)
    model.toggleImport(from: .page)
    XCTAssertNil(model.importAnchor)
    XCTAssertFalse(panel.controller.shell.isPopoverOpen)
    model.openImport(from: .page)
    model.openImport(from: .pill)
    XCTAssertEqual(model.importAnchor, .pill, "the popover moves to the anchor that asked last")
    model.closeImport()
    XCTAssertNil(model.importAnchor)
  }

  func testAFinishedImportShowsInThePillUntilItsPopoverHasBeenOpenedAndClosed() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let model = controller.library
    XCTAssertFalse(ImportActivityPill.isActive(in: controller), "an idle app has no pill")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    panel.dialogs.presentingWindow = window
    let source = panel.root.appendingPathComponent("sources/123456")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("movie".utf8).write(to: source.appendingPathComponent("movie.mp4"))
    try JSONSerialization.data(withJSONObject: ["title": "T", "type": "video", "file": "movie.mp4"])
      .write(to: source.appendingPathComponent("project.json"))
    controller.chooseImportFiles = { _, _ in [source] }

    await model.chooseImportFiles().value
    try await panel.waitUntil(timeout: 10) { controller.importState.report != nil && !controller.imports.isBusy }
    try await panel.waitUntil {
      model.importPill.state.report != nil && !model.importPill.state.isBusy
    }
    XCTAssertTrue(ImportActivityPill.isActive(in: controller))
    XCTAssertEqual(model.importPill.label, L("1 imported · 0 skipped"))

    model.openImport(from: .pill)
    XCTAssertTrue(ImportActivityPill.isActive(in: controller), "the popover keeps its anchor while it is open")
    model.closeImport()
    XCTAssertFalse(ImportActivityPill.isActive(in: controller), "it has been looked at")
  }

  func testAReportThatArrivesWhileThePopoverIsOpenNeedsNoPill() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let model = controller.library
    panel.dialogs.presentingWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
      defer: true)
    panel.dialogs.presentingWindow?.isReleasedWhenClosed = false
    let missing = panel.root.appendingPathComponent("not-there")
    controller.chooseImportFiles = { _, _ in [missing] }
    model.openImport(from: .page)
    await model.chooseImportFiles().value
    try await panel.waitUntil(timeout: 10) { controller.importState.report != nil && !controller.imports.isBusy }
    try await panel.quiet()
    XCTAssertFalse(ImportActivityPill.isActive(in: controller), "the report is already being read")
    XCTAssertEqual(model.importPill.state.report?.needsAttention, true)
    XCTAssertEqual(model.importPill.state.report?.failures.count, 1)
  }
}
