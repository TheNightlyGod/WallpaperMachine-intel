import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The Workshop's filter boxes and how they count: Wallpaper Engine's own sidebar, tag for tag, with
/// the defaults that must equal the Workshop store's.
final class WorkshopFilterCatalogTests: XCTestCase {
  private typealias Catalog = WorkshopFilterCatalog

  func testTheDefaultExcludedTagsAreTheStoresOwn() {
    XCTAssertEqual(
      WorkshopFilterDraft.defaultExcludedTags, WorkshopStore.defaultExcludedTags,
      "the two lists must be kept identical: what the page ticks by default is what the store sends")
    XCTAssertEqual(Catalog.hiddenExcludedTags, ["Application", "Asset"], "never offered, always excluded")
  }

  func testEveryTagIsOfferedOnceAndNoShowOnlyBoxIsAlsoAHidingBox() {
    let tags = Catalog.entries.map(\.tag)
    XCTAssertEqual(Set(tags).count, tags.count, "a tag in two boxes would be ticked by both")
    XCTAssertTrue(Set(Catalog.showOnly.map(\.tag)).isDisjoint(with: tags))
    XCTAssertTrue(Set(tags).isDisjoint(with: Catalog.hiddenExcludedTags), "Application and Asset are never offered")
    XCTAssertEqual(Catalog.showOnly.map(\.tag), ["Approved", "Audio responsive", "Customizable"])
  }

  func testTheGroupsAreWallpaperEnginesInTheirOrder() {
    XCTAssertEqual(Catalog.groups.map(\.id), ["type", "rating", "resolution", "genre"])
    let sections = Catalog.sections
    XCTAssertEqual(
      sections.map(\.id),
      [
        "type", "category", "rating", "widescreen", "ultrawide", "dual", "triple", "portrait",
        "other-resolution", "genre",
      ])
    XCTAssertEqual(sections.first { $0.id == "type" }?.tags, ["Scene", "Video", "Web"])
    XCTAssertEqual(sections.first { $0.id == "category" }?.tags, ["Wallpaper", "Preset"])
    XCTAssertEqual(
      sections.first { $0.id == "rating" }?.tags, ["Everyone", "Questionable", "Mature"])
    XCTAssertEqual(sections.first { $0.id == "genre" }?.entries.count, 25)
    XCTAssertEqual(
      sections.filter(\.hasQuickLinks).map(\.id),
      ["widescreen", "ultrawide", "dual", "triple", "portrait", "genre"],
      "All and None are offered for the resolutions and the genres")
    XCTAssertEqual(sections.first { $0.id == "genre" }?.style, .chips)
  }

  func testAResolutionTagCarriesItsFamilyAsAPrefix() {
    func tags(_ id: String) -> [String] { Catalog.sections.first { $0.id == id }?.tags ?? [] }
    XCTAssertEqual(
      tags("widescreen"),
      [
        "Standard Definition", "1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440",
        "3840 x 2160",
      ])
    XCTAssertEqual(
      tags("ultrawide"),
      ["Ultrawide Standard Definition", "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440"])
    XCTAssertEqual(
      tags("dual"),
      ["Dual Standard Definition", "Dual 3840 x 1080", "Dual 5120 x 1440", "Dual 7680 x 2160"])
    XCTAssertEqual(tags("triple").count, 5)
    XCTAssertEqual(tags("triple").first, "Triple Standard Definition")
    XCTAssertEqual(
      tags("portrait"),
      [
        "Portrait Standard Definition", "Portrait 720 x 1280", "Portrait 1080 x 1920",
        "Portrait 1440 x 2560", "Portrait 2160 x 3840",
      ])
    XCTAssertEqual(tags("other-resolution"), ["Other resolution", "Dynamic resolution"])
  }

  func testOnlyQuestionableMatureAndUnspecifiedStartUnticked() {
    XCTAssertEqual(
      Catalog.entries.filter(\.isOffByDefault).map(\.tag), ["Questionable", "Mature", "Unspecified"])
    let fresh = WorkshopFilterDraft.cleared
    XCTAssertEqual(fresh.count, 0, "a fresh sidebar filters nothing, so the count reads zero")
    XCTAssertFalse(fresh.isIncluded("Mature"))
    XCTAssertTrue(fresh.isIncluded("Anime"))
  }

  func testTheCountIsEveryRequiredTagPlusEveryBoxThatDiffersFromItsDefault() {
    var draft = WorkshopFilterDraft.cleared
    draft.setRequired("Approved", true)
    XCTAssertEqual(draft.count, 1)
    draft.setIncluded("Mature", true)
    XCTAssertEqual(draft.count, 2, "ticking a box that starts unticked is a filter change")
    draft.setIncluded("Anime", false)
    XCTAssertEqual(draft.count, 3, "unticking a box that starts ticked is one too")
    draft.setIncluded("Anime", true)
    draft.setIncluded("Mature", false)
    draft.setRequired("Approved", false)
    XCTAssertEqual(draft.count, 0, "putting everything back reads zero")

    let rating = try! XCTUnwrap(Catalog.groups.first { $0.id == "rating" })
    draft.setIncluded("Mature", true)
    draft.setIncluded("Questionable", true)
    XCTAssertEqual(draft.count(in: rating), 2, "a group counts its boxes that differ from their default")
    XCTAssertEqual(draft.count(in: try! XCTUnwrap(Catalog.groups.first { $0.id == "genre" })), 0)
    draft.clear()
    XCTAssertEqual(draft, .cleared)
    XCTAssertEqual(draft.tags, [])
    XCTAssertEqual(draft.excludedTags, WorkshopStore.defaultExcludedTags)
  }

