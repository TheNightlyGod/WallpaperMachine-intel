import CoreGraphics
import Foundation
import ImageIO

/// Where a panel image comes from. Typed values replace the page's announced addresses: a view
/// can only ask for one of these, and each is checked again when it is loaded, so no path or URL
/// reaches a decoder unvetted.
enum PanelImageSource: Hashable, Sendable {
  /// A cover of an installed wallpaper's preview file, at most 512 px, cached on disk. `stamp` is
  /// `LibraryCoverStamps`' number for the file: it changes when the preview is replaced, which
  /// makes the replacement a different image to the memory cache and the view.
  case libraryCover(file: URL, stamp: UInt64)
  /// The preview file itself, for the inspector and Now Playing artwork. It must lie inside the
  /// library after symlinks resolve, name an image, be a regular file and fit 32 MiB.
  case libraryPreview(file: URL)
  /// A Workshop preview as a 512 px still. The URL must be https.
  case steamThumbnail(URL)
  /// A pixiv thumbnail or page preview. Only `i.pximg.net` is read, with pixiv's referrer.
  case pixivThumbnail(URL)
  /// Artwork an author's property label shows. Only the fixed list of image hosts is read.
  case propertyImage(URL)

  fileprivate var cacheKey: String {
    switch self {
    case .libraryCover(let file, let stamp): "cover|\(stamp)|\(file.path)"
    case .libraryPreview(let file): "preview|\(file.path)"
    case .steamThumbnail(let url): "steam|\(url.absoluteString)"
    case .pixivThumbnail(let url): "pixiv|\(url.absoluteString)"
    case .propertyImage(let url): "property|\(url.absoluteString)"
    }
  }
}

/// A decoded still, small enough for the view that asked for it.
final class DecodedPanelImage: @unchecked Sendable {
  let cgImage: CGImage
  var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
  /// What the memory cache charges for it: four bytes a pixel.
  var cost: Int { cgImage.width * cgImage.height * 4 }
  init(_ cgImage: CGImage) { self.cgImage = cgImage }
}

/// Loads the images the panel shows over the app's own caches and limits.
///
/// The caches are the ones the web panel used, unchanged: `WorkshopThumbnailCache` for Steam
/// stills and animations (512 MiB, 8 stills and 2 animations at a time), for pixiv (256 MiB, 6 at
/// a time, the referrer sent by its fetcher) and for installed covers (128 MiB, 4 at a time, no
/// animation kept), and `PropertyImageCache` for author artwork (a fixed host list, 16 MiB, 4 at a
/// time). Each caller shares one fetch per tile, so a view that scrolls away stops waiting without
/// cancelling a download another view still needs.
///
/// What it adds is a decode sized to the view (ImageIO, off the main thread, never a full-size
/// decode of a preview for a tile) and a bounded memory cache of the decoded stills, so scrolling
/// back does not decode again.
@MainActor
final class PanelImagePipeline {
  enum Failure: Error, Equatable {
    /// The source names something the panel never reads: a path outside the library, a URL that is
    /// not https, a host that is not on the list.
    case refused
    /// The source has nothing to animate or does not fit the animation budget.
    case notAnimated
    case undecodable
  }

  /// The most memory the decoded stills may hold.
  nonisolated static let memoryLimit = 128 * 1024 * 1024

  let thumbnailCache: WorkshopThumbnailCache
  let pixivThumbnailCache: WorkshopThumbnailCache
  let libraryThumbnailCache: WorkshopThumbnailCache
  let propertyImages: PropertyImageCache
  /// Resolved on each request, so a library root that moves (a test's temporary home) is followed.
  private let libraryRoot: @Sendable () -> URL
  private let memory: NSCache<NSString, DecodedPanelImage>
  /// Covers that could not be made, by source: they show the downsampled preview instead and
  /// are not asked for again until their stamp, and so their key, changes.
  private var brokenCovers = Set<String>()

  init(
    thumbnailCache: WorkshopThumbnailCache = WorkshopThumbnailCache(),
    pixivThumbnailCache: WorkshopThumbnailCache = WorkshopThumbnailCache(
      directory: ClientPaths.pixivThumbnailCacheURL, fetcher: PixivThumbnailFetcher(),
      maxConcurrentFetches: 6, byteLimit: 256 * 1024 * 1024),
    libraryThumbnailCache: WorkshopThumbnailCache = WorkshopThumbnailCache(
      directory: ClientPaths.libraryThumbnailCacheURL, fetcher: LibraryPreviewFetcher(),
      maxConcurrentFetches: 4, byteLimit: 128 * 1024 * 1024, keepsAnimation: false,
      sourceByteLimit: LibraryPreviewFetcher.maximumBytes),
    propertyImages: PropertyImageCache = PropertyImageCache(),
    libraryRoot: @escaping @Sendable () -> URL = { ClientPaths.libraryURL },
    memory: NSCache<NSString, DecodedPanelImage> = NSCache()
  ) {
    self.thumbnailCache = thumbnailCache
    self.pixivThumbnailCache = pixivThumbnailCache
    self.libraryThumbnailCache = libraryThumbnailCache
    self.propertyImages = propertyImages
    self.libraryRoot = libraryRoot
    self.memory = memory
    memory.totalCostLimit = Self.memoryLimit
  }

