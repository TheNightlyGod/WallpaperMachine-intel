#include "MetalRender/MetalBackendRouter.hpp"

#include "MetalRender/MetalCapability.hpp"

namespace wallpaper::metal
{

SceneBackendSelection SelectSceneBackend(const Scene& scene)
{
    return EvaluateMetalSupport(scene);
}

SceneBackendSelection NativeRefusal(std::string reason)
{
    if (reason.empty()) reason = "the native renderer does not support this wallpaper";
    SceneBackendSelection refused;
    refused.failure_stage  = SceneFailureStage::Unsupported;
    refused.failure_reason = std::move(reason);
    return refused;
}

} // namespace wallpaper::metal
