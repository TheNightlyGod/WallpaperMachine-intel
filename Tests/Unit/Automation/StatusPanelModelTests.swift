import XCTest
@testable import WallpaperMachine

/// What the menu bar panel shows for the chosen display and what its quick switcher offers.
final class StatusPanelModelTests: XCTestCase {
    typealias Model = StatusPanelModel
    typealias Random = PlaylistPlannerTests.SplitMix

    // MARK: Fixtures

    private func wallpaper(_ id: String, playable: Bool = true) -> Model.Wallpaper {
        .init(id: id, title: "Wallpaper \(id)", kind: .scene,
              previewFile: URL(fileURLWithPath: "/library/\(id)/preview.jpg"), isPlayable: playable)
    }

    private func display(
        _ id: String, title: String? = nil, shows wallpaper: String? = nil, previous: Bool = false,
        next: Bool = false, random: Bool = false, recent: [String] = []
    ) -> StatusMenuModel.Display {
        .init(id: id, title: title ?? "Display \(id)", wallpaperID: wallpaper, canPrevious: previous,
              canNext: next, canRandom: random, recent: recent.map { .init(id: $0, title: "Wallpaper \($0)") })
    }

    private func input(
        displays: [StatusMenuModel.Display], library: [String] = [], unplayable: Set<String> = [],
        favorites: Set<String> = [], active: Bool = true, paused: Bool = false, muted: Bool = false,
        hold: Model.Hold? = nil, switching: Set<String> = [], target: String? = nil
    ) -> Model.Input {
        Model.Input(
            menu: .init(playbackIsCurrent: true, hasActiveWallpapers: active, paused: paused,
                        wallpapersMuted: muted, displays: displays, canLockScreen: true),
            library: library.map { wallpaper($0, playable: !unplayable.contains($0)) },
            favorites: favorites, hold: hold, switching: switching, targetDisplayID: target)
    }

    private func draw(_ input: Model.Input, display: String? = nil, avoiding previous: Set<String> = [],
                      seed: UInt64 = 7) -> [String] {
        var random = Random(state: seed)
        return Model.drawStrip(input, display: display, avoiding: previous, using: &random).ids
    }

    private let ids = (1...20).map { "w\($0)" }

    // MARK: What the panel shows

    func testAnUpdateRemainsVisibleWhenNoDisplayCanPlay() {
        var empty = input(displays: [], active: false)
        empty.update = AppUpdateNotice(kind: .ready, version: "2.0.0", automatic: true)
        let panel = Model.make(empty, display: nil, strip: [])
        XCTAssertEqual(panel.update, empty.update)
        XCTAssertEqual(panel.state, .unavailable)
    }

    func testAnEmptyLibraryHasNothingToShowOrSwitchTo() {
        let empty = input(displays: [display("primary")], active: false)
        let strip = draw(empty)
        let panel = Model.make(empty, display: nil, strip: strip)

        XCTAssertTrue(panel.isLibraryEmpty)
        XCTAssertEqual(strip, [])
        XCTAssertEqual(panel.state, .empty)
        XCTAssertNil(panel.wallpaper)
        XCTAssertFalse(panel.canTogglePlayback, "With nothing applied anywhere there is nothing to play or pause")
        XCTAssertFalse(panel.canShowOthers)
    }

    func testAnEmptyDisplayStillOffersTheLibraryToPickFrom() {
        let nothingApplied = input(displays: [display("primary")], library: ["a", "b", "c"], active: false)
        let strip = draw(nothingApplied)
        let panel = Model.make(nothingApplied, display: nil, strip: strip)

        XCTAssertEqual(Set(strip), ["a", "b", "c"])
        XCTAssertEqual(panel.strip.map(\.id), strip)
        XCTAssertEqual(panel.state, .empty)
        XCTAssertEqual(panel.stripSource, .all)
        XCTAssertFalse(panel.canTogglePlayback)
    }

    func testNoDisplayThatCanShowAWallpaperMakesThePanelUnavailable() {
        let starting = input(displays: [], library: ["a"])
        let panel = Model.make(starting, display: "primary", strip: [])

        XCTAssertEqual(panel.state, .unavailable)
        XCTAssertNil(panel.displayID)
    }

    func testThePanelShowsTheChosenDisplaysWallpaperAndWhetherItIsAFavorite() {
        let playing = input(
            displays: [display("primary", shows: "b", previous: true, next: true, random: true)],
            library: ["a", "b"], favorites: ["b"])
        let panel = Model.make(playing, display: nil, strip: [])

        XCTAssertEqual(panel.wallpaper?.id, "b")
        XCTAssertEqual(panel.state, .playing)
        XCTAssertTrue(panel.isFavorite)
        XCTAssertTrue(panel.canPrevious && panel.canNext && panel.canRandom && panel.canTogglePlayback)
    }

