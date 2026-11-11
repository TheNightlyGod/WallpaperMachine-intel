#pragma once

namespace wallpaper::metal
{

/// Whether a scene drawn below full resolution is brought back to full size by
/// MetalFX before it is composed, instead of being stretched by the
/// composition's bilinear sample.
///
/// Process-wide and off unless it is turned on. It changes nothing at render
/// scale 1, where there is nothing to bring back; below it, each presented
/// frame runs one MetalFX spatial pass and keeps one image the size the scene
/// would have at full resolution. A frame that cannot use MetalFX (a format it
/// does not take, a scaler that could not be made) is composed the old way.
void SetMetalUpscalingEnabled(bool enabled);
[[nodiscard]] bool MetalUpscalingEnabled();

/// Makes every scaler from now on answer as a GPU without MetalFX's spatial scaler does, so
/// the fallback can be tested on a machine that has one. Tests only.
void SetMetalUpscalerUnsupportedForTests(bool unsupported);

} // namespace wallpaper::metal
