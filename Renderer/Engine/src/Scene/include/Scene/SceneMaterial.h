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
struct ShadowMaterialVariants;

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
    /// Optional, bounded on/off programs for a scene whose configured lights support shadows.
    std::shared_ptr<ShadowMaterialVariants> shadow_variants;
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
    /// The authored `alphawriting`: whether the draw writes alpha into its target.
    AlphaWriting              alpha_writing { AlphaWriting::Default };
};

/// How a depth-tested draw compares its depth with the target's. The scene draws with
/// standard depth (nearer is smaller); the shadow atlas is drawn reversed, as Wallpaper
/// Engine's device draws every depth (C-6.md): nearer is greater, cleared to 0.
enum class DepthCompare : uint8_t
{
    LessEqual,
    GreaterEqual,
    Greater
};

/// Whether one draw depth-tests, whether it writes depth, and how it compares.
struct SceneDepthState {
    bool         test { false };
    bool         write { false };
    DepthCompare compare { DepthCompare::LessEqual };
};

/// The depth state of a draw of `material` with the blending `draw_blend` into
/// a target with or without a depth attachment (`SceneRenderTarget::withDepth`)
/// -- the one rule both renderers follow.
///
/// A material's `depthtest` and `depthwrite` words only switch depth off;
/// Wallpaper Engine's device picks the depth-stencil state from those two
/// flags and the draw's blend mode (`sub_140099F60`: index = depth flags |
/// (mode is neither `normal` nor `alphatocoverage`)), so a draw that blends --
/// translucent or additive -- never writes depth, whatever its material says,
/// and still tests it. A `normal`, `alphatocoverage` or unblended draw writes
/// depth when its material asks. Its frames agree
/// (`artifacts/we-parity/probes/depth-probe`): a nearer translucent card
/// authored with both enabled, at any alpha, does not hide a farther card drawn
/// after it; a nearer `normal` one does, and the farther translucent card is
/// hidden by it, so it tests. As in Direct3D, OpenGL and Metal, a draw that does
/// not depth-test writes no depth, and a target without a depth attachment
/// draws in painter's order.
[[nodiscard]] inline SceneDepthState ResolveSceneDepthState(const SceneMaterial& material,
                                                            BlendMode           draw_blend,
                                                            bool target_has_depth) {
    const bool test   = target_has_depth && material.depth_test;
    const bool blends = draw_blend == BlendMode::Translucent || draw_blend == BlendMode::Additive;
    return { .test = test, .write = test && material.depth_write && ! blends };
}
} // namespace wallpaper
