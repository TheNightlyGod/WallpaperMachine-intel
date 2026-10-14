import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WallpaperMachine

final class ImageImportTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent("managed/Library") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperMachine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    /// A solid picture of the given size, encoded by ImageIO as `type`.
    private func picture(_ name: String, width: Int, height: Int, type: UTType = .png) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = root.appendingPathComponent(name)
        try (output as Data).write(to: url)
        return url
    }

    private func importOne(_ url: URL, policy: WallpaperImportService.DuplicatePolicy = .skip) async throws
        -> WallpaperImportService.Report
    {
        try await WallpaperImportService().importItems([url], into: library, duplicates: policy, progress: { _ in })
    }

    private func manifest(_ id: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: library.appendingPathComponent("\(id)/project.json"))) as? [String: Any])
    }

    func testPictureBecomesStillWebWallpaperKeepingItsBytes() async throws {
        let source = try picture("Sunset <b>.png", width: 64, height: 32)
        let report = try await importOne(source)
        XCTAssertEqual(report.importedIDs, ["image-Sunset <b>.png"])
        let id = try XCTUnwrap(report.importedIDs.first)
        let folder = library.appendingPathComponent(id)
        let json = try manifest(id)
        XCTAssertEqual(json["type"] as? String, "web")
        XCTAssertEqual(json["file"] as? String, "index.html")
        XCTAssertEqual(json["title"] as? String, "Sunset <b>")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("image.png")), try Data(contentsOf: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("preview.jpg").path))
        // A format the web view shows as it is needs no second copy.
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("display.jpg").path))
        let page = try String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(page.contains(#"src="image.png""#))
        XCTAssertFalse(page.contains("Sunset"), "the file name never reaches the page's markup")
        let fit = try XCTUnwrap(((json["general"] as? [String: Any])?["properties"] as? [String: Any])?["fit"] as? [String: Any])
        XCTAssertEqual(fit["value"] as? String, "fill", "a wide picture fills the screen")
    }

    func testTallPictureOpensWholeOverItsBackdrop() async throws {
        let report = try await importOne(try picture("Portrait.png", width: 30, height: 60))
        let json = try manifest(try XCTUnwrap(report.importedIDs.first))
        let fit = ((json["general"] as? [String: Any])?["properties"] as? [String: Any])?["fit"] as? [String: Any]
        XCTAssertEqual(fit?["value"] as? String, "blur")
    }

    func testFormatOutsideTheWebViewIsShownFromAJPEGCopy() async throws {
        let source = try picture("Scan.tiff", width: 40, height: 40, type: .tiff)
        let report = try await importOne(source)
        let id = try XCTUnwrap(report.importedIDs.first)
        let folder = library.appendingPathComponent(id)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("image.tiff")), try Data(contentsOf: source))
        let display = try Data(contentsOf: folder.appendingPathComponent("display.jpg"))
        XCTAssertEqual(StillImageWallpaper.pixelSize(of: display)?.width, 40)
        let page = try String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(page.contains(#"src="display.jpg""#))
    }

    func testUnreadablePictureIsReportedWithoutALibraryEntry() async throws {
        let broken = root.appendingPathComponent("Broken.jpg")
        try Data("not an image".utf8).write(to: broken)
        let report = try await importOne(broken)
        XCTAssertTrue(report.importedIDs.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("image-Broken.jpg").path))
    }

    func testKeepingBothCopiesOfAPictureKeepsItsPrefix() async throws {
        _ = try await importOne(try picture("Twice.png", width: 20, height: 20))
        // Another picture under the same name is another wallpaper: it is kept beside the first.
        let second = try await importOne(try picture("Twice.png", width: 24, height: 20), policy: .keepBoth)
        let id = try XCTUnwrap(second.importedIDs.first)
        XCTAssertNotEqual(id, "image-Twice.png")
        XCTAssertTrue(id.hasPrefix(WallpaperImportService.imageIDPrefix))
        XCTAssertTrue(second.identical.isEmpty)
    }

    func testKeepingBothNeverCopiesAPictureTheLibraryAlreadyHolds() async throws {
        // A PNG is shown as it is, a TIFF from a JPEG copy; either way the original is what is compared.
        for (name, type) in [("Same.png", UTType.png), ("Scan.tiff", UTType.tiff)] {
            let source = try picture(name, width: 20, height: 20, type: type)
            _ = try await importOne(source)
            let again = try await importOne(source, policy: .keepBoth)
            XCTAssertEqual(again.identical, [name])
            XCTAssertTrue(again.importedIDs.isEmpty)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).sorted(), ["image-Same.png", "image-Scan.tiff"])
    }

    @MainActor
    func testImportStoreRunsOneImportAndRescansTheLibrary() async throws {
        let imports = LibraryImportStore(library: library)
        var rescans = 0
        imports.refreshLibrary = { rescans += 1 }
        try imports.start([try picture("One.png", width: 8, height: 8)], duplicates: .skip)
        XCTAssertTrue(imports.isBusy)
        XCTAssertThrowsError(try imports.start([try picture("Two.png", width: 8, height: 8)], duplicates: .skip))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while imports.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !imports.isBusy else {
            await imports.shutdown()
            XCTFail("The import did not finish before the deadline")
            return
        }
        XCTAssertEqual(imports.report?.importedIDs, ["image-One.png"])
        XCTAssertNil(imports.failure)
        XCTAssertEqual(rescans, 1)
    }
}
