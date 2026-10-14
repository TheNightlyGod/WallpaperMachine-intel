import XCTest
@testable import WallpaperMachine

final class StatusMenuModelTests: XCTestCase {
    typealias Command = StatusMenuModel.Command
    typealias Entry = StatusMenuModel.Entry

    /// An entry without its wording: the command (and whether it is ticked), a submenu with
    /// what it holds, or a separator. Item titles are localized, so tests do not compare them.
    private enum Shape: Equatable {
        case command(Command, checked: Bool)
        case submenu([Shape])
        case separator
    }

    private func shape(_ entries: [Entry]) -> [Shape] {
        entries.map { entry -> Shape in
            switch entry {
            case .command(let command, _, let checked): return .command(command, checked: checked)
            case .submenu(_, let entries): return .submenu(shape(entries))
            case .separator: return .separator
            }
        }
    }

    /// The commands directly in `entries`, leaving submenus out.
    private func commands(in entries: [Entry]) -> [Command] {
        entries.compactMap { entry -> Command? in
            if case .command(let command, _, _) = entry { return command }
            return nil
        }
    }

    /// What each submenu directly in `entries` holds.
    private func submenus(in entries: [Entry]) -> [[Entry]] {
        entries.compactMap { entry -> [Entry]? in
            if case .submenu(_, let inner) = entry { return inner }
            return nil
        }
    }

    private func display(
        _ id: String, title: String? = nil, shows wallpaper: String? = nil, previous: Bool = false, next: Bool = false,
        random: Bool = false, recent: [String] = []
    ) -> StatusMenuModel.Display {
        .init(id: id, title: title ?? "Display \(id)", wallpaperID: wallpaper, canPrevious: previous, canNext: next,
              canRandom: random, recent: recent.map { .init(id: $0, title: "Wallpaper \($0)") })
    }

    private func input(
        displays: [StatusMenuModel.Display], current: Bool = true, active: Bool = true, paused: Bool = false,
        muted: Bool = false, downloads: StatusMenuModel.DownloadActivity? = nil, canLock: Bool = true
    ) -> StatusMenuModel.Input {
        .init(playbackIsCurrent: current, hasActiveWallpapers: active, paused: paused, wallpapersMuted: muted,
              downloads: downloads, displays: displays, canLockScreen: canLock)
    }

    private func titles(_ entries: [Entry]) -> [String] {
        entries.compactMap { entry -> String? in
            switch entry {
            case .command(_, let title, _), .submenu(let title, _): return title
            case .separator: return nil
            }
        }
    }

    // MARK: Layout

    func testOneDisplayKeepsTheFlatMenuForThatDisplay() {
        let entries = StatusMenuModel.entries(for: input(
            displays: [display("primary", shows: "b", previous: true, next: true, recent: ["b", "a"])]))

        XCTAssertEqual(shape(entries), [
            .command(.openControlPanel, checked: false),
            .separator,
            .command(.playPause, checked: false),
            .command(.toggleMute, checked: false),
            .command(.previous(display: "primary"), checked: false),
            .command(.next(display: "primary"), checked: false),
            .submenu([
                .command(.apply(wallpaper: "b", display: "primary"), checked: true),
                .command(.apply(wallpaper: "a", display: "primary"), checked: false),
            ]),
            .command(.lockScreen, checked: false),
        ])
    }

    func testTheFlatMenuOffersOnlyWhatCanAct() {
        let nothing = StatusMenuModel.entries(for: input(displays: [display("primary")], active: false, canLock: false))
        XCTAssertEqual(shape(nothing), [.command(.openControlPanel, checked: false)], "no switch, no history, no Play/Pause")

        let onlyNext = StatusMenuModel.entries(for: input(displays: [display("primary", next: true)], active: false, canLock: false))
        XCTAssertEqual(shape(onlyNext), [
            .command(.openControlPanel, checked: false), .separator, .command(.next(display: "primary"), checked: false),
        ])
    }

    func testNoDisplayLeavesOnlyTheCommandsThatNeedNone() {
        // The app is starting or quitting: nothing can be switched, but the panel and Lock Screen still work.
        let entries = StatusMenuModel.entries(for: input(displays: []))
        XCTAssertEqual(shape(entries), [
            .command(.openControlPanel, checked: false), .separator,
            .command(.playPause, checked: false), .command(.toggleMute, checked: false), .command(.lockScreen, checked: false),
        ])
    }

