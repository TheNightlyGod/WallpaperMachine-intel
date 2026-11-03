#pragma once

namespace wallpaper::metal
{

/// SDR display framing (`scene_display_framing` under `[experimental]`): whether an SDR scene
/// at Display resolution whose canvas overhangs the display draws only the part of its
/// canvas-cover raster the composition shows (`render::SceneRasterWindow`), as Wallpaper
/// Engine's window-sized frame does, instead of the whole raster cropped.
///
/// Process-wide and off unless it is turned on. `WALLPAPER_MACHINE_SDR_FRAMING=1` or `=0`
/// overrides it either way, for an A/B in one binary. A running scene takes a change at its
/// next draw, which sizes its targets again in place; nothing is compiled. The getter answers
/// the setting, not the override.
void SetMetalSceneDisplayFramingEnabled(bool enabled);
[[nodiscard]] bool MetalSceneDisplayFramingEnabled();

} // namespace wallpaper::metal
