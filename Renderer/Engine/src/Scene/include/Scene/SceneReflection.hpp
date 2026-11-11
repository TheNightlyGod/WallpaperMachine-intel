#pragma once

#include <memory>
#include <string_view>

namespace wallpaper {
class Scene;
class SceneCamera;
class SceneNode;

inline constexpr std::string_view kReflectionTarget = "_rt_Reflection";
inline constexpr std::string_view kReflectionCamera = "__reflection";

struct SceneReflection {
    bool requested { false };
    // The ordinary view remains the shader's forward source while the renderer
    // temporarily makes the reflected camera active for other global uniforms.
    const SceneCamera* source_camera { nullptr };
    std::shared_ptr<SceneCamera> camera;
    std::shared_ptr<SceneNode> camera_node;
};

/// Wallpaper Engine allocates the sampled planar picture as rgb888, independently
/// of HDR and MSAA, and renders it through its active view reflected about world y=0.
void EnsureSceneReflectionTarget(Scene& scene, int width, int height);
void PrepareSceneReflection(Scene& scene, bool requested);
void UpdateSceneReflection(Scene& scene);
}
