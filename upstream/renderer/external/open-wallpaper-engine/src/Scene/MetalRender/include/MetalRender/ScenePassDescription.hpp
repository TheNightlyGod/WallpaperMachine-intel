#pragma once

#include "MetalRender/MetalBlend.hpp"
#include "MetalRender/MetalCapability.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace wallpaper
{
class Scene;
class SceneNode;

namespace rg
{
class RenderGraph;
}

namespace metal
{

/// Mirror of `MTLLoadAction`, for the same reason as `MetalBlendFactor`:
/// the description has to be buildable and testable without Metal.
enum class MetalLoadAction : uint32_t
{
    DontCare = 0,
    Load = 1,
    Clear = 2,
};

/// Mirror of the `MTLPixelFormat` values this backend can render into.
/// `Invalid` is zero so a forgotten assignment is visibly wrong.
enum class MetalPixelFormat : uint32_t
{
    Invalid = 0,
    RGBA8Unorm = 70,
    RGBA8Unorm_sRGB = 71,
    BGRA8Unorm = 80,
    BGRA8Unorm_sRGB = 81,
    RGBA16Float = 115,
    Depth32Float = 252,
};

/// Mirror of `MTLCompareFunction` for the two values this backend writes.
enum class MetalDepthCompare : uint32_t
{
    Never = 0,
    LessEqual = 3,
};

/// One step of the frame, in terms a backend can execute without knowing how
/// the scene was authored.
///
/// Deliberately small: it carries what a first Metal backend needs and nothing
/// else. The scene objects a draw needs every frame -- the node whose transform
/// and material constants move -- are referenced, not copied, because copying
/// them would freeze exactly the values that are supposed to change.
struct ScenePassDescription
{
    MetalPassKind kind { MetalPassKind::Unsupported };
    std::string   name;

    // ---- target
    /// Resolved render-target key. Empty for a pass that produces no pixels.
    std::string          target_key;
    uint32_t             target_width { 0 };
    uint32_t             target_height { 0 };
    MetalLoadAction      load_action { MetalLoadAction::DontCare };
    std::array<float, 4> clear_color { 0.0f, 0.0f, 0.0f, 0.0f };
    bool uses_scene_clear_color { false };

    // ---- Copy
    std::string source_key;
    /// Size of the copy's source. Carried because a copy between two targets of
    /// different size is a resample, not a blit, and the executor cannot tell
    /// the two apart from the destination alone.
    uint32_t    source_width { 0 };
    uint32_t    source_height { 0 };

    /// Set on the pass after which a mip-mapped target's smaller levels have to
    /// be regenerated: the last writer before the first reader in the frame, or
    /// the final writer. The pass that writes level 0 does not produce the rest,
    /// so an effect that samples a coarse level would otherwise read whatever
    /// the level held before.
    bool generate_mipmaps { false };

    // ---- CustomShader
    SceneNode*               node { nullptr };
    SceneNode*               visibility_node { nullptr };
    uint32_t                 material_slot { 0 };
    std::size_t              submesh_index { 0 };
    std::string              camera_override;
    BlendMode                blend { BlendMode::Disable };
    bool                     write_alpha { true };
    bool                     depth_test { false };
    bool                     depth_write { false };
    /// The faces this draw discards; see `SceneMetalCullMode`.
    MetalCullMode            cull_mode { kSceneCullMode };
    /// One entry per material texture slot, in slot order. An empty string is
    /// a slot the material leaves unbound, which must stay an empty slot
    /// rather than collapsing and shifting every later binding.
    std::vector<std::string> texture_keys;
    /// Per slot, the cover bound in place of that slot's render target while
    /// one is published (`SceneMaterial::texture_covers`); empty, or shorter
    /// than `texture_keys`, for slots that always sample what they name.
    std::vector<std::string> cover_keys;
};

/// Identity of a pipeline state, so one is built per distinct combination and
/// never inside a frame.
///
/// Blend mode and target pixel format are part of the key because Metal bakes
/// both into the pipeline: two passes that share a shader but differ in either
/// need two pipelines, and reusing one would either blend wrongly or fail
/// validation against the attachment.
struct MetalPipelineKey
{
    /// Identity of the translated shader program, stable for the lifetime of
    /// the compiled graph.
    uint64_t         program_id { 0 };
    /// Identity of the vertex buffer layout the submesh presents.
    uint64_t         vertex_layout_id { 0 };
    MetalBlendState  blend {};
    MetalPixelFormat color_format { MetalPixelFormat::Invalid };
    MetalPixelFormat depth_format { MetalPixelFormat::Invalid };
    MetalDepthCompare depth_compare { MetalDepthCompare::Never };
    uint32_t         sample_count { 1 };
    bool             write_alpha { true };
    bool             depth_test { false };
    bool             depth_write { false };

    friend bool operator==(const MetalPipelineKey&, const MetalPipelineKey&) = default;
};

struct MetalPipelineKeyHash
{
    std::size_t operator()(const MetalPipelineKey& key) const noexcept;
};

/// Lowers the render graph the compatibility backend consumes into the pass
/// list this backend executes. One graph, two backends: the ordering, the
/// load/store decisions and the per-target clear behaviour are the graph's, not
/// this function's.
///
/// Returns false and fills `error` on anything it does not recognise, which is
/// how an unsupported construct becomes a whole-scene fallback instead of a
/// silently skipped draw.
///
/// `scene` is mutable because a copy's destination may be a graph-internal
/// target the parser never declared -- the link textures and the copies that
/// break a read-while-write are named by the graph builder. The compatibility
/// backend registers those in `Scene::renderTargets` from their source when it
/// prepares the copy; this does the same, so both backends allocate the same
/// set of images at the same sizes.
bool BuildScenePassDescriptions(Scene& scene, const rg::RenderGraph& graph,
                                std::vector<ScenePassDescription>& out, std::string* error);

} // namespace metal
} // namespace wallpaper
