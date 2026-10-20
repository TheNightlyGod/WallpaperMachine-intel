#include "SceneToRenderGraph.hpp"

#include "Scene/Scene.h"
#include "RenderGraph/RenderGraph.hpp"
#include "SpecTexs.hpp"
#include "Utils/Logging.h"
#include "Core/MapSet.hpp"

#include "Vulkan/SampleCount.hpp"
#include "VulkanRender/AllPasses.hpp"
#include "PrePass.hpp"

#include <algorithm>
#include <cstdlib>
#include <sstream>
#include <type_traits>
#include <variant>

using namespace wallpaper;
namespace wallpaper::rg
{

void doCopy(RenderGraphBuilder& builder, vulkan::CopyPass::Desc& desc, TexNode* in, TexNode* out) {
    builder.read(in);
    builder.write(out);

    desc.src = in->key();
    desc.dst = out->key();
}
void addCopyPass(RenderGraph& rgraph, TexNode* in, TexNode* out) {
    rgraph.addPass<vulkan::CopyPass>(
        "copy",
        PassNode::Type::Copy,
        [&in, &out](RenderGraphBuilder& builder, vulkan::CopyPass::Desc& desc) {
            doCopy(builder, desc, in, out);
        });
}

void addCopyPass(RenderGraph& rgraph, const TexNode::Desc& in, const TexNode::Desc& out) {
    rgraph.addPass<vulkan::CopyPass>(
        "copy",
        PassNode::Type::Copy,
        [&in, &out](RenderGraphBuilder& builder, vulkan::CopyPass::Desc& desc) {
            auto* in_node  = builder.createTexNode(in);
            auto* out_node = builder.createTexNode(out, true);
            doCopy(builder, desc, in_node, out_node);
        });
}

TexNode* addCopyPass(RenderGraph& rgraph, TexNode* in, TexNode::Desc* out_desc = nullptr) {
    TexNode* copy { nullptr };
    rgraph.addPass<vulkan::CopyPass>(
        "copy",
        PassNode::Type::Copy,
        [&copy, in, out_desc](RenderGraphBuilder& builder, vulkan::CopyPass::Desc& pdesc) {
            auto desc = out_desc == nullptr ? in->genDesc() : *out_desc;
            if (out_desc == nullptr) {
                desc.key += "_" + std::to_string(in->version()) + "_copy";
                desc.name += "_" + std::to_string(in->version()) + "_copy";
            }
            copy = builder.createTexNode(desc, true);
            doCopy(builder, pdesc, in, copy);
        });
    return copy;
}

static TexNode::Desc createTexDesc(std::string path) {
    return TexNode::Desc { .name = path,
                           .key  = path,
                           .type = IsSpecTex(path) ? TexNode::TexType::Temp
                                                   : TexNode::TexType::Imported };
}
} // namespace wallpaper::rg

static bool EnvFlagEnabled(const char* name)
{
    const char* value = std::getenv(name);
    if (value == nullptr || value[0] == '\0') return false;
    const std::string_view view(value);
    return view != "0" && view != "false" && view != "FALSE";
}

static bool EnvMatches(const char* name, std::string_view expected)
{
    const char* value = std::getenv(name);
    return value != nullptr && expected == value;
}

static bool IsComposeEffectCamera(
    Scene& scene,
    const std::shared_ptr<SceneCamera>& camera,
    const SceneNode* owner)
{
    if (camera == nullptr || scene.activeCamera == nullptr) return false;
    if (!camera->HasImgEffect() || !camera->IsComposeLayer()) return false;

    const auto effect_anchor = camera->GetAttachedNode();
    if (effect_anchor == nullptr) return false;
    if (owner != nullptr && effect_anchor.get() == owner) return true;

    const auto active_anchor = scene.activeCamera->GetAttachedNode();
    return active_anchor != nullptr && effect_anchor.get() == active_anchor.get();
}

static bool IsComposeEffectNode(Scene& scene, const SceneNode* node)
{
    if (node == nullptr || node->Camera().empty()) return false;
    auto camera_iterator = scene.cameras.find(node->Camera());
    if (camera_iterator == scene.cameras.end() || camera_iterator->second == nullptr) return false;
    return IsComposeEffectCamera(scene, camera_iterator->second, node);
}