    func testSeveralDisplaysGetOneSubmenuEachWithTheirOwnCommands() {
        let entries = StatusMenuModel.entries(for: input(displays: [
            display("primary", title: "Main", shows: "a", previous: true, next: true, recent: ["a", "c"]),
            display("7", title: "Side", shows: "b", previous: false, next: true, recent: ["b"]),
        ]))

        XCTAssertEqual(shape(entries), [
            .command(.openControlPanel, checked: false),
            .separator,
            .command(.playPause, checked: false),
            .command(.toggleMute, checked: false),
            .submenu([
                .command(.previous(display: "primary"), checked: false),
                .command(.next(display: "primary"), checked: false),
                .submenu([
                    .command(.apply(wallpaper: "a", display: "primary"), checked: true),
                    .command(.apply(wallpaper: "c", display: "primary"), checked: false),
                ]),
                .separator,
                .command(.remove(display: "primary"), checked: false),
                .separator,
                .command(.openInPanel(display: "primary"), checked: false),
            ]),
            .submenu([
                .command(.next(display: "7"), checked: false),
                .submenu([.command(.apply(wallpaper: "b", display: "7"), checked: true)]),
                .separator,
                .command(.remove(display: "7"), checked: false),
                .separator,
                .command(.openInPanel(display: "7"), checked: false),
            ]),
            .command(.lockScreen, checked: false),
        ])
        XCTAssertEqual(Array(titles(entries).dropFirst(3).prefix(2)), ["Main", "Side"], "each submenu is named for its display")
    }

    func testEveryCommandInASubmenuNamesTheSubmenusDisplay() {
        let entries = StatusMenuModel.entries(for: input(displays: ["1", "2", "3"].map {
            display($0, shows: $0 == "2" ? nil : "a", previous: true, next: true, random: true, recent: ["a", "b"])
        }))

        func displayOf(_ command: Command) -> String? {
            switch command {
            case .previous(let id), .next(let id), .random(let id), .remove(let id), .openInPanel(let id),
                 .apply(_, let id), .startAgain(_, let id): return id
            case .openControlPanel, .openDownloads, .playPause, .toggleMute, .lockScreen: return nil
            }
        }
        func allCommands(_ entries: [Entry]) -> [Command] {
            entries.flatMap { entry -> [Command] in
                switch entry {
                case .command(let command, _, _): return [command]
                case .submenu(_, let entries): return allCommands(entries)
                case .separator: return []
                }
            }
        }
        let inner = submenus(in: entries)
        XCTAssertEqual(inner.count, 3)
        for (submenu, id) in zip(inner, ["1", "2", "3"]) {
            let named = allCommands(submenu).compactMap(displayOf)
            XCTAssertFalse(named.isEmpty)
            XCTAssertEqual(Set(named), [id], "a command in the submenu for \(id) acts on another display")
        }
        XCTAssertEqual(commands(in: entries).compactMap(displayOf), [],
                       "the flat Previous, Next and Recently used are gone")
    }

    // MARK: Random Wallpaper

    func testTheFlatMenuOffersRandomWallpaperAfterNextAndBeforeRecentlyUsed() {
        let entries = StatusMenuModel.entries(for: input(
            displays: [display("primary", shows: "b", previous: true, next: true, random: true, recent: ["b"])]))

        XCTAssertEqual(shape(entries), [
            .command(.openControlPanel, checked: false),
            .separator,
            .command(.playPause, checked: false),
            .command(.toggleMute, checked: false),
            .command(.previous(display: "primary"), checked: false),
            .command(.next(display: "primary"), checked: false),
            .command(.random(display: "primary"), checked: false),
            .submenu([.command(.apply(wallpaper: "b", display: "primary"), checked: true)]),
            .command(.lockScreen, checked: false),
        ])
    }

