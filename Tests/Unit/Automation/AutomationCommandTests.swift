import XCTest
@testable import WallpaperMachine

final class AutomationCommandTests: XCTestCase {
    private func command(_ link: String) -> AutomationCommand? {
        URL(string: link).flatMap(AutomationCommand.init(url:))
    }

    func testLinksNameTheCommandAndItsDetails() {
        XCTAssertEqual(command("wallpapermachine://play"), .play)
        XCTAssertEqual(command("wallpapermachine://pause"), .pause)
        XCTAssertEqual(command("WallpaperMachine://TOGGLE"), .togglePlayback, "scheme and command ignore case")
        XCTAssertEqual(command("wallpapermachine://next"), .next(display: nil))
        XCTAssertEqual(command("wallpapermachine://next?display=primary"), .next(display: "primary"))
        XCTAssertEqual(command("wallpapermachine://previous"), .previous(display: nil))
        XCTAssertEqual(command("wallpapermachine://previous?display=identity%3A%7B%7D"), .previous(display: "identity:{}"))
        XCTAssertEqual(command("wallpapermachine://apply?id=3632513108"), .apply(wallpaperID: "3632513108", display: nil))
        XCTAssertEqual(
            command("wallpapermachine://apply?id=image-Sunset%20.png&display=identity%3A%7B%7D"),
            .apply(wallpaperID: "image-Sunset .png", display: "identity:{}"))
        XCTAssertEqual(command("wallpapermachine://apply?id=3632513108&display=all"), .applyEverywhere(wallpaperID: "3632513108"))
        XCTAssertEqual(command("wallpapermachine://apply?display=ALL&id=image-Sunset%20.png"),
                       .applyEverywhere(wallpaperID: "image-Sunset .png"), "the value ignores case like the command does")
        XCTAssertEqual(command("wallpapermachine://open"), .open(page: nil))
        XCTAssertEqual(command("wallpapermachine://open?page=Settings"), .open(page: .settings))
        XCTAssertEqual(command("wallpapermachine://playlist?id=plan%20one&display=secondary"), .applyPlaylist(planID: "plan one", display: "secondary"))
        XCTAssertEqual(command("wallpapermachine://playlist?id=p"), .applyPlaylist(planID: "p", display: nil))
        XCTAssertEqual(command("wallpapermachine://preset?id=preset%20one"), .applyPreset(presetID: "preset one"))
        XCTAssertEqual(command("wallpapermachine://layout?id=desk"), .applyDisplayLayout(layoutID: "desk"))
    }

    func testMuteLinksTakeNothingAndKeepTheirOwnMeaning() {
        XCTAssertEqual(command("wallpapermachine://mute"), .mute)
        XCTAssertEqual(command("wallpapermachine://unmute"), .unmute)
        XCTAssertEqual(command("wallpapermachine://togglemute"), .toggleMute)
        XCTAssertEqual(command("WallpaperMachine://ToggleMute"), .toggleMute, "scheme and command ignore case")
        XCTAssertNotEqual(command("wallpapermachine://togglemute"), command("wallpapermachine://toggle"),
                          "muting is not playing and pausing")
    }

    /// Muting is one global switch: a link that names a display, a volume or anything else must
    /// not be read as the nearest thing it resembles, such as muting one display or setting a level.
    func testMuteLinksRefuseWhatTheyDoNotTake() {
        for link in [
            "wallpapermachine://mute?display=primary", "wallpapermachine://mute?x=1", "wallpapermachine://mute?volume=0",
            "wallpapermachine://unmute?display=primary", "wallpapermachine://unmute?id=1",
            "wallpapermachine://togglemute?display=a", "wallpapermachine://togglemute?now=1",
            "wallpapermachine://togglemute/extra", "wallpapermachine://toggle-mute",
            "wallpapermachine://volume?level=0",
        ] {
            XCTAssertNil(command(link), link)
        }
    }

    func testRandomTakesAnOptionalDisplayAndPool() {
        XCTAssertEqual(command("wallpapermachine://random"), .random(display: nil, pool: .all))
        XCTAssertEqual(command("wallpapermachine://random?display=primary"), .random(display: "primary", pool: .all))
        XCTAssertEqual(command("wallpapermachine://random?from=favorites"), .random(display: nil, pool: .favorites))
        XCTAssertEqual(command("wallpapermachine://random?display=a&from=all"), .random(display: "a", pool: .all))
        XCTAssertEqual(command("wallpapermachine://RANDOM?from=Favorites&display=identity%3A%7B%7D"),
                       .random(display: "identity:{}", pool: .favorites), "the command and the pool ignore case")
        XCTAssertEqual(command("wallpapermachine://random?display=all"), .random(display: "all", pool: .all),
                       "all is not a display here; running it reports an unknown display")
    }

