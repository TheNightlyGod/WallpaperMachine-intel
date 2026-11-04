import XCTest

@testable import WallpaperMachine

/// What a library wallpaper must have before any display changes to it. Scenes are left out:
/// their check reads the shared resources wherever this Mac has them installed.
@MainActor
final class WallpaperPlaybackPreflightTests: XCTestCase {
    private var library: URL!

    override func setUpWithError() throws {
        library = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: library)
    }

    func testAVideoWithoutAPlayableFileAndAPageWithoutItsEntryAreRefused() async throws {
        try write(["type": "Video", "file": "clip.mp4"])
        await assertFailure(.undecodableVideo)
        try Data().write(to: library.appendingPathComponent("item/clip.mp4"))
        await assertFailure(.undecodableVideo, "an empty file is not a video")

        try write(["type": "web", "file": "index.html"])
        await assertFailure(.missingWebEntry)
        try write(["type": "web"])
        await assertFailure(.missingWebEntry, "a page names its entry")
    }

    func testAPlayableVideoAPresentPageAndOtherKindsPass() async throws {
        try write(["type": "video", "file": "clip.mp4"])
        try Data(repeating: 1, count: 64).write(to: library.appendingPathComponent("item/clip.mp4"))
        try await check()

        try write(["type": "web", "file": "index.html"])
        try Data("<html></html>".utf8).write(to: library.appendingPathComponent("item/index.html"))
        try await check()

        try write(["type": "application", "file": "app.exe"])
        try await check()
        try write([:])
        try await check()
    }

    func testAVideoFormatNothingPlaysIsARefusalThatNamesIt() async throws {
        try write(["type": "video", "file": "clip.mp4"])
        try Data(repeating: 1, count: 64).write(to: library.appendingPathComponent("item/clip.mp4"))
        do {
            try await check { _ in .unsupported(.init(container: "MP4", codec: "AV1"), .needsHardwareAV1Decode) }
            XCTFail("an AV1 clip without hardware decode passed")
        } catch let error as WallpaperActionError {
            XCTAssertTrue(error.localizedDescription.contains("AV1"), error.localizedDescription)
        }
    }

    func testAMissingOversizedOrUnreadableManifestFails() async throws {
        await assertThrows("no project.json")
        let folder = library.appendingPathComponent("item", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: folder.appendingPathComponent("project.json"))
        await assertThrows("not JSON")
        try Data(count: WallpaperPlaybackPreflight.manifestByteLimit + 1)
            .write(to: folder.appendingPathComponent("project.json"))
        do {
            try await check()
            XCTFail("an oversized manifest was read")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileReadTooLarge)
        }
    }

    // MARK: - helpers

    private func write(_ manifest: [String: String]) throws {
        let folder = library.appendingPathComponent("item", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("project.json"))
    }

    private func check(
        videoFormat: (URL) async -> VideoFormatSupport.Verdict = { _ in .unreadable("not inspected") }
    ) async throws {
        try await WallpaperPlaybackPreflight.check(wallpaperID: "item", library: library, videoFormat: videoFormat)
    }

    private func assertThrows(_ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await check()
            XCTFail("passed: \(message)", file: file, line: line)
        } catch {}
    }

    private func assertFailure(_ expected: WallpaperPlaybackPreflight.Failure, _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await check()
            XCTFail("passed: \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? WallpaperPlaybackPreflight.Failure, expected, message, file: file, line: line)
        }
    }
}
