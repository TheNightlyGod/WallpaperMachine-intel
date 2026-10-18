import XCTest

@testable import WallpaperMachine

/// Installed filters the library with Discover's rules: a ticked "Show only" box requires its tag,
/// an unticked box excludes the wallpapers that carry it.
@MainActor
final class LibraryFilterTests: XCTestCase {
  private let rows = [
    LibraryRows.row(
      "anime", kind: .scene, tags: ["anime", "Everyone", "Audio responsive"], approved: true),
    LibraryRows.row("nature", kind: .video, tags: ["Nature", "Mature"], active: true),
    LibraryRows.row("plain", kind: .web, tags: ["Everyone", "Customizable"]),
    LibraryRows.row("bare", kind: .unknown),
  ]

  private func shown(
    required: [String] = [], excluded: [String] = [], text: String = "", collection: Set<String>? = nil
  ) -> [String] {
    var filter = LibraryFilter()
    filter.requiredTags = required
    filter.excludedTags = excluded
    filter.text = text
    return filter.apply(to: rows, favorites: ["plain"], members: collection).map(\.id)
  }

  func testNothingIsHiddenByDefault() {
    XCTAssertEqual(shown(), ["anime", "nature", "plain", "bare"])
    XCTAssertEqual(LibraryFilter().activeCount, 0)
  }

  func testShowOnlyBoxesRequireTheirTagFromTheLibrarysOwnFactsAndTheManifest() {
    XCTAssertEqual(shown(required: ["Favorite"]), ["plain"], "Favorites is a Show only box")
    XCTAssertEqual(shown(required: ["Active"]), ["nature"], "so is Active on the target display")
    XCTAssertEqual(shown(required: ["Approved"]), ["anime"], "Approved reads the manifest's approval")
    XCTAssertEqual(shown(required: ["Audio responsive"]), ["anime"])
    XCTAssertEqual(shown(required: ["Customizable"]), ["plain"])
    XCTAssertEqual(shown(required: ["Everyone", "Customizable"]), ["plain"], "every required tag must match")
  }

  func testUpdateIsAShowOnlyBoxToo() {
    let updated = [LibraryRows.row("u", update: true), LibraryRows.row("n")]
    var filter = LibraryFilter()
    filter.requiredTags = ["Update"]
    XCTAssertEqual(filter.apply(to: updated, favorites: [], members: nil).map(\.id), ["u"])
  }

  func testUntickingATagHidesWallpapersCarryingItWhateverItsCase() {
    XCTAssertEqual(shown(excluded: ["Anime"]), ["nature", "plain", "bare"], "the manifest says anime")
    XCTAssertEqual(shown(excluded: ["Mature"]), ["anime", "plain", "bare"], "age rating is a manifest tag")
  }

  func testAWallpaperWithNoGenreCountsAsUnspecified() {
    XCTAssertEqual(
      shown(excluded: ["Anime", "Unspecified"]), ["nature"],
      "plain and bare name no genre, so unticking Unspecified hides them")
  }

  func testTypeBoxesReadTheKindAndAKindSteamHasNoBoxForStays() {
    XCTAssertEqual(shown(excluded: ["Video", "Web"]), ["anime", "bare"])
    XCTAssertEqual(shown(excluded: ["Scene", "Video", "Web"]), ["bare"], "Unknown has no Type box")
  }

  func testNoneOnTagsHidesEverythingUnspecifiedIncluded() {
    let section = LibraryFilterCatalog.section(key: "genre")!
    XCTAssertEqual(shown(excluded: section.tags), [])
  }

  func testSearchNarrowsByTitleAndTagsAndIsNotTrimmed() {
    XCTAssertEqual(shown(text: "nat"), ["nature"])
    XCTAssertEqual(shown(text: "EVERYONE"), ["anime", "plain"], "tags count, whatever the case")
    XCTAssertEqual(
      shown(text: " "), ["anime", "nature", "plain", "bare"],
      "the text is not trimmed, and the title and tags are joined by a space")
    XCTAssertEqual(shown(text: "nature mature"), ["nature"], "the search spans the joined text")
    XCTAssertEqual(shown(text: "a", collection: ["bare", "plain"]), ["plain", "bare"])
  }

