#pragma once

#include "Scene/include/Scene/SceneVideoPath.hpp"

#include <cstdint>
#include <string>

namespace wallpaper
{
class Scene;

namespace metal
{

/// The renderer-local name for the scene-level report. One definition, in the
/// layer the wallpaper and the host binding can both see.
using VideoFramePath = wallpaper::SceneVideoPath;

/// Why this scene's video texture cannot be played by the native backend, or
/// empty when nothing about it is known to be unsupported.
///
/// This is the compile-time half of the answer and it only reads what the scene
/// already recorded: no decoder is opened, no media is probed and nothing here
/// touches Metal, so it stays usable from the capability gate. A format the
/// decoder actually produces is a different question and is answered where the
/// frames are — `MetalVideoTextures::prepare` rejects the pixel formats the
/// import cannot handle, with the frame in hand.
[[nodiscard]] std::string MetalVideoTextureRejection(const Scene&       scene,
                                                     const std::string& texture_name);

/// Whether a material that can sample a video's NV12 planes directly is allowed
/// to do so, instead of sampling one pre-converted image.
///
/// Off unless it is turned on. It selects between two programs that were both
/// compiled with the graph, so switching it costs a plan update at a frame
/// boundary and never a compile inside a frame. A material with no usable
/// plane variant, or a frame that is not 8-bit NV12, keeps converting whatever
/// this says.
void SetMetalVideoPlaneSamplingEnabled(bool enabled);
[[nodiscard]] bool MetalVideoPlaneSamplingEnabled();

} // namespace metal
} // namespace wallpaper
