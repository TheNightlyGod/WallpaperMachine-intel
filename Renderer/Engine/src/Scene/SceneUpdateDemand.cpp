#include "Scene/include/Scene/SceneUpdateDemand.hpp"

#include <atomic>

namespace wallpaper
{
namespace
{
/// Off by default. Stopping a wallpaper's clock changes what the user sees
/// happen, so it is opted into. Read on the render thread once per frame; a
/// relaxed load is the whole cost.
std::atomic<bool> g_scene_on_demand_enabled { false };
} // namespace

void SetSceneOnDemandEnabled(bool enabled)
{
    g_scene_on_demand_enabled.store(enabled, std::memory_order_relaxed);
}

bool SceneOnDemandEnabled()
{
    return g_scene_on_demand_enabled.load(std::memory_order_relaxed);
}

} // namespace wallpaper
