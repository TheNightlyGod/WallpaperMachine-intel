#pragma once
#include <string>
#include <vector>
#include <memory>
#include <unordered_set>

#include "SceneShader.h"
#include "Type.hpp"

namespace wallpaper
{

struct SceneMaterialCustomShader {
    std::shared_ptr<SceneShader> shader;
    ShaderValues                 constValues;
};

struct SceneMaterial {
public:
    SceneMaterial()                     = default;
    SceneMaterial(const SceneMaterial&) = default;
    SceneMaterial(SceneMaterial&&)      = default;
    SceneMaterial& operator=(SceneMaterial&&) = default;

    std::string              name;
    std::vector<std::string> textures;
    std::vector<std::string> defines;

    bool hasSprite { false };

    SceneMaterialCustomShader customShader;
    BlendMode                 blenmode { BlendMode::Disable };
    /// Authored `depthtest` other than disabled/enabled/less/lessorequal.
    /// Presence is a whole-scene Metal fallback, not a silent disable.
    bool                      depth_compare_unsupported { false };
    /// As authored. A renderer draws with `ResolveSceneDepthState`, not these.
    bool                      depth_test { false };
    bool                      depth_write { false };
    CullMode                  cull_mode { CullMode::None };
};

/// Whether one draw depth-tests and whether it writes depth.
struct SceneDepthState {
    bool test { false };
    bool write { false };
};

/// The depth state of a draw of `material` into a target with or without a
/// depth attachment (`SceneRenderTarget::withDepth`) -- the one rule both
/// renderers follow.
///
/// Wallpaper Engine applies a material's `depthtest` and `depthwrite` as
/// authored, whatever its blending: its own depth-tested font materials are
/// translucent and write depth. A translucent or additive draw that asks to
/// write depth therefore hides what is drawn behind it afterwards, its
/// transparent texels included. As in Direct3D, OpenGL and Vulkan, a draw that
/// does not depth-test writes no depth, and a target without a depth
/// attachment draws in painter's order.
[[nodiscard]] inline SceneDepthState ResolveSceneDepthState(const SceneMaterial& material,
                                                            bool target_has_depth) {
    const bool test = target_has_depth && material.depth_test;
    return { .test = test, .write = test && material.depth_write };
}
} // namespace wallpaper
