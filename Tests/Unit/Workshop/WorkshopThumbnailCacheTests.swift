import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

final class WorkshopThumbnailCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-thumbnails-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEncodeThumbnailKeepsOneScaledFrameOfAnAnimatedPreview() throws {
        let gif = try Self.image(type: .gif, width: 1024, height: 640, frames: 3)
        let jpeg = try WorkshopThumbnailCache.encodeThumbnail(gif, maxPixelSize: 512)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 320)
        XCTAssertThrowsError(try WorkshopThumbnailCache.encodeThumbnail(Data("not an image".utf8)))
    }

    func testEncodeThumbnailSkipsTheBlackFadeInOfAnAnimatedPreview() throws {
        // Six black frames, then a fade to a bright scene: the still must not be black.
        let fadeIn = try Self.image(type: .gif, width: 256, height: 160, frames: 24) { frame in
            frame < 6 ? 0 : min(1, Double(frame - 6) / 6)
        }
        let stillOfFadeIn = try WorkshopThumbnailCache.encodeThumbnail(fadeIn, maxPixelSize: 128)
        XCTAssertGreaterThan(try Self.meanLuminance(of: stillOfFadeIn), 0.35)

        // A preview that is dark throughout keeps its first frame rather than hunting for light.
        let darkSource = try XCTUnwrap(CGImageSourceCreateWithData(
            try Self.image(type: .gif, width: 64, height: 64, frames: 12) { _ in 0.02 } as CFData, nil))
        XCTAssertEqual(WorkshopThumbnailCache.representativeFrameIndex(of: darkSource), 0)

        // A preview that starts bright keeps its first frame too.
        let brightSource = try XCTUnwrap(CGImageSourceCreateWithData(
            try Self.image(type: .gif, width: 64, height: 64, frames: 12) { frame in 0.9 - Double(frame) * 0.02 } as CFData, nil))
        XCTAssertEqual(WorkshopThumbnailCache.representativeFrameIndex(of: brightSource), 0)

        let stillSource = try XCTUnwrap(CGImageSourceCreateWithData(
            try Self.image(type: .png, width: 64, height: 64, frames: 1) { _ in 0 } as CFData, nil))
        XCTAssertEqual(WorkshopThumbnailCache.representativeFrameIndex(of: stillSource), 0)
    }

    func testThumbnailIsFetchedOnceThenServedFromDiskAcrossInstances() async throws {
        let png = try Self.image(type: .png, width: 900, height: 900, frames: 1)
        let fetcher = RecordingFetcher { _ in png }
        let preview = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/2/DEF/"))
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher)

        async let first = cache.thumbnail(for: preview)
        async let second = cache.thumbnail(for: preview)
        async let third = cache.thumbnail(for: preview)
        let results = try await [first, second, third]
        XCTAssertEqual(Set(results.map(\.count)).count, 1)
        XCTAssertEqual(fetcher.requests.count, 1)
        XCTAssertEqual(fetcher.requests.first, preview, "Steam's edge serves the original fastest; no scaled variant is asked for")

        let relaunched = WorkshopThumbnailCache(directory: root, fetcher: fetcher)
        let again = try await relaunched.thumbnail(for: preview)
        XCTAssertEqual(again, results[0])
        XCTAssertEqual(fetcher.requests.count, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(files.count, 1)
    }

    func testFailedFetchLeavesNothingCachedAndRetriesLater() async throws {
        let png = try Self.image(type: .png, width: 300, height: 200, frames: 1)
        let fetcher = RecordingFetcher { _ in png }
        fetcher.failNext = URLError(.notConnectedToInternet)
        let preview = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/4/JKL/"))
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher)
        do {
            _ = try await cache.thumbnail(for: preview)
            XCTFail("expected the transport failure to surface")
        } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".jpg") }.isEmpty)
        let data = try await cache.thumbnail(for: preview)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(fetcher.requests.count, 2)
    }

    func testFetchesRunAtMostTheConfiguredNumberAtOnce() async throws {
        let png = try Self.image(type: .png, width: 200, height: 200, frames: 1)
        let fetcher = RecordingFetcher(delay: .milliseconds(40)) { _ in png }
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher, maxConcurrentFetches: 2)
        try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0..<6 {
                let url = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/\(index)/X/"))
                group.addTask { try await cache.thumbnail(for: url) }
            }
            for try await _ in group {}
        }
        XCTAssertEqual(fetcher.requests.count, 6)
        XCTAssertLessThanOrEqual(fetcher.peakConcurrency, 2)
    }

    func testOneDownloadYieldsTheStillAndTheAnimationAndStillsAreRefused() async throws {
        let gif = try Self.image(type: .gif, width: 200, height: 120, frames: 4)
        let png = try Self.image(type: .png, width: 200, height: 120, frames: 1)
        let fetcher = RecordingFetcher { url in url.path.contains("gif") ? gif : png }
        let animated = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/5/gif/"))
        let still = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/6/png/"))
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher)

        _ = try await cache.thumbnail(for: animated)
        _ = try await cache.thumbnail(for: still)
        XCTAssertEqual(fetcher.requests.count, 2)

        let played = try await cache.animatedPreview(for: animated)
        XCTAssertEqual(played, gif, "The animation plays as Steam encoded it")
        XCTAssertEqual(WorkshopThumbnailCache.mimeType(of: played), "image/gif")
        let relaunched = WorkshopThumbnailCache(directory: root, fetcher: fetcher)
        let afterRelaunch = try await relaunched.animatedPreview(for: animated)
        XCTAssertEqual(afterRelaunch, gif)
        XCTAssertEqual(fetcher.requests.count, 2, "The still's download already paid for the animation")

        do {
            _ = try await cache.animatedPreview(for: still)
            XCTFail("a single-frame preview must not be relayed")
        } catch let failure as WorkshopThumbnailFailure {
            XCTAssertEqual(failure.code, .notAnimated)
        }
        XCTAssertEqual(fetcher.requests.count, 2, "Refusing a still costs no request")
    }

    func testAnimationAskedForDuringTheStillPassSharesItsDownload() async throws {
        let gif = try Self.image(type: .gif, width: 200, height: 120, frames: 4)
        let fetcher = RecordingFetcher(delay: .milliseconds(60)) { _ in gif }
        let preview = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/7/gif/"))
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher)
        async let still = cache.thumbnail(for: preview)
        try await Task.sleep(for: .milliseconds(15))
        let animation = try await cache.animatedPreview(for: preview)
        _ = try await still
        XCTAssertEqual(animation, gif)
        XCTAssertEqual(fetcher.requests.count, 1)
    }

    func testPrunedAnimationIsFetchedAgainOnceAndKept() async throws {
        let gif = try Self.image(type: .gif, width: 200, height: 120, frames: 4)
        let fetcher = RecordingFetcher { _ in gif }
        let preview = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/8/gif/"))
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher)
        _ = try await cache.thumbnail(for: preview)
        let file = await cache.fileURL(for: preview)
        try FileManager.default.removeItem(at: WorkshopThumbnailCache.animationFile(for: file))

        async let first = cache.animatedPreview(for: preview)
        async let second = cache.animatedPreview(for: preview)
        let results = try await [first, second]
        XCTAssertEqual(results, [gif, gif])
        _ = try await cache.animatedPreview(for: preview)
        XCTAssertEqual(fetcher.requests.count, 2, "One refetch serves every waiter and later plays")
    }

    func testWarmingCachesPreviewsBeforeAnyoneAsks() async throws {
        let png = try Self.image(type: .png, width: 300, height: 200, frames: 1)
        let fetcher = RecordingFetcher { _ in png }
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher)
        let previews = try (0..<3).map { try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/\($0)/warm/")) }
        cache.warm(previews)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try FileManager.default.contentsOfDirectory(atPath: root.path).filter({ $0.hasSuffix(".jpg") }).count < 3 {
            guard ContinuousClock.now < deadline else { return XCTFail("warming never finished") }
            try await Task.sleep(for: .milliseconds(5))
        }
        for preview in previews { _ = try await cache.thumbnail(for: preview) }
        XCTAssertEqual(fetcher.requests.count, 3, "Tiles asked for after warming cost no request")
    }

    func testAnimatedPreviewsQueueOnTheirOwnLaneBesideStills() async throws {
        let gif = try Self.image(type: .gif, width: 64, height: 64, frames: 2)
        let fetcher = RecordingFetcher(delay: .milliseconds(40)) { _ in gif }
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher, maxConcurrentFetches: 1, maxConcurrentAnimatedFetches: 2)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<4 {
                let url = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/\(index)/anim/"))
                group.addTask { try await cache.animatedPreview(for: url).count }
            }
            for try await _ in group {}
        }
        XCTAssertEqual(fetcher.requests.count, 4)
        XCTAssertEqual(fetcher.peakConcurrency, 2, "Two animations stream at once even though stills are limited to one")
    }

    func testPruneRemovesTheOldestEntriesUntilTheCacheFits() async throws {
        let cache = WorkshopThumbnailCache(directory: root, fetcher: RecordingFetcher { _ in Data() }, byteLimit: 2_500)
        let files = FileManager.default
        for (index, age) in [400.0, 300, 200, 100].enumerated() {
            let file = root.appendingPathComponent("entry-\(index).jpg")
            try Data(repeating: 0, count: 1_000).write(to: file)
            try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
        }
        await cache.prune()
        let remaining = try files.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(remaining, ["entry-2.jpg", "entry-3.jpg"])
    }

    func testAnimationBudgetKeepsStillFallbackForOrdinaryImagesAboveTheChosenBudget() throws {
        let gif = try Self.image(type: .gif, width: 32, height: 24, frames: 3)
        XCTAssertTrue(WorkshopThumbnailCache.animationFitsBudget(gif))
        XCTAssertFalse(WorkshopThumbnailCache.animationFitsBudget(gif, maximumFrames: 2))
        XCTAssertFalse(WorkshopThumbnailCache.animationFitsBudget(gif, maximumFramePixels: 512))
        XCTAssertFalse(WorkshopThumbnailCache.animationFitsBudget(gif, maximumTotalPixels: 2_000))
        XCTAssertFalse(try WorkshopThumbnailCache.encodeThumbnail(gif).isEmpty)
    }

    func testLongAnimationKeepsItsStillWithoutRelayingTheOriginalFrames() async throws {
        let gif = try Self.image(type: .gif, width: 16, height: 16, frames: 301)
        let fetcher = RecordingFetcher { _ in gif }
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher)
        let url = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/9/long-preview/"))
        let still = try await cache.thumbnail(for: url)
        XCTAssertEqual(WorkshopThumbnailCache.frameCount(of: still), 1)
        do { _ = try await cache.animatedPreview(for: url); XCTFail("long animation should use its still") }
        catch let failure as WorkshopThumbnailFailure { XCTAssertEqual(failure.code, .notAnimated) }
        XCTAssertEqual(fetcher.requests.count, 1)
    }

    func testCacheThatKeepsNoAnimationWritesOnlyStillsAndRelaysNothing() async throws {
        let gif = try Self.image(type: .gif, width: 200, height: 120, frames: 4)
        let png = try Self.image(type: .png, width: 200, height: 120, frames: 1)
        let fetcher = RecordingFetcher { url in url.path.contains("gif") ? gif : png }
        let cache = WorkshopThumbnailCache(directory: root, fetcher: fetcher, keepsAnimation: false)
        let animated = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/20/gif/"))
        let still = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/21/png/"))

        let cover = try await cache.thumbnail(for: animated)
        _ = try await cache.thumbnail(for: still)
        XCTAssertEqual(WorkshopThumbnailCache.frameCount(of: cover), 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(files.filter { $0.hasSuffix(".jpg") }.count, 2)
        XCTAssertEqual(files.filter { !$0.hasSuffix(".jpg") }, [], "No original animation and no single-frame marker is left behind")

        do {
            _ = try await cache.animatedPreview(for: animated)
            XCTFail("a cache that keeps no animation has none to relay")
        } catch let failure as WorkshopThumbnailFailure {
            XCTAssertEqual(failure.code, .notAnimated)
        }
        XCTAssertEqual(fetcher.requests.count, 2, "Declining to relay costs no request")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testSourceLargerThanTheCachesLimitIsRefusedAndLeavesNothing() async throws {
        let png = try Self.image(type: .png, width: 400, height: 300, frames: 1)
        let fetcher = RecordingFetcher { _ in png }
        let url = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/22/limit/"))

        let strict = WorkshopThumbnailCache(directory: root, fetcher: fetcher, sourceByteLimit: png.count - 1)
        do {
            _ = try await strict.thumbnail(for: url)
            XCTFail("a source over the limit must not become a cover")
        } catch let failure as WorkshopThumbnailFailure {
            XCTAssertEqual(failure.code, .tooLarge)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let exact = WorkshopThumbnailCache(directory: root, fetcher: fetcher, sourceByteLimit: png.count)
        let cover = try await exact.thumbnail(for: url)
        XCTAssertFalse(cover.isEmpty)

        let gif = try Self.image(type: .gif, width: 32, height: 32, frames: 3)
        let animated = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/23/limit/"))
        let relaying = WorkshopThumbnailCache(directory: root, fetcher: RecordingFetcher { _ in gif }, sourceByteLimit: gif.count - 1)
        do {
            _ = try await relaying.animatedPreview(for: animated)
            XCTFail("an animation over the limit must not be relayed")
        } catch let failure as WorkshopThumbnailFailure {
            XCTAssertEqual(failure.code, .tooLarge)
        }
    }

    private static func meanLuminance(of encoded: Data) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var total = 0
        for row in 0..<image.height {
            for column in 0..<image.width { total += Int(pixels[row * context.bytesPerRow + column]) }
        }
        return Double(total) / Double(image.width * image.height * 255)
    }

    /// `brightness` maps a frame index to 0...1; `nil` keeps the default varied fill per frame.
    private static func image(
        type: UTType, width: Int, height: Int, frames: Int, brightness: ((Int) -> Double)? = nil
    ) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, frames, nil))
        let space = CGColorSpaceCreateDeviceRGB()
        for frame in 0..<frames {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            if let level = brightness?(frame) {
                context.setFillColor(gray: level, alpha: 1)
            } else {
                context.setFillColor(CGColor(red: CGFloat(frame) / CGFloat(max(frames, 2)), green: 0.4, blue: 0.7, alpha: 1))
            }
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Noise keeps the encoder from collapsing the frame to a few bytes; a black fade-in
            // frame stays black so the still-frame choice sees what a real preview shows.
            if brightness == nil {
                for y in stride(from: 0, to: height, by: 16) {
                    context.setFillColor(CGColor(red: CGFloat(y % 97) / 97, green: CGFloat(y % 53) / 53, blue: 0.2, alpha: 1))
                    context.fill(CGRect(x: (y * 7) % width, y: y, width: 40, height: 8))
                }
            }
            let image = try XCTUnwrap(context.makeImage())
            let properties: [CFString: Any] = type == .gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] : [:]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

private final class RecordingFetcher: WorkshopThumbnailFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let respond: @Sendable (URL) throws -> Data
    private let delay: Duration
    private var active = 0
    private(set) var requests: [URL] = []
    private(set) var peakConcurrency = 0
    var failNext: Error?

    init(delay: Duration = .zero, respond: @escaping @Sendable (URL) throws -> Data) {
        self.delay = delay
        self.respond = respond
    }

    func fetch(_ url: URL) async throws -> Data {
        lock.lock()
        requests.append(url)
        active += 1
        peakConcurrency = max(peakConcurrency, active)
        let failure = failNext
        failNext = nil
        lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return try respond(url)
    }
}