static std::string ActiveCameraName(Scene& scene)
{
    for (const auto& [name, camera] : scene.cameras) {
        if (camera != nullptr && camera.get() == scene.activeCamera) return name;
    }
    return {};
}

static bool IsResolvedImageEffectFinalNode(
    Scene& scene,
    const SceneNode* effect_node,
    const SceneNode* owner)
{
    if (effect_node == nullptr || owner == nullptr || owner->Camera().empty()) return false;
    auto camera_iterator = scene.cameras.find(owner->Camera());
    if (camera_iterator == scene.cameras.end() || camera_iterator->second == nullptr) return false;
    if (!camera_iterator->second->HasImgEffect()) return false;
    return camera_iterator->second->GetImgEffect()->ResolvedFinalRenderNode() == effect_node;
}

static bool ShouldDebugSkipGraphPass(const SceneNode* node, std::string_view material_name)
{
    if (node != nullptr && EnvMatches("WE_DEBUG_SKIP_NODE", node->Name())) return true;
    if (EnvMatches("WE_DEBUG_SKIP_MATERIAL", material_name)) return true;
    if (material_name == "passthrough" && EnvFlagEnabled("WE_DEBUG_SKIP_PASSTHROUGH")) return true;
    return false;
}

/// Hidden by a visibility only a reload changes, its own or an ancestor's.
static bool HiddenUntilReload(const SceneNode* node)
{
    for (const auto* current = node; current != nullptr; current = current->Parent()) {
        if (! current->Visible() && current->VisibilitySettled()) return true;
    }
    return false;
}

struct ComposeTarget
{
    std::string target;
    /// The camera the layers below draw through; empty for the one they would
    /// draw through on screen.
    std::string camera;
};

static ComposeTarget ResolveNearestComposeTarget(Scene& scene, SceneNode* node)
{
    for (auto* current = node; current != nullptr; current = current->Parent()) {
        if (current->Camera().empty()) continue;
        auto camera_iterator = scene.cameras.find(current->Camera());
        if (camera_iterator == scene.cameras.end() || camera_iterator->second == nullptr) continue;
        if (!IsComposeEffectCamera(scene, camera_iterator->second, current)) continue;
        return {
            .target = camera_iterator->second->GetImgEffect()->FirstTarget(),
            .camera = camera_iterator->second->ChildrenUseSceneCamera() ? std::string {}
                                                                        : current->Camera(),
        };
    }
    return {};
}

enum class GraphPassMode
{
    All,
    BaseOnly,
    EffectsOnly,
};

static void TraverseNode(
    const std::function<void(SceneNode*)>& func,
    SceneNode* node) {
    if (node == nullptr) return;
    func(node);
    for (auto& child : node->GetChildren()) {
        TraverseNode(func, child.get());
    }
}

static void CheckAndSetSprite(Scene& scene, vulkan::CustomShaderPass::Desc& desc,
                              std::span<const std::string> texs) {
    for (usize i = 0; i < texs.size(); i++) {
        auto& tex = texs[i];
        if (! tex.empty() && ! IsSpecTex(tex) && scene.textures.count(tex) != 0) {
            const auto& stex = scene.textures.at(tex);
            if (stex.isSprite) {
                desc.sprites_map[i] = stex.spriteAnim;
            }
        }
    }
}

struct DelayLinkInfo {
    rg::NodeID id;
    rg::NodeID link_id;
    i32        tex_index;
};

struct ExtraInfo {
    Map<size_t, rg::TexNode*>  id_link_map {};
    Map<size_t, rg::TexNode*>  id_base_output_link_map {};
    Set<size_t>                ids_with_effect_graph {};
    Set<size_t>                referenced_ids {};
    std::vector<DelayLinkInfo> link_info {};
    Set<SceneNode*> cleared_effect_inputs {};
    rg::RenderGraph*           rgraph { nullptr };
    Scene*                     scene { nullptr };
    bool                       use_mipmap_framebuffer { false };
    /// Whether a pass drawing into the scene output has been added yet, and
    /// whether a layer left out for being hidden came before any did.
    bool                       output_written { false };
    bool                       output_writer_left_out { false };
};