    func testAWallpaperThatLeftTheLibraryLeavesTheCardEmpty() {
        let gone = input(displays: [display("primary", shows: "deleted")], library: ["a"])
        let panel = Model.make(gone, display: nil, strip: [])

        XCTAssertNil(panel.wallpaper)
        XCTAssertFalse(panel.isFavorite)
    }

    // MARK: The state line

    func testARuleThatHoldsWallpapersIsNamedUnlessTheUserPausedThem() {
        let heat = EngagedSystemCondition(condition: .heat, effect: .pause)
        let shows = [display("primary", shows: "a")]

        XCTAssertEqual(Model.make(input(displays: shows, library: ["a"], hold: .condition(heat)),
                                  display: nil, strip: []).state, .held(.condition(heat)))
        XCTAssertEqual(Model.make(input(displays: shows, library: ["a"], hold: .onBattery),
                                  display: nil, strip: []).state, .held(.onBattery))
        XCTAssertEqual(Model.make(input(displays: shows, library: ["a"], paused: true, hold: .rule(stopped: false)),
                                  display: nil, strip: []).state, .paused,
                       "The user's own Pause is what they need to undo, so it is named first")
        XCTAssertEqual(Model.make(input(displays: shows, library: ["a"], paused: true),
                                  display: nil, strip: []).state, .paused)
    }

    func testADisconnectedLibraryDriveIsNamedBeforeAnyRule() {
        let heat = EngagedSystemCondition(condition: .heat, effect: .stop)
        XCTAssertEqual(Model.hold(libraryDriveDisconnected: true, condition: heat, onBatteryPauses: true,
                                  presentation: .unloaded), .libraryDrive,
                       "The drive's stop is what a rule cannot lift, and the policy's stop is the drive's own")
        XCTAssertEqual(Model.hold(libraryDriveDisconnected: false, condition: heat, onBatteryPauses: true,
                                  presentation: .unloaded), .condition(heat))
        XCTAssertEqual(Model.hold(libraryDriveDisconnected: false, condition: nil, onBatteryPauses: true,
                                  presentation: .suspended), .onBattery)
        XCTAssertEqual(Model.hold(libraryDriveDisconnected: false, condition: nil, onBatteryPauses: false,
                                  presentation: .unloaded), .rule(stopped: true))
        XCTAssertEqual(Model.hold(libraryDriveDisconnected: false, condition: nil, onBatteryPauses: false,
                                  presentation: .suspended), .rule(stopped: false))
        XCTAssertNil(Model.hold(libraryDriveDisconnected: false, condition: nil, onBatteryPauses: false,
                                presentation: .running))
        XCTAssertNil(Model.hold(libraryDriveDisconnected: false, condition: nil, onBatteryPauses: false,
                                presentation: nil), "Nothing is said while the Mac sleeps or is locked")
    }

    @MainActor
    func testEachHoldNamesItsOwnCause() {
        let inactive = EngagedSystemCondition(condition: .inactivity, effect: .pause)
        XCTAssertEqual(Model.hold(libraryDriveDisconnected: false, condition: inactive, onBatteryPauses: false,
                                  presentation: .suspended), .condition(inactive))
        let holds: [Model.Hold] = [
            .libraryDrive, .condition(inactive), .condition(.init(condition: .lowPowerMode, effect: .stop)),
            .onBattery, .rule(stopped: false), .rule(stopped: true),
        ]
        XCTAssertEqual(Set(holds.map(\.text)).count, holds.count,
                       "An ejected drive or an inactive Mac does not read as a playback rule")
    }

    func testASwitchOnTheDisplayIsSaidBeforeAnythingElse() {
        let two = [display("primary", shows: "a"), display("2", shows: "b")]
        let switching = input(displays: two, library: ["a", "b"], paused: true, switching: ["2"])

        XCTAssertEqual(Model.make(switching, display: "2", strip: []).state, .switching)
        XCTAssertEqual(Model.make(switching, display: "primary", strip: []).state, .paused,
                       "Another display's switch says nothing about this one")
        XCTAssertEqual(Model.make(input(displays: [display("primary")], library: ["a"], switching: ["primary"]),
                                  display: nil, strip: []).state, .switching,
                       "An empty display that is getting a wallpaper is changing, not empty")
    }

    // MARK: Displays

    func testOneDisplayHasNoPicker() {
        let panel = Model.make(input(displays: [display("primary", shows: "a")], library: ["a"]),
                               display: nil, strip: [])

        XCTAssertFalse(panel.showsDisplayPicker)
        XCTAssertEqual(panel.displayID, "primary")
    }