    /// A pick is made at random, so a link that names a wallpaper, an unknown pool or anything
    /// else must not be read as the nearest thing it resembles.
    func testRandomRefusesWhatItDoesNotTake() {
        for link in [
            "wallpapermachine://random?from=weekly", "wallpapermachine://random?from=all&from=favorites",
            "wallpapermachine://random?id=1", "wallpapermachine://random?from=", "wallpapermachine://random?display=a&display=b",
            "wallpapermachine://random?from=favorites&volume=1", "wallpapermachine://random/extra",
            "wallpapermachine://random?from=collection",
        ] {
            XCTAssertNil(command(link), link)
        }
    }

    func testAPoolOffersTheWallpapersThatCanPlayInLibraryOrder() {
        let library = ["d", "a", "c", "b"]
        XCTAssertEqual(AutomationCommand.RandomPool.all.candidates(library: library, favorites: ["a", "x"], held: []), library)
        XCTAssertEqual(AutomationCommand.RandomPool.favorites.candidates(library: library, favorites: ["a", "b", "x"], held: []),
                       ["a", "b"], "a favorite that left the library is not offered")
        XCTAssertEqual(AutomationCommand.RandomPool.favorites.candidates(library: library, favorites: [], held: []), [])
    }

    /// A pick is the user's own choice and so releases a wallpaper the app is holding back after
    /// a crash: chance must not be able to reopen it.
    func testAHeldBackWallpaperIsNeverOffered() {
        let library = ["a", "b", "c"]
        XCTAssertEqual(AutomationCommand.RandomPool.all.candidates(library: library, favorites: [], held: ["b"]), ["a", "c"])
        XCTAssertEqual(AutomationCommand.RandomPool.favorites.candidates(library: library, favorites: ["b", "c"], held: ["b"]), ["c"])
    }

    /// `all` means every display only on an apply link; the other commands still take a display's
    /// own selector and report an unknown one when they run.
    func testAllIsNotADisplayForAnyOtherCommand() {
        XCTAssertEqual(command("wallpapermachine://next?display=all"), .next(display: "all"))
        XCTAssertEqual(command("wallpapermachine://previous?display=all"), .previous(display: "all"))
        XCTAssertEqual(command("wallpapermachine://playlist?id=p&display=all"), .applyPlaylist(planID: "p", display: "all"))
        XCTAssertEqual(command("wallpapermachine://apply?id=1&display=primary"), .apply(wallpaperID: "1", display: "primary"))
    }

    func testAnythingElseIsRefusedRatherThanGuessed() {
        for link in [
            "https://play", "wallpapermachine://", "wallpapermachine://delete?id=1", "wallpapermachine://apply",
            "wallpapermachine://apply?id=", "wallpapermachine://apply?id=1&id=2", "wallpapermachine://play?now=1",
            "wallpapermachine://next?display=a&volume=1", "wallpapermachine://open?page=elsewhere",
            "wallpapermachine://play/extra",
            "wallpapermachine://previous?id=a", "wallpapermachine://previous?display=a&display=b",
            "wallpapermachine://playlist", "wallpapermachine://playlist?id=a&id=b",
            "wallpapermachine://preset?id=", "wallpapermachine://preset?id=p&display=primary",
            "wallpapermachine://layout?id=", "wallpapermachine://layout?id=a&id=b", "wallpapermachine://layout?id=a&display=primary",
            "wallpapermachine://apply?display=all", "wallpapermachine://apply?id=1&display=all&x=1",
            "wallpapermachine://apply?id=1&display=all&display=primary", "wallpapermachine://apply?id=&display=all",
            // Removing a wallpaper from a display is the menu bar's own command: no link blanks a display.
            "wallpapermachine://remove", "wallpapermachine://remove?display=primary", "wallpapermachine://removewallpaper",
            "wallpapermachine://eject?display=primary", "wallpapermachine://clear",
        ] {
            XCTAssertNil(command(link), link)
        }
    }
}
