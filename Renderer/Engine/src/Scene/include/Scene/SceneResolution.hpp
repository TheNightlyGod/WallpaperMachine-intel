#pragma once

#include <cstdint>

namespace wallpaper
{

/// How many pixels a 2D scene is rasterized with, before the internal render
/// scale is applied.
///
/// Only a scene with an authored canvas has the choice. A perspective scene
/// already rasterizes at the output size, and a plain video keeps the frame's
/// own size, so neither reads this.
enum class SceneResolution : uint8_t
{
    /// The authored canvas, whatever the display is. The picture is then
    /// stretched to the display when it is presented, which is the cheapest
    /// choice and the softest on a display with more pixels than the canvas.
    Canvas = 0,
    /// The size the canvas is presented at on the display, which is what
    /// Wallpaper Engine rasterizes. The canvas stays the source of every
    /// coordinate (layout, cursor, scripts, camera); only the raster behind
    /// them is finer.
    Display = 1,
};

/// The process-wide choice that every scene takes when its render graph is
/// built, and that a running scene re-reads when the host re-applies its
/// render scale. The engine's own default is the canvas, which is what every
/// harness that builds a scene without a host gets; the app pushes its
/// setting at startup.
void SetSceneResolution(SceneResolution resolution);
SceneResolution CurrentSceneResolution();

} // namespace wallpaper
