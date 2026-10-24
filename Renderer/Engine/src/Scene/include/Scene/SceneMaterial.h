#pragma once
#include <array>
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

/// What the colour of a layer's `g_Color4` is made of. Wallpaper Engine multiplies
/// the layer's colour by its brightness where the scene renders HDR -- the brightness
/// is 1 here everywhere else -- and either may change while the scene runs (a user
/// property, a script), so the product is built again from both.
struct SceneMaterialTint {
    std::array<float, 3> color { 1.0f, 1.0f, 1.0f };
    float                brightness { 1.0f };
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

    /// Per texture slot, the cover the slot shows once one is published
    /// (`$mediaThumbnail` or `$mediaPreviousThumbnail`), and empty for every other
    /// slot; empty altogether when no slot is one. Only a slot whose authored
    /// texture is another layer's composite is listed: the slot keeps sampling that
    /// composite (its entry in `textures`) until a cover exists. A slot over a
    /// picture is a runtime image of its own and needs no entry.
    std::vector<std::string> cover_slots;

    SceneMaterialCustomShader customShader;
    /// Set on the materials that take a layer's `g_Color4`; the rest keep white.
    SceneMaterialTint         tint;
    /// An effect's `g_UserAlpha` is the effect's own opacity (`"material": "alpha"`
    /// in its shader, `alpha` in its constants), not the layer's: it starts from the
    /// layer's authored alpha, as every pass of the layer does, and an `alpha` the
    /// effect sets replaces that. The layer's alpha is applied by the layer's own
    /// pass and the effect's multiplies it, so whatever drives the layer's alpha, a
    /// property, a script or a timeline, leaves it alone. Set on the passes of a
    /// layer's effects.
    bool                      own_user_alpha { false };
    BlendMode                 blenmode { BlendMode::Disable };
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
/// transparent texels included. As in Direct3D, OpenGL and Metal, a draw that
/// does not depth-test writes no depth, and a target without a depth
/// attachment draws in painter's order.
[[nodiscard]] inline SceneDepthState ResolveSceneDepthState(const SceneMaterial& material,
                                                            bool target_has_depth) {
    const bool test = target_has_depth && material.depth_test;
    return { .test = test, .write = test && material.depth_write };
}
} // namespace wallpaper