static std::string IsolateReferencedLayerOutput(
    Scene& scene, ExtraInfo& extra, i32 imgId, std::string output, SceneImageEffectLayer* imgeff,
    bool is_resolved_final) {
    if (imgId == 0 || extra.referenced_ids.count((size_t)imgId) == 0) return output;
    // The pre-effect card of a chain stays on ping-pong A. A compose-routed
    // final stays on the compose target. SpecTex_Default is the scene
    // framebuffer: isolate it so a referenced source -- plain card or the
    // node ResolveEffect resolves onto -- is not sampled from `_rt_default`.
    if (imgeff != nullptr) return output;
    if (output != SpecTex_Default) return output;
    (void)is_resolved_final;
    const auto key = LayerCompositeTargetKey(imgId);
    if (! scene.HasRenderTarget(key)) {
        const auto* defaults = scene.FindRenderTarget(std::string(SpecTex_Default));
        SceneRenderTarget target;
        target.width      = defaults != nullptr ? defaults->width : std::max(1, scene.ortho[0]);
        target.height     = defaults != nullptr ? defaults->height : std::max(1, scene.ortho[1]);
        target.allowReuse = true;
        target.format     = defaults != nullptr ? defaults->format
                                               : (scene.hdr ? TextureFormat::RGBA16F
                                                            : TextureFormat::RGBA8);
        scene.renderTargets[key] = target;
    }
    return key;
}

static void AddCustomShaderGraphPass(
    rg::RenderGraph& rgraph,
    Scene& scene,
    ExtraInfo& extra,
    SceneNode* node,
    SceneNode* visibility_node,
    SceneMaterial& material,
    std::string_view output,
    std::string output_override,
    i32 imgId,
    std::string camera_override,
    std::size_t submesh_index,
    uint32_t material_slot,
    bool register_base_link_output = false,
    bool capture_as_layer_link = false,
    std::optional<BlendMode> blend_override = std::nullopt) {
    rgraph.addPass<vulkan::CustomShaderPass>(
        material.name,
        rg::PassNode::Type::CustomShader,
        [&material,
         node,
         visibility_node,
         output,
         output_override,
         imgId,
         &rgraph,
         &scene,
         &extra,
         camera_override,
         submesh_index,
         material_slot,
         register_base_link_output,
         capture_as_layer_link,
         blend_override](
            rg::RenderGraphBuilder& builder, vulkan::CustomShaderPass::Desc& pdesc) {
            const auto& pass = builder.workPassNode();
            const auto  pass_output = output_override.empty()
                ? std::string(output)
                : std::move(output_override);
            const auto  resolved_output = scene.ResolveRenderTargetName(pass_output);
            if (resolved_output == SpecTex_Default) extra.output_written = true;
            pdesc.node            = node;
            pdesc.visibility_node = visibility_node != nullptr ? visibility_node : node;
            pdesc.output          = resolved_output;
            pdesc.camera_override = camera_override;
            pdesc.submesh_index   = submesh_index;
            pdesc.material_slot   = material_slot;
            pdesc.blend_override  = blend_override;
            pdesc.texture_covers  = material.texture_covers;
            CheckAndSetSprite(scene, pdesc, material.textures);
            for (usize i = 0; i < material.textures.size(); i++) {
                const auto& texture_name = material.textures[i];
                const auto  url = IsSpecTex(texture_name)
                    ? scene.ResolveRenderTargetName(texture_name)
                    : texture_name;
                rg::TexNode* input { nullptr };
                if (url.empty()) {
                    pdesc.textures.emplace_back("");
                    continue;
                } else if (IsSpecLinkTex(url)) {
                    auto id = ParseLinkTex(url);
                    extra.link_info.push_back(
                        DelayLinkInfo { .id = pass.ID(), .link_id = id, .tex_index = (i32)i });
                    pdesc.textures.emplace_back("");
                    continue;
                } else {
                    rg::TexNode::Desc desc;
                    desc.key  = url;
                    desc.name = url;
                    desc.type = ! IsSpecTex(url) ? rg::TexNode::TexType::Imported
                                                 : rg::TexNode::TexType::Temp;
                    input     = builder.createTexNode(desc);
                    if (IsSpecTex(url)) builder.markVirtualWrite(input);
                    if (sstart_with(url, WE_MIP_MAPPED_FRAME_BUFFER))
                        extra.use_mipmap_framebuffer = true;
                }

                if (url == resolved_output) {
                    builder.markSelfWrite(input);
                    input = rg::addCopyPass(rgraph, input);
                }
                builder.read(input);
                pdesc.textures.emplace_back(input->key());
            }

            rg::TexNode* output_node { nullptr };
            output_node =
                builder.createTexNode(rg::TexNode::Desc { .name = resolved_output,
                                                          .key  = resolved_output,
                                                          .type = rg::TexNode::TexType::Temp },
                                      true);
            builder.write(output_node);
            if (sstart_with(resolved_output, WE_IMAGE_LAYER_COMPOSITE_PREFIX) ||
                (capture_as_layer_link && resolved_output != SpecTex_Default)) {
                extra.id_link_map[(usize)imgId] = output_node;
            } else if (resolved_output == SpecTex_Default) {
                // A referenced source's composite is never `_rt_default`; that is
                // the scene framebuffer, including after ResolveEffect rewrites
                // the last ping-pong onto it.
                if (! exists(extra.id_link_map, (usize)imgId) &&
                    extra.referenced_ids.count((size_t)imgId) == 0) {
                    extra.id_link_map[(usize)imgId] = output_node;
                }
            } else if (register_base_link_output) {
                extra.id_base_output_link_map[(usize)imgId] = output_node;
            }
        });
}