  /// The decoded still for `source` if it is already in memory, for a view that wants to show it
  /// in its first frame instead of a placeholder.
  func cachedImage(for source: PanelImageSource, maxPixelSize: Int) -> DecodedPanelImage? {
    memory.object(forKey: Self.memoryKey(source, maxPixelSize) as NSString)
  }

  /// The still for `source` decoded to at most `maxPixelSize` on its long side. Throws `refused`
  /// for a source that fails its checks, and `CancellationError` when the caller goes away.
  func image(for source: PanelImageSource, maxPixelSize: Int) async throws -> DecodedPanelImage {
    let key = Self.memoryKey(source, maxPixelSize) as NSString
    if let cached = memory.object(forKey: key) { return cached }
    let data = try await stillData(for: source)
    try Task.checkCancellation()
    let image = try await Task.detached(priority: .userInitiated) {
      try Self.downsample(data, maxPixelSize: maxPixelSize)
    }.value
    try Task.checkCancellation()
    memory.setObject(image, forKey: key, cost: image.cost)
    return image
  }

  /// The bytes of an animation for `source`, to be played by `AnimatedPreview`. Only a source
  /// that can move offers one, and only when it fits the animation budget: more than one frame,
  /// at most 300, 4,194,304 px a frame and 33,554,432 px in all. Anything larger keeps its still.
  func animation(for source: PanelImageSource) async throws -> Data {
    let data: Data
    switch source {
    case .libraryPreview(let file):
      data = try await libraryPreviewData(file)
    case .steamThumbnail(let url):
      guard Self.isAllowedSteam(url) else { throw Failure.refused }
      // Steam's own bytes, kept beside the still; a single frame or an oversized animation throws.
      do { data = try await thumbnailCache.animatedPreview(for: url) } catch is CancellationError {
        throw CancellationError()
      } catch { throw Failure.notAnimated }
    case .propertyImage(let url):
      guard PropertyImageCache.allowedURL(url) else { throw Failure.refused }
      data = try await propertyImages.image(for: url).data
    case .libraryCover, .pixivThumbnail:
      throw Failure.notAnimated
    }
    try Task.checkCancellation()
    let fits = await Task.detached(priority: .utility) {
      WorkshopThumbnailCache.animationFitsBudget(data)
    }.value
    guard fits else { throw Failure.notAnimated }
    return data
  }

  // MARK: Fetching

  private func stillData(for source: PanelImageSource) async throws -> Data {
    switch source {
    case .libraryCover(let file, _):
      if brokenCovers.contains(source.cacheKey) { return try await libraryPreviewData(file) }
      do {
        let root = libraryRoot()
        let identity = try await Task.detached(priority: .utility) {
          try LibraryPreviewFetcher.identity(of: file, in: root)
        }.value
        return try await libraryThumbnailCache.thumbnail(for: identity)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // The cover could not be made: show the preview itself, downsampled, and do not try the
        // cover again until the preview changes. A path outside the library is refused there too.
        brokenCovers.insert(source.cacheKey)
        return try await libraryPreviewData(file)
      }
    case .libraryPreview(let file):
      return try await libraryPreviewData(file)
    case .steamThumbnail(let url):
      guard Self.isAllowedSteam(url) else { throw Failure.refused }
      return try await thumbnailCache.thumbnail(for: url)
    case .pixivThumbnail(let url):
      guard PixivService.isImageURL(url) else { throw Failure.refused }
      return try await pixivThumbnailCache.thumbnail(for: url)
    case .propertyImage(let url):
      guard PropertyImageCache.allowedURL(url) else { throw Failure.refused }
      return try await propertyImages.image(for: url).data
    }
  }

  private func libraryPreviewData(_ file: URL) async throws -> Data {
    let root = libraryRoot()
    do {
      return try await Task.detached(priority: .utility) {
        try await LibraryPreviewFetcher(root: root).fetch(file)
      }.value
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Failure.refused
    }
  }

  private nonisolated static func isAllowedSteam(_ url: URL) -> Bool {
    url.scheme == "https" && url.user == nil && url.password == nil
  }

  // MARK: Decoding

  private nonisolated static func memoryKey(_ source: PanelImageSource, _ size: Int) -> String {
    "\(source.cacheKey)@\(size)"
  }

  /// One still of any image ImageIO reads, at most `maxPixelSize` on its long side, without
  /// decoding the full-size picture. An animation contributes its representative frame.
  nonisolated static func downsample(_ data: Data, maxPixelSize: Int) throws -> DecodedPanelImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 0
    else { throw Failure.undecodable }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixelSize),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    let index = WorkshopThumbnailCache.representativeFrameIndex(of: source)
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    else { throw Failure.undecodable }
    return DecodedPanelImage(image)
  }
}