    func testTwoDisplaysGetAPickerAndThePanelActsOnTheChosenOne() {
        let displays = [
            display("primary", title: "Studio Display (1 - Primary)", shows: "a"),
            display("2", title: "LG UltraFine (2 - Secondary)", shows: "b", next: true),
        ]
        let two = input(displays: displays, library: ["a", "b"], target: "primary")

        let chosen = Model.make(two, display: "2", strip: [])
        XCTAssertTrue(chosen.showsDisplayPicker)
        XCTAssertEqual(chosen.displayID, "2")
        XCTAssertEqual(chosen.wallpaper?.id, "b")
        XCTAssertTrue(chosen.canNext)
        XCTAssertEqual(chosen.displays.map(\.shortTitle), ["Studio Display", "LG UltraFine"])

        XCTAssertEqual(Model.make(two, display: "gone", strip: []).displayID, "primary",
                       "A display that left falls back to the control panel's target display")
        XCTAssertEqual(Model.make(input(displays: displays, library: ["a", "b"], target: "gone"),
                                  display: nil, strip: []).displayID, "primary",
                       "Without a usable target the main display, first in menu order, is the one")
        XCTAssertEqual(Model.make(input(displays: displays, library: ["a", "b"], target: "2"),
                                  display: nil, strip: []).displayID, "2")
    }

    func testDisplaysWithTheSameNameKeepTheirFullTitlesInThePicker() {
        let twins = [
            display("1", title: "Studio Display (1 - Primary)"),
            display("2", title: "Studio Display (2 - Secondary)"),
        ]
        XCTAssertEqual(Model.choices(twins).map(\.shortTitle),
                       ["Studio Display (1 - Primary)", "Studio Display (2 - Secondary)"])
    }

    // MARK: Recently used

