import Foundation

/// Wallpaper Engine's per-wallpaper options as a renderer the app drives itself takes them: the
/// colour adjustments, the image filter (a colour lookup table), the horizontal flip, the
/// mouse-parallax switch and the playback rate. Values are as saved: the colour sliders 0...100
/// around 50, the filter strength 0...100 and the playback rate 10...200 percent
/// (`wallpaper64.exe` `sub_140104B60`). `identity` changes nothing.
struct WallpaperEngineOptions: Codable, Equatable, Sendable {
  var colorEnabled = false
  var brightness: Double = 50
  var contrast: Double = 50
  var saturation: Double = 50
  var hueShift: Double = 50
  /// A file stem under the shared assets' `materials/lut`; empty for none.
  var imageFilter = ""
  var filterStrength: Double = 100
  var flipHorizontal = false
  var mouseParallax = true
  var playbackRate: Double = 100

  static let identity = WallpaperEngineOptions()

  /// The colour adjustments leave the picture as it is: switched off, or every slider at 50.
  var isColorIdentity: Bool {
    !colorEnabled || [brightness, contrast, saturation, hueShift].allSatisfy { $0 == 50 }
  }

  /// No image filter is drawn: none chosen, or its strength is 0.
  var isFilterIdentity: Bool { imageFilter.isEmpty || filterStrength <= 0 }
}

/// The scene quality settings as the renderer takes them (`owe_scene_quality`): an MSAA sample
/// count of 0, 2, 4 or 8, shadow and volumetric levels 0 (off) to 4 (ultra), reflections, and the
/// post-processing level (0 disabled, 2 enabled, 4 ultra, 5 Display HDR).
struct SceneQualitySettings: Codable, Equatable, Sendable {
  var msaa: Int32 = 0
  var shadows: Int32 = 2
  var volumetrics: Int32 = 2
  var reflection = true
  var postProcessing: Int32 = 2

  /// Wallpaper Engine's first-run "medium" preset.
  static let wallpaperEngineDefault = SceneQualitySettings()
}