static void ToGraphPass(
    SceneNode* node,
    std::string output,
    i32 imgId,
    ExtraInfo& extra,
    SceneNode* visibility_node = nullptr,
    GraphPassMode mode = GraphPassMode::All) {
    auto& rgraph = *extra.rgraph;
    auto& scene  = *extra.scene;

    auto loadEffect = [node, &rgraph, &scene, &extra](SceneImageEffectLayer* effs) {
        effs->ResolveEffect(scene.default_effect_mesh, "effect");

        for (usize i = 0; i < effs->EffectCount(); i++) {
            auto& eff     = effs->GetEffect(i);
            // An effect a script has switched off, or the fallback while
            // another effect runs, is not part of the chain this graph draws.
            if (! eff->included) continue;
            auto commands = eff->commands;
            std::stable_sort(commands.begin(), commands.end(), [](const auto& a, const auto& b) {
                return a.afterpos < b.afterpos;
            });
            auto  cmdItor = commands.begin();
            auto  cmdEnd  = commands.end();
            int   nodePos = 0;
            const auto copiesAt = [&](int position) {
                while (cmdItor != cmdEnd && cmdItor->afterpos <= position) {
                    if (cmdItor->afterpos == position) {
                        rg::addCopyPass(rgraph, rg::createTexDesc(cmdItor->src),
                                       rg::createTexDesc(cmdItor->dst));
                    }
                    ++cmdItor;
                }
            };
            for (auto& n : eff->nodes) {
                copiesAt(nodePos);
                auto& name = n.output;
                extra.ids_with_effect_graph.insert((usize)node->ID());
                ToGraphPass(n.sceneNode.get(), name, node->ID(), extra, node);
                nodePos++;
            }
            copiesAt(nodePos);
        }
    };

    if (node->Mesh() == nullptr) return;
    auto* mesh = node->Mesh();

    SceneImageEffectLayer* imgeff = nullptr;
    if (! node->Camera().empty()) {
        auto& cam = scene.cameras.at(node->Camera());
        if (cam->HasImgEffect()) {
            imgeff = cam->GetImgEffect().get();
            output = imgeff->FirstTarget();
        }
    }

    // copybackground=false means an empty transparent input, not an
    // uninitialized pooled texture left behind by an unrelated effect.
    // Clear before compose children too, so they can draw over the empty input.
    if (imgeff != nullptr && node->SkipRenderPass() &&
        extra.cleared_effect_inputs.insert(node).second) {
        // Aliases and concrete names must denote one graph resource. Otherwise
        // the clear can be scheduled after a reader of the concrete target.
        const auto target = scene.ResolveRenderTargetName(imgeff->FirstTarget());
        rgraph.addPass<vulkan::PrePass>("clear effect input", rg::PassNode::Type::Clear,
            [target](rg::RenderGraphBuilder& builder, vulkan::PrePass::Desc& desc) {
                desc.result = target;
                desc.transparent = true;
                builder.write(builder.createTexNode(rg::createTexDesc(target), true));
            });
    }

    std::string camera_override;
    if (mode == GraphPassMode::BaseOnly && IsComposeEffectNode(scene, node)) {
        camera_override = ActiveCameraName(scene);
    }
    // Where the layer draws before a compose layer around it claims the draw.
    const std::string scene_output = output;
    const bool route_effect_final_to_compose =
        IsResolvedImageEffectFinalNode(scene, node, visibility_node);
    if (!output.empty() && (output == SpecTex_Default || route_effect_final_to_compose)) {
        SceneNode* compose_anchor = node->Parent();
        if (compose_anchor == nullptr && visibility_node != nullptr) {
            compose_anchor = visibility_node->Parent();
        }
        const auto compose_target = ResolveNearestComposeTarget(scene, compose_anchor);
        if (!compose_target.target.empty()) output = compose_target.target;
        if (!compose_target.camera.empty()) camera_override = compose_target.camera;
    }

    if (mode != GraphPassMode::EffectsOnly && !node->SkipRenderPass()) {
        const bool resolved_final =
            IsResolvedImageEffectFinalNode(scene, node, visibility_node);
        // Inside a compose layer a referenced layer is part of that layer's
        // picture, and its own card besides: the compose layer's effects may
        // sample it too.
        const auto isolated_output = IsolateReferencedLayerOutput(
            scene, extra, imgId, scene_output, imgeff, resolved_final);
        const auto draw_output = isolated_output != scene_output ? isolated_output : output;
        const bool capture_link =
            extra.referenced_ids.count((size_t)imgId) != 0 &&
            draw_output != SpecTex_Default &&
            (resolved_final ||
             sstart_with(draw_output, WE_IMAGE_LAYER_COMPOSITE_PREFIX));
        // Drawn into its own composite, a referenced layer is its card in its
        // own texture space, which is what another layer samples; drawn on
        // screen, it is wherever the scene puts it.
        std::string composite_camera = camera_override;
        if (draw_output != output) {
            auto key = LayerCompositeCameraKey(imgId);
            if (scene.cameras.contains(key)) composite_camera = std::move(key);
        }
        const auto& submeshes = mesh->Submeshes();
        auto add_draws = [&](const std::string& target, const std::string& camera,
                             bool register_base, bool capture,
                             std::optional<BlendMode> blend = std::nullopt) {
            if (submeshes.size() > 1) {
                for (std::size_t submesh_index = 0; submesh_index < submeshes.size(); ++submesh_index) {
                    const auto material_slot = submeshes[submesh_index].material_slot;
                    auto* submesh_material = mesh->MaterialForSlot(material_slot);
                    if (submesh_material == nullptr) continue;
                    if (ShouldDebugSkipGraphPass(node, submesh_material->name)) continue;
                    AddCustomShaderGraphPass(
                        rgraph,
                        scene,
                        extra,
                        node,
                        visibility_node,
                        *submesh_material,
                        target,
                        submeshes[submesh_index].output_override,
                        imgId,
                        camera,
                        submesh_index,
                        material_slot,
                        register_base,
                        capture,
                        blend);
                }
            } else {
                auto* material = mesh->MaterialForSlot(0);
                if (material == nullptr) return;
                if (!ShouldDebugSkipGraphPass(node, material->name)) {
                    AddCustomShaderGraphPass(
                        rgraph,
                        scene,
                        extra,
                        node,
                        visibility_node,
                        *material,
                        target,
                        {},
                        imgId,
                        camera,
                        0,
                        0,
                        register_base,
                        capture,
                        blend);
                }
            }
        };
        // A composite-only layer covers its whole target with what is behind
        // it: anywhere but its own composite, that is the wrong picture.
        const bool composite_only = node->CompositeOnly();
        // The chain's last pass puts the layer onto the scene with the layer's
        // blending, but what it leaves in the layer's own composite is its
        // result as it is, written as every other pass of the chain writes:
        // blended onto the cleared composite, colour was multiplied by alpha,
        // and a buffer that keeps data in all four channels lost most of it.
        const bool chain_result_into_own_composite =
            resolved_final && sstart_with(draw_output, WE_IMAGE_LAYER_COMPOSITE_PREFIX);
        if (! composite_only || sstart_with(draw_output, WE_IMAGE_LAYER_COMPOSITE_PREFIX)) {
            add_draws(draw_output, composite_camera, imgeff != nullptr, capture_link,
                      chain_result_into_own_composite ? std::optional(BlendMode::Normal)
                                                      : std::nullopt);
        }
        if (draw_output != output && ! composite_only) {
            // Hidden now, a layer a script shows later still needs this draw:
            // nothing asks for a new graph when it appears.
            auto* vis = visibility_node != nullptr ? visibility_node : node;
            if (vis == nullptr || ! HiddenUntilReload(vis)) {
                add_draws(output, camera_override, false, false);
            }
        }
    }

    // load effect
    if (mode != GraphPassMode::BaseOnly && imgeff != nullptr) loadEffect(imgeff);
}