  func testACollectionNarrowsToItsMembersAndCountsAsAFilter() {
    XCTAssertEqual(shown(collection: ["bare", "anime"]), ["anime", "bare"])
    var filter = LibraryFilter()
    filter.collectionID = "night"
    filter.requiredTags = ["Favorite"]
    filter.excludedTags = ["Anime", "Web"]
    XCTAssertEqual(filter.activeCount, 4, "required tags, unticked boxes and the collection")
    XCTAssertEqual(filter.clearingFilters().activeCount, 0)
  }

  func testClearKeepsTheSearchText() {
    var filter = LibraryFilter(text: "nat", requiredTags: ["Favorite"], excludedTags: ["Web"])
    filter.collectionID = "night"
    XCTAssertEqual(filter.clearingFilters().text, "nat")
    XCTAssertFalse(filter.clearingFilters().hasFilters)
  }

  func testGroupCountsCountTheUntickedBoxesOfTheGroup() {
    let filter = LibraryFilter(excludedTags: ["Anime", "Web", "Mature"])
    let groups = LibraryFilterCatalog.installedGroups
    func count(_ key: String) -> Int {
      filter.count(among: groups.first { $0.key == key }!.tags)
    }
    XCTAssertEqual(count("type"), 1)
    XCTAssertEqual(count("rating"), 1)
    XCTAssertEqual(count("genre"), 1)
  }

  func testGroupCountsCountSelectedChipsToo() {
    let filter = LibraryFilter(requiredTags: ["Approved", "Anime"], excludedTags: ["Nature"])
    let genre = LibraryFilterCatalog.installedGroups.first { $0.key == "genre" }!
    XCTAssertEqual(filter.count(among: genre.tags), 2)
    XCTAssertTrue(LibraryFilterCatalog.chipTags.contains("Anime"))
    XCTAssertFalse(LibraryFilterCatalog.chipTags.contains("Scene"), "Type stays a list of boxes")
  }

  func testRestoredRequiredTagsNoWallpaperCarriesAreStaleAndExcludedOnesAreNot() {
    let filter = LibraryFilter(
      requiredTags: ["Approved", "Customizable", "Gone"], excludedTags: ["Gone"])
    XCTAssertEqual(
      filter.staleRequiredTags(in: rows, favorites: []), ["Gone"],
      "a tag some wallpaper still carries stays")
    XCTAssertEqual(
      LibraryFilter(requiredTags: ["Favorite"]).staleRequiredTags(in: rows, favorites: []),
      ["Favorite"], "no favorite is left")
    XCTAssertEqual(
      LibraryFilter(requiredTags: ["Favorite"]).staleRequiredTags(in: rows, favorites: ["plain"]), [])
  }

  // MARK: The catalog

  func testInstalledOffersWhatAManifestCanAnswerAndNotDiscoversResolutionOrCategory() {
    XCTAssertEqual(
      LibraryFilterCatalog.installedGroups.map(\.key), ["type", "rating", "genre"])
    XCTAssertEqual(LibraryFilterCatalog.installedGroups[0].sections.map(\.key), ["type"])
    XCTAssertEqual(
      LibraryFilterCatalog.showOnly.map(\.tag),
      ["Favorite", "Active", "Update", "Approved", "Audio responsive", "Customizable"])
  }

  func testTheCatalogsDefaultExclusionsAreTheWorkshopStoresSoTheyCannotDrift() {
    XCTAssertEqual(LibraryFilterCatalog.defaultExcludedTags, WorkshopStore.defaultExcludedTags)
  }

  func testEveryGenreTagIsLowerCasedForMatchingAndUnspecifiedIsNotAmongThem() {
    XCTAssertEqual(LibraryFilterCatalog.genreTags.count, 24)
    XCTAssertFalse(LibraryFilterCatalog.genreTags.contains("unspecified"))
    XCTAssertTrue(LibraryFilterCatalog.genreTags.contains("pixel art"))
  }

  func testEveryTagIsOfferedOnce() {
    let tags = LibraryFilterCatalog.sections.flatMap(\.tags)
    XCTAssertEqual(Set(tags).count, tags.count)
  }
}