    func testEverySubmenuOffersRandomWallpaperAfterNext() {
        let entries = StatusMenuModel.entries(for: input(displays: [
            display("primary", shows: "a", previous: true, next: true, random: true, recent: ["a"]),
            display("7", shows: nil, next: true, random: true),
        ]))

        let inner = submenus(in: entries)
        XCTAssertEqual(inner.count, 2)
        XCTAssertEqual(commands(in: inner[0]), [
            .previous(display: "primary"), .next(display: "primary"), .random(display: "primary"),
            .remove(display: "primary"), .openInPanel(display: "primary"),
        ])
        XCTAssertEqual(commands(in: inner[1]), [.next(display: "7"), .random(display: "7"), .openInPanel(display: "7")],
                       "an empty display can be given a random wallpaper")
    }

    func testRandomWallpaperIsLeftOutWhereThereIsNothingElseToChooseFrom() {
        let flat = StatusMenuModel.entries(for: input(displays: [display("primary", shows: "a", next: true, random: false)]))
        XCTAssertFalse(shape(flat).contains(.command(.random(display: "primary"), checked: false)))

        let several = StatusMenuModel.entries(for: input(displays: [
            display("primary", shows: "a", random: false), display("7", shows: "b", random: true),
        ]))
        let inner = submenus(in: several)
        XCTAssertFalse(commands(in: inner[0]).contains(.random(display: "primary")), "this display shows the only wallpaper")
        XCTAssertTrue(commands(in: inner[1]).contains(.random(display: "7")), "the other display can still be changed")
    }

    // MARK: Mute Wallpapers

    func testMuteWallpapersSitsAfterPlayPauseInTheFlatMenu() {
        let entries = StatusMenuModel.entries(for: input(
            displays: [display("primary", shows: "b", previous: true, next: true)]))
        XCTAssertEqual(shape(entries), [
            .command(.openControlPanel, checked: false),
            .separator,
            .command(.playPause, checked: false),
            .command(.toggleMute, checked: false),
            .command(.previous(display: "primary"), checked: false),
            .command(.next(display: "primary"), checked: false),
            .command(.lockScreen, checked: false),
        ])
    }

    func testMuteWallpapersSitsAfterPlayPauseWithSeveralDisplaysToo() {
        let entries = StatusMenuModel.entries(for: input(
            displays: [display("primary", shows: "a", next: true), display("7", shows: "b", next: true)], muted: true))
        let kinds = shape(entries)
        XCTAssertEqual(Array(kinds.prefix(4)), [
            .command(.openControlPanel, checked: false), .separator,
            .command(.playPause, checked: false), .command(.toggleMute, checked: true),
        ])
        guard case .submenu = kinds[4] else { return XCTFail("the display submenus follow the mute item") }
        XCTAssertEqual(commands(in: entries).filter { $0 == .toggleMute }.count, 1,
                       "it is one global item, not one in every display's submenu")
        XCTAssertTrue(submenus(in: entries).allSatisfy { !commands(in: $0).contains(.toggleMute) })
    }

    func testMuteWallpapersIsTickedWhileMuted() {
        func checked(muted: Bool) -> Bool? {
            for case .command(.toggleMute, _, let checked) in StatusMenuModel.entries(for: input(displays: [display("primary")], muted: muted)) {
                return checked
            }
            return nil
        }
        XCTAssertEqual(checked(muted: false), false)
        XCTAssertEqual(checked(muted: true), true)
    }

    /// A mute outlives what was playing when it was chosen, so the way to lift it must too.
    func testMuteWallpapersStaysWhileMutedEvenWithNothingPlaying() {
        func offered(active: Bool, current: Bool = true, muted: Bool) -> Bool {
            shape(StatusMenuModel.entries(for: input(displays: [display("primary")], current: current, active: active, muted: muted)))
                .contains { if case .command(.toggleMute, _) = $0 { return true } else { return false } }
        }
        XCTAssertTrue(offered(active: false, muted: true))
        XCTAssertTrue(offered(active: false, current: false, muted: true), "a stale playback snapshot cannot hide it")
        XCTAssertFalse(offered(active: false, muted: false), "nothing to silence")
        XCTAssertFalse(offered(active: true, current: false, muted: false), "playback state from before a failure may be wrong")
        XCTAssertTrue(offered(active: true, muted: false))
    }

