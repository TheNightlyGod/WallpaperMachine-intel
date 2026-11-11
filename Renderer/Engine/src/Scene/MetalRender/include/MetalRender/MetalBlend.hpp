#pragma once

#include "Type.hpp"

#include <cstdint>

namespace wallpaper::metal
{

/// Mirror of `MTLBlendFactor`, so blend mapping can be written and tested
/// without a Metal device or an Objective-C translation unit. `MetalRender.mm`
/// static-asserts every enumerator against the real framework value, which is
/// what keeps this mirror honest.
enum class MetalBlendFactor : uint32_t
{
    Zero = 0,
    One = 1,
    SourceColor = 2,
    OneMinusSourceColor = 3,
    SourceAlpha = 4,
    OneMinusSourceAlpha = 5,
    DestinationColor = 6,
    OneMinusDestinationColor = 7,
    DestinationAlpha = 8,
    OneMinusDestinationAlpha = 9,
};

/// Mirror of `MTLBlendOperation`.
enum class MetalBlendOperation : uint32_t
{
    Add = 0,
    Subtract = 1,
    ReverseSubtract = 2,
    Min = 3,
    Max = 4,
};

/// Mirror of `MTLCullMode`.
enum class MetalCullMode : uint32_t
{
    None = 0,
    Front = 1,
    Back = 2,
};

/// The cull mode a render pass starts with, before a draw sets its material's
/// (`SceneMetalCullMode`). Named here rather than written at the call site so
/// the invariant can be asserted.
inline constexpr MetalCullMode kSceneCullMode = MetalCullMode::None;

/// Whether the front face of a culled pass is the counter-clockwise one.
///
/// Counter-clockwise faces are the front ones on Metal's unflipped viewport,
/// which is the winding authors' meshes are written in. Any clip-space transform folded into the projection
/// that mirrors an axis would reverse it, which is why it is named.
inline constexpr bool kSceneFrontFaceCounterClockwise = true;

/// The cull mode a material asks for. WE applies it whether or not the target has
/// depth: a 2D canvas culls a `cullmode normal` card mirrored by a negative scale
/// (WE probe ordinary-cull-v1).
[[nodiscard]] constexpr MetalCullMode SceneMetalCullMode(CullMode material_cull_mode)
{
    switch (material_cull_mode) {
    case CullMode::Front: return MetalCullMode::Front;
    case CullMode::Back: return MetalCullMode::Back;
    case CullMode::None: break;
    }
    return MetalCullMode::None;
}

/// The colour-attachment blend state for one authored blend mode.
struct MetalBlendState
{
    bool                blending_enabled { false };
    MetalBlendOperation rgb_operation { MetalBlendOperation::Add };
    MetalBlendOperation alpha_operation { MetalBlendOperation::Add };
    MetalBlendFactor    source_rgb { MetalBlendFactor::One };
    MetalBlendFactor    destination_rgb { MetalBlendFactor::Zero };
    MetalBlendFactor    source_alpha { MetalBlendFactor::One };
    MetalBlendFactor    destination_alpha { MetalBlendFactor::Zero };
    /// Authored `alphatocoverage` asks for coverage from alpha in addition to
    /// the blend factors, so it is carried alongside rather than folded in.
    bool                alpha_to_coverage { false };

    friend bool operator==(const MetalBlendState&, const MetalBlendState&) = default;
};

/// Translates an authored blend mode to Metal state, factor for factor as
/// Wallpaper Engine 2.8.0.42 blends (`sub_140099F60`).
///
/// `BlendMode::Normal` is ONE / ZERO, an opaque replace. It is not Porter-Duff
/// source-over despite the name, and turning it into source-over would change
/// every scene that uses it.
/// `BlendMode::Translucent` blends alpha with the colour's factors, SRC_ALPHA /
/// INV_SRC_ALPHA, under `AlphaBlendRule::Material`; `AlphaBlendRule::SourceOver`
/// gives ONE / INV_SRC_ALPHA instead. `AlphaBlendRule::Max` turns the alpha of a
/// translucent or additive draw into MAX(As, Ad), as Wallpaper Engine draws the
/// children of a layer without copybackground; it leaves unblended modes alone.
/// Single-sample targets use translucent blending instead of a nonexistent
/// coverage mask.
[[nodiscard]] MetalBlendState ToMetalBlendState(BlendMode mode,
                                                AlphaBlendRule alpha_rule = AlphaBlendRule::Material,
                                                std::uint32_t sample_count = 1);

} // namespace wallpaper::metal
