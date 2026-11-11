import Foundation

/// Hands Wallpaper Engine's per-wallpaper options and the scene quality to a scene renderer the
/// app drives itself. Set before `owe_scene_wallpaper_apply_config`, both are in force for the
/// first frame; options set on a loaded scene are applied live.
enum SceneEngineOptionsBinding {
  /// The renderer's status for each call: 0 is accepted.
  static func apply(_ options: WallpaperEngineOptions, to renderer: OpaquePointer) -> Int32 {
    options.imageFilter.withCString { lut in
      var value = owe_user_options(
        color_enabled: options.colorEnabled, brightness: Float(options.brightness),
        contrast: Float(options.contrast), saturation: Float(options.saturation),
        hue: Float(options.hueShift), lut: lut, lut_strength: Float(options.filterStrength),
        flip_horizontal: options.flipHorizontal, mouse_parallax: options.mouseParallax,
        playback_rate: Float(options.playbackRate))
      return owe_scene_wallpaper_set_user_options(renderer, &value)
    }
  }

  static func apply(_ quality: SceneQualitySettings, to renderer: OpaquePointer) -> Int32 {
    var value = owe_scene_quality(
      msaa: quality.msaa, shadows: quality.shadows, volumetrics: quality.volumetrics,
      reflection: quality.reflection, post_processing: quality.postProcessing)
    return owe_scene_wallpaper_set_quality(renderer, &value)
  }
}