    func testPlayPauseAppearsOnlyWithAFreshSnapshotAndActiveWallpapers() {
        func hasPlayPause(current: Bool, active: Bool, paused: Bool = false) -> Bool {
            shape(StatusMenuModel.entries(for: input(displays: [display("primary")], current: current, active: active, paused: paused)))
                .contains(.command(.playPause, checked: false))
        }
        XCTAssertTrue(hasPlayPause(current: true, active: true))
        XCTAssertTrue(hasPlayPause(current: true, active: true, paused: true))
        XCTAssertFalse(hasPlayPause(current: false, active: true), "a snapshot from before a failure may be wrong")
        XCTAssertFalse(hasPlayPause(current: true, active: false), "nothing is playing")

        func playPauseTitle(paused: Bool) -> String? {
            StatusMenuModel.entries(for: input(displays: [], paused: paused)).compactMap { entry -> String? in
                if case .command(.playPause, let title, _) = entry { return title }
                return nil
            }.first
        }
        XCTAssertNotNil(playPauseTitle(paused: true))
        XCTAssertNotEqual(playPauseTitle(paused: true), playPauseTitle(paused: false), "it says what it will do")
    }

    // MARK: Downloads

    private typealias Activity = StatusMenuModel.DownloadActivity

    func testDownloadActivityAveragesByBytesAndOmitsAPercentItCannotMeasure() {
        XCTAssertNil(Activity.make([]), "no downloads, no line")

        // Weighted by size: 1 of 4 and 3 of 4 is half of the bytes, whatever each job's own fraction.
        XCTAssertEqual(Activity.make([(1, 4), (3, 4)]), Activity(count: 2, percent: 50))
        XCTAssertEqual(Activity.make([(10, 100), (900, 900)]), Activity(count: 2, percent: 91),
                       "a big job outweighs a small one")
        XCTAssertEqual(Activity.make([(1, 3)]), Activity(count: 1, percent: 33), "rounded to the nearest percent")
        XCTAssertEqual(Activity.make([(2, 3)]), Activity(count: 1, percent: 67))
        XCTAssertEqual(Activity.make([(0, 500)]), Activity(count: 1, percent: 0))

        // One job that cannot say how far it is leaves the figure out, but it still counts.
        XCTAssertEqual(Activity.make([(1, 4), (nil, nil)]), Activity(count: 2, percent: nil), "queued or signing in")
        XCTAssertEqual(Activity.make([(1, 4), (5, nil)]), Activity(count: 2, percent: nil), "no size listed")
        XCTAssertEqual(Activity.make([(nil, 4)]), Activity(count: 1, percent: nil))
        XCTAssertEqual(Activity.make([(1, 4), (0, 0)]), Activity(count: 2, percent: nil), "a size of zero says nothing")
        XCTAssertEqual(Activity.make([(nil, nil)]), Activity(count: 1, percent: nil))
    }

    func testDownloadActivityNeverReadsAsCompleteWhileAJobIsStillInProgress() {
        // Steam's own success line claims the last percent, and a finished job is no longer in progress.
        XCTAssertEqual(Activity.make([(1000, 1000)]), Activity(count: 1, percent: 99))
        XCTAssertEqual(Activity.make([(2000, 1000)]), Activity(count: 1, percent: 99), "more bytes than listed")
        XCTAssertEqual(Activity.make([(499, 500)]), Activity(count: 1, percent: 99))
        XCTAssertEqual(Activity.make([(-5, 100)]), Activity(count: 1, percent: 0), "a counter that went backwards")
    }