  func testAllAndNoneTickAndUntickASectionAndAreDisabledWhereTheyHaveNothingToDo() {
    let genre = try! XCTUnwrap(Catalog.sections.first { $0.id == "genre" })
    var draft = WorkshopFilterDraft.cleared
    XCTAssertFalse(draft.includesAll(in: genre), "Unspecified starts unticked, so All still has a box to tick")
    draft.includeAll(in: genre)
    XCTAssertTrue(draft.includesAll(in: genre), "All is then disabled")
    XCTAssertFalse(draft.includesNone(in: genre))
    XCTAssertEqual(draft.count, 1, "Unspecified is now ticked")
    draft.excludeAll(in: genre)
    XCTAssertTrue(draft.includesNone(in: genre), "None is then disabled")
    XCTAssertEqual(draft.count, genre.entries.count - 1, "all but the one that started unticked differ")
    XCTAssertEqual(Set(draft.excludedTags), Set(WorkshopStore.defaultExcludedTags + genre.tags))
  }

  func testARequiredTagIsKeptOnceAndTagsWithoutABoxAreListedForUnticking() {
    var draft = WorkshopFilterDraft.cleared
    draft.setRequired("Approved", true)
    draft.setRequired("Approved", true)
    XCTAssertEqual(draft.tags, ["Approved"], "required tags are unique")
    XCTAssertEqual(draft.otherRequiredTags, [])
    draft.setRequired("Hand-picked", true)
    XCTAssertEqual(draft.otherRequiredTags, ["Hand-picked"], "a required tag no box offers is listed under Other selected tags")
    draft.setRequired("Hand-picked", false)
    XCTAssertEqual(draft.tags, ["Approved"])
  }

  func testAClickSelectsAChipAndOptionClickHidesIt() {
    typealias Chip = FilterTagChip<EmptyView>
    XCTAssertEqual(Chip.selection(after: .plain, hiding: false), .required, "a click selects")
    XCTAssertEqual(Chip.selection(after: .required, hiding: false), .plain, "a second click lets go")
    XCTAssertEqual(Chip.selection(after: .excluded, hiding: false), .plain)
    XCTAssertEqual(Chip.selection(after: .plain, hiding: true), .excluded, "Option-click hides")
    XCTAssertEqual(Chip.selection(after: .required, hiding: true), .excluded)
    XCTAssertEqual(Chip.selection(after: .excluded, hiding: true), .plain)
  }

  func testASelectedChipRequiresItsTagAndCountsInItsGroupNotInShowOnly() throws {
    let genre = try XCTUnwrap(Catalog.groups.first { $0.id == "genre" })
    let section = try XCTUnwrap(Catalog.sections.first { $0.id == "genre" })
    var draft = WorkshopFilterDraft.cleared
    XCTAssertEqual(draft.chipSelection("Anime"), .plain, "chips start out filtering nothing")
    XCTAssertEqual(draft.chipSelection("Unspecified"), .excluded, "Wallpaper Engine hides it by default")
    XCTAssertTrue(draft.chipsAreAtDefaults(in: section))

    draft.setChip("Anime", .required)
    XCTAssertEqual(draft.tags, ["Anime"], "a selected chip is sent as a required tag")
    XCTAssertEqual(draft.count, 1)
    XCTAssertEqual(draft.count(in: genre), 1)
    XCTAssertEqual(draft.requiredCount, 0, "Show only counts only its own boxes")
    XCTAssertEqual(draft.otherRequiredTags, [], "the chip shows it, so Show only does not list it")

    draft.setChip("Unspecified", .required)
    XCTAssertFalse(draft.excludedTags.contains("Unspecified"), "a tag is never both required and excluded")
    XCTAssertEqual(draft.count, 2, "selecting a chip that starts hidden is one change")
    draft.setChip("Anime", .excluded)
    XCTAssertFalse(draft.tags.contains("Anime"))
    XCTAssertTrue(draft.excludedTags.contains("Anime"))

    draft.resetChips(in: section)
    XCTAssertTrue(draft.chipsAreAtDefaults(in: section))
    XCTAssertEqual(draft, .cleared)
  }

  func testTheDraftTravelsToSteamAsTheTagsTheBoxesNameInEnglish() {
    var draft = WorkshopFilterDraft.cleared
    draft.setIncluded("MMD", false)
    draft.setIncluded("Unspecified", true)
    XCTAssertTrue(draft.excludedTags.contains("MMD"), "the tag, not the label 'MMD (Miku Miku Dance)'")
    XCTAssertFalse(draft.excludedTags.contains("Unspecified"))
  }
}
