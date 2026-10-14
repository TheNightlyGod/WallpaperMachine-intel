import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// The Installed grid's still covers: which files the cache may read and when a cover is made again.
final class LibraryPreviewFetcherTests: XCTestCase {
    private var home: URL!
    private var library: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-library-covers-\(UUID().uuidString)", isDirectory: true)
        library = home.appendingPathComponent("Library", isDirectory: true)
        outside = home.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testReadsAnImageInsideTheLibraryEvenWhenAskedForByAStampedAddress() async throws {
        let gif = try Self.image(type: .gif, width: 64, height: 48, frames: 3)
        let file = try write(gif, to: "42/preview.gif")
        let fetcher = LibraryPreviewFetcher(root: library)

        let plain = try await fetcher.fetch(file)
        XCTAssertEqual(plain, gif)
        let stamped = try LibraryPreviewFetcher.identity(of: file, in: library)
        XCTAssertNotEqual(stamped, file)
        let viaStamp = try await fetcher.fetch(stamped)
        XCTAssertEqual(viaStamp, gif, "The stamp rides in the query; the path still names the file")

        let spaced = try write(gif, to: "a folder/preview 1.gif")
        let viaSpacedStamp = try await fetcher.fetch(try LibraryPreviewFetcher.identity(of: spaced, in: library))
        XCTAssertEqual(viaSpacedStamp, gif)
    }

