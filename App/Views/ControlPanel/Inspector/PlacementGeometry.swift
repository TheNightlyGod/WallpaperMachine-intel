import CoreGraphics
import Foundation

/// The arithmetic of the Position on screen frame: how the picture sits in a frame that has the
/// target display's proportions, what a drag or a key press does to it, and the limits of its
/// values. A port of `placement.js`, not of `StillImagePlacement.projection`, which differs on
/// purpose: that one works from the display's viewport, treats Original size as a scale of 1 and
/// ignores the fallback for a picture whose pixel size is unknown.
enum PlacementGeometry {
  static let zoomRange = 1.0...3.0
  /// A frame for a display whose shape is unknown.
  static let fallbackAspect = 1.6
  /// The smallest overflow, in points, that makes the picture something to drag.
  static let overflowThreshold = 0.5
  static let keyStep = 0.01
  static let largeKeyStep = 0.05
  /// A key press waits this long for the next before it is saved.
  static let keyDebounce: Duration = .milliseconds(400)

  /// A fraction held to 0...1; a value that is not a number is `fallback`.
  static func fraction(_ value: Double?, fallback: Double) -> Double {
    guard let value, value.isFinite else { return fallback }
    return min(1, max(0, value))
  }

  static func zoom(_ value: Double?) -> Double {
    guard let value, value.isFinite else { return 1 }
    return min(zoomRange.upperBound, max(zoomRange.lowerBound, value))
  }

  /// Values are sent to three decimals.
  static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

  /// The frame's width over its height: the display's own shape, else its viewport's, else 1.6.
  static func stageAspect(displayAspect: Double?, viewport: CGSize?) -> Double {
    if let displayAspect, displayAspect > 0, displayAspect.isFinite { return displayAspect }
    if let viewport, viewport.width > 0, viewport.height > 0 { return viewport.width / viewport.height }
    return fallbackAspect
  }

  /// The picture's box inside the frame, in frame points.
  struct Box: Equatable {
    let stage: CGSize
    let size: CGSize
    let origin: CGPoint
    let x: Double
    let y: Double

    /// How far the box overflows the frame on each axis (negative when it is smaller).
    var overflow: CGSize { CGSize(width: size.width - stage.width, height: size.height - stage.height) }
    /// The picture is larger than the frame on some axis, so it can be dragged.
    var isPannable: Bool {
      size.width > stage.width + PlacementGeometry.overflowThreshold
        || size.height > stage.height + PlacementGeometry.overflowThreshold
    }
  }

  /// How the wallpaper page sizes the picture for the chosen fit, times the zoom, with the overflow
  /// aligned by `x` and `y` the way `object-position` aligns it (0 keeps the leading edge in view,
  /// 1 the trailing edge). Nil while the frame has no size or the picture's proportions are unknown.
  ///
  /// - Parameters:
  ///   - imageAspect: width over height; the caller falls back to the loaded image's own.
  ///   - imagePixelSize, viewportSize: for Original size, which draws the picture at its pixel width
  ///     as a share of the display's width.
  static func box(
    stage: CGSize, imageAspect: Double?, fit: StillImageWallpaper.Fit?, imagePixelSize: CGSize?,
    viewportSize: CGSize?, x: Double, y: Double, zoom: Double
  ) -> Box? {
    guard stage.width > 0, stage.height > 0, let aspect = imageAspect, aspect > 0, aspect.isFinite
    else { return nil }
    let base: Double
    if fit == .center, let pixels = imagePixelSize, pixels.width > 0, let viewport = viewportSize,
      viewport.width > 0
    {
      base = pixels.width * (stage.width / viewport.width)
    } else if fit == .fit || fit == .blur || fit == .center {
      base = min(stage.width, stage.height * aspect)
    } else {
      base = max(stage.width, stage.height * aspect)
    }
    let width = base * zoom
    let height = width / aspect
    return Box(
      stage: stage, size: CGSize(width: width, height: height),
      origin: CGPoint(x: (stage.width - width) * x, y: (stage.height - height) * y), x: x, y: y)
  }

  /// Dragging the picture right shows more of its left side, so the fraction falls: inverse. An
  /// axis the picture does not overflow does not move.
  static func dragged(
    from start: (x: Double, y: Double), overflow: CGSize, translation: CGSize
  ) -> (x: Double, y: Double) {
    var x = start.x
    var y = start.y
    if overflow.width > overflowThreshold {
      x = min(1, max(0, start.x - translation.width / overflow.width))
    }
    if overflow.height > overflowThreshold {
      y = min(1, max(0, start.y - translation.height / overflow.height))
    }
    return (x, y)
  }

  /// A press moves the picture by a hundredth, a Shift press by five hundredths.
  static func nudged(x: Double, y: Double, dx: Int, dy: Int, large: Bool)
    -> (x: Double, y: Double)
  {
    let step = large ? largeKeyStep : keyStep
    return (
      min(1, max(0, x + Double(dx) * step)), min(1, max(0, y + Double(dy) * step))
    )
  }

  /// A drag that moved by no more than two points in total is a click, which restores the values
  /// the drag started from.
  static func isDrag(_ translation: CGSize) -> Bool {
    abs(translation.width) + abs(translation.height) > 2
  }
}
