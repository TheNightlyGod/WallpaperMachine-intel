import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// Answers preview requests only once the test releases it.
private final class GatedFetcher: WorkshopThumbnailFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private var fetched = 0
  private let payload: Data

  init(payload: Data) { self.payload = payload }

  var fetchCount: Int { lock.withLock { fetched } }

  func release() {
    lock.lock()
    released = true
    let waiters = self.waiters
    self.waiters = []
    lock.unlock()
    waiters.forEach { $0.resume() }
  }

  func fetch(_ url: URL) async throws -> Data {
    lock.withLock { fetched += 1 }
    await withCheckedContinuation { continuation in
      lock.lock()
      if released {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
    return payload
  }
}

/// What the panel's image loader reads, from where, and what it refuses: the checks the web
/// panel's address scheme made, now on typed sources.
@MainActor
final class PanelImagePipelineTests: XCTestCase {
  private var home: URL!
  private var library: URL { home.appendingPathComponent("Library", isDirectory: true) }

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-images-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  private func pipeline(
    steam: (any WorkshopThumbnailFetching)? = nil, pixiv: (any WorkshopThumbnailFetching)? = nil
  ) -> PanelImagePipeline {
    let library = library
    return PanelImagePipeline(
      thumbnailCache: WorkshopThumbnailCache(
        directory: home.appendingPathComponent("steam"), fetcher: steam ?? PreviewFetcher { _ in try Self.png(width: 1600, height: 900) }),
      pixivThumbnailCache: WorkshopThumbnailCache(
        directory: home.appendingPathComponent("pixiv"), fetcher: pixiv ?? PreviewFetcher { _ in try Self.png(width: 1600, height: 900) }),
      libraryThumbnailCache: WorkshopThumbnailCache(
        directory: home.appendingPathComponent("covers"), fetcher: LibraryPreviewFetcher(root: library),
        keepsAnimation: false),
      propertyImages: PropertyImageCache(),
      libraryRoot: { library })
  }

  private func writePreview(_ name: String, in folder: URL? = nil, width: Int = 1600, height: Int = 900) throws -> URL {
    let file = (folder ?? library).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.png(width: width, height: height).write(to: file)
    return file
  }

  func testALibraryCoverIsAScaledStillAndNeverReadsOutsideTheLibrary() async throws {
    let inside = try writePreview("42/preview.png")
    let outside = try writePreview("preview.png", in: home.appendingPathComponent("Elsewhere"))
    let covers = home.appendingPathComponent("covers")
    let pipeline = pipeline()

    let cover = try await pipeline.image(for: .libraryCover(file: inside, stamp: 3), maxPixelSize: 512)
    XCTAssertEqual(cover.pixelSize, CGSize(width: 512, height: 288), "a tile gets a downscaled cover, not the preview file")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: covers.path).filter { $0.hasSuffix(".jpg") }.count, 1)

    do {
      _ = try await pipeline.image(for: .libraryCover(file: outside, stamp: 1), maxPixelSize: 512)
      XCTFail("a preview outside the library must not be read")
    } catch { XCTAssertEqual(error as? PanelImagePipeline.Failure, .refused) }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: covers.path).filter { $0.hasSuffix(".jpg") }.count, 1,
      "and leaves nothing in the cover cache")
    do {
      _ = try await pipeline.image(for: .libraryPreview(file: outside), maxPixelSize: 512)
      XCTFail("the preview route is confined too")
    } catch { XCTAssertEqual(error as? PanelImagePipeline.Failure, .refused) }
  }

  func testASymlinkOutOfTheLibraryAndANonImageAreRefused() async throws {
    let outside = try writePreview("secret.png", in: home.appendingPathComponent("Elsewhere"))
    let link = library.appendingPathComponent("9/preview.png")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let text = library.appendingPathComponent("9/notes.txt")
    try Data("not an image".utf8).write(to: text)
    let pipeline = pipeline()
    for source in [PanelImageSource.libraryPreview(file: link), .libraryPreview(file: text), .libraryCover(file: link, stamp: 1)] {
      do {
        _ = try await pipeline.image(for: source, maxPixelSize: 256)
        XCTFail("\(source) must be refused")
      } catch { XCTAssertEqual(error as? PanelImagePipeline.Failure, .refused, "\(source)") }
    }
  }

  func testAReplacedPreviewUnderANewStampIsAnotherImage() async throws {
    let file = try writePreview("42/preview.png", width: 1600, height: 900)
    let pipeline = pipeline()
    let old = try await pipeline.image(for: .libraryCover(file: file, stamp: 1), maxPixelSize: 512)
    XCTAssertEqual(old.pixelSize, CGSize(width: 512, height: 288))

    try Self.png(width: 900, height: 1600).write(to: file)
    let sameStamp = try await pipeline.image(for: .libraryCover(file: file, stamp: 1), maxPixelSize: 512)
    XCTAssertTrue(sameStamp === old, "an unchanged stamp is served from memory")
    let replaced = try await pipeline.image(for: .libraryCover(file: file, stamp: 2), maxPixelSize: 512)
    XCTAssertEqual(replaced.pixelSize, CGSize(width: 288, height: 512), "the new stamp asks the cache again, which re-stamps by modification")
  }

  func testACoverThatCannotBeMadeFallsBackToTheDownsampledPreviewAndIsNotAskedAgain() async throws {
    let file = try writePreview("42/preview.png")
    // The cover cache's fetcher refuses everything, so no cover can be made, but the preview
    // file is a good image inside the library.
    let library = library
    let pipeline = PanelImagePipeline(
      thumbnailCache: WorkshopThumbnailCache(directory: home.appendingPathComponent("steam"), fetcher: PreviewFetcher { _ in Data() }),
      pixivThumbnailCache: WorkshopThumbnailCache(directory: home.appendingPathComponent("pixiv"), fetcher: PreviewFetcher { _ in Data() }),
      libraryThumbnailCache: WorkshopThumbnailCache(
        directory: home.appendingPathComponent("covers"), fetcher: PreviewFetcher { _ in throw URLError(.cannotOpenFile) },
        keepsAnimation: false),
      libraryRoot: { library })
    let image = try await pipeline.image(for: .libraryCover(file: file, stamp: 7), maxPixelSize: 200)
    XCTAssertEqual(max(image.pixelSize.width, image.pixelSize.height), 200, "the preview itself, downsampled, never decoded at full size")
    let again = try await pipeline.image(for: .libraryCover(file: file, stamp: 7), maxPixelSize: 100)
    XCTAssertEqual(max(again.pixelSize.width, again.pixelSize.height), 100)
  }

  func testStillsAreDecodedToTheSizeOfTheViewAndCachedInMemory() async throws {
    let file = try writePreview("42/preview.png")
    let pipeline = pipeline()
    XCTAssertNil(pipeline.cachedImage(for: .libraryPreview(file: file), maxPixelSize: 160))
    let small = try await pipeline.image(for: .libraryPreview(file: file), maxPixelSize: 160)
    XCTAssertEqual(small.pixelSize, CGSize(width: 160, height: 90))
    XCTAssertTrue(pipeline.cachedImage(for: .libraryPreview(file: file), maxPixelSize: 160) === small)
    XCTAssertNil(
      pipeline.cachedImage(for: .libraryPreview(file: file), maxPixelSize: 320),
      "another size is another image")
    let large = try await pipeline.image(for: .libraryPreview(file: file), maxPixelSize: 320)
    XCTAssertEqual(large.pixelSize, CGSize(width: 320, height: 180))
    try FileManager.default.removeItem(at: file)
    let afterDeletion = try await pipeline.image(for: .libraryPreview(file: file), maxPixelSize: 160)
    XCTAssertTrue(afterDeletion === small, "a cached still needs no file or fetch")
  }

  func testOnlyHttpsSteamPreviewsAreFetched() async throws {
    let fetcher = PreviewFetcher { _ in try Self.png(width: 800, height: 450) }
    let pipeline = pipeline(steam: fetcher)
    let secure = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/1/A/"))
    let image = try await pipeline.image(for: .steamThumbnail(secure), maxPixelSize: 300)
    XCTAssertEqual(image.pixelSize, CGSize(width: 300, height: 169))
    XCTAssertEqual(fetcher.requests, [secure])

    for refused in [
      "http://images.steamusercontent.com/ugc/2/B/", "file:///etc/passwd",
      "https://user:password@images.steamusercontent.com/ugc/3/C/", "ftp://example.test/x.png",
    ] {
      do {
        _ = try await pipeline.image(for: .steamThumbnail(try XCTUnwrap(URL(string: refused))), maxPixelSize: 300)
        XCTFail("\(refused) must be refused")
      } catch { XCTAssertEqual(error as? PanelImagePipeline.Failure, .refused, refused) }
    }
    XCTAssertEqual(fetcher.requests, [secure], "a refused source costs no request")
  }

  func testOnlyPixivsImageHostAndTheFixedPropertyArtHostsAreRead() async throws {
    let pixivFetcher = PreviewFetcher { _ in try Self.png(width: 400, height: 400) }
    let pipeline = pipeline(pixiv: pixivFetcher)
    let allowed = try XCTUnwrap(URL(string: "https://i.pximg.net/img-master/img/2026/01/01/a_p0_master1200.jpg"))
    _ = try await pipeline.image(for: .pixivThumbnail(allowed), maxPixelSize: 128)
    XCTAssertEqual(pixivFetcher.requests, [allowed])
    for refused in [
      "https://i.pximg.net.evil.test/a.jpg", "http://i.pximg.net/a.jpg", "https://www.pixiv.net/a.jpg",
      "https://i.pximg.net:8443/a.jpg",
    ] {
      do {
        _ = try await pipeline.image(for: .pixivThumbnail(try XCTUnwrap(URL(string: refused))), maxPixelSize: 128)
        XCTFail("\(refused) must be refused")
      } catch { XCTAssertEqual(error as? PanelImagePipeline.Failure, .refused, refused) }
    }
    XCTAssertEqual(pixivFetcher.requests.count, 1)

    for refused in [
      "https://127.0.0.1/art.png", "https://i.ibb.co.evil.test/art.png", "http://i.ibb.co/art.png",
      "https://i.ibb.co:8443/art.png", "https://user:password@i.ibb.co/art.png",
    ] {
      do {
        _ = try await pipeline.image(for: .propertyImage(try XCTUnwrap(URL(string: refused))), maxPixelSize: 128)
        XCTFail("author art from \(refused) must be refused")
      } catch { XCTAssertEqual(error as? PanelImagePipeline.Failure, .refused, refused) }
    }
  }

  func testAViewThatGoesAwayStopsWaitingWithoutCancellingTheSharedFetch() async throws {
    let fetcher = GatedFetcher(payload: try Self.png(width: 800, height: 450))
    let pipeline = pipeline(steam: fetcher)
    let steam = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/1/A/"))
    let leaving = Task { try await pipeline.image(for: .steamThumbnail(steam), maxPixelSize: 256) }
    let staying = Task { try await pipeline.image(for: .steamThumbnail(steam), maxPixelSize: 128) }
    while fetcher.fetchCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
    leaving.cancel()
    fetcher.release()
    let image = try await staying.value
    XCTAssertEqual(image.pixelSize, CGSize(width: 128, height: 72))
    XCTAssertEqual(fetcher.fetchCount, 1, "both views shared one download")
    do {
      _ = try await leaving.value
    } catch { XCTAssertTrue(error is CancellationError, "the view that left is told it was cancelled") }
  }

  func testAnimationsComeOnlyFromSourcesThatCanMoveAndFitTheBudget() async throws {
    let gif = library.appendingPathComponent("7/preview.gif")
    try FileManager.default.createDirectory(at: gif.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PanelTestCase.gifData(frames: 3).write(to: gif)
    let still = try writePreview("8/preview.png", width: 64, height: 64)
    let outside = home.appendingPathComponent("Elsewhere/preview.gif")
    try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PanelTestCase.gifData(frames: 3).write(to: outside)
    let pipeline = pipeline()

    let animation = try await pipeline.animation(for: .libraryPreview(file: gif))
    XCTAssertEqual(WorkshopThumbnailCache.frameCount(of: animation), 3)
    for (source, failure) in [
      (PanelImageSource.libraryPreview(file: still), PanelImagePipeline.Failure.notAnimated),
      (.libraryPreview(file: outside), .refused),
      (.libraryCover(file: gif, stamp: 1), .notAnimated),
      (.pixivThumbnail(URL(string: "https://i.pximg.net/a.jpg")!), .notAnimated),
    ] {
      do {
        _ = try await pipeline.animation(for: source)
        XCTFail("\(source) has no animation to offer")
      } catch { XCTAssertEqual(error as? PanelImagePipeline.Failure, failure, "\(source)") }
    }
  }

  nonisolated static func png(width: Int, height: Int) throws -> Data {
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }
}

extension PanelTestCase {
  /// A small animated GIF without needing a test instance.
  static func gifData(frames: Int) throws -> Data {
    try PanelTestCase.gif(frames: frames, brightness: 0.5)
  }
}