    func testRecentlyUsedLeavesOutTheShownWallpaperAndKeepsTheNewestFour() {
        let shown = input(
            displays: [display("primary", shows: "a", recent: ["a", "b", "c", "d", "e", "f"])],
            library: ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(Model.make(shown, display: nil, strip: []).recent.map(\.id), ["b", "c", "d", "e"])
    }

    // MARK: The quick switcher

    func testTheShownWallpaperIsAlwaysFirstInTheBatch() {
        let shown = input(displays: [display("primary", shows: "w5")], library: ids, favorites: ["w1", "w2", "w3"])
        for seed in UInt64(1)...20 {
            XCTAssertEqual(draw(shown, seed: seed).first, "w5", "seed \(seed)")
        }
        XCTAssertEqual(Set(draw(shown)), ["w5", "w1", "w2", "w3"],
                       "Favorites feed the batch, and the shown wallpaper joins them though it is not one")
    }

    func testABatchHoldsAtMostEightDistinctWallpapers() {
        let shown = input(displays: [display("primary", shows: "w1")], library: ids)
        let strip = draw(shown)
        XCTAssertEqual(strip.count, Model.stripSize)
        XCTAssertEqual(Set(strip).count, strip.count)
    }

    func testANewBatchAvoidsThePreviousOneWhileThereAreEnoughOthers() {
        let shown = input(displays: [display("primary", shows: "w1")], library: ids)
        let first = draw(shown, seed: 3)
        let second = draw(shown, avoiding: Set(first), seed: 4)

        XCTAssertEqual(second.first, "w1", "The shown wallpaper stays in every batch")
        XCTAssertTrue(Set(second.dropFirst()).isDisjoint(with: first),
                      "Twenty wallpapers hold enough others for a batch without a repeat")
    }

    func testABatchRepeatsOnlyWhenThePoolHasTooFewOthers() {
        let small = input(displays: [display("primary", shows: "w1")], library: Array(ids.prefix(10)))
        let first = draw(small, seed: 3)
        let second = draw(small, avoiding: Set(first), seed: 9)

        XCTAssertEqual(second.count, Model.stripSize, "A small pool still fills the batch")
        let fresh = Set(ids.prefix(10)).subtracting(first)
        XCTAssertTrue(fresh.isSubset(of: Set(second)), "Every wallpaper the last batch left out comes first")
    }

    func testTheSameSeedDrawsTheSameBatch() {
        let shown = input(displays: [display("primary", shows: "w1")], library: ids)
        XCTAssertEqual(draw(shown, seed: 11), draw(shown, seed: 11))
    }

    func testFavoritesFeedTheSwitcherUntilNoneButTheShownOneCanPlay() {
        let onlyShown = input(displays: [display("primary", shows: "w1")], library: ids, favorites: ["w1"])
        XCTAssertEqual(Model.make(onlyShown, display: nil, strip: []).stripSource, .all)
        XCTAssertEqual(draw(onlyShown).count, Model.stripSize)

        let heldFavorite = input(displays: [display("primary", shows: "w1")], library: ids,
                                 unplayable: ["w2"], favorites: ["w1", "w2"])
        XCTAssertEqual(Model.make(heldFavorite, display: nil, strip: []).stripSource, .all,
                       "A favorite that cannot play does not keep the whole library out")

        let favorites = input(displays: [display("primary", shows: "w1")], library: ids, favorites: ["w2", "w3"])
        XCTAssertEqual(Model.make(favorites, display: nil, strip: []).stripSource, .favorites)
    }

    func testTheCaptionNamesThePoolTheBatchOnShowCameFrom() {
        let before = input(displays: [display("primary", shows: "w1")], library: ids, favorites: ["w2"])
        var random = Random(state: 7)
        let batch = Model.drawStrip(before, display: nil, avoiding: [], using: &random)
        XCTAssertEqual(batch, Model.Batch(ids: ["w1", "w2"], source: .favorites))

        // A click on the one favorite puts it on the display: a new draw would take the whole library.
        let after = input(displays: [display("primary", shows: "w2")], library: ids, favorites: ["w2"])
        let panel = Model.make(after, display: nil, strip: batch.ids, drawnFrom: batch.source)
        XCTAssertEqual(panel.stripSource, .favorites, "The tiles on show are still the favorites' batch")
        XCTAssertTrue(panel.canShowOthers, "Another batch, from the whole library, has others to show")
        XCTAssertEqual(Model.drawStrip(after, display: nil, avoiding: Set(batch.ids), using: &random).source, .all)
    }

    func testAnotherBatchIsOfferedWhenTheNextDrawTakesAnotherPool() {
        // The one favorite is on the display, so the batch comes from the whole library.
        let before = input(displays: [display("primary", shows: "w1")], library: ids, favorites: ["w1"])
        var random = Random(state: 7)
        let batch = Model.drawStrip(before, display: nil, avoiding: [], using: &random)
        XCTAssertEqual(batch.source, .all)
        XCTAssertEqual(batch.ids.first, "w1")
        XCTAssertEqual(batch.ids.count, Model.stripSize)

        // A click on another tile leaves the favorite free: a new draw would take the favorites,
        // every one of them already on show, and still give a different batch.
        let picked = batch.ids[1]
        let after = input(displays: [display("primary", shows: picked)], library: ids, favorites: ["w1"])
        let panel = Model.make(after, display: nil, strip: batch.ids, drawnFrom: batch.source)
        XCTAssertEqual(panel.stripSource, .all, "The tiles on show are still the whole library's batch")
        XCTAssertTrue(panel.canShowOthers, "Another batch, from the favorites, differs from this one")
        let next = Model.drawStrip(after, display: nil, avoiding: Set(batch.ids), using: &random)
        XCTAssertEqual(next, Model.Batch(ids: [picked, "w1"], source: .favorites))

        // Drawn from the pool a draw takes now, the same tiles leave nothing else to show.
        XCTAssertFalse(Model.make(after, display: nil, strip: next.ids, drawnFrom: next.source).canShowOthers)
    }

    func testWallpapersThatCannotPlayAreNeverOffered() {
        let shown = input(displays: [display("primary", shows: "w1")], library: Array(ids.prefix(6)),
                          unplayable: ["w2", "w3"])
        for seed in UInt64(1)...10 {
            XCTAssertTrue(Set(draw(shown, seed: seed)).isDisjoint(with: ["w2", "w3"]), "seed \(seed)")
        }
    }

    func testEachDisplayDrawsAroundItsOwnWallpaper() {
        let two = input(displays: [display("primary", shows: "w1"), display("2", shows: "w9")], library: ids)
        XCTAssertEqual(draw(two, display: "2").first, "w9")
        XCTAssertEqual(draw(two, display: "primary").first, "w1")
    }

    func testAnotherBatchIsOfferedOnlyWhileThePoolHoldsWallpapersNotOnShow() {
        let small = input(displays: [display("primary", shows: "a")], library: ["a", "b", "c"])
        XCTAssertFalse(Model.make(small, display: nil, strip: draw(small)).canShowOthers,
                       "Three wallpapers all fit in one batch")
        let large = input(displays: [display("primary", shows: "w1")], library: ids)
        XCTAssertTrue(Model.make(large, display: nil, strip: draw(large)).canShowOthers)
    }

    func testThePanelDropsBatchWallpapersThatLeftTheLibrary() {
        let shown = input(displays: [display("primary", shows: "a")], library: ["a", "c"])
        XCTAssertEqual(Model.make(shown, display: nil, strip: ["a", "b", "c"]).strip.map(\.id), ["a", "c"])
    }
}
