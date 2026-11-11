import AVFoundation
import CoreGraphics

/// How a picture is scaled to its display, by the numbers the lock-screen configuration
/// and the renderer use: none (original size) 0, stretch 1, fit 2, fill 3. Fit with a blurred
/// backdrop is the renderer's number 4; here it is a case of its own that is laid out as Fit, and
/// `init(rendererValue:)` is how those numbers come in. Its `rawValue` is only this enum's tag.
enum NativeVideoScalingMode: Int32, Equatable, Sendable {
    case none = 0
    case stretch = 1
    case match = 2
    case fill = 3
    case matchBlurred = 5

    /// The mode for a number of the lock-screen configuration or the renderer.
    init?(rendererValue: Int32) {
        if rendererValue == 4 {
            self = .matchBlurred
        } else if let mode = NativeVideoScalingMode(rawValue: rendererValue), mode != .matchBlurred {
            self = mode
        } else {
            return nil
        }
    }
}

/// Where a clip's picture goes on a display under each scaling mode.
///
/// Pure arithmetic, shared by the live layer, the desktop poster and the
/// tests, so the three cannot drift apart. It follows the Compatibility
/// backend's layout rule rather than inventing a second one: a user who
/// switches a clip between the two backends must see the same picture.
///
/// - **Fit, Fill, Stretch** scale the picture to the display by the smaller
///   ratio, the larger ratio, or each axis on its own. **Fit with blurred backdrop** is Fit
///   here: this player has no blurred fill, so its bars stay black.
/// - **Original size** is one video pixel to one *point*, not one device
///   pixel: a 1920x1080 clip covers 1920x1080 points of a Retina display,
///   exactly as Compatibility draws it.
/// - The scale factor multiplies whichever of those applies. A factor that is
///   not a finite positive number counts as 1.
/// - The picture is centred unless a position is given: `pan` is the fraction of
///   the room the picture leaves on each axis that lies before it (0 the left or
///   top edge, 1 the right or bottom edge), as the renderer's `WallpaperScaling`
///   divides it. Its origin and size are rounded in device pixels the way the
///   renderer rounds them.
///
/// Compiled by the app and by the lock-screen extension, so it names no bridge
/// type: `NativeVideoScalingMode` carries the same four values by the same numbers.
enum NativeVideoLayout {
    /// Where the picture sits in the room around it, as `LockScreenFraming` publishes it.
    struct Pan: Equatable {
        static let centered = Pan(x: 0.5, y: 0.5)
        var x: Double
        var y: Double

        /// What the renderer does with a position it is given: a number outside 0...1
        /// is held to the nearest edge and one that is not a number is the middle.
        var normalized: Pan {
            func clamp(_ value: Double) -> Double {
                value.isFinite ? min(max(value, 0), 1) : 0.5
            }
            return Pan(x: clamp(x), y: clamp(y))
        }
    }

    /// A rectangle in device pixels, measured from the display's top-left
    /// corner. Negative origins and sizes larger than the display are normal:
    /// Fill and Original size overflow it, and the overflow is cropped.
    struct PixelRect: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// How the player layer is positioned for one scaling choice.
    enum Placement: Equatable {
        /// The layer fills the display and AVFoundation places the picture
        /// inside it. Used for the three plain modes at scale factor 1, where
        /// it is the same arithmetic and also follows the clip's rotation.
        case gravity(AVLayerVideoGravity)
        /// The layer is the picture, in points, and is stretched to it.
        case frame(CGRect)
        /// The picture's size is not known yet, so there is nothing to place.
        /// No picture is shown before the size exists, so keeping the previous
        /// placement for that moment is not visible.
        case pending
    }

    /// A scale factor, or display scale, the renderer would use: anything that
    /// is not finite and positive is 1.
    static func normalizedFactor(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }

