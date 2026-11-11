import AppKit
import ImageIO

/// What a display's wallpaper is drawing, as a small picture for the panel: the backdrop of
/// Settings › Desktop Widgets' preview. The wallpaper's own surface reads back its final pixels
/// once through the poster pipeline (`DesktopPosterGrab`), so the picture has the display's
/// aspect, the wallpaper's placement and scaling and its current properties, unlike the author's
/// preview image. Nothing runs between requests: no timer, no second renderer.
///
/// Many wallpapers open with an intro or fade in from black, so a frame is settled only once the
/// wallpaper has played a whole settle window where it can be seen (`WallpaperSettleClock`). A
/// wallpaper that has not settled still gives the frame it draws now, at once, as a first picture
/// the caller replaces when it asks again after the window; a blank frame (black or one flat
/// colour) is never given. A paused surface answers too (the panel's own window usually covers the
/// display) with the frame it holds. The last settled frame of each display is kept, at the panel's
/// size, for as long as the wallpaper keeps its look, so a wallpaper replaying its intro still shows
/// it; the desktop picture sync's settled poster stands in for one this has not taken.
@MainActor
final class DesktopWallpaperFrames {
    /// What the display's wallpaper window is and how far it has played.
    struct Surface {
        var layer: CALayer
        /// It has played a whole settle window, so a frame of it is past any intro.
        var isSettled: Bool
        /// How long until it has settled, while it plays on; nil otherwise.
        var remaining: Duration?
        /// What its picture shows, as a settled poster is keyed; nil when that cannot be told,
        /// and then no frame is kept for it.
        var look: DesktopPosterLook?
    }

    enum Answer {
        /// A settled frame of what the display shows.
        case frame(CGImage)
        /// The wallpaper has not played long enough for a frame to be past its intro: `first` is
        /// the frame it draws now, which may be in it (nil when it gave none or a blank one).
        /// Asking again after `retryAfter` can have a settled one; nil when waiting would change
        /// nothing (it does not play).
        case unsettled(first: CGImage?, retryAfter: Duration?)
        /// No frame can be had: no wallpaper window, no answer, or a blank one.
        case unavailable
    }

    struct Configuration {
        /// How long the wallpaper has to answer.
        var timeout: Duration = .seconds(1)
    }

    private let center: NotificationCenter
    private let surface: @MainActor (UInt32) -> Surface?
    private let awaitsFrame: @MainActor (CALayer) -> Bool
    private let settledPoster: @MainActor (UInt32) -> Data?
    private let configuration: Configuration
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The last settled frame of each display and the look it was taken under.
    private var kept: [UInt32: (look: DesktopPosterLook, image: CGImage)] = [:]

    /// `surface` is the display's front wallpaper window; `awaitsFrame` whether the desktop
    /// picture sync waits for a frame from a layer, which is then taken instead of asking again (a
    /// request of our own would take the place of the sync's); `settledPoster` the sync's poster of
    /// the display when it is a settled one.
    init(center: NotificationCenter = .default,
         surface: @escaping @MainActor (UInt32) -> Surface?,
         awaitsFrame: @escaping @MainActor (CALayer) -> Bool = { _ in false },
         settledPoster: @escaping @MainActor (UInt32) -> Data? = { _ in nil },
         configuration: Configuration = .init(),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.center = center
        self.surface = surface
        self.awaitsFrame = awaitsFrame
        self.settledPoster = settledPoster
        self.configuration = configuration
        self.sleep = sleep
    }

    /// A picture of what `display` shows, its longer edge at most `maxPixelSize` pixels: settled
    /// when it can be. A wallpaper that has settled is asked for the frame it draws now; the frame
    /// kept for its look, then the sync's settled poster, stand in for one that has not, does not
    /// answer or answers with a blank frame. Without either, one that has not settled is asked for
    /// its first frame.
    func frame(display: UInt32, maxPixelSize: Int) async -> Answer {
        guard let surface = surface(display) else {
            kept[display] = nil
            return .unavailable
        }
        if surface.isSettled, let image = await grab(surface.layer, maxPixelSize: maxPixelSize) {
            if let look = surface.look { kept[display] = (look, image) }
            return .frame(image)
        }
        if let look = surface.look, let frame = kept[display], frame.look == look {
            return .frame(frame.image)
        }
        if let poster = settledPoster(display),
           let image = await Task.detached(priority: .userInitiated, operation: {
               Self.thumbnail(poster, maxPixelSize: maxPixelSize).flatMap { Self.isBlank($0) ? nil : $0 }
           }).value {
            return .frame(image)
        }
        guard !surface.isSettled else { return .unavailable }
        let first = await grab(surface.layer, maxPixelSize: maxPixelSize)
        return .unsettled(first: first, retryAfter: surface.remaining)
    }

    /// The frame `layer` draws now, scaled; nil without an answer or when it is blank.
    private func grab(_ layer: CALayer, maxPixelSize: Int) async -> CGImage? {
        let grab = DesktopPosterGrab(center: center, contextPrefix: "panel-preview")
        guard let frame = await grab.run(on: layer, timeout: configuration.timeout,
                                         asks: !awaitsFrame(layer), sleep: sleep) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            frame.cgImage().flatMap { Self.scaled($0, maxPixelSize: maxPixelSize) }
                .flatMap { Self.isBlank($0) ? nil : $0 }
        }.value
    }

    /// `image` drawn no larger than `maxPixelSize` on its longer edge, in sRGB.
    nonisolated static func scaled(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longer = max(image.width, image.height)
        let ratio = longer > maxPixelSize ? Double(max(maxPixelSize, 1)) / Double(longer) : 1
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// An encoded picture decoded no larger than `maxPixelSize` on its longer edge.
    nonisolated static func thumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The side of the grid a frame is sampled on to tell whether it is blank.
    nonisolated static let blankSample = 32
    /// The brightest a sample may be in a black frame, and the most two samples of a flat frame may
    /// differ by, out of 255: a frame of an intro that has not faded in, or a plain fade colour.
    nonisolated static let blankLevel = 6

    /// Whether `image` is black, or one flat colour, all over: what an intro or a fade-in shows
    /// before the wallpaper does. Sampled on a small grid, so a lone star still counts as content
    /// only when it covers a sample; a frame with anything to arrange widgets over has much more.
    nonisolated static func isBlank(_ image: CGImage) -> Bool {
        let side = blankSample
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data
        else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var lowest = [Int](repeating: 255, count: 3), highest = [Int](repeating: 0, count: 3)
        for pixel in 0..<(side * side) {
            for channel in 0..<3 {
                let value = Int(bytes[pixel * 4 + channel])
                lowest[channel] = min(lowest[channel], value)
                highest[channel] = max(highest[channel], value)
            }
        }
        let black = highest.allSatisfy { $0 <= blankLevel }
        let flat = zip(lowest, highest).allSatisfy { $1 - $0 <= blankLevel }
        return black || flat
    }
}
