#include "Scene/include/Scene/SceneResolution.hpp"

#include <atomic>

namespace wallpaper
{
namespace
{
/// Read on the render thread when a graph is built or a render scale is
/// applied, never per frame, so a relaxed load is the whole cost.
std::atomic<SceneResolution> g_resolution { SceneResolution::Canvas };
} // namespace

void SetSceneResolution(SceneResolution resolution)
{
    g_resolution.store(resolution, std::memory_order_relaxed);
}

SceneResolution CurrentSceneResolution()
{
    return g_resolution.load(std::memory_order_relaxed);
}

} // namespace wallpaper
