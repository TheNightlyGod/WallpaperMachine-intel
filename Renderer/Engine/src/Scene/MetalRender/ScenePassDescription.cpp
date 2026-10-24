#include "MetalRender/ScenePassDescription.hpp"

#include "RenderCommon/ScenePass.hpp"
#include "RenderGraph/Pass.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "SpecTexs.hpp"

#include <functional>
#include <unordered_map>

namespace wallpaper::metal
{
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
            desc.node            = src.node;
            desc.visibility_node = src.visibility_node != nullptr ? src.visibility_node : src.node;
            desc.material_slot   = src.material_slot;
            desc.submesh_index   = src.submesh_index;
            desc.camera_override = src.camera_override;
            desc.blend           = src.replace_target ? BlendMode::Disable : material->blenmode;
            desc.write_alpha     = src.write_alpha;
            desc.target_key      = scene.ResolveRenderTargetName(src.output);
            {
                const auto* target    = scene.FindRenderTarget(desc.target_key);
                const bool  has_depth = target != nullptr && target->withDepth;
                const auto  depth     = ResolveSceneDepthState(*material, has_depth);
                desc.depth_test       = depth.test;
                desc.depth_write      = depth.write;
                desc.cull_mode        = SceneMetalCullMode(material->cull_mode, has_depth);
            }
            desc.load_action = ResolveLoadAction(src.preserve_target_contents,
                                                 src.clear_on_first_use);
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
            out.push_back(std::move(desc));
            continue;
        }
        }
        return set_error("the render graph contains a step the native renderer does not recognise");
    }

    if (out.empty()) return set_error("the render graph draws nothing");
    ClearSceneBeforeAnEarlyRead(scene, out);
    PlaceMipmapGeneration(scene, out);
    return true;
}

} // namespace wallpaper::metal
