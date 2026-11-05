import AVFoundation
import CoreVideo
import ImageIO
import XCTest

@testable import WallpaperMachine

/// A video imported from disk gets a still for its library tile, and one imported before that
/// gets it later. The poster maker is replaced, so nothing is decoded here; the real decode is
/// in `VideoPosterMediaTests`.
final class VideoImportPreviewTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("Library") }
    private let still = Data("poster-jpeg".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("video-import-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func importer(failing: Bool = false) -> WallpaperImportService {
        let still = still
        return WallpaperImportService(poster: { video, size in
            XCTAssertEqual(size, StillImageWallpaper.previewPixels)
            XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
            if failing { throw VideoPoster.Failure(reason: "undecodable") }
            return still
        })
    }

    private func manifest(_ id: String) throws -> [String: Any] {
        let data = try Data(contentsOf: library.appendingPathComponent("\(id)/project.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func installed(_ id: String, _ manifest: [String: Any], files: [String] = ["clip.mp4"]) throws {
        let folder = library.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files { try Data("video".utf8).write(to: folder.appendingPathComponent(file)) }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("project.json"))
    }

    func testImportedVideoGetsAPreview() async throws {
        let video = root.appendingPathComponent("Rain.mp4")
        try Data("video-content".utf8).write(to: video)
        let report = try await importer().importItems([video], into: library, duplicates: .skip) { _ in }
        let id = try XCTUnwrap(report.importedIDs.first)
        XCTAssertEqual(try manifest(id)["preview"] as? String, StillImageWallpaper.previewFile)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("\(id)/\(StillImageWallpaper.previewFile)")), still)
    }

    func testVideoTheSystemCannotDecodeStillImportsWithoutAPreview() async throws {
        let video = root.appendingPathComponent("Rain.webm")
        try Data("video-content".utf8).write(to: video)
        let report = try await importer(failing: true).importItems([video], into: library, duplicates: .skip) { _ in }
        let id = try XCTUnwrap(report.importedIDs.first)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertNil(try manifest(id)["preview"])
        XCTAssertEqual(try manifest(id)["file"] as? String, "Rain.webm")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("\(id)/\(StillImageWallpaper.previewFile)").path))
    }

    func testEarlierVideoImportsGainAPreviewAndNothingElseChanges() async throws {
        try installed("local-old.mp4", ["title": "old", "type": "video", "file": "clip.mp4", "general": ["properties": [:]]])
        try installed("local-kept.mp4", ["title": "kept", "type": "video", "file": "clip.mp4", "preview": "mine.png"],
                      files: ["clip.mp4", "mine.png"])
        try installed("local-page.html", ["title": "page", "type": "web", "file": "clip.mp4"])
        try installed("123456", ["title": "workshop", "type": "video", "file": "clip.mp4"])
        try installed("local-missing.mp4", ["title": "missing", "type": "video", "file": "gone.mp4"])
        let untouched = ["local-kept.mp4", "local-page.html", "123456", "local-missing.mp4"]
        let before = try untouched.map { try Data(contentsOf: library.appendingPathComponent("\($0)/project.json")) }

        let added = await importer().addMissingVideoPreviews(in: library)

        XCTAssertEqual(added, ["local-old.mp4"])
        let upgraded = try manifest("local-old.mp4")
        XCTAssertEqual(upgraded["preview"] as? String, StillImageWallpaper.previewFile)
        XCTAssertEqual(upgraded["title"] as? String, "old")
        XCTAssertEqual(upgraded["file"] as? String, "clip.mp4")
        XCTAssertNotNil(upgraded["general"])
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("local-old.mp4/\(StillImageWallpaper.previewFile)")), still)
        XCTAssertEqual(try untouched.map { try Data(contentsOf: library.appendingPathComponent("\($0)/project.json")) }, before)
        for id in untouched {
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("\(id)/\(StillImageWallpaper.previewFile)").path), id)
        }
        // Once each has one, a later launch has nothing to do.
        let again = await importer().addMissingVideoPreviews(in: library)
        XCTAssertEqual(again, [])
    }

    func testAVideoWithoutADecodableFrameIsLeftAsItWas() async throws {
        try installed("local-old.webm", ["title": "old", "type": "video", "file": "clip.mp4"])
        let before = try Data(contentsOf: library.appendingPathComponent("local-old.webm/project.json"))
        let added = await importer(failing: true).addMissingVideoPreviews(in: library)
        XCTAssertEqual(added, [])
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("local-old.webm/project.json")), before)
    }

    func testPosterIsTakenPastTheOpeningButEarly() {
        XCTAssertEqual(VideoPoster.time(duration: .invalid), .zero)
        XCTAssertEqual(VideoPoster.time(duration: .zero), .zero)
        XCTAssertEqual(VideoPoster.time(duration: CMTime(seconds: 10, preferredTimescale: 600)).seconds, 1, accuracy: 0.01)
        XCTAssertEqual(VideoPoster.time(duration: CMTime(seconds: 600, preferredTimescale: 600)).seconds,
                       VideoPoster.latestSeconds, accuracy: 0.01)
    }
}

/// `VideoPoster` against a real clip written by `SyntheticVideoFixture`. Opt-in, like the other
/// media tests, because it decodes on this machine's media hardware:
///
/// ```
/// WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py --only VideoPosterMediaTests
/// ```
final class VideoPosterMediaTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_MEDIA_TESTS"] == "1",
            "media/device integration tests are opt-in; set WALLPAPER_MACHINE_MEDIA_TESTS=1")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("video-poster-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    func testPosterIsABoundedJPEGPastABlackOpening() async throws {
        // Two seconds at 30 fps whose first three frames are black, as a fade-in starts.
        var request = SyntheticVideoFixture.Request.constantRate(name: "fade-in", numerator: 30, denominator: 1, frames: 60)
        request.width = 1280
        request.height = 720
        request.painter = { buffer, step in
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            memset(base, step < 3 ? 0 : 230, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        let clip = try await SyntheticVideoFixture.write(request, into: directory)

        let data = try await VideoPoster.jpeg(of: clip, maxPixelSize: 512)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 288)
        var gray = [UInt8](repeating: 0, count: 16)
        let context = try XCTUnwrap(CGContext(
            data: &gray, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertGreaterThan(gray.map(Int.init).reduce(0, +) / gray.count, 150)
    }

    func testAnHev1ClipHasAPosterFromACopyThatGoesAfterIt() async throws {
        // AVFoundation refuses the embedded clip as it is; the poster is taken from a retagged copy.
        let clip = try Hev1Fixture.write(name: "hev1", into: directory)
        let folder = directory.appendingPathComponent("DerivedVideos", isDirectory: true)
        let data = try await VideoPoster.jpeg(of: clip, maxPixelSize: 32, derived: DerivedVideoCache(folder: { folder }))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [], [],
            "the copy made for the poster alone is gone")
    }
}