    func testTheDownloadsLineSitsRightUnderControlPanelAndIsAbsentWhenIdle() {
        let busy = StatusMenuModel.entries(for: input(
            displays: [display("primary", next: true)], downloads: Activity(count: 2, percent: 40)))
        XCTAssertEqual(shape(busy), [
            .command(.openControlPanel, checked: false),
            .command(.openDownloads, checked: false),
            .separator,
            .command(.playPause, checked: false),
            .command(.toggleMute, checked: false),
            .command(.next(display: "primary"), checked: false),
            .command(.lockScreen, checked: false),
        ])

        let idle = StatusMenuModel.entries(for: input(displays: [display("primary", next: true)]))
        XCTAssertFalse(shape(idle).contains(.command(.openDownloads, checked: false)))
        XCTAssertEqual(shape(idle).first, .command(.openControlPanel, checked: false))

        // With nothing else to offer the line still shows, without a trailing separator.
        let alone = StatusMenuModel.entries(for: input(
            displays: [], active: false, downloads: Activity(count: 1, percent: nil), canLock: false))
        XCTAssertEqual(shape(alone), [.command(.openControlPanel, checked: false), .command(.openDownloads, checked: false)])

        // Several displays: the line is the same, above the display submenus.
        let several = StatusMenuModel.entries(for: input(
            displays: [display("primary"), display("7")], downloads: Activity(count: 1, percent: nil)))
        XCTAssertEqual(Array(shape(several).prefix(2)),
                       [.command(.openControlPanel, checked: false), .command(.openDownloads, checked: false)])
    }

    func testTheDownloadsLineSaysHowManyAndHowFar() {
        func title(_ activity: Activity) -> String? {
            StatusMenuModel.entries(for: input(displays: [], downloads: activity)).compactMap { entry -> String? in
                if case .command(.openDownloads, let title, _) = entry { return title }
                return nil
            }.first
        }
        let measured = title(Activity(count: 3, percent: 42))
        XCTAssertTrue(measured?.contains("3") == true && measured?.contains("42%") == true, "\(measured ?? "nil")")
        let unmeasured = title(Activity(count: 3, percent: nil))
        XCTAssertTrue(unmeasured?.contains("3") == true && unmeasured?.contains("%") == false, "\(unmeasured ?? "nil")")
        XCTAssertNotEqual(measured, unmeasured)
    }

    func testRecentlyUsedMarksTheCurrentWallpaperAndCapsAtTen() {
        let ids = (1...14).map { "w\($0)" }
        let entries = StatusMenuModel.entries(for: input(displays: [display("primary", shows: "w3", recent: ids)]))

        guard let recent = submenus(in: entries).first else { return XCTFail("no Recently used submenu") }
        XCTAssertEqual(shape(recent).count, StatusMenuModel.recentLimit)
        XCTAssertEqual(StatusMenuModel.recentLimit, 10)
        XCTAssertEqual(shape(recent), ids.prefix(10).map {
            .command(.apply(wallpaper: $0, display: "primary"), checked: $0 == "w3")
        }, "newest first, and only the wallpaper on the display is ticked")
        XCTAssertEqual(titles(recent).first, "Wallpaper w1", "a wallpaper is listed by its title")
    }

    func testAnEmptyDisplayAmongSeveralTicksNothing() {
        let entries = StatusMenuModel.entries(for: input(displays: [
            display("primary", shows: nil, recent: ["a", "b"]), display("7", shows: "b", recent: ["b"]),
        ]))
        let first = submenus(in: entries).first ?? []
        XCTAssertFalse(shape(first).contains(.command(.apply(wallpaper: "a", display: "primary"), checked: true)))
        XCTAssertFalse(shape(first).contains(.command(.apply(wallpaper: "b", display: "primary"), checked: true)))
    }

    // MARK: Remove and Start Again

    func testRemoveBecomesStartAgainOnAnEmptyDisplayWhenHistoryExists() {
        func submenuCommands(_ display: StatusMenuModel.Display) -> [Command] {
            let entries = StatusMenuModel.entries(for: input(displays: [display, self.display("other", shows: "z")]))
            return commands(in: submenus(in: entries).first ?? [])
        }
        // It shows a wallpaper: Remove, and no Start Again.
        XCTAssertEqual(submenuCommands(display("primary", shows: "a", recent: ["a", "b"])),
                       [.remove(display: "primary"), .openInPanel(display: "primary")])
        // It was emptied: the wallpaper it showed is the newest in its history.
        XCTAssertEqual(submenuCommands(display("primary", shows: nil, recent: ["a", "b"])),
                       [.startAgain(wallpaper: "a", display: "primary"), .openInPanel(display: "primary")])
        // Nothing to remove and nothing to bring back.
        XCTAssertEqual(submenuCommands(display("primary", shows: nil, recent: [])),
                       [.openInPanel(display: "primary")])
    }