    /// Where `videoSize` is drawn inside `viewport` (points) on a display with
    /// `backingScale` device pixels per point.
    ///
    /// `videoSize` is the size the picture is shown at, rotation applied.
    /// Sizes are never below one, the same floor the renderer applies, so a
    /// degenerate input yields a degenerate but valid rectangle, not a crash.
    static func pictureRect(
        mode: NativeVideoScalingMode, factor: Double, videoSize: CGSize, viewport: CGSize,
        backingScale: CGFloat, pan: Pan = .centered
    ) -> PixelRect {
        let scale = normalizedFactor(Double(backingScale))
        let sceneWidth = Double(max(1, rounded(Double(videoSize.width))))
        let sceneHeight = Double(max(1, rounded(Double(videoSize.height))))
        // The renderer receives the display in device pixels and derives whole
        // logical points from them; the same two steps keep every rounding
        // tie on the same side.
        let deviceWidth = max(0, rounded(Double(viewport.width) * scale))
        let deviceHeight = max(0, rounded(Double(viewport.height) * scale))
        let displayWidth = Double(max(1, rounded(Double(deviceWidth) / scale)))
        let displayHeight = Double(max(1, rounded(Double(deviceHeight) / scale)))

        let ratioX = displayWidth / sceneWidth
        let ratioY = displayHeight / sceneHeight
        var scaleX = 1.0
        var scaleY = 1.0
        switch mode {
        case .none:
            break
        case .stretch:
            scaleX = ratioX
            scaleY = ratioY
        case .match, .matchBlurred:
            scaleX = min(ratioX, ratioY)
            scaleY = scaleX
        case .fill:
            scaleX = max(ratioX, ratioY)
            scaleY = scaleX
        }
        let userFactor = normalizedFactor(factor)
        scaleX *= userFactor
        scaleY *= userFactor

        let width = sceneWidth * scaleX
        let height = sceneHeight * scaleY
        let pan = pan.normalized
        let x = (displayWidth - width) * pan.x
        let y = (displayHeight - height) * pan.y
        return PixelRect(
            x: rounded(x * scale), y: rounded(y * scale),
            width: max(1, rounded(width * scale)), height: max(1, rounded(height * scale)))
    }

    /// How to position the layer for this choice. `videoSize` is `nil` until
    /// the platform player has reported the picture's size.
    static func placement(
        mode: NativeVideoScalingMode, factor: Double, videoSize: CGSize?, viewport: CGSize,
        backingScale: CGFloat, pan: Pan = .centered
    ) -> Placement {
        // The gravity rules centre the picture, so a position needs the explicit frame.
        if normalizedFactor(factor) == 1, pan.normalized == .centered {
            switch mode {
            case .fill: return .gravity(.resizeAspectFill)
            // The native player has no blurred fill: its bars stay black.
            case .match, .matchBlurred: return .gravity(.resizeAspect)
            case .stretch: return .gravity(.resize)
            case .none: break
            }
        }
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return .pending }
        let rect = pictureRect(
            mode: mode, factor: factor, videoSize: videoSize, viewport: viewport,
            backingScale: backingScale, pan: pan)
        let scale = CGFloat(normalizedFactor(Double(backingScale)))
        return .frame(
            CGRect(
                x: CGFloat(rect.x) / scale, y: CGFloat(rect.y) / scale,
                width: CGFloat(rect.width) / scale, height: CGFloat(rect.height) / scale))
    }

    /// `rect`, which `placement` measures from the display's top edge, as a layer frame inside a
    /// parent whose y axis grows upward, as the plain layers of a window and of the lock-screen
    /// surface do. The Position sliders are measured from the top (0 is the top edge), so a
    /// layer given the rectangle unconverted would sit at the bottom instead.
    static func layerFrame(_ rect: CGRect, viewportHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: viewportHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// `image` drawn over the same border as the live layer: a bitmap of the display in
    /// device pixels, for a poster or the frame behind a layer. `nil` for a size no display has.
    /// The layout measures from the top edge and a bitmap context from the bottom.
    static func composeFrame(
        _ image: CGImage, pixelSize: CGSize, backingScale: CGFloat, mode: NativeVideoScalingMode,
        factor: Double, pan: Pan = .centered, borderColor: CGColor? = nil
    ) -> CGImage? {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0,
              pixelSize.width <= 16_384, pixelSize.height <= 16_384 else { return nil }
        let width = Int(pixelSize.width.rounded(.up)), height = Int(pixelSize.height.rounded(.up))
        guard width * height <= 32 * 1024 * 1024,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let showsBorder = mode != .fill && mode != .stretch
        context.setFillColor((showsBorder ? borderColor : nil) ?? CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The context is the display in device pixels, so the layout is asked
        // for the same display expressed in points.
        let scale = CGFloat(normalizedFactor(Double(backingScale)))
        let rect = pictureRect(
            mode: mode, factor: factor,
            videoSize: CGSize(width: image.width, height: image.height),
            viewport: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale),
            backingScale: scale, pan: pan)
        context.draw(image, in: CGRect(
            x: rect.x, y: height - rect.y - rect.height, width: rect.width, height: rect.height))
        return context.makeImage()
    }

    /// `lround`: halves away from zero, held inside 32 bits so an absurd scale
    /// factor produces an absurd rectangle instead of a trap.
    private static func rounded(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), Double(Int32.min)), Double(Int32.max)))
    }
}
