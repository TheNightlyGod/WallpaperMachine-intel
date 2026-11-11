import CoreGraphics
import Foundation

extension WallpaperEngineOptions {
  /// The bridge's values, as saved for a wallpaper or shown while it is edited.
  init(_ values: BridgeEngineOptionValues) {
    self.init(
      colorEnabled: values.colorEnabled, brightness: values.brightness, contrast: values.contrast,
      saturation: values.saturation, hueShift: values.hueShift, imageFilter: values.imageFilter,
      filterStrength: values.filterStrength, flipHorizontal: values.flipHorizontal,
      mouseParallax: values.mouseParallax, playbackRate: values.playbackRate)
  }
}

extension SceneQualitySettings {
  init(_ quality: BridgeSceneQuality) {
    func level(_ value: BridgeQualityLevel) -> Int32 {
      switch value {
      case .off: 0
      case .low: 1
      case .medium: 2
      case .high: 3
      case .ultra: 4
      }
    }
    let msaa: Int32 =
      switch quality.msaa {
      case .off: 0
      case .x2: 2
      case .x4: 4
      case .x8: 8
      }
    let postProcessing: Int32 =
      switch quality.postProcessing {
      case .disabled: 0
      case .enabled: 2
      case .ultra: 4
      case .displayHdr: 5
      }
    self.init(
      msaa: msaa, shadows: level(quality.shadows), volumetrics: level(quality.volumetrics),
      reflection: quality.reflections, postProcessing: postProcessing)
  }
}

extension BridgeRgb {
  /// A border colour the bridge read from a project's `schemecolor`, authored as sRGB 0...1.
  var cgColor: CGColor {
    CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
  }
}
