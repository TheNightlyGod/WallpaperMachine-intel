#include "MetalRender/ScenePassDescription.hpp"

#include "RenderCommon/ScenePass.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"
#include "RenderGraph/Pass.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "SpecTexs.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
#include <unordered_map>

namespace wallpaper::metal
{
uint32_t SelectSceneSampleCount(uint32_t requested, uint32_t supported_mask)
{
    for (const uint32_t count : { 8u, 4u, 2u })
        if (count <= requested && (supported_mask & count) != 0) return count;
    return 1;
}

bool BlendReplacesDestination(const MetalBlendState& blend)
{
    if (blend.alpha_to_coverage) return false;
    if (! blend.blending_enabled) return true;
    return blend.rgb_operation == MetalBlendOperation::Add &&
           blend.alpha_operation == MetalBlendOperation::Add &&
           blend.source_rgb == MetalBlendFactor::One && blend.destination_rgb == MetalBlendFactor::Zero &&
           blend.source_alpha == MetalBlendFactor::One &&
           blend.destination_alpha == MetalBlendFactor::Zero;
}

bool BlendKeepsDestinationAtZeroAlpha(const MetalBlendState& blend)
{
    if (blend.alpha_to_coverage || ! blend.blending_enabled) return false;
    // Cs * As + Cd * k with As = 0 and Cs finite: Cd * k, and k must be 1.
    if (blend.rgb_operation != MetalBlendOperation::Add || blend.source_rgb != MetalBlendFactor::SourceAlpha) return false;
    if (blend.destination_rgb != MetalBlendFactor::One &&
        blend.destination_rgb != MetalBlendFactor::OneMinusSourceAlpha) {
        return false;
    }
    switch (blend.alpha_operation) {
    case MetalBlendOperation::Add:
        return (blend.source_alpha == MetalBlendFactor::SourceAlpha || blend.source_alpha == MetalBlendFactor::One ||
                blend.source_alpha == MetalBlendFactor::Zero) &&
               (blend.destination_alpha == MetalBlendFactor::One ||
                blend.destination_alpha == MetalBlendFactor::OneMinusSourceAlpha);
    case MetalBlendOperation::Max:
        // max(As, Ad) = max(0, Ad), whether or not the factors are applied, with `One` for both.
        return blend.source_alpha == MetalBlendFactor::One && blend.destination_alpha == MetalBlendFactor::One;
    default:
        return false;
    }
}

std::vector<std::optional<std::vector<std::size_t>>> PlanUnreadClears(
    const std::vector<ScenePassDescription>& descriptions, const std::vector<std::size_t>& order,
    const std::function<bool(std::size_t)>& considered, const std::function<bool(std::size_t)>& produced)
{
    const std::size_t count = descriptions.size();
    std::vector<std::optional<std::vector<std::size_t>>> plan(count);
    if (! order.empty() && order.size() != count) return plan;
    const auto at = [&order](std::size_t position) { return order.empty() ? position : order[position]; };
    // Clears its target whatever is visible, in every frame it is not itself left out.
    const auto resets = [&](std::size_t j, const std::string& key) {
        const auto& d = descriptions[j];
        return d.enabled && d.target_key == key && d.load_action == MetalLoadAction::Clear &&
               ! d.conditional_scene_clear && ! d.depth_only &&
               (d.kind == MetalPassKind::Clear || d.kind == MetalPassKind::CustomShader) &&
               (d.kind != MetalPassKind::CustomShader || produced(j));
    };
    // Sees what the target holds: a copy of it always, a draw sampling it or drawing onto it
    // without clearing it when it draws.
    enum class Read : uint8_t { None, Draw, Always };
    const auto reads = [&](std::size_t j, const std::string& key) {
        const auto& d = descriptions[j];
        if (! d.enabled) return Read::None;
        if (d.kind == MetalPassKind::Copy) return d.source_key == key ? Read::Always : Read::None;
        if (d.kind != MetalPassKind::CustomShader) return Read::None;
        if (std::find(d.texture_keys.begin(), d.texture_keys.end(), key) != d.texture_keys.end() ||
            (d.target_key == key && d.load_action != MetalLoadAction::Clear)) {
            return Read::Draw;
        }
        return Read::None;
    };
    for (std::size_t position = 0; position < count; ++position) {
        const std::size_t i   = at(position);
        const auto&       key = descriptions[i].target_key;
        if (i >= count || key.empty() || ! resets(i, key) || ! considered(i)) continue;
        std::vector<std::size_t> readers;
        bool                     ends = false;
        bool                     seen = false;
        for (std::size_t later = position + 1; later < count && ! seen; ++later) {
            const std::size_t j = at(later);
            if (resets(j, key)) {
                ends = true;
                break;
            }
            const auto read = reads(j, key);
            if (read == Read::Always) seen = true;
            else if (read == Read::Draw) readers.push_back(j);
        }
        // Through the end of the frame: the next frame's passes ahead of this one, whatever they
        // draw then, until one clears the target (this one, at the latest).
        for (std::size_t earlier = 0; earlier < position && ! seen && ! ends; ++earlier) {
            const std::size_t j = at(earlier);
            if (resets(j, key)) break;
            if (reads(j, key) != Read::None) seen = true;
        }
        if (! seen) plan[i] = std::move(readers);
    }
    return plan;
}

std::vector<std::optional<std::vector<std::size_t>>> PlanUnreadCopies(
    const std::vector<ScenePassDescription>& descriptions, const std::vector<std::size_t>& order,
    const std::function<bool(std::size_t)>& considered)
{
    const std::size_t count = descriptions.size();
    std::vector<std::optional<std::vector<std::size_t>>> plan(count);
    if (! order.empty() && order.size() != count) return plan;
    const auto at = [&order](std::size_t position) { return order.empty() ? position : order[position]; };
    for (std::size_t position = 0; position < count; ++position) {
        const std::size_t i    = at(position);
        const auto&       copy = descriptions[i];
        if (i >= count || ! copy.enabled || copy.kind != MetalPassKind::Copy || copy.target_key.empty() ||
            ! considered(i)) {
            continue;
        }
        const auto&              key = copy.target_key;
        std::vector<std::size_t> readers;
        bool                     alone = true;
        for (std::size_t other = 0; other < count && alone; ++other) {
            const std::size_t j = at(other);
            const auto&       d = descriptions[j];
            if (j == i || ! d.enabled) continue;
            // Another writer, a copy of it, or a reader of the frame before.
            if (d.target_key == key || (d.kind == MetalPassKind::Copy && d.source_key == key)) {
                alone = false;
            } else if (std::find(d.texture_keys.begin(), d.texture_keys.end(), key) != d.texture_keys.end()) {
                if (d.kind != MetalPassKind::CustomShader || other < position) alone = false;
                else readers.push_back(j);
            }
        }
        // A copy nothing samples at all is the copy plan's to remove, while scene optimisation
        // is on; with it off every such copy is made, so its image can be looked at.
        if (alone && ! readers.empty()) plan[i] = std::move(readers);
    }
    return plan;
}

bool QuadCoversViewport(const MetalQuad& quad, const std::array<float, 16>& matrix, uint32_t width,
                        uint32_t height)
{
    if (width == 0 || height == 0) return false;
    // Depth within [0, w] by a margin the GPU's rounding cannot cross, unless every term of the
    // depth row is an exact zero (an orthographic card at z = 0), which no rounding moves.
    constexpr double kDepthMargin = 1e-5;
    std::array<std::array<double, 2>, 4> ndc {};
    for (std::size_t k = 0; k < 4; ++k) {
        const std::array<double, 4> v { quad.corners[k][0], quad.corners[k][1], quad.corners[k][2], 1.0 };
        std::array<double, 4> clip {};
        bool                  exact_zero_depth = true;
        for (std::size_t c = 0; c < 4; ++c) {
            for (std::size_t r = 0; r < 4; ++r) clip[r] += double(matrix[c * 4 + r]) * v[c];
            exact_zero_depth = exact_zero_depth && (matrix[c * 4 + 2] == 0.0f || v[c] == 0.0);
        }
        for (const double value : clip)
            if (! std::isfinite(value)) return false;
        const double w = clip[3];
        if (! (w > 0.0)) return false;
        if (! exact_zero_depth && ! (clip[2] >= kDepthMargin * w && clip[2] <= (1.0 - kDepthMargin) * w))
            return false;
        ndc[k] = { clip[0] / w, clip[1] / w };
    }

    // The two triangles share exactly one edge (p, q); the corner each has of its own (r, s)
    // makes the quad r-p-s-q, which they tile when it is convex.
    const auto& first  = quad.triangles[0];
    const auto& second = quad.triangles[1];
    for (const auto& triangle : quad.triangles) {
        for (const auto index : triangle)
            if (index >= 4) return false;
        if (triangle[0] == triangle[1] || triangle[1] == triangle[2] || triangle[0] == triangle[2]) return false;
    }
    std::vector<uint8_t> shared;
    int                  own_first = -1;
    for (const auto index : first) {
        if (std::find(second.begin(), second.end(), index) != second.end()) shared.push_back(index);
        else own_first = index;
    }
    int own_second = -1;
    for (const auto index : second)
        if (std::find(first.begin(), first.end(), index) == first.end()) own_second = index;
    if (shared.size() != 2 || own_first < 0 || own_second < 0) return false;
    const std::array<std::array<double, 2>, 4> ring { ndc[std::size_t(own_first)], ndc[shared[0]],
                                                      ndc[std::size_t(own_second)], ndc[shared[1]] };
    const auto turn = [](const std::array<double, 2>& a, const std::array<double, 2>& b,
                         const std::array<double, 2>& c) {
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
    };
    const double orientation = turn(ring[0], ring[1], ring[2]) > 0.0 ? 1.0 : -1.0;
    for (std::size_t i = 0; i < 4; ++i) {
        if (! (orientation * turn(ring[i], ring[(i + 1) % 4], ring[(i + 2) % 4]) > 0.0)) return false;
    }
    const double inset_x = 1.0 - 0.5 / double(width);
    const double inset_y = 1.0 - 0.5 / double(height);
    for (const auto& point : { std::array<double, 2> { -inset_x, -inset_y }, std::array<double, 2> { inset_x, -inset_y },
                               std::array<double, 2> { inset_x, inset_y }, std::array<double, 2> { -inset_x, inset_y } }) {
        for (std::size_t i = 0; i < 4; ++i) {
            if (! (orientation * turn(ring[i], ring[(i + 1) % 4], point) > 0.0)) return false;
        }
    }
    return true;
}

namespace
{

uint64_t HashMix(uint64_t seed, uint64_t value)
{
    seed ^= value + 0x9e3779b97f4a7c15ULL + (seed << 6) + (seed >> 2);
    return seed;
}

MetalLoadAction ResolveLoadAction(bool preserve_target_contents, bool clear_on_first_use)
{
    if (clear_on_first_use) return MetalLoadAction::Clear;
    if (preserve_target_contents) return MetalLoadAction::Load;
    return MetalLoadAction::DontCare;
}

bool TargetExtent(const Scene& scene, const std::string& key, uint32_t& width, uint32_t& height)
{
    const auto* target = scene.FindRenderTarget(key);
    if (target == nullptr || target->width <= 0 || target->height <= 0) return false;
    width  = static_cast<uint32_t>(target->width);
    height = static_cast<uint32_t>(target->height);
    return true;
}

/// Declares a copy's destination when the graph invented the name.
///
/// The destination inherits
/// the source's shape and becomes reusable. Inventing a different shape here
/// would size the link texture or the feedback-break copy differently from
/// the authored one, and every effect that samples it would then sample at a
/// different texel step.
void EnsureCopyDestination(Scene& scene, const std::string& source, const std::string& destination)
{
    if (destination.empty() || scene.FindRenderTarget(destination) != nullptr) return;
    const auto* source_target = scene.FindRenderTarget(source);
    if (source_target == nullptr) return;
    auto copy       = *source_target;
    copy.allowReuse = true;
    scene.renderTargets[destination] = copy;
}

/// Every render-target key a pass samples, in slot order for a draw and as the
/// single source for a copy.
void ForEachRead(const ScenePassDescription& desc, const std::function<void(const std::string&)>& op)
{
    if (desc.kind == MetalPassKind::Copy) {
        if (! desc.source_key.empty()) op(desc.source_key);
        return;
    }
    for (const auto& key : desc.texture_keys) {
        if (! key.empty()) op(key);
    }
}

/// Clears the scene's own image before a pass that reads it ahead of anything
/// drawing into it this frame.
///
/// The image is cleared to the background in the first pass that draws into it. A
/// pass that samples or copies it before then -- a layer blending with the
/// screen, or reading the frame buffer, ahead of any other layer -- would read
/// whatever the image held: nothing on the first frame, and the previous
/// frame's picture after it, where the background belongs.
void ClearSceneBeforeAnEarlyRead(Scene& scene, std::vector<ScenePassDescription>& out)
{
    const auto scene_key = scene.ResolveRenderTargetName(std::string(SpecTex_Default));
    const bool sorted = std::any_of(out.begin(), out.end(), [](const auto& pass) {
        return pass.sort_owner != nullptr;
    });
    if (sorted) {
        bool any_read = false;
        bool first_reads = false;
        bool touched = false;
        for (const auto& pass : out) {
            bool reads = false;
            ForEachRead(pass, [&](const std::string& key) { reads = reads || key == scene_key; });
            any_read = any_read || reads;
            if (!touched && (reads || pass.target_key == scene_key)) {
                first_reads = reads;
                touched = true;
            }
        }
        if (any_read) {
            ScenePassDescription clear;
            clear.kind = MetalPassKind::Clear;
            clear.name = "clear scene before its first reader";
            clear.target_key = scene_key;
            clear.load_action = MetalLoadAction::Clear;
            clear.uses_scene_clear_color = true;
            clear.conditional_scene_clear = true;
            clear.enabled = first_reads;
            clear.clear_color = {scene.clearColor[0], scene.clearColor[1], scene.clearColor[2], 1.0f};
            if (const auto* target = scene.FindRenderTarget(scene_key))
                clear.samples = rg::NormalizeSampleCount(target->sample_count);
            if (TargetExtent(scene, scene_key, clear.target_width, clear.target_height))
                out.insert(out.begin(), std::move(clear));
        }
        return;
    }
    for (std::size_t i = 0; i < out.size(); ++i) {
        bool reads = false;
        ForEachRead(out[i], [&](const std::string& key) { reads = reads || key == scene_key; });
        if (reads) {
            ScenePassDescription clear;
            clear.kind                   = MetalPassKind::Clear;
            clear.name                   = "clear scene before its first reader";
            clear.target_key             = scene_key;
            clear.load_action            = MetalLoadAction::Clear;
            clear.uses_scene_clear_color = true;
            clear.clear_color = { scene.clearColor[0], scene.clearColor[1], scene.clearColor[2],
                                  1.0f };
            if (! TargetExtent(scene, scene_key, clear.target_width, clear.target_height)) return;
            out.insert(out.begin() + static_cast<std::ptrdiff_t>(i), std::move(clear));
            return;
        }
        if (out[i].kind != MetalPassKind::Virtual && out[i].target_key == scene_key) return;
    }
}

/// Places mip generation at the last writer of each mip-mapped target before a
/// reader of it, and at its final writer. Walked in execution order, so a target
/// written, read, written and read again is regenerated twice rather than once.
void PlaceMipmapGeneration(const Scene& scene, std::vector<ScenePassDescription>& out)
{
    std::unordered_map<std::string, std::size_t> pending;
    const auto mipmapped = [&scene](const std::string& key) {
        const auto* target = scene.FindRenderTarget(key);
        return target != nullptr && target->mipmap_level > 1;
    };

    for (std::size_t i = 0; i < out.size(); ++i) {
        ForEachRead(out[i], [&](const std::string& key) {
            if (! mipmapped(key)) return;
            const auto found = pending.find(key);
            if (found == pending.end()) return;
            out[found->second].generate_mipmaps = true;
            pending.erase(found);
        });
        if (! out[i].target_key.empty() && mipmapped(out[i].target_key)) {
            pending[out[i].target_key] = i;
        }
    }
    for (const auto& [key, index] : pending) {
        (void)key;
        out[index].generate_mipmaps = true;
    }
}

} // namespace

std::size_t MetalPipelineKeyHash::operator()(const MetalPipelineKey& key) const noexcept
{
    uint64_t hash = 0xcbf29ce484222325ULL;
    hash          = HashMix(hash, key.program_id);
    hash          = HashMix(hash, key.vertex_layout_id);
    hash          = HashMix(hash, static_cast<uint64_t>(key.color_format));
    hash          = HashMix(hash, static_cast<uint64_t>(key.depth_format));
    hash          = HashMix(hash, static_cast<uint64_t>(key.depth_compare));
    hash          = HashMix(hash, key.sample_count);
    hash          = HashMix(hash, key.write_alpha ? 1u : 0u);
    hash          = HashMix(hash, key.depth_test ? 1u : 0u);
    hash          = HashMix(hash, key.depth_write ? 1u : 0u);
    hash          = HashMix(hash, key.blend.blending_enabled ? 1u : 0u);
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.rgb_operation));
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.alpha_operation));
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.source_rgb));
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.destination_rgb));
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.source_alpha));
    hash          = HashMix(hash, static_cast<uint64_t>(key.blend.destination_alpha));
    hash          = HashMix(hash, key.blend.alpha_to_coverage ? 1u : 0u);
    return static_cast<std::size_t>(hash);
}

