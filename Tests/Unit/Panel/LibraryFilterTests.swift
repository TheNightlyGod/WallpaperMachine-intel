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

  func testSearchIgnoresCaseAccentsAndWidthOnBothSides() {
    let rows = [
      LibraryRows.row("cafe", "Café Nocturne"),
      LibraryRows.row("wide", "ＮＥＯＮ　Ｃｉｔｙ"),
      LibraryRows.row("plain", "Cafeteria"),
      LibraryRows.row("kana", "夜のカフェ"),
      LibraryRows.row("bus", "バス停"),
    ]
    func shown(_ text: String) -> [String] {
      LibraryFilter(text: text).apply(to: rows, favorites: [], members: nil).map(\.id)
    }
    XCTAssertEqual(shown("cafe"), ["cafe", "plain"], "the accent on the title does not matter")
    XCTAssertEqual(shown("CAFÉ"), ["cafe", "plain"], "nor the one typed, nor the case")
    XCTAssertEqual(shown("Cafe\u{301}"), ["cafe", "plain"], "nor how the accent was typed")
    XCTAssertEqual(shown("neon city"), ["wide"], "full-width letters and spaces read as usual")
    XCTAssertEqual(shown("ｶﾌｪ"), ["kana"], "half-width katakana reads as full width")
    XCTAssertEqual(shown("ﾊﾞｽ"), ["bus"], "its voicing mark included")
    XCTAssertEqual(shown("ハス"), [], "a voicing mark is part of the kana, not an accent")
    XCTAssertEqual(shown("nocturnes"), [])
  }

  func testSearchReadsTheAuthorAndDescriptionTheManifestNames() {
    let rows = [
      LibraryRows.row(
        "pixiv-1-0", "Sunset", manifest: ["pixiv": ["author": "Élodie"], "description": "Dusk"]),
      LibraryRows.row("top", "Rain", manifest: ["author": "Kyōko"]),
      LibraryRows.row(
        "described", "Forest",
        manifest: ["description": "A quiet glade at dawn, with birdsong and moving fog."]),
      LibraryRows.row("bare", "Glade"),
    ]
    func shown(_ text: String) -> [String] {
      LibraryFilter(text: text).apply(to: rows, favorites: [], members: nil).map(\.id)
    }
    XCTAssertEqual(shown("elodie"), ["pixiv-1-0"], "a pixiv save records its author")
    XCTAssertEqual(shown("kyoko"), ["top"])
    XCTAssertEqual(shown("moving fog"), ["described"])
    XCTAssertEqual(shown("glade"), ["described", "bare"], "the description and the title alike")
    XCTAssertEqual(shown("rain kyoko"), [], "a search never spans the title and the author")
  }

  func testAWorkshopLinkOrIdFindsThatWallpaperAndNothingThatMerelyMentionsIt() {
    let rows = [
      LibraryRows.row("2077200001", "Neon City"),
      LibraryRows.row(
        "fan", "Neon fan art",
        manifest: [
          "description":
            "Based on https://steamcommunity.com/sharedfiles/filedetails/?id=2077200001 (2077200001)"
        ]),
      LibraryRows.row("year", "Night of 2077"),
    ]
    func shown(_ text: String) -> [String] {
      LibraryFilter(text: text).apply(to: rows, favorites: [], members: nil).map(\.id)
    }
    XCTAssertEqual(
      shown("https://steamcommunity.com/sharedfiles/filedetails/?id=2077200001"), ["2077200001"],
      "a link to the item finds it, not the description that links it")
    XCTAssertEqual(shown("steam://url/CommunityFilePage/2077200001"), ["2077200001"])
    XCTAssertEqual(shown(" 2077200001\n"), ["2077200001"], "a pasted bare id, spaces and all")
    XCTAssertEqual(
      shown("2077"), ["fan", "year"],
      "a short number is still words, found in descriptions and titles but never in an id")
    XCTAssertEqual(shown("https://steamcommunity.com/sharedfiles/filedetails/?id=1"), [])
  }

  func testABareNumberNoWallpaperHasForItsIdIsSearchedAsWordsAndALinkNeverIs() {
    let rows = [
      LibraryRows.row(
        "pixiv-123456789-0", "Sunset",
        manifest: ["description": "Sunset by Élodie on pixiv: https://www.pixiv.net/artworks/123456789"]),
      LibraryRows.row(
        "fan", "Neon fan art",
        manifest: ["description": "Based on https://steamcommunity.com/sharedfiles/filedetails/?id=2077200001"]),
      LibraryRows.row("plain", "Glade"),
    ]
    func shown(_ text: String) -> [String] {
      LibraryFilter(text: text).apply(to: rows, favorites: [], members: nil).map(\.id)
    }
    XCTAssertEqual(
      shown("123456789"), ["pixiv-123456789-0"],
      "no wallpaper has that id, so it is words, as the artwork id of a work saved from pixiv")
    XCTAssertEqual(shown(" 123456789\n"), ["pixiv-123456789-0"], "without the spaces a paste brings")
    XCTAssertEqual(shown("987654321"), [])
    XCTAssertEqual(
      shown("https://steamcommunity.com/sharedfiles/filedetails/?id=2077200001"), [],
      "a link names a Workshop item whether or not it is installed, never a description that links it")
  }

  func testTypingACollectionsNameAlsoShowsItsWallpapers() {
    let rows = [
      LibraryRows.row("a", "Aurora"), LibraryRows.row("b", "Beach"), LibraryRows.row("c", "Café"),
    ]
    let collections = [
      CollectionRow(id: "1", name: "Café", wallpaperIDs: ["b"]),
      CollectionRow(id: "2", name: "Cafés of Paris", wallpaperIDs: ["a"]),
    ]
    func shown(_ text: String) -> [String] {
      let filter = LibraryFilter(text: text)
      return filter.apply(
        to: rows, favorites: [], members: nil,
        named: filter.membersOfCollectionsNamed(in: collections)
      ).map(\.id)
    }
    XCTAssertEqual(shown("cafe "), ["b", "c"], "its whole name, whatever the accent, case and spaces")
    XCTAssertEqual(shown("caf"), ["c"], "part of a name is not the name")
    XCTAssertEqual(shown("cafes of paris"), ["a"])
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
