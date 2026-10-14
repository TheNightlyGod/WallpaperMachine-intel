import CoreGraphics
import Foundation

/// The scale factor that makes Fill crop baked-in black bars off the screen.
///
/// The engine's Fill layout (`ComputeWallpaperScalingLayout`) scales the video by
/// `max(displayWidth / videoWidth, displayHeight / videoHeight) * userFactor` and centres it,
/// so how much of the picture is visible at factor 1 depends on the display's proportions:
/// a 21:9 screen already crops the top and bottom of a 16:9 video, a 16:10 one crops its sides.
/// The factor is therefore computed for one display, from the bars the probe measured.
enum LetterboxZoom {
  enum Outcome: Equatable, Sendable {
    /// Fill alone already crops the bars (within `alreadyHiddenBelow`).
    case alreadyHidden
    /// The scale factor to set, rounded up to two decimals.
    case factor(Double)
    /// Hiding the bars would need more than `maximumFactor`, or the inputs make no sense.
    case implausible
  }

  /// Half a percent of overscan, so codec ringing at the edge of a bar stays off screen.
  static let overscan = 1.005
  /// A raw requirement within one percent of 1 is not worth a change.
  static let alreadyHiddenBelow = 1.01
  static let maximumFactor = 3.0

  /// `aspect` is the decoded frame's width over height, `viewport` the target display's size.
  /// Bars are the fractions from `LetterboxDetector`.
  static func outcome(bars: LetterboxDetector.Bars, aspect: Double, viewport: CGSize) -> Outcome {
    let displayAspect = viewport.height > 0 ? Double(viewport.width / viewport.height) : 0
    guard aspect.isFinite, aspect > 0, displayAspect.isFinite, displayAspect > 0 else { return .implausible }
    // The share of the video's width and height that Fill shows at factor 1.
    let visibleX = min(1, displayAspect / aspect)
    let visibleY = min(1, aspect / displayAspect)
    // The share of each dimension that is picture; opposite bars are cut from both ends.
    let pictureX = 1 - 2 * max(bars.left, bars.right)
    let pictureY = 1 - 2 * max(bars.top, bars.bottom)
    guard pictureX > 0, pictureY > 0 else { return .implausible }
    let required = max(visibleX / pictureX, visibleY / pictureY, 1)
    if required <= alreadyHiddenBelow { return .alreadyHidden }
    // The epsilon keeps a product that is 134 up to rounding error from becoming 1.35.
    let factor = (required * overscan * 100 - 1e-9).rounded(.up) / 100
    return factor > maximumFactor ? .implausible : .factor(factor)
  }
}
