import XCTest

@testable import WallpaperMachine

/// What counts as naming a Workshop item in the search box: a bare id, the item's Steam page or
/// a `steam://` link. Everything else stays a search.
final class WorkshopLinkTests: XCTestCase {
    private let id = "3632513108"

    func testABareIdNamesItsItemOnceItHasSixDigits() {
        XCTAssertEqual(WorkshopLink.itemID(in: id), id)
        XCTAssertEqual(WorkshopLink.itemID(in: "  \(id)\n"), id, "pasted text often carries whitespace")
        XCTAssertEqual(WorkshopLink.itemID(in: "123456"), "123456")
        // A short number is still something to search for, such as a year or a resolution.
        for text in ["2077", "12345", "1", ""] { XCTAssertNil(WorkshopLink.itemID(in: text), text) }
        // Leading zeros are not part of an id, so the id equals the one Steam answers with.
        XCTAssertEqual(WorkshopLink.itemID(in: "00123456"), "123456")
        XCTAssertNil(WorkshopLink.itemID(in: "0000000"), "no item has id zero")
        // Beyond what a 64-bit id can hold, or not ASCII digits, it is not an id.
        for text in ["18446744073709551616", "99999999999999999999999", "１２３４５６７", "١٢٣٤٥٦٧"] {
            XCTAssertNil(WorkshopLink.itemID(in: text), text)
        }
        XCTAssertEqual(WorkshopLink.itemID(in: "18446744073709551615"), "18446744073709551615")
    }

    func testAWorkshopPageLinkNamesItsItemWhateverElseItCarries() {
        let page = "steamcommunity.com/sharedfiles/filedetails"
        for text in [
            "https://\(page)/?id=\(id)",
            "http://\(page)/?id=\(id)",
            "https://www.\(page)/?id=\(id)",
            "https://\(page)?id=\(id)",
            "https://\(page)/?searchtext=forest&id=\(id)&l=english",
            "https://\(page)/?id=\(id)&searchtext=#description",
            "HTTPS://SteamCommunity.com/SharedFiles/FileDetails/?id=\(id)",
            "https://steamcommunity.com/workshop/filedetails/?id=\(id)",
            "https://steamcommunity.com/workshop/filedetails?id=\(id)",
            "\n  https://\(page)/?id=\(id)  \n",
            "steam://url/CommunityFilePage/\(id)",
            "steam://url/CommunityFilePage/\(id)/",
            "STEAM://URL/communityfilepage/\(id)",
        ] {
            XCTAssertEqual(WorkshopLink.itemID(in: text), id, text)
            XCTAssertEqual(WorkshopLink.itemID(inLink: text), id, text)
        }
        // A link may name a short id; only a bare number needs six digits.
        XCTAssertEqual(WorkshopLink.itemID(in: "https://steamcommunity.com/sharedfiles/filedetails/?id=42"), "42")
    }

    func testOnlyALinkIsALinkNotABareId() {
        XCTAssertNil(WorkshopLink.itemID(inLink: id))
        XCTAssertNil(WorkshopLink.itemID(inLink: ""))
    }

    func testLinksToOtherPlacesAreNotWorkshopItems() {
        for text in [
            "https://example.com/sharedfiles/filedetails/?id=\(id)",
            "https://steamcommunity.com.example.org/sharedfiles/filedetails/?id=\(id)",
            "https://notsteamcommunity.com/sharedfiles/filedetails/?id=\(id)",
            "https://steamcommunity.com@example.org/sharedfiles/filedetails/?id=\(id)",
            "https://user:pass@steamcommunity.com/sharedfiles/filedetails/?id=\(id)",
            "https://steamcommunity.com:8443/sharedfiles/filedetails/?id=\(id)",
            "ftp://steamcommunity.com/sharedfiles/filedetails/?id=\(id)",
            "javascript:alert(1)",
            "file:///sharedfiles/filedetails/?id=\(id)",
            "https://steamcommunity.com/app/431960/workshop/",
            "https://steamcommunity.com/sharedfiles/filedetails/",
            "https://steamcommunity.com/sharedfiles/filedetails/extra/?id=\(id)",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=abc",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=0",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)x",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=99999999999999999999999",
            "https://steamcommunity.com/sharedfiles/filedetails/?appid=\(id)",
            "steam://url/CommunityFilePage/",
            "steam://url/CommunityFilePage/abc",
            "steam://url/StoreAppPage/431960",
            "steam://open/main",
            "steam://run/431960",
            "steam://CommunityFilePage/\(id)",
        ] {
            XCTAssertNil(WorkshopLink.itemID(in: text), text)
        }
    }

    func testFreeTextIsASearchEvenWhenItHoldsAnIdOrALink() {
        for text in [
            "forest",
            "forest \(id)",
            "\(id) forest",
            "wallpaper 2024",
            "1920 1080",
            "\(id) \(id)",
            "id=\(id)",
            "see https://steamcommunity.com/sharedfiles/filedetails/?id=\(id) for details",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id) https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)",
            "123,456,789",
            "-\(id)",
        ] {
            XCTAssertNil(WorkshopLink.itemID(in: text), text)
        }
    }

    /// Only the wallpapers list looks an item up; the other sources read the text as words.
    func testOnlyTheWallpapersListTakesALinkAsAnItem() {
        func query(_ text: String, _ source: WorkshopSource) -> WorkshopQuery {
            WorkshopQuery(text: text, kind: .scene, sort: .popular, source: source)
        }
        XCTAssertEqual(query(id, .browse).itemID, id)
        XCTAssertEqual(query("https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)", .browse).itemID, id)
        XCTAssertNil(query("forest", .browse).itemID)
        for source: WorkshopSource in [
            .collections, .collection(id: "77", title: "Night"), .creator(id: "76561198000000001", name: "A"),
            .subscriptions,
        ] {
            XCTAssertNil(query(id, source).itemID, "\(source)")
        }
    }
}