    func testASubmenuNeverStartsOrEndsWithASeparatorOrRepeatsOne() {
        let cases: [StatusMenuModel.Display] = [
            display("1"), display("1", shows: "a"), display("1", recent: ["a"]),
            display("1", shows: "a", previous: true, next: true, recent: ["a"]),
        ]
        for value in cases {
            let entries = StatusMenuModel.entries(for: input(displays: [value, display("2")]))
            for case .submenu(_, let inner) in entries {
                let kinds = shape(inner)
                XCTAssertNotEqual(kinds.first, .separator)
                XCTAssertNotEqual(kinds.last, .separator)
                XCTAssertFalse(zip(kinds, kinds.dropFirst()).contains { $0 == .separator && $1 == .separator })
            }
        }
    }

    // MARK: Which displays, in which order

    private func row(
        _ id: String, title: String, enabled: Bool = true, mode: BridgeDisplayMode = .standalone
    ) -> BridgeDisplaySettingsRow {
        .init(displayId: id, title: title, enabled: enabled, mode: mode, mirrorTargets: [], selectedMirrorTarget: nil,
              scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60, muted: false, volume: 0)
    }

    func testADisabledMirroredOrDisconnectedDisplayNeverAppears() {
        let rows = [
            row("primary", title: "Main (1 - Primary)"),
            row("2", title: "Side (2)"),
            row("3", title: "Off (3)", enabled: false),
            row("4", title: "Mirror (4)", mode: .mirror),
            row("5", title: "Unplugged (5)"),
            row("identity:{}", title: "No live id"),
        ]
        let eligible = StatusMenuModel.eligibleDisplays(rows, connected: [1, 2, 3, 4, 6])
        XCTAssertEqual(eligible.map(\.displayId), ["primary", "2"])
        XCTAssertEqual(StatusMenuModel.eligibleDisplays(rows, connected: []).map(\.displayId), [])
    }

    private func candidate(_ id: String, _ title: String, physical: UInt32? = nil, minX: Double = 0) -> StatusMenuModel.Candidate {
        .init(id: id, title: title, physicalID: physical, minX: minX)
    }

    func testDisplaysAreOrderedMainThenLeftToRightWithDistinctTitles() {
        let ordered = StatusMenuModel.orderedDisplays([
            candidate("30", "Right", physical: 30, minX: 3840),
            candidate("10", "Left", physical: 10, minX: -2560),
            candidate("20", "Main", physical: 20, minX: 0),
        ], mainDisplay: 20)
        XCTAssertEqual(ordered.map(\.id), ["20", "10", "30"], "the main display, then left to right")

        // The renderer's own `primary` selector is the main display whichever screen is listed first.
        let byRole = StatusMenuModel.orderedDisplays([
            candidate("10", "Left", physical: 10, minX: -1920), candidate("primary", "Main", physical: 20, minX: 0),
        ], mainDisplay: nil)
        XCTAssertEqual(byRole.map(\.id), ["primary", "10"])

        // Same position: the id decides, so the order does not change between rebuilds.
        let tied = StatusMenuModel.orderedDisplays([candidate("b", "X", minX: 5), candidate("a", "Y", minX: 5)], mainDisplay: nil)
        XCTAssertEqual(tied.map(\.id), ["a", "b"])
    }

    func testTwoScreensWithTheSameNameStayDistinguishable() {
        let ordered = StatusMenuModel.orderedDisplays([
            candidate("4", "LG UltraFine", physical: 4, minX: 1920),
            candidate("3", "LG UltraFine", physical: 3, minX: 0),
            candidate("5", "LG UltraFine", physical: 5, minX: 3840),
            candidate("2", "LG UltraFine (2)", physical: 2, minX: 5760),
        ], mainDisplay: 3)
        XCTAssertEqual(ordered.map(\.id), ["3", "4", "5", "2"])
        XCTAssertEqual(ordered.map(\.title), ["LG UltraFine", "LG UltraFine (2)", "LG UltraFine (3)", "LG UltraFine (2) (2)"])
        XCTAssertEqual(Set(ordered.map(\.title)).count, ordered.count)
    }
}
