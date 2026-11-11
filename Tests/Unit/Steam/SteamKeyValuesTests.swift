import XCTest
@testable import WallpaperMachine

final class SteamKeyValuesTests: XCTestCase {
    func testReadsNestedProductInfoInBothManifestShapes() throws {
        let text = """
            "appinfo"
            {
                "appid"  "431960"
                // a comment
                "depots"
                {
                    "431961" { "manifests" { "public" { "gid" "5060075082323178717" "size" "826" } } }
                    "431962" { "Manifests" { "public" "123" } }
                    "branches" { "public" { "buildid" "1" } }
                }
                "extended" { "name" "Wallpaper \\"Engine\\"" }
            }
            \u{0}
            """
        let info = try SteamKeyValues.parse(text)
        XCTAssertEqual(info["appinfo"]?["depots"]?["431961"]?["manifests"]?["public"]?["gid"]?.string, "5060075082323178717")
        XCTAssertEqual(info["APPINFO"]?["depots"]?["431962"]?["manifests"]?["public"]?.string, "123")
        XCTAssertEqual(info["appinfo"]?["extended"]?["name"]?.string, "Wallpaper \"Engine\"")
        XCTAssertNil(info["appinfo"]?["missing"])
    }

    func testRejectsUnbalancedText() {
        XCTAssertThrowsError(try SteamKeyValues.parse(#""a" { "b" "c""#))
        XCTAssertThrowsError(try SteamKeyValues.parse(#""a" "b" }"#))
        XCTAssertThrowsError(try SteamKeyValues.parse(#""a" "unterminated"#))
    }
}
