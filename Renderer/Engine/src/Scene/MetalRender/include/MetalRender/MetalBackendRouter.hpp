#pragma once

#include "Scene/SceneBackendSelection.hpp"

#include <string>

namespace wallpaper
{
class Scene;

namespace metal
{

/// Decides whether a scene can be drawn, once, before a renderer is created.
///
/// Native Metal is the only renderer, so this is the capability gate and
/// nothing else: a scene it refuses comes back with `failure_stage`
/// `Unsupported` and the gate's own reason as `failure_reason`. Nothing is
/// remembered between calls, so asking again (a retry) really evaluates the
/// scene afresh.
[[nodiscard]] SceneBackendSelection SelectSceneBackend(const Scene& scene);

/// What a scene gets when the native backend refuses it for `reason`: no
/// renderer and the reason as an `Unsupported` failure. The one place that
/// turns a refusal into a selection, so the capability gate and anything
/// standing in for it agree.
[[nodiscard]] SceneBackendSelection NativeRefusal(std::string reason);

} // namespace metal
} // namespace wallpaper
