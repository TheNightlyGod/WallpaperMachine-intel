#include "MetalRender/MetalVideoSupport.hpp"

#include "Scene/Scene.h"

#include <atomic>

namespace wallpaper::metal
{
namespace
{

/// Off by default: the pre-converted path is what every Metal scene has been
/// drawing, and a new sampling path becomes the default only once someone has
/// looked at real wallpapers through it.
std::atomic<bool> g_video_plane_sampling_enabled { false };

} // namespace

void SetMetalVideoPlaneSamplingEnabled(bool enabled)
{
    g_video_plane_sampling_enabled.store(enabled, std::memory_order_relaxed);
}

bool MetalVideoPlaneSamplingEnabled()
{
    return g_video_plane_sampling_enabled.load(std::memory_order_relaxed);
}

std::string MetalVideoTextureRejection(const Scene& scene, const std::string& texture_name)
{
    const auto iterator = scene.textures.find(texture_name);
    // A texture the scene never described is not a claim of anything. The
    // parser resolves it later, and the frames decide.
    if (iterator == scene.textures.end()) return {};

    const SceneTexture& texture = iterator->second;
    if (! texture.isVideo) return {};

    // A sprite sheet is played by stepping frames of one uploaded image; a
    // video texture that is also one would need both, and this path only ever
    // produces the video frame.
    if (texture.isSprite) return "the video texture is an animated sprite sheet";

    if (texture.url.empty()) return "the video texture names no media";

    return {};
}

} // namespace wallpaper::metal
