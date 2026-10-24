import XCTest
@testable import WallpaperMachine

/// The posters kept for desktops that follow Spaces but are not on screen. Only a temporary
/// folder is touched.
@MainActor
final class DesktopSpacePosterCacheTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("space-posters-" + UUID().uuidString)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testAPosterOutlivesARelaunchUntilNoDesktopIsSetToItsWallpaper() {
        let cache = DesktopSpacePosterCache(folder: folder)
        cache.store(Data([1]), display: "primary", wallpaperID: "ocean")
        cache.store(Data([2]), display: "primary", wallpaperID: "../forest")
        cache.store(Data([3]), display: "external", wallpaperID: "ocean")

        let relaunched = DesktopSpacePosterCache(folder: folder)
        XCTAssertEqual(relaunched.poster(display: "primary", wallpaperID: "ocean"), Data([1]))
        XCTAssertEqual(relaunched.poster(display: "primary", wallpaperID: "../forest"), Data([2]),
                       "any wallpaper id is a safe name on disk")
        XCTAssertEqual(relaunched.poster(display: "external", wallpaperID: "ocean"), Data([3]), "each display keeps its own")
        XCTAssertNil(relaunched.poster(display: "primary", wallpaperID: "desert"))

        relaunched.retain([.init(display: "primary", wallpaperID: "ocean")])
        XCTAssertEqual(relaunched.poster(display: "primary", wallpaperID: "ocean"), Data([1]))
        XCTAssertNil(relaunched.poster(display: "primary", wallpaperID: "../forest"))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(files.count, 1, "what no desktop is set to leaves the disk too")
    }

    func testANewerPosterReplacesTheOldOneAndAMissIsFoundOnceItIsKept() {
        let cache = DesktopSpacePosterCache(folder: folder)
        XCTAssertNil(cache.poster(display: "primary", wallpaperID: "ocean"))
        cache.store(Data([1]), display: "primary", wallpaperID: "ocean")
        cache.store(Data([4]), display: "primary", wallpaperID: "ocean")

        XCTAssertEqual(cache.poster(display: "primary", wallpaperID: "ocean"), Data([4]))
        XCTAssertEqual(DesktopSpacePosterCache(folder: folder).poster(display: "primary", wallpaperID: "ocean"), Data([4]))
    }
}
