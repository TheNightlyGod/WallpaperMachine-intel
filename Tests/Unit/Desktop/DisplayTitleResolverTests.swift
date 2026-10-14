import XCTest

@testable import WallpaperMachine

@MainActor
final class DisplayTitleResolverTests: XCTestCase {
    private let titles = DisplayTitleResolver(names: {
        [
            "1": "Built-in Retina Display", "7": "  ", "9": "LG UltraFine",
            "37D8832A-2D66-02CA-B9F7-8F30A301B230": "Studio Display",
        ]
    }).resolved()

    func testReplacesVendorModelLabelWithLocalizedNameKeepingSuffix() {
        XCTAssertEqual(
            titles.title("Vendor 1552 - Model 41055 (1 - Primary)", displayId: "1"),
            "Built-in Retina Display (1 - Primary)")
        XCTAssertEqual(titles.title("Vendor 7789 - Model 30460 (9)", displayId: "9"), "LG UltraFine (9)")
    }

    func testReplacesTheWholeLabelWhenTheRendererHasNoSuffix() {
        XCTAssertEqual(titles.title("Vendor 1552 - Model 41055", displayId: "1"), "Built-in Retina Display")
        XCTAssertEqual(titles.title("(1)", displayId: "1"), "Built-in Retina Display")
    }

    func testResolvesPrimaryAndIdentitySelectorsThroughTheLiveIdInTheSuffix() {
        XCTAssertEqual(
            titles.title("Vendor 1552 - Model 41055 (1 - Primary)", displayId: "primary"),
            "Built-in Retina Display (1 - Primary)")
        let identity = #"identity:{"uuid":"37d8832a-2d66-02ca-b9f7-8f30a301b230","vendor_id":1552}"#
        XCTAssertEqual(
            titles.title("Vendor 1552 - Model 41055 (9)", displayId: identity), "LG UltraFine (9)")
        XCTAssertEqual(
            titles.title("Vendor 1552 - Model 41055 (4)", displayId: identity), "Studio Display (4)")
        XCTAssertEqual(
            titles.title("Vendor 1552 - Model 41055", displayId: "identity:{not json"),
            "Vendor 1552 - Model 41055")
    }

    func testKeepsRendererTitleWithoutAUsableName() {
        XCTAssertEqual(titles.title("Vendor 4 - Model 5 (3)", displayId: "3"), "Vendor 4 - Model 5 (3)")
        XCTAssertEqual(titles.title("Vendor 4 - Model 5 (7)", displayId: "7"), "Vendor 4 - Model 5 (7)")
        XCTAssertEqual(DisplayTitleResolver.renderer.resolved().title("Display (1)", displayId: "1"), "Display (1)")
    }

    func testSystemResolverKeysNamesByScreenNumberAndUUID() throws {
        let names = DisplayTitleResolver.system.names()
        for screen in NSScreen.screens {
            guard let id = SystemDesktopPictureWorkspace.id(screen), let number = UInt32(id) else { continue }
            XCTAssertEqual(names[id], screen.localizedName)
            let uuid = try XCTUnwrap(CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue())
            XCTAssertEqual(names[(CFUUIDCreateString(nil, uuid) as String).uppercased()], screen.localizedName)
        }
    }

    func testDisplayGeometryHasNoShapeForADisplayThatIsNotAttached() {
        // Neither a selector nor a title naming a live id, nor an id no screen has.
        XCTAssertNil(DisplayGeometry.aspectRatio(displayID: "primary", title: "Vendor 1 - Model 2"))
        XCTAssertNil(DisplayGeometry.aspectRatio(displayID: "identity:{not json", title: ""))
        XCTAssertNil(DisplayGeometry.aspectRatio(displayID: "4000000000", title: "Vendor 1 - Model 2 (4000000000 - Primary)"))
        XCTAssertNil(DisplayGeometry.screen(displayID: "4000000000", title: ""))
    }

    func testDisplayGeometryReadsTheShapeOfEachAttachedScreenByIdOrTitleSuffix() throws {
        for screen in NSScreen.screens {
            guard let id = SystemDesktopPictureWorkspace.id(screen) else { continue }
            let expected = DisplayGeometry.aspectRatio(of: screen.frame.size)
            XCTAssertEqual(DisplayGeometry.aspectRatio(displayID: id, title: ""), expected)
            // `primary` and identity selectors reach the screen through the title's live id.
            XCTAssertEqual(DisplayGeometry.aspectRatio(displayID: "primary", title: "Vendor 1 - Model 2 (\(id) - Primary)"), expected)
            XCTAssertTrue(DisplayGeometry.screen(displayID: id, title: "") === screen)
        }
    }

    func testDisplayGeometryShapesStayInTheRangeAWindowCanShow() {
        XCTAssertEqual(try XCTUnwrap(DisplayGeometry.aspectRatio(of: CGSize(width: 1920, height: 1080))), 16.0 / 9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(DisplayGeometry.aspectRatio(of: CGSize(width: 1080, height: 1920))), 9.0 / 16, accuracy: 0.0001)
        XCTAssertEqual(DisplayGeometry.aspectRatio(of: CGSize(width: 10_000, height: 100)), 4)
        XCTAssertEqual(DisplayGeometry.aspectRatio(of: CGSize(width: 100, height: 10_000)), 0.25)
        for size in [CGSize.zero, CGSize(width: 100, height: 0), CGSize(width: 0, height: 100),
                     CGSize(width: -5, height: 10), CGSize(width: CGFloat.nan, height: 10), CGSize(width: 10, height: CGFloat.infinity)] {
            XCTAssertNil(DisplayGeometry.aspectRatio(of: size), "\(size)")
        }
    }
}