static bool SubtreeDraws(SceneNode* node) {
    if (node->Mesh() != nullptr) return true;
    for (const auto& child : node->GetChildren()) {
        if (SubtreeDraws(child.get())) return true;
    }
    return false;
}

std::unique_ptr<rg::RenderGraph> wallpaper::sceneToRenderGraph(Scene& scene) {
    std::unique_ptr<rg::RenderGraph> rgraph = std::make_unique<rg::RenderGraph>();
    ExtraInfo                        extra { .rgraph = rgraph.get(), .scene = &scene };
    for (const auto id : scene.layer_texture_sources) {
        extra.referenced_ids.insert(static_cast<size_t>(id));
    }
    // A layer hidden by a visibility only a reload changes -- its own or an
    // ancestor's -- cannot draw before the next parse, so its passes, the
    // effect targets they would allocate and the textures they would load are
    // left out. Something can still show it: a script writing `visible`, which
    // then owns that visibility, or a property applied in place. Either asks
    // for a new graph (`render_excluded_nodes`). A layer another one samples
    // keeps drawing into its composite while hidden, and so does every layer
    // above it, so its subtree stays.
    std::unordered_set<const SceneNode*> producing;
    const auto mark_producing = [&scene, &producing](auto&& self, SceneNode* node) -> bool {
        bool produces = node->MustProduce() || scene.layer_texture_sources.contains(node->ID());
        for (const auto& child : node->GetChildren()) {
            produces = self(self, child.get()) || produces;
        }
        if (produces) producing.insert(node);
        return produces;
    };
    if (scene.sceneGraph != nullptr) mark_producing(mark_producing, scene.sceneGraph.get());
    const auto left_out = [&producing](const SceneNode* node) {
        return ! producing.contains(node) && HiddenUntilReload(node);
    };
    scene.render_excluded_nodes.clear();
    const auto note_left_out = [&extra](SceneNode* node) {
        if (! extra.output_written && SubtreeDraws(node)) extra.output_writer_left_out = true;
    };

    std::unordered_set<SceneNode*> opaque_nodes;
    if (scene.opaque_first) {
        // Depth-tested opaque geometry must precede translucent cards: a
        // skybox drawn later otherwise erases their glow without touching the
        // opaque bodies. Effect/compose subgraphs retain their own ordering.
        const auto opaque = [&](auto&& self, SceneNode* node) -> void {
            if (node == nullptr || IsComposeEffectNode(scene, node)) return;
            if (left_out(node)) {
                note_left_out(node);
                return;
            }
            const auto camera = scene.cameras.find(node->Camera());
            const bool effect = camera != scene.cameras.end() && camera->second != nullptr &&
                                camera->second->HasImgEffect();
            auto* mesh = node->Mesh();
            if (! effect && ! node->SkipRenderPass() && mesh != nullptr &&
                ! mesh->MaterialSlots().empty()) {
                bool all_opaque = true;
                for (const auto& material : mesh->MaterialSlots()) {
                    if (material == nullptr ||
                        (material->blenmode != BlendMode::Disable &&
                         material->blenmode != BlendMode::Normal) || ! material->depth_test) {
                        all_opaque = false;
                        break;
                    }
                }
                if (all_opaque) {
                    ToGraphPass(node, std::string(SpecTex_Default), node->ID(), extra);
                    opaque_nodes.insert(node);
                }
            }
            if (! effect)
                for (const auto& child : node->GetChildren()) self(self, child.get());
        };
        opaque(opaque, scene.sceneGraph.get());
    }
    std::function<void(const std::shared_ptr<SceneNode>&)> build_graph =
        [&extra, &build_graph, &opaque_nodes, &left_out, &note_left_out, &scene](
            const std::shared_ptr<SceneNode>& shared) {
        auto* node = shared.get();
        if (node == nullptr) return;
        if (left_out(node)) {
            note_left_out(node);
            scene.render_excluded_nodes.push_back(shared);
            return;
        }

        const bool is_compose_effect_node = IsComposeEffectNode(*extra.scene, node);

        if (is_compose_effect_node) {
            ToGraphPass(
                node,
                std::string(SpecTex_Default),
                node->ID(),
                extra,
                nullptr,
                GraphPassMode::BaseOnly);
        } else if (!node->SkipRenderPass() && !opaque_nodes.contains(node)) {
            ToGraphPass(node, std::string(SpecTex_Default), node->ID(), extra);
        }

        for (auto& child : node->GetChildren()) {
            build_graph(child);
        }

        if (is_compose_effect_node) {
            ToGraphPass(
                node,
                std::string(SpecTex_Default),
                node->ID(),
                extra,
                nullptr,
                GraphPassMode::EffectsOnly);
        } else if (node->SkipRenderPass()) {
            ToGraphPass(node, std::string(SpecTex_Default), node->ID(), extra);
        }
    };
    build_graph(scene.sceneGraph);

    for (const auto& post_process : scene.post_processes) {
        if (post_process == nullptr) continue;
        for (const auto& step : post_process->steps) {
            std::visit(
                [&extra](const auto& post_step) {
                    using Step = std::decay_t<decltype(post_step)>;
                    if constexpr (std::is_same_v<Step, ScenePostProcessPass>) {
                        if (post_step.node == nullptr) return;
                        ToGraphPass(
                            post_step.node.get(),
                            post_step.output,
                            post_step.node->ID(),
                            extra);
                    } else if constexpr (std::is_same_v<Step, ScenePostProcessCopy>) {
                        const auto src = extra.scene->ResolveRenderTargetName(post_step.src);
                        const auto dst = extra.scene->ResolveRenderTargetName(post_step.dst);
                        rg::addCopyPass(
                            *extra.rgraph,
                            rg::createTexDesc(src),
                            rg::createTexDesc(dst));
                    }
                },
                step);
        }
    }

    for (auto& info : extra.link_info) {
        if (! exists(extra.id_link_map, info.link_id) &&
            ! exists(extra.ids_with_effect_graph, info.link_id) &&
            exists(extra.id_base_output_link_map, info.link_id)) {
            extra.id_link_map[info.link_id] = extra.id_base_output_link_map.at(info.link_id);
        }
        if (! exists(extra.id_link_map, info.link_id)) {
            LOG_ERROR("link tex %d not found", info.link_id);
            continue;
        }
        rgraph->afterBuild(
            info.id, [&rgraph, &extra, &info](rg::RenderGraphBuilder& builder, rg::Pass& rgpass) {
                auto& pass = static_cast<vulkan::CustomShaderPass&>(rgpass);

                auto* link_tex_node = extra.id_link_map.at(info.link_id);
                auto  copy_desc     = link_tex_node->genDesc();
                copy_desc.key       = GenLinkTex((idx)info.link_id);
                copy_desc.name      = copy_desc.key;

                auto new_in = rg::addCopyPass(*rgraph, link_tex_node, &copy_desc);
                builder.read(new_in);
                pass.setDescTex((u32)info.tex_index, new_in->key());
                return true;
            });
    }

    if (extra.use_mipmap_framebuffer) {
        rg::addCopyPass(*rgraph,
                        rg::TexNode::Desc { .name = SpecTex_Default.data(),
                                            .key  = SpecTex_Default.data(),
                                            .type = rg::TexNode::TexType::Temp },
                        rg::TexNode::Desc { .name = WE_MIP_MAPPED_FRAME_BUFFER.data(),
                                            .key  = WE_MIP_MAPPED_FRAME_BUFFER.data(),
                                            .type = rg::TexNode::TexType::Temp });
    }

    // A target read before anything this frame writes it holds what the
    // previous frame left there, so it must keep its own image from one frame
    // to the next. Pooled, its image goes to another target once the frame is
    // done with it, and that target's pixels are what the next frame reads --
    // a motion blur trail then shows whatever else was drawn at that size. The
    // scene output is exempt: the frame's prepass clears it before any reader.
    for (const auto& key : rgraph->getCarriedOverKeys(rgraph->topologicalOrder())) {
        if (scene.ResolveRenderTargetName(key) == scene.ResolveRenderTargetName(SpecTex_Default))
            continue;
        auto* target = scene.FindRenderTarget(key);
        if (target == nullptr) continue;
        target->carriesPreviousFrame = true;
        target->allowReuse           = false;
    }

    Set<std::string> written_targets {};
    Set<std::string> transfer_written_targets {};
    // Targets whose latest write is a transparent clear and nothing else yet.
    Set<std::string> transparent_cleared_targets {};
    for (const auto node_id : rgraph->topologicalOrder()) {
        if (auto* copy_pass = dynamic_cast<vulkan::CopyPass*>(rgraph->getPass(node_id));
            copy_pass != nullptr) {
            const auto copy_dst = scene.ResolveRenderTargetName(copy_pass->desc().dst);
            if (!copy_dst.empty()) {
                written_targets.insert(copy_dst);
                transfer_written_targets.insert(copy_dst);
                transparent_cleared_targets.erase(copy_dst);
            }
            continue;
        }

        if (auto* clear = dynamic_cast<vulkan::PrePass*>(rgraph->getPass(node_id))) {
            written_targets.insert(clear->desc().result);
            transfer_written_targets.insert(clear->desc().result);
            if (clear->desc().transparent)
                transparent_cleared_targets.insert(clear->desc().result);
            else
                transparent_cleared_targets.erase(clear->desc().result);
            continue;
        }
        auto* custom_pass = dynamic_cast<vulkan::CustomShaderPass*>(rgraph->getPass(node_id));
        if (custom_pass == nullptr) continue;

        auto& desc = custom_pass->desc();
        desc.write_alpha = desc.output != SpecTex_Default;
        const auto render_target = scene.FindRenderTarget(desc.output);
        const bool force_clear =
            desc.output != SpecTex_Default && render_target != nullptr && render_target->forceClear;
        desc.sample_count = render_target != nullptr
                                ? vulkan::SampleCountFromValue(render_target->sample_count)
                                : VK_SAMPLE_COUNT_1_BIT;

        const bool first_writer =
            !desc.output.empty() && written_targets.insert(desc.output).second;
        // The first draw into a target that was just cleared to transparent
        // may open with that same clear instead of loading it: every other
        // target clears to transparent too, so the pixels are identical, and
        // the per-frame check then drops the separate clear as redundant.
        // Every later draw still loads what this one left.
        const bool opens_cleared_target = !desc.output.empty() &&
                                          transparent_cleared_targets.erase(desc.output) > 0 &&
                                          desc.output != SpecTex_Default;
        if (!first_writer && !force_clear) {
            // Written by a transfer before: stays single-sample, exactly as
            // when it loaded, and so does every draw after it.
            if (transfer_written_targets.find(desc.output) != transfer_written_targets.end()) {
                desc.sample_count = VK_SAMPLE_COUNT_1_BIT;
            }
            desc.clear_on_first_use = opens_cleared_target;
            desc.preserve_target_contents = !opens_cleared_target;
            continue;
        }

        desc.preserve_target_contents = false;
        if (!desc.output.empty()) {
            transfer_written_targets.erase(desc.output);
        }
        if (desc.output == SpecTex_Default) {
            // With clearing off, a hidden first writer neither cleared nor
            // drew, and the first layer drawn loaded what the frame began
            // with. Leaving the hidden one out must not make it discard that.
            if (! scene.clearEnabled && extra.output_writer_left_out) {
                desc.preserve_target_contents = true;
                continue;
            }
            desc.clear_on_first_use = scene.clearEnabled;
            continue;
        }

        desc.clear_on_first_use = render_target != nullptr && (render_target->allowReuse || force_clear);
    }

    return rgraph;
}