bool BuildScenePassDescriptions(Scene& scene, const rg::RenderGraph& graph,
                                std::vector<ScenePassDescription>& out, std::string* error)
{
    out.clear();
    const auto set_error = [error](std::string message) {
        if (error != nullptr) *error = std::move(message);
        return false;
    };

    for (const auto node_id : graph.topologicalOrder()) {
        const auto* pass_node = graph.getPassNode(node_id);
        auto*       pass      = graph.getPass(node_id);
        if (pass_node == nullptr || pass == nullptr) {
            return set_error("the render graph contains a step with no pass");
        }

        const auto kind = ClassifyMetalPassKind(static_cast<int>(pass_node->type()));
        switch (kind) {
        case MetalPassKind::Virtual:
            // Bookkeeping only: it records a writer so versioning works, and
            // produces no pixels. Skipped rather than rejected.
            continue;
        case MetalPassKind::Unsupported:
            return set_error("the render graph contains a step the native renderer does not "
                             "recognise");
        case MetalPassKind::Clear: {
            const auto* clear = dynamic_cast<const rg::ClearPass*>(pass);
            if (clear == nullptr) return set_error("a clear step has an unexpected shape");
            const auto& pre = clear->desc();
            ScenePassDescription desc;
            desc.kind        = MetalPassKind::Clear;
            desc.sort_owner  = pre.sort_owner;
            desc.reflection_pass = pre.reflection_pass;
            desc.name        = std::string(pass_node->name());
            desc.target_key  = scene.ResolveRenderTargetName(pre.result);
            desc.load_action = MetalLoadAction::Clear;
            if (pre.transparent) {
                desc.clear_color = { 0.0f, 0.0f, 0.0f, 0.0f };
            } else {
                desc.uses_scene_clear_color = true;
                desc.clear_color = { scene.clearColor[0], scene.clearColor[1], scene.clearColor[2],
                                     1.0f };
            }
            if (! TargetExtent(scene, desc.target_key, desc.target_width, desc.target_height)) {
                return set_error("a clear step targets an image with no size");
            }
            out.push_back(std::move(desc));
            continue;
        }
        case MetalPassKind::Copy: {
            const auto* step = dynamic_cast<const rg::CopyPass*>(pass);
            if (step == nullptr) return set_error("a copy step has an unexpected shape");
            const auto& copy = step->desc();
            ScenePassDescription desc;
            desc.kind        = MetalPassKind::Copy;
            desc.sort_owner  = copy.sort_owner;
            desc.reflection_pass = copy.reflection_pass;
            desc.name        = std::string(pass_node->name());
            desc.source_key  = scene.ResolveRenderTargetName(copy.src);
            desc.target_key  = scene.ResolveRenderTargetName(copy.dst);
            desc.load_action = MetalLoadAction::DontCare;
            if (! TargetExtent(scene, desc.source_key, desc.source_width, desc.source_height)) {
                return set_error("a copy step reads an image with no size");
            }
            EnsureCopyDestination(scene, desc.source_key, desc.target_key);
            if (! TargetExtent(scene, desc.target_key, desc.target_width, desc.target_height)) {
                return set_error("a copy step targets an image with no size");
            }
            out.push_back(std::move(desc));
            continue;
        }
        case MetalPassKind::CustomShader: {
            const auto* custom = dynamic_cast<const rg::DrawPass*>(pass);
            if (custom == nullptr) return set_error("a draw step has an unexpected shape");
            const auto& src = custom->desc();
            if (src.node == nullptr || src.node->Mesh() == nullptr) {
                return set_error("a draw step has no mesh");
            }
            auto* mesh = src.node->Mesh();
            if (src.submesh_index >= mesh->Submeshes().size()) {
                return set_error("a draw step names a submesh that does not exist");
            }
            const auto* material = mesh->MaterialForSlot(src.material_slot);
            if (material == nullptr) return set_error("a draw step has no material");

            ScenePassDescription desc;
            desc.kind            = MetalPassKind::CustomShader;
            desc.name            = material->name;
            desc.sort_owner      = src.sort_owner;
            desc.reflection_pass = src.reflection_pass;
            desc.node            = src.node;
            desc.visibility_node = src.visibility_node != nullptr ? src.visibility_node : src.node;
            desc.material_slot   = src.material_slot;
            desc.submesh_index   = src.submesh_index;
            desc.camera_override = src.camera_override;
            desc.blend           = src.replace_target ? BlendMode::Disable : material->blenmode;
            desc.alpha_rule      = src.alpha_rule;
            desc.samples         = src.samples;
            desc.force_single_sample = src.force_single_sample;
            desc.write_alpha     = src.write_alpha;
            desc.target_key      = scene.ResolveRenderTargetName(src.output);
            {
                const auto* target    = scene.FindRenderTarget(desc.target_key);
                const bool  has_depth = target != nullptr && target->withDepth;
                auto        depth     = ResolveSceneDepthState(*material, desc.blend, has_depth);
                if (src.depth_override.has_value()) depth = *src.depth_override;
                desc.depth_test       = depth.test;
                desc.depth_write      = depth.write;
                desc.depth_compare    = depth.compare == DepthCompare::GreaterEqual
                                            ? MetalDepthCompare::GreaterEqual
                                            : depth.compare == DepthCompare::Greater
                                                  ? MetalDepthCompare::Greater : MetalDepthCompare::LessEqual;
                desc.cull_mode        = SceneMetalCullMode(src.cull_override.value_or(material->cull_mode));
            }
            desc.depth_only   = src.depth_only;
            desc.depth_bias_slope = src.depth_bias_slope;
            desc.depth_bias_clamp = src.depth_bias_clamp;
            desc.viewport     = src.viewport_uv;
            desc.flip_winding = src.flip_winding;
            if (src.depth_only) {
                // Depth alone: nothing blends, and the clear is the reversed far plane.
                desc.blend       = BlendMode::Disable;
                desc.write_alpha = false;
                desc.clear_depth = src.depth_clear;
                desc.load_action = src.clear_depth_on_first_use ? MetalLoadAction::Clear
                                                                : MetalLoadAction::Load;
            } else {
                desc.load_action = ResolveLoadAction(src.preserve_target_contents,
                                                     src.clear_on_first_use);
            }
            // Only the scene's own colour buffer clears to the author's
            // background; every other target clears to nothing, so a layer
            // composited onto it is not composited onto a colour.
            if (desc.target_key == scene.ResolveRenderTargetName(SpecTex_Default)) {
                desc.uses_scene_clear_color = true;
                desc.clear_color = { scene.clearColor[0], scene.clearColor[1], scene.clearColor[2],
                                     1.0f };
            } else {
                desc.clear_color = { 0.0f, 0.0f, 0.0f, 0.0f };
            }
            if (! TargetExtent(scene, desc.target_key, desc.target_width, desc.target_height)) {
                return set_error("a draw step targets an image with no size");
            }
            desc.texture_keys.reserve(src.textures.size());
            for (const auto& texture : src.textures) {
                desc.texture_keys.push_back(texture.empty()
                                                ? std::string {}
                                                : scene.ResolveRenderTargetName(texture));
            }
            if (!material->cover_slots.empty()) {
                desc.cover_keys = material->cover_slots;
                desc.cover_keys.resize(desc.texture_keys.size());
            }
            for (std::size_t i = 0; i < material->textures.size() && i < desc.texture_keys.size(); ++i) {
                if (! std::string_view(material->textures[i]).starts_with(WE_ALIAS_PREFIX)) continue;
                desc.border_slots.resize(desc.texture_keys.size());
                desc.border_slots[i] = true;
                if (scene.shadows.cookie_features && material->textures[i] == kLightCookieAlias) {
                    desc.light_cookie_slots |= 1u << i;
                    desc.texture_keys[i] = kLightCookieAlias;
                }
            }
            out.push_back(std::move(desc));
            continue;
        }
        }
        return set_error("the render graph contains a step the native renderer does not recognise");
    }

    if (out.empty()) {
        // A property init may create the scene's first model, or a replacement
        // may temporarily remove its last shape. Keep a shader-free output so
        // the runtime can reach that next event without inventing geometry.
        ScenePassDescription clear;
        clear.kind = MetalPassKind::Clear;
        clear.name = "empty scene output";
        clear.target_key = scene.ResolveRenderTargetName(std::string(SpecTex_Default));
        clear.load_action = scene.clearEnabled ? MetalLoadAction::Clear : MetalLoadAction::Load;
        clear.uses_scene_clear_color = true;
        clear.clear_color = {scene.clearColor[0], scene.clearColor[1], scene.clearColor[2], 1.0f};
        if (!TargetExtent(scene, clear.target_key, clear.target_width, clear.target_height))
            return set_error("the empty scene has no output target");
        out.push_back(std::move(clear));
    }
    ClearSceneBeforeAnEarlyRead(scene, out);
    const auto* frame = scene.FindRenderTarget(SpecTex_Default);
    if (frame != nullptr && frame->withDepth && scene.FindRenderTarget("_rt_volumetricsBack")) {
        const auto scene_key = scene.ResolveRenderTargetName(SpecTex_Default);
        for (auto& desc : out) {
            desc.scene_depth_attachment = desc.target_key == scene_key && !desc.depth_only &&
                !desc.force_single_sample &&
                (desc.kind == MetalPassKind::CustomShader || desc.kind == MetalPassKind::Clear);
            desc.reads_scene_depth = std::find(desc.texture_keys.begin(), desc.texture_keys.end(),
                "_rt_volumetricsBack") != desc.texture_keys.end();
        }
    }
    PlaceMipmapGeneration(scene, out);
    if (ScenePassMergeEnabled()) ShareDepthAttachments(out, scene.transparent_sorting);
    return true;
}