    func testRefusesAnythingThatIsNotAnImageInsideTheLibrary() async throws {
        let png = try Self.image(type: .png, width: 32, height: 32, frames: 1)
        let fetcher = LibraryPreviewFetcher(root: library)

        let elsewhere = outside.appendingPathComponent("preview.png")
        try png.write(to: elsewhere)
        try await assertRefused(fetcher, elsewhere, "a file outside the library")

        // A root-relative path that climbs out is the same file once it is standardised.
        let climbing = library.appendingPathComponent("../Elsewhere/preview.png")
        try await assertRefused(fetcher, climbing, "a path that climbs out of the library")

        // A symlink inside the library whose target lies outside it.
        let folder = library.appendingPathComponent("7", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("preview.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        try await assertRefused(fetcher, link, "a symlink that leaves the library")

        // A folder that is a symlink to outside the library.
        let linkedFolder = library.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: outside)
        try await assertRefused(fetcher, linkedFolder.appendingPathComponent("preview.png"), "a folder symlink that leaves the library")

        let notAnImage = try write(Data("{}".utf8), to: "9/project.json")
        try await assertRefused(fetcher, notAnImage, "a file that is not an image")
        let video = try write(Data(count: 16), to: "9/preview.mp4")
        try await assertRefused(fetcher, video, "a video")

        let directory = library.appendingPathComponent("10/preview.png", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await assertRefused(fetcher, directory, "a directory named like an image")
        try await assertRefused(fetcher, library.appendingPathComponent("gone/preview.png"), "a file that does not exist")
        try await assertRefused(fetcher, try XCTUnwrap(URL(string: "https://example.com/\(elsewhere.lastPathComponent)")), "an address that is not a file")
    }

    func testRefusesAFileOverTheByteLimitAndReadsOneAtTheLimit() async throws {
        let bytes = try Self.image(type: .png, width: 64, height: 64, frames: 1)
        let file = try write(bytes, to: "5/preview.png")
        let exact = LibraryPreviewFetcher(root: library, byteLimit: bytes.count)
        let readBack = try await exact.fetch(file)
        XCTAssertEqual(readBack, bytes)
        try await assertRefused(LibraryPreviewFetcher(root: library, byteLimit: bytes.count - 1), file, "a file over the limit")
    }

    func testAReplacedPreviewGetsANewCoverAndAnUntouchedOneKeepsItsCover() async throws {
        let file = try write(try Self.image(type: .png, width: 640, height: 320, frames: 1), to: "11/preview.png")
        let cache = WorkshopThumbnailCache(
            directory: home.appendingPathComponent("covers", isDirectory: true), fetcher: LibraryPreviewFetcher(root: library),
            keepsAnimation: false, sourceByteLimit: LibraryPreviewFetcher.maximumBytes)

        let first = try await cache.thumbnail(for: try LibraryPreviewFetcher.identity(of: file, in: library))
        let again = try await cache.thumbnail(for: try LibraryPreviewFetcher.identity(of: file, in: library))
        XCTAssertEqual(again, first, "A preview nobody touched is served from its cover")
        XCTAssertEqual(try Self.size(of: first), CGSize(width: 512, height: 256))
        let covers = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("covers").path)
        XCTAssertEqual(covers.filter { $0.hasSuffix(".jpg") }.count, 1)

        // The wallpaper's folder was replaced by an update: same name, different picture.
        try Self.image(type: .png, width: 300, height: 600, frames: 1).write(to: file)
        let replaced = try await cache.thumbnail(for: try LibraryPreviewFetcher.identity(of: file, in: library))
        XCTAssertEqual(try Self.size(of: replaced), CGSize(width: 256, height: 512), "The new picture is not shown as the old cover")
    }

    func testTheStampChangesWithTheFilesSizeOrModificationTimeOnly() throws {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        let file = try write(Data(count: 64), to: "12/preview.png")
        func stamp(_ bytes: Int, at date: Date) throws -> URL {
            try Data(count: bytes).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            return try LibraryPreviewFetcher.identity(of: file, in: library)
        }
        let base = try stamp(64, at: moment)
        XCTAssertEqual(try stamp(64, at: moment), base, "The same size and time is the same preview")
        let longer = try stamp(65, at: moment)
        XCTAssertNotEqual(longer, base, "A different size is a different preview")
        XCTAssertNotEqual(try stamp(65, at: moment.addingTimeInterval(60)), longer, "A different time is a different preview")

        XCTAssertThrowsError(try LibraryPreviewFetcher.identity(of: outside.appendingPathComponent("preview.png"), in: library))
    }

    func testTheCoverStampChangesWithTheFilesSizeOrModificationTimeOnlyAndFollowsSymlinks() throws {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        let file = try write(Data(count: 64), to: "13/preview.png")
        func stamp(_ bytes: Int, at date: Date) throws -> UInt64 {
            try Data(count: bytes).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            return try XCTUnwrap(LibraryPreviewFetcher.coverStamp(of: file))
        }
        let base = try stamp(64, at: moment)
        XCTAssertEqual(try stamp(64, at: moment), base, "The same size and time is the same preview")
        XCTAssertNotEqual(try stamp(65, at: moment), base, "A different size is a different preview")
        XCTAssertNotEqual(try stamp(64, at: moment.addingTimeInterval(60)), base, "A different time is a different preview")
        XCTAssertNotEqual(try stamp(64, at: moment.addingTimeInterval(0.5)), base, "Even by half a second")

        XCTAssertNil(LibraryPreviewFetcher.coverStamp(of: library.appendingPathComponent("gone/preview.png")))
        let link = library.appendingPathComponent("14/preview.png")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(LibraryPreviewFetcher.coverStamp(of: link), LibraryPreviewFetcher.coverStamp(of: file), "A link is stamped by the file it names")
    }

    private func assertRefused(
        _ fetcher: LibraryPreviewFetcher, _ url: URL, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        do {
            _ = try await fetcher.fetch(url)
            XCTFail("\(what) must not be read", file: file, line: line)
        } catch is URLError {
        }
    }

    @discardableResult
    private func write(_ data: Data, to relativePath: String) throws -> URL {
        let file = library.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    private static func size(of encoded: Data) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    private static func image(type: UTType, width: Int, height: Int, frames: Int) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, frames, nil))
        for frame in 0..<frames {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(frame + 1) / CGFloat(frames + 1), green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let properties: [CFString: Any] = type == .gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] : [:]
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
