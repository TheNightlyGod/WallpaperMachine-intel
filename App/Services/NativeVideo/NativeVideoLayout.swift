import AVFoundation
import CoreGraphics

/// Where a clip's picture goes on a display under each scaling mode.
///
/// Pure arithmetic, shared by the live layer, the desktop poster and the
/// tests, so the three cannot drift apart. It follows the Compatibility
/// backend's layout rule rather than inventing a second one: a user who
/// switches a clip between the two backends must see the same picture.
///
/// - **Fit, Fill, Stretch** scale the picture to the display by the smaller
///   ratio, the larger ratio, or each axis on its own.
/// - **Original size** is one video pixel to one *point*, not one device
///   pixel: a 1920x1080 clip covers 1920x1080 points of a Retina display,
///   exactly as Compatibility draws it.
/// - The scale factor multiplies whichever of those applies. A factor that is
///   not a finite positive number counts as 1.
/// - The picture is centred, and its origin and size are rounded in device
///   pixels the way the renderer rounds them.
enum NativeVideoLayout {
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
        mode: BridgeScalingMode, factor: Double, videoSize: CGSize, viewport: CGSize,
        backingScale: CGFloat
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
        case BridgeScalingMode.none:
            break
        case .stretch:
            scaleX = ratioX
            scaleY = ratioY
        case .match:
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
        let x = (displayWidth - width) * 0.5
        let y = (displayHeight - height) * 0.5
        return PixelRect(
            x: rounded(x * scale), y: rounded(y * scale),
            width: max(1, rounded(width * scale)), height: max(1, rounded(height * scale)))
    }

    /// How to position the layer for this choice. `videoSize` is `nil` until
    /// the platform player has reported the picture's size.
    static func placement(
        mode: BridgeScalingMode, factor: Double, videoSize: CGSize?, viewport: CGSize,
        backingScale: CGFloat
    ) -> Placement {
        if normalizedFactor(factor) == 1 {
            switch mode {
            case .fill: return .gravity(.resizeAspectFill)
            case .match: return .gravity(.resizeAspect)
            case .stretch: return .gravity(.resize)
            case BridgeScalingMode.none: break
            }
        }
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return .pending }
        let rect = pictureRect(
            mode: mode, factor: factor, videoSize: videoSize, viewport: viewport,
            backingScale: backingScale)
        let scale = CGFloat(normalizedFactor(Double(backingScale)))
        return .frame(
            CGRect(
                x: CGFloat(rect.x) / scale, y: CGFloat(rect.y) / scale,
                width: CGFloat(rect.width) / scale, height: CGFloat(rect.height) / scale))
    }

    /// `lround`: halves away from zero, held inside 32 bits so an absurd scale
    /// factor produces an absurd rectangle instead of a trap.
    private static func rounded(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), Double(Int32.min)), Double(Int32.max)))
    }
}