void ShareDepthAttachments(std::vector<ScenePassDescription>& descriptions, bool sorted_by_depth)
{
    // A scene sorted by depth puts its objects in a new order whenever the camera or a layer
    // moves, so "between two depth-tested draws" in build order would not hold at run time: a
    // shared draw that ends up outside them would split the pass it was meant to join.
    if (sorted_by_depth) return;
    const auto draws = [](const ScenePassDescription& desc) {
        return desc.kind == MetalPassKind::CustomShader && ! desc.depth_only && ! desc.target_key.empty();
    };
    // Per target: whether every draw into it is single-sample, and where its first and last
    // depth-tested draw are.
    struct Span {
        bool        single_sample { true };
        std::size_t first { 0 };
        std::size_t last { 0 };
        bool        tested { false };
    };
    std::unordered_map<std::string, Span> spans;
    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        const auto& desc = descriptions[i];
        if (! draws(desc)) continue;
        auto& span = spans[desc.target_key];
        span.single_sample = span.single_sample && desc.samples == 1;
        if (! desc.depth_test) continue;
        if (! span.tested) span.first = i;
        span.last   = i;
        span.tested = true;
    }
    // A run is consecutive draws into one target, which the encoder can put in one render pass.
    // A flat draw only joins a depth-tested one through its own run: one that a pass on another
    // target cuts off from them on both sides would carry the attachment, loading and storing the
    // depth, without saving a render pass.
    std::vector<std::size_t> run_of(descriptions.size(), 0);
    std::vector<char>        run_tested;
    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        const auto& desc       = descriptions[i];
        const bool  continues  = i > 0 && draws(desc) && draws(descriptions[i - 1]) &&
                               descriptions[i - 1].target_key == desc.target_key;
        if (! continues) run_tested.push_back(0);
        run_of[i] = run_tested.size() - 1;
        if (draws(desc) && desc.depth_test) run_tested.back() = 1;
    }
    for (std::size_t i = 0; i < descriptions.size(); ++i) {
        auto& desc = descriptions[i];
        if (! draws(desc) || desc.depth_test || desc.scene_depth_attachment) continue;
        const auto span = spans.find(desc.target_key);
        if (span == spans.end() || ! span->second.tested || ! span->second.single_sample) continue;
        desc.shares_depth_attachment =
            span->second.first < i && i < span->second.last && run_tested[run_of[i]];
    }
}

} // namespace wallpaper::metal
