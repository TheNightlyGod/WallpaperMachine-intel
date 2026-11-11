import XCTest

@testable import WallpaperMachine

final class MirrorAudioOwnershipTests: XCTestCase {
    func testSourceWinsOverEarlierMirrorAndHiddenSourceHandsOverOneOwner() {
        let wallpapers: [UInt32: BridgeWebWallpaper] = [7: descriptor(7, source: 7), 2: descriptor(2, source: 7), 3: descriptor(3, source: 7)]
        XCTAssertEqual(MirrorAudioOwnership.owners(in: wallpapers, canPresent: { _ in true }), [7: 7])
        XCTAssertEqual(MirrorAudioOwnership.owners(in: wallpapers, canPresent: { $0 != 7 }), [7: 2])
        XCTAssertEqual(MirrorAudioOwnership.owners(in: wallpapers, canPresent: { _ in false }), [:])
    }

    func testIndependentInstancesOfTheSameWallpaperRemainSeparate() {
        let wallpapers: [UInt32: BridgeWebWallpaper] = [7: descriptor(7, source: 7), 8: descriptor(8, source: 8)]
        XCTAssertEqual(MirrorAudioOwnership.owners(in: wallpapers, canPresent: { _ in true }), [7: 7, 8: 8])
    }

    func testPausedMutedAndZeroVolumeSurfacesCannotBecomeAudioOwner() {
        var source = descriptor(7, source: 7)
        source.paused = true
        var mirror = descriptor(2, source: 7)
        mirror.muted = true
        var silent = descriptor(3, source: 7)
        silent.volume = 0
        let wallpapers: [UInt32: BridgeWebWallpaper] = [7: source, 2: mirror, 3: silent, 4: descriptor(4, source: 7)]
        XCTAssertEqual(MirrorAudioOwnership.owners(in: wallpapers, canPresent: { _ in true }), [7: 4])
    }

    private func descriptor(_ display: UInt32, source: UInt32) -> BridgeWebWallpaper {
        BridgeWebWallpaper(displayId: display, startupRevision: 0, displayKey: String(display), audioSourceDisplayId: source,
            wallpaperId: "same-project", title: "Test", projectPath: "/fixture", entryFile: "index.html",
            fps: 30, renderScale: 1, paused: false, volume: 1, muted: false, audioResponseEnabled: true,
            mediaIntegrationEnabled: false, propertiesJson: "{}")
    }
}
