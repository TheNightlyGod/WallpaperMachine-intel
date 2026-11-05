#pragma once

#include "MetalRender/MetalBlend.hpp"
#include "MetalRender/MetalCapability.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
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

/// Mirror of `MTLCompareFunction` for the values this backend writes.
enum class MetalDepthCompare : uint32_t
{
    Never = 0,
    LessEqual = 3,
    Greater = 4,
    GreaterEqual = 6,
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
    /// Stable logical owner of an atomic transparent-sorted pass group.
    SceneNode* sort_owner { nullptr };
    bool reflection_pass { false };
    /// A reserved prefix clear may be switched off when the first scene access writes.
    bool conditional_scene_clear { false };
    bool enabled { true };
    /// Reuse the scene's sampled depth in its existing color encoder, including
    /// a clear/background draw with depth testing disabled.
    bool scene_depth_attachment { false };
    bool reads_scene_depth { false };
    /// A draw that does not depth-test but takes its target's depth attachment all the same,
    /// with depth testing off, so it shares one render pass with the depth-tested draws around
    /// it (`ShareDepthAttachments`).
    bool shares_depth_attachment { false };

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
    /// See `DrawPass::Desc::alpha_rule`.
    AlphaBlendRule           alpha_rule { AlphaBlendRule::Material };
    /// The samples per pixel the draw's target asks for.
    uint32_t                 samples { 1 };
    bool                     force_single_sample { false };
    bool                     write_alpha { true };
    bool                     depth_test { false };
    bool                     depth_write { false };
    /// How a depth-tested draw compares: standard for the scene, reversed for the shadow atlas.
    MetalDepthCompare        depth_compare { MetalDepthCompare::LessEqual };
    /// The target is a depth image the draw writes depth into, with no colour attachment.
    bool                     depth_only { false };
    /// See `DrawPass::Desc::depth_bias_slope`.
    float                    depth_bias_slope { 0.0f };
    float                    depth_bias_clamp { 0.0f };
    /// The depth a depth-only draw that clears its target clears it to.
    float                    clear_depth { 0.0f };
    /// The part of the target drawn into, (x, y, width, height) fractions of it, y down.
    std::array<float, 4>     viewport { 0.0f, 0.0f, 1.0f, 1.0f };
    /// Front faces wind clockwise instead of counter-clockwise.
    bool                     flip_winding { false };
    /// The faces this draw discards; see `SceneMetalCullMode`.
    MetalCullMode            cull_mode { kSceneCullMode };
    /// One entry per material texture slot, in slot order. An empty string is
    /// a slot the material leaves unbound, which must stay an empty slot
    /// rather than collapsing and shifting every later binding.
    std::vector<std::string> texture_keys;
    /// The cover a slot swaps to while one is published, in slot order, or empty
    /// when no slot does; see `SceneMaterial::cover_slots`.
    std::vector<std::string> cover_keys;
    /// Per slot, in slot order (empty when no slot is): the slot names an `_alias_*` texture,
    /// which reads transparent black outside 0..1 (Wallpaper Engine 2.8.0.42 `sub_14009ACD0`:
    /// an alias wrapper samples its target with the BORDER flag 0x4000000, E-D6).
    std::vector<bool>        border_slots;
    /// Cookie aliases retain their live shared light selection across graph reuse.
    uint32_t                 light_cookie_slots { 0 };
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

/// Highest supported sample count no greater than requested. The mask contains
/// the sample-count bits 1, 2, 4 and 8; single-sample is always the fallback.
[[nodiscard]] uint32_t SelectSceneSampleCount(uint32_t requested, uint32_t supported_mask);

/// Four corners and the two triangles over them, in the order a draw issues them: the
/// geometry of a draw that may write every texel of its target (an effect pass's card).
struct MetalQuad
{
    std::array<std::array<float, 3>, 4> corners {};
    std::array<std::array<uint8_t, 3>, 2> triangles {};
};

/// Whether what a draw with `blend` leaves in a texel it covers is its fragment's output alone,
/// whatever the texel held: blending off without alpha to coverage, or `One`/`Zero` added. With
/// `One`/`Zero` the held value is still multiplied by zero, which is zero only when it is finite;
/// the caller decides whether the target's format can hold anything else.
[[nodiscard]] bool BlendReplacesDestination(const MetalBlendState& blend);

/// Whether what a draw with `blend` leaves in a texel is exactly what the texel held whenever
/// the fragment's alpha is 0 and its colour finite: the colour is added scaled by its own alpha
/// (`SourceAlpha`) onto the held colour kept whole (`One` or `OneMinusSourceAlpha`), and the
/// alpha is added as `As * As` or `As * 1` onto the held alpha kept whole, or is the larger of
/// the two (`Max`, which is the held alpha only where alpha is never negative). Blending off and
/// alpha to coverage write the fragment; a multiply scales the held colour by the fragment's.
/// The caller decides whether the target's format brings the held value back unchanged.
[[nodiscard]] bool BlendKeepsDestinationAtZeroAlpha(const MetalBlendState& blend);

/// For each description, `std::nullopt` or the passes whose drawing decides whether its clear is
/// seen at all: the clear (a clear step, or a draw that clears its target first) of a target
/// whose next frame, through every pass ahead of it in `order` until one clears the target
/// again, reads none of what it leaves, whatever those passes draw then; and which, in its own
/// frame, only draws read (sample it, or draw onto it without clearing) up to the target's next
/// clear: those are listed. A copy that reads the target makes its clear one that is always seen.
/// A clear ends the span only when it applies whatever is visible: not a clear that is switched
/// on and off with the order (`conditional_scene_clear`), nor a draw dropped for an input nothing
/// produces (`produced` false).
///
/// `order` is the execution order, empty for the descriptions' own; `considered` says which
/// descriptions' clears may be planned at all (the caller's target rules).
[[nodiscard]] std::vector<std::optional<std::vector<std::size_t>>> PlanUnreadClears(
    const std::vector<ScenePassDescription>& descriptions, const std::vector<std::size_t>& order,
    const std::function<bool(std::size_t)>& considered, const std::function<bool(std::size_t)>& produced);

/// For each description, `std::nullopt` or the draws that are all a copy's result is for: the
/// copy is the only pass that writes its destination, nothing copies the destination on, and
/// every draw that samples it runs after the copy in `order` (empty for the descriptions' own),
/// so in a frame none of them draws in, nothing reads what the copy would have left before the
/// next frame's copy replaces it. A copy no draw samples is not planned: removing it is the copy
/// plan's (`CopyElision`), which keeps it while scene optimisation is off. `considered` says which
/// copies may be planned at all.
[[nodiscard]] std::vector<std::optional<std::vector<std::size_t>>> PlanUnreadCopies(
    const std::vector<ScenePassDescription>& descriptions, const std::vector<std::size_t>& order,
    const std::function<bool(std::size_t)>& considered);

/// Marks `shares_depth_attachment` on every draw that does not depth-test and comes, in the
/// descriptions' order, between two draws into the same single-sample target that do. A render
/// pass has one depth attachment or none, so a draw without one between two with one ends the
/// render pass, and with it the target's colour and depth are stored and loaded back (a 3D
/// model, then a flat layer or text over it, then another model). The draw then takes the
/// attachment with depth testing off: what it draws is the same, and the three share one render
/// pass. A draw before the first or after the last depth-tested one is left alone, and so is one
/// that passes on other targets cut off from every depth-tested draw (it would load and store
/// the depth without joining anything), so a render pass that holds no depth-tested draw never
/// carries the attachment. A scene `sorted_by_depth`
/// (transparent sorting) changes its objects' order at run time, so none of its draws is marked.
void ShareDepthAttachments(std::vector<ScenePassDescription>& descriptions, bool sorted_by_depth = false);

/// Whether drawing `quad` with its corners at clip position `matrix * vec4(corner, 1.0)`
/// (`matrix` column-major, as the shader's `float4x4` reads it) covers the centre of every texel
/// of a full `width` x `height` viewport. Every corner must be in front (w > 0) and inside the
/// depth range, so nothing is clipped away, and the two triangles must tile one convex
/// quadrilateral that contains the viewport shrunk by a quarter texel on each side: the GPU's
/// own float rounding of the corners is far smaller than that, so no texel centre can fall
/// outside. Anything else is "not covered", which only costs the caller the load it keeps.
[[nodiscard]] bool QuadCoversViewport(const MetalQuad& quad, const std::array<float, 16>& matrix,
                                      uint32_t width, uint32_t height);

struct MetalPipelineKeyHash
{
    std::size_t operator()(const MetalPipelineKey& key) const noexcept;
};

/// Lowers the render graph into the pass
/// list this backend executes. The ordering, the
/// load/store decisions and the per-target clear behaviour are the graph's, not
/// this function's.
///
/// Returns false and fills `error` on anything it does not recognise, which is
/// how an unsupported construct becomes a whole-scene fallback instead of a
/// silently skipped draw.
///
/// `scene` is mutable because a copy's destination may be a graph-internal
/// target the parser never declared -- the link textures and the copies that
/// break a read-while-write are named by the graph builder. They are
/// registered in `Scene::renderTargets` from their source when the copy is
/// described, so every pass finds its images at the sizes the graph implies.
bool BuildScenePassDescriptions(Scene& scene, const rg::RenderGraph& graph,
                                std::vector<ScenePassDescription>& out, std::string* error);

} // namespace metal
} // namespace wallpaper
