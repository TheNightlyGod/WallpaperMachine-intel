// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#include "RenderCommon/SceneToRenderGraph.hpp"

#include "RenderCommon/ScenePass.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "SpecTexs.hpp"
#include "Utils/Logging.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <limits>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <variant>
#include <vector>

namespace wallpaper
{
namespace
{

std::atomic<bool>& ScenePassMergeSwitch()
{
    static std::atomic<bool> enabled { [] {
        const char* value = std::getenv("WALLPAPER_MACHINE_SCENE_PASS_MERGE");
        return value == nullptr || std::string_view(value) != "0";
    }() };
    return enabled;
}

using rg::ClearPass;
using rg::CopyPass;
using rg::DrawPass;
using rg::PassNode;
using rg::TexNode;

// What a draw is, as far as "the picture of a layer" (a link source) is concerned.
enum class PictureRole
{
    None,
    PlainCard, // the card of a layer without an effect chain
    ChainCard, // the card of a layer with a chain, drawn into the chain's first buffer
    ChainFinal // the chain's final pass
};

// One thing to draw: a node (a card, a chain pass or a post-process step) and where it
// belongs before routing.
struct DrawSource {
    SceneNode*  node { nullptr };
    SceneNode*  visibility_node { nullptr };
    i32         image_id { 0 };
    std::string destination;
    // Where the search for an enclosing compose layer starts.
    SceneNode*  redirect_from { nullptr };
    std::string camera;
    PictureRole role { PictureRole::None };
};

// A texture slot waiting for a layer link to be filled in.
struct LinkConsumer {
    rg::NodeID pass { 0 };
    uint32_t   slot { 0 };
    i32        layer { 0 };
    i32        owner { 0 };
};

struct Route {
    std::string dest;
    std::string camera;
    // The destination came from a submesh's output override, not from the layer's routing.
    bool overridden { false };
};

// What the load-action rules remember about one render target.
struct TargetHistory {
    bool written { false };
    // The latest write was a clear to transparent that no later write replaced.
    bool transparent_clear { false };
    // The latest write came from a copy or a clear: draws then sample once.
    bool single_sample { false };
};

class GraphBuilder {
public:
    explicit GraphBuilder(Scene& scene): m_scene(scene), m_graph(std::make_unique<rg::RenderGraph>()),
        m_custom_sort(scene.runtime && scene.runtime->CustomSortOrder()),
        m_ordered_objects((scene.transparent_sorting && !m_custom_sort) ||
                          !scene.layer_texture_sources.empty()) {}

    std::unique_ptr<rg::RenderGraph> build() {
        const bool shadows_changed = m_scene.shadows.dirty;
        RefreshSceneShadows(m_scene);
        if (shadows_changed && m_scene.volumetric_cast_count) m_scene.volumetric_dirty=true;
        if (m_scene.volumetric_dirty && m_scene.prepare_volumetrics && !m_scene.prepare_volumetrics())
            return nullptr;
        PrepareSceneReflection(m_scene, reflectionRequested(m_scene.sceneGraph.get()));
        m_ordered_objects = m_ordered_objects || m_scene.reflection.requested;
        for (const auto& weak : m_scene.transparent_order)
            if (const auto node = weak.lock()) node->SetTransparentSortTracking(false);
        m_scene.render_excluded_nodes.clear();
        m_compose_enabled = m_scene.activeCamera != nullptr;
        if (m_compose_enabled) {
            for (const auto& [name, camera] : m_scene.cameras) {
                if (camera.get() != m_scene.activeCamera) continue;
                if (m_active_camera_key.empty() || name < m_active_camera_key)
                    m_active_camera_key = name;
            }
        }
        if (m_ordered_objects) {
            // A later source may be sampled before its first write this frame.
            // Give each retained layer picture an explicit previous-frame version.
            rg::RenderGraphBuilder builder(*m_graph);
            for (const i32 id : m_scene.layer_texture_sources) {
                const auto key = LayerCompositeTargetKey(id);
                ensureCompositeRecord(key);
                auto* initial = builder.createTexNode(texDesc(key, true), false);
                builder.markVirtualWrite(initial);
                m_initial_composites.emplace(id, initial);
            }
        }
        if (m_scene.sceneGraph != nullptr) {
            shadowPasses();
            if (m_scene.reflection.requested) {
                m_reflection_pass=true;
                if (m_scene.clearEnabled || !m_scene.reflection_enabled)
                    clearTarget(std::string(kReflectionTarget),false);
                m_sorted_prefix_size=m_emitted_passes.size();
                if (m_scene.reflection_enabled) walk(m_scene.sceneGraph);
                // Layer links observe the picture available in this phase. Resolve
                // them before ordinary draws replace those pictures in the map.
                resolveLinks();
                for (const auto& [id, picture] : m_picture_composite)
                    m_initial_composites[id] = picture;
                m_consumers.clear();
                m_picture_composite.clear();
                m_picture_scene.clear();
                m_picture_first_buffer.clear();
                m_reflection_pass=false;
                m_cleared.clear();
            } else m_sorted_prefix_size = m_emitted_passes.size();
            walk(m_scene.sceneGraph);
        }
        // WE copies the drawn scene into _rt_MipMappedFrameBuffer before bloom and
        // the combine (sub_14017FA70), and only while reflection quality is on.
        if (m_mip_frame_sampled && m_scene.reflection_enabled) {
            addCopy(std::string(SpecTex_Default), resolve(WE_MIP_MAPPED_FRAME_BUFFER));
        }
        if (m_scene.transparent_sorting && !m_custom_sort)
            m_scene.transparent_order = std::move(m_next_transparent_order);
        m_postprocessing = true;
        volumetricPasses();
        postProcesses();
        resolveLinks();
        sequenceSortedPasses();
        declareHistory();
        applyLoadActions();
        return std::move(m_graph);
    }

private:
    // ---- names and small queries -------------------------------------------------

    std::string resolve(std::string_view name) const {
        auto key=m_scene.ResolveRenderTargetName(name);
        return m_reflection_pass && key==SpecTex_Default ? std::string(kReflectionTarget) : key;
    }
    std::vector<SceneNode*>& sortedOwners() { return m_reflection_pass ? m_reflected_owners : m_sorted_owners; }
    static bool samplesReflection(SceneNode* node) {
        if (!node || !node->Mesh()) return false;
        const auto& mesh=*node->Mesh();
        for (const auto& part:mesh.Submeshes()) {
            const auto* material=mesh.MaterialForSlot(part.material_slot);
            if(material && std::find(material->textures.begin(),material->textures.end(),kReflectionTarget)!=material->textures.end()) return true;
        }
        return false;
    }
    bool reflectionRequested(SceneNode* node) {
        if (!node) return false;
        // WE's scene flag comes from object flag 8, which the model material
        // loader sets for this sampler. An image sampler alone does not enable it.
        if (node->PlanarReflectionKind() == SceneNode::ReflectionKind::Model &&
            samplesReflection(node)) return true;
        for(const auto& child:node->GetChildren()) if(reflectionRequested(child.get())) return true;
        return false;
    }
    bool reflected(SceneNode* node) const {
        while(node && node->Name().empty() && node->Parent()) node=node->Parent();
        // With transparent sorting, WE appends its global marked list to both
        // scene phases, independently of membership in the reflected base list.
        if (node && m_scene.transparent_sorting && !m_custom_sort &&
            node->TransparentSortKind() != SceneNode::TransparentSort::Unmarked) return true;
        if(!node || !node->Reflected()) return false;
        return node->PlanarReflectionKind()!=SceneNode::ReflectionKind::Model || !samplesReflection(node);
    }

    static TexNode::Desc texDesc(const std::string& key, bool temp) {
        return TexNode::Desc { .name = key,
                               .key  = key,
                               .type = temp ? TexNode::TexType::Temp : TexNode::TexType::Imported };
    }

    void logOnce(const std::string& message) {
        if (m_logged.insert(message).second) LOG_ERROR("render graph: %s", message.c_str());
    }

    bool referenced(i32 id) const { return id != 0 && m_scene.layer_texture_sources.contains(id); }

    SceneCamera* cameraOf(SceneNode* node) const {
        if (node == nullptr) return nullptr;
        const auto found = m_scene.cameras.find(node->Camera());
        return found == m_scene.cameras.end() ? nullptr : found->second.get();
    }

    SceneImageEffectLayer* chainOf(SceneNode* node) const {
        SceneCamera* camera = cameraOf(node);
        if (camera == nullptr || ! camera->HasImgEffect()) return nullptr;
        return camera->GetImgEffect().get();
    }

    bool isCompose(SceneNode* node) const {
        if (! m_compose_enabled) return false;
        SceneCamera* camera = cameraOf(node);
        return camera != nullptr && camera->HasImgEffect() && camera->IsComposeLayer() &&
               camera->GetAttachedNode().get() == node;
    }

    // The node or an ancestor is hidden and nothing but a reload can change that.
    static bool hiddenForGood(const SceneNode* node) {
        for (; node != nullptr; node = node->Parent()) {
            if (! node->Visible() && node->VisibilitySettled()) return true;
        }
        return false;
    }

    // Must produce, is sampled by another layer, or has a descendant like that.
    bool producing(SceneNode* node) {
        const auto cached = m_producing.find(node);
        if (cached != m_producing.end()) return cached->second;
        bool result = node->MustProduce() || referenced(node->ID());
        if (! result) {
            for (const auto& child : node->GetChildren()) {
                if (child != nullptr && producing(child.get())) {
                    result = true;
                    break;
                }
            }
        }
        m_producing[node] = result;
        return result;
    }

    bool leftOut(SceneNode* node) { return ! producing(node) && hiddenForGood(node); }

    // ---- walking the tree --------------------------------------------------------

    void transparentSortedChildren(const SceneNode& parent) {
        struct Entry {
            std::shared_ptr<SceneNode> node;
            std::size_t scene_index;
            std::size_t previous_index;
            float depth;
            int alpha_depth;
            bool marked;
        };
        std::unordered_map<const SceneNode*, std::size_t> previous;
        for (std::size_t i = 0; i < m_scene.transparent_order.size(); ++i)
            if (const auto node = m_scene.transparent_order[i].lock()) previous[node.get()] = i;
        const linalg::Vector3f direction = m_scene.activeCamera
            ? m_scene.activeCamera->GetDirection().cast<float>() : linalg::Vector3f(0, 0, -1);
        std::vector<Entry> entries;
        const auto collect = [&](const auto& self, const std::shared_ptr<SceneNode>& node,
                                 int alpha_depth) -> void {
            if (!node) return;
            // Particle renderer mirrors and event children have no layer name: they
            // draw as part of the enclosing authored layer, not as new scene objects.
            const SceneNode* owner = node.get();
            while (owner->Name().empty() && owner->Parent()) owner = owner->Parent();
            const auto kind = owner->TransparentSortKind();
            const int runtime_index = m_scene.runtime ? m_scene.runtime->LayerIndex(owner->Name()) : -1;
            const std::size_t scene_index = runtime_index >= 0
                ? static_cast<std::size_t>(runtime_index) : entries.size();
            const auto last = previous.find(owner);
            const auto previous_index = last != previous.end() ? last->second
                : m_scene.transparent_order.size() + scene_index;
            linalg::Vector3f origin = owner->Translate();
            if (m_scene.runtime) origin = m_scene.runtime->NodeSortingOrigin(*owner);
            else if (const auto raw = m_scene.sorting_origins.find(owner);
                     raw != m_scene.sorting_origins.end()) origin = raw->second;
            float depth = kind == SceneNode::TransparentSort::Last
                ? -std::numeric_limits<float>::infinity()
                : (origin.y() * direction.y() + origin.x() * direction.x()) + origin.z() * direction.z();
            entries.push_back({node, scene_index, previous_index, depth, alpha_depth,
                               kind != SceneNode::TransparentSort::Unmarked});
            if (isCompose(node.get())) return;
            const auto next = alpha_depth + (node->ChildrenAlphaMax() ? 1 : 0);
            for (const auto& child : node->GetChildren()) self(self, child, next);
        };
        for (const auto& child : parent.GetChildren()) collect(collect, child, 0);
        std::stable_sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
            if (a.marked != b.marked) return !a.marked;
            if (!a.marked) return a.scene_index < b.scene_index;
            if (a.depth != b.depth) return a.depth > b.depth;
            return a.previous_index < b.previous_index;
        });
        const auto inherited = m_alpha_max_depth;
        for (const auto& entry : entries) {
            m_sort_owner = entry.node.get();
            while (m_sort_owner->Name().empty() && m_sort_owner->Parent())
                m_sort_owner = m_sort_owner->Parent();
            if (std::find(sortedOwners().begin(), sortedOwners().end(), m_sort_owner) ==
                sortedOwners().end()) sortedOwners().push_back(m_sort_owner);
            if(!m_reflection_pass) m_next_transparent_order.push_back(entry.node);
            m_alpha_max_depth = inherited + entry.alpha_depth;
            walk(entry.node, isCompose(entry.node.get()));
        }
        m_alpha_max_depth = inherited;
        m_sort_owner = nullptr;
    }

    void customSortedChildren(const SceneNode& parent) {
        struct Entry {
            std::shared_ptr<SceneNode> node;
            int32_t order;
            std::size_t scene_index;
            int alpha_depth;
        };
        std::vector<Entry> entries;
        const auto collect = [&](const auto& self, const std::shared_ptr<SceneNode>& node,
                                  int depth) -> void {
            if (!node) return;
            const auto index = m_scene.runtime->LayerIndex(node->Name());
            const auto scene_index = index >= 0 ? static_cast<std::size_t>(index)
                : m_scene.runtime->LayerCount() + entries.size();
            entries.push_back({node, m_scene.runtime->NodeSortOrder(node->Name()).value_or(0), scene_index, depth});
            // A composition's descendants produce its private input before it is drawn.
            // Ordinary parenting only supplies transforms: its descendants participate in
            // the same global sort, even when their parents have different sort orders.
            if (isCompose(node.get())) return;
            const auto next = depth + (node->ChildrenAlphaMax() ? 1 : 0);
            for (const auto& child : node->GetChildren()) self(self, child, next);
        };
        for (const auto& child : parent.GetChildren()) collect(collect, child, 0);
        std::stable_sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
            return a.order != b.order ? a.order < b.order : a.scene_index < b.scene_index;
        });
        const auto inherited = m_alpha_max_depth;
        for (const auto& entry : entries) {
            m_alpha_max_depth = inherited + entry.alpha_depth;
            walk(entry.node, isCompose(entry.node.get()));
        }
        m_alpha_max_depth = inherited;
    }

    void walk(const std::shared_ptr<SceneNode>& handle, bool traverse_children = true) {
        SceneNode* node = handle.get();
        if (node == nullptr) return;
        // Linked composites follow the authored traversal even without depth
        // sorting. A compose object owns its descendants' private work; ordinary
        // parenting does not combine separate scene objects into one group.
        struct OwnerScope {
            SceneNode*& owner;
            SceneNode* previous;
            int& compose_depth;
            bool composition;
            ~OwnerScope() { owner = previous; if (composition) --compose_depth; }
        } scope {m_sort_owner, m_sort_owner, m_compose_depth, false};
        if (m_ordered_objects && node != m_scene.sceneGraph.get()) {
            if (m_compose_depth == 0) {
                m_sort_owner = node;
                while (m_sort_owner->Name().empty() && m_sort_owner->Parent())
                    m_sort_owner = m_sort_owner->Parent();
            }
            if (isCompose(node)) {
                ++m_compose_depth;
                scope.composition = true;
            }
        }
        if (leftOut(node)) {
            m_scene.render_excluded_nodes.push_back(handle);
            return;
        }
        // Wallpaper Engine keeps alpha MAX on for everything drawn while a layer
        // without copybackground draws its children, their own effect passes
        // included, and counts nested layers (ctx+457 in sub_1401ECB20).
        const auto children = [&] {
            if (!traverse_children) return;
            const bool alpha_max = node->ChildrenAlphaMax();
            if (alpha_max) ++m_alpha_max_depth;
            if (m_custom_sort) customSortedChildren(*node);
            else if (m_scene.transparent_sorting && node == m_scene.sceneGraph.get())
                transparentSortedChildren(*node);
            else for (const auto& child : node->GetChildren()) walk(child);
            if (alpha_max) --m_alpha_max_depth;
        };
        if (m_reflection_pass && node!=m_scene.sceneGraph.get() && (m_compose_depth==0 || (isCompose(node) && m_compose_depth==1)) && !reflected(node)) {
            if (!isCompose(node)) children();
            return;
        }
        if (node->Mesh() == nullptr) {
            children();
            return;
        }
        SceneImageEffectLayer* layer = chainOf(node);
        // A text layer none of whose effects runs draws straight onto the scene (T.7.2).
        if (layer != nullptr && layer->DrawsOwnerDirectly()) layer = nullptr;
        if (layer == nullptr) {
            if (! node->SkipRenderPass())
                drawCard(node, nullptr, false);
            children();
            return;
        }
        if (isCompose(node)) {
            if (node->SkipRenderPass()) clearChainInput(layer);
            else drawCard(node, layer, true);
            children();
            drawChain(node, layer);
        } else if (node->SkipRenderPass()) {
            children();
            clearChainInput(layer);
            drawChain(node, layer);
        } else {
            drawCard(node, layer, false);
            drawChain(node, layer);
            children();
        }
    }

    void volumetricPasses() {
        if (m_scene.volumetric_lights.empty()) return;
        // Depth belongs to the scene draw, so keep this stage after every scene
        // object even when the back-buffer depth was never a colour graph node.
        const auto scene_steps = m_emitted_passes;
        const auto begin = m_emitted_passes.size();
        clearTarget("_rt_volumetricsLightBuffer");
        for (const auto& volume : m_scene.volumetric_lights) {
            if (!volume.light->castsVolumetrics()) continue;
            auto* light_node = volume.light->node();
            if (light_node == nullptr || !light_node->Visible()) continue;
            DrawPass::Desc depth;
            depth.node = volume.back.get();
            depth.visibility_node = volume.back.get();
            depth.output = "_rt_volumetricsSingle";
            depth.depth_only = true;
            depth.clear_depth_on_first_use = true;
            depth.depth_clear = 1.0f;
            depth.depth_override = SceneDepthState{true,true,DepthCompare::LessEqual};
            const auto* pass=m_graph->addPass<DrawPass>("volumetric back faces",PassNode::Type::CustomShader,
                [&](rg::RenderGraphBuilder& b,DrawPass::Desc& out){
                    out=depth;b.write(b.createTexNode(texDesc(depth.output,true),true));
                });
            recordPass(pass->ID());
            for (const auto& node : {volume.front,volume.fullscreen}) {
                DrawSource source;
                source.node=node.get();source.visibility_node=node.get();
                source.destination="_rt_volumetricsLightBuffer";
                drawNode(source);
                if (auto* front=dynamic_cast<DrawPass*>(m_graph->getPass(m_emitted_passes.back())))
                    front->desc().cull_override=node==volume.fullscreen ? CullMode::None : CullMode::Back;
            }
        }
        if (m_scene.volumetric_combine) {
            for (const auto& step:m_scene.volumetric_combine->steps) {
                const auto* pass=std::get_if<ScenePostProcessPass>(&step);
                if (!pass) continue;
                DrawSource source;
                source.node=pass->node.get();source.visibility_node=source.node;
                source.destination=pass->output;drawNode(source);
            }
        }
        if (begin < m_emitted_passes.size()) {
            for (const auto id:scene_steps)m_graph->orderBefore(id,m_emitted_passes[begin]);
            for (auto i=begin+1;i<m_emitted_passes.size();++i)
                m_graph->orderBefore(m_emitted_passes[i-1],m_emitted_passes[i]);
        }
    }

    void postProcesses() {
        for (const auto& post : m_scene.post_processes) {
            if (post == nullptr) continue;
            for (const auto& step : post->steps) {
                if (const auto* pass = std::get_if<ScenePostProcessPass>(&step)) {
                    SceneNode* node = pass->node.get();
                    if (node == nullptr || node->Mesh() == nullptr || node->SkipRenderPass()) continue;
                    if (pass->output.empty()) {
                        logOnce("a post-process step has no output");
                        continue;
                    }
                    DrawSource source;
                    source.node            = node;
                    source.visibility_node = node;
                    source.image_id        = node->ID();
                    source.destination     = resolve(pass->output);
                    source.redirect_from   = node->Parent();
                    drawNode(source);
                } else if (const auto* copy = std::get_if<ScenePostProcessCopy>(&step)) {
                    if (copy->src.empty() || copy->dst.empty()) {
                        logOnce("a post-process copy lacks an endpoint");
                        continue;
                    }
                    addCopy(resolve(copy->src), resolve(copy->dst));
                }
            }
        }
    }

    // ---- cards, clears and effect chains -----------------------------------------

    void drawCard(SceneNode* node, SceneImageEffectLayer* layer, bool compose) {
        DrawSource source;
        source.node            = node;
        source.visibility_node = node;
        source.image_id        = node->ID();
        source.redirect_from   = node->Parent();
        if (layer == nullptr) {
            source.destination = std::string(SpecTex_Default);
            source.role        = PictureRole::PlainCard;
        } else {
            source.destination = resolve(layer->FirstTarget());
            source.role        = PictureRole::ChainCard;
            // A compose layer's card reads the screen behind it, so it is drawn
            // through the scene's camera.
            if (compose) source.camera = m_active_camera_key;
        }
        drawNode(source);
        if (layer == nullptr || compose) return;
        for (const auto& overlay : layer->CardOverlays()) {
            if (overlay == nullptr) continue;
            DrawSource paint;
            paint.node            = overlay.get();
            paint.visibility_node = overlay.get();
            paint.image_id        = node->ID();
            paint.redirect_from   = node->Parent();
            paint.destination     = source.destination;
            drawNode(paint);
        }
    }

    void clearChainInput(SceneImageEffectLayer* layer) {
        if (! m_cleared.insert(layer).second) return;
        clearTarget(resolve(layer->FirstTarget()));
    }

    void clearTarget(const std::string& key, bool transparent=true) {
        const auto* pass = m_graph->addPass<ClearPass>(
            "clear effect input", PassNode::Type::Clear,
            [&](rg::RenderGraphBuilder& b, ClearPass::Desc& desc) {
                desc.sort_owner  = m_sort_owner;
                desc.reflection_pass=m_reflection_pass;
                desc.result      = key;
                desc.transparent = transparent;
                b.write(b.createTexNode(texDesc(key, true), true));
            });
        recordPass(pass->ID());
    }

    void drawChain(SceneNode* owner, SceneImageEffectLayer* layer) {
        layer->ResolveEffect(m_scene.default_effect_mesh, "effect");
        SceneNode* final_node = layer->ResolvedFinalRenderNode();
        for (std::size_t index = 0; index < layer->EffectCount(); ++index) {
            const auto effect = layer->GetEffect(index);
            if (effect == nullptr || ! effect->included) continue;
            std::vector<SceneImageEffect::Command> commands = effect->commands;
            std::stable_sort(commands.begin(), commands.end(), [](const auto& a, const auto& b) {
                return a.afterpos < b.afterpos;
            });
            std::vector<SceneImageEffectNode*> steps;
            for (auto& step : effect->nodes) steps.push_back(&step);
            for (std::size_t position = 0; position <= steps.size(); ++position) {
                for (const auto& command : commands) {
                    if (command.afterpos != static_cast<i32>(position)) continue;
                    if (command.src.empty() || command.dst.empty()) {
                        logOnce("an effect command lacks an endpoint");
                        continue;
                    }
                    addCopy(resolve(command.src), resolve(command.dst));
                }
                if (position == steps.size()) break;
                m_has_effect_graph.insert(owner->ID());
                SceneImageEffectNode& step = *steps[position];
                if (step.sceneNode == nullptr) continue;
                DrawSource source;
                source.node            = step.sceneNode.get();
                source.visibility_node = owner;
                source.image_id        = owner->ID();
                source.destination     = m_scene.ResolveRenderTargetName(step.output);
                source.redirect_from   = owner->Parent();
                source.role = source.node == final_node ? PictureRole::ChainFinal : PictureRole::None;
                drawNode(source);
            }
        }
    }

    // ---- shadow atlas ------------------------------------------------------------

    static void collectCasters(SceneNode* node, std::vector<SceneNode*>& out) {
        if (node == nullptr) return;
        if (node->CastsShadow() && node->EffectiveVisible() &&
            node->Mesh() != nullptr && !node->ShadowCasterSlots().empty()) out.push_back(node);
        for (const auto& child : node->GetChildren()) collectCasters(child.get(), out);
    }

    // Wallpaper Engine draws each shadow view's casters before the scene (sub_140190C80,
    // sub_140196530): depth only into the view's tile of `_rt_shadowAtlas`, reversed depth
    // cleared to 0 once a frame and compared GREATER; a point light's six faces each into
    // their own viewport of its tile. One draw per viewport here (instance 0 of the caster
    // shader's viewport matrices).
    void shadowPasses() {
        const auto& shadows = m_scene.shadows;
        const std::string atlas(kShadowAtlas);
        if (! shadows.active() || ! m_scene.renderTargets.contains(atlas)) return;
        std::vector<SceneNode*> casters;
        collectCasters(m_scene.sceneGraph.get(), casters);
        if (casters.empty()) return;
        bool first = true;
        for (const auto& view : shadows.views) {
            for (std::size_t face = 0; face < view.cameras.size(); ++face) {
                for (SceneNode* node : casters) {
                    const auto&       slots = node->ShadowCasterSlots();
                    const std::size_t count = std::max<std::size_t>(node->Mesh()->Submeshes().size(), 1);
                    for (std::size_t sub = 0; sub < std::min(count, slots.size()); ++sub) {
                        if (slots[sub] == kNoShadowCasterSlot) continue;
                        const SceneMaterial* material = node->Mesh()->MaterialForSlot(slots[sub]);
                        if (material == nullptr) continue;
                        DrawPass::Desc desc;
                        desc.node                     = node;
                        desc.visibility_node          = node;
                        desc.output                   = atlas;
                        desc.camera_override          = view.cameras[face];
                        desc.submesh_index            = sub;
                        desc.material_slot            = slots[sub];
                        desc.depth_only               = true;
                        desc.viewport_uv              = view.viewports[face];
                        desc.clear_depth_on_first_use = first;
                        desc.depth_override           = SceneDepthState {
                            .test = true, .write = true, .compare = DepthCompare::Greater };
                        // The view's constant offset (`CasterOffset`) alone leaves surfaces
                        // lit at a grazing angle shadowing themselves in stripes; push them
                        // further toward the reversed far plane by their slope, clamped.
                        desc.depth_bias_slope         = kShadowCasterSlopeBias;
                        desc.depth_bias_clamp         = kShadowCasterBiasClamp;
                        desc.textures.assign(material->textures.size(), std::string {});
                        for (std::size_t i = 0; i < material->textures.size(); ++i) {
                            if (! material->textures[i].empty() && ! IsSpecLinkTex(material->textures[i]))
                                desc.textures[i] = resolve(material->textures[i]);
                        }
                        first = false;
                        const auto* pass = m_graph->addPass<DrawPass>(
                            material->name, PassNode::Type::CustomShader,
                            [&](rg::RenderGraphBuilder& b, DrawPass::Desc& out) {
                                out = desc;
                                for (const auto& key : desc.textures) {
                                    if (key.empty()) continue;
                                    b.read(b.createTexNode(texDesc(key, IsSpecTex(key)), false));
                                }
                                b.write(b.createTexNode(texDesc(atlas, true), true));
                            });
                        recordPass(pass->ID());
                    }
                }
            }
        }
    }

    // ---- draws -------------------------------------------------------------------

    void drawNode(const DrawSource& source) {
        SceneNode* node = source.node;
        if (node == nullptr || node->Mesh() == nullptr) return;
        SceneMesh* mesh = node->Mesh();
        if (source.destination.empty()) {
            logOnce("a draw has no destination");
            return;
        }
        const auto& submeshes = mesh->Submeshes();
        if (submeshes.size() > 1) {
            for (std::size_t index = 0; index < submeshes.size(); ++index) {
                const uint32_t slot = submeshes[index].material_slot;
                if (mesh->MaterialForSlot(slot) == nullptr) continue;
                if (submeshes[index].clear_output && ! submeshes[index].output_override.empty())
                    clearTarget(resolve(submeshes[index].output_override));
                emitDraw(source, index, slot, submeshes[index].output_override);
            }
        } else if (mesh->MaterialForSlot(0) != nullptr) {
            emitDraw(source, 0, 0, {});
        }
    }

    // Where a draw that would go to the scene output really goes when a compose
    // layer encloses it.
    Route redirect(const DrawSource& source) const {
        Route route { source.destination, source.camera };
        if (! m_compose_enabled || source.destination != SpecTex_Default) return route;
        for (SceneNode* node = source.redirect_from; node != nullptr; node = node->Parent()) {
            if (! isCompose(node)) continue;
            SceneCamera* camera = cameraOf(node);
            route.dest          = resolve(camera->GetImgEffect()->FirstTarget());
            if (! camera->ChildrenUseSceneCamera()) route.camera = node->Camera();
            return route;
        }
        return route;
    }

    void ensureCompositeRecord(const std::string& key) {
        if (m_scene.renderTargets.contains(key)) return;
        SceneRenderTarget record {};
        if (const SceneRenderTarget* output = m_scene.FindRenderTarget(SpecTex_Default)) {
            record.width  = output->width;
            record.height = output->height;
            record.format = output->format;
        } else {
            record.width  = std::max<i32>(1, m_scene.ortho[0]);
            record.height = std::max<i32>(1, m_scene.ortho[1]);
            record.format = m_scene.hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8;
        }
        record.allowReuse         = true;
        m_scene.renderTargets[key] = record;
    }

    void emitDraw(const DrawSource& source, std::size_t submesh, uint32_t slot,
                  const std::string& output_override) {
        SelectSceneShadowMaterial(m_scene, source.node, slot);
        SceneMaterial* material = source.node->Mesh()->MaterialForSlot(slot);
        if (material == nullptr) return;

        std::vector<Route> routes;
        Route plain = redirect(source);
        if(m_reflection_pass && plain.dest==SpecTex_Default) plain.dest=std::string(kReflectionTarget);
        const bool composite_only =
            source.visibility_node != nullptr && source.visibility_node->CompositeOnly();
        if (! output_override.empty()) {
            routes.push_back({ resolve(output_override), plain.camera, true });
        } else if (referenced(source.image_id) && source.destination == SpecTex_Default) {
            const std::string composite = LayerCompositeTargetKey(source.image_id);
            ensureCompositeRecord(composite);
            const std::string local_camera = LayerCompositeCameraKey(source.image_id);
            routes.push_back({ composite,
                               m_scene.cameras.contains(local_camera) ? local_camera : plain.camera });
            if (! composite_only && ! hiddenForGood(source.visibility_node)) routes.push_back(plain);
        } else {
            routes.push_back(plain);
        }
        // Only what would reach the scene is dropped; the buffers of an effect chain are not.
        if (composite_only && source.destination == SpecTex_Default) {
            std::erase_if(routes, [](const Route& route) {
                return ! std::string_view(route.dest).starts_with(WE_IMAGE_LAYER_COMPOSITE_PREFIX);
            });
        }
        for (std::size_t index = 0; index < routes.size(); ++index)
            emitPass(source, submesh, slot, *material, routes[index], index == 0);
    }

    std::string snapshotKey(const std::string& output) {
        std::string key;
        do {
            key = output + "_snapshot_" + std::to_string(m_snapshot_count++);
        } while (m_scene.renderTargets.contains(key) || m_scene.renderTargetAliases.contains(key));
        return key;
    }

    // Wallpaper Engine's colour write mask is RGB unless a pass asks for alpha
    // (sub_140099F60): `alphawriting: enabled` (sub_140155FC0) or alpha MAX, which
    // forces RGBA. Its layer and chain buffers are written with alpha, the scene
    // output is not.
    static bool ResolveWriteAlpha(bool scene_output, AlphaWriting writing, bool alpha_max) {
        if (writing == AlphaWriting::Enabled || alpha_max) return true;
        if (writing == AlphaWriting::Disabled) return false;
        return ! scene_output;
    }

    void emitPass(const DrawSource& source, std::size_t submesh, uint32_t slot,
                  const SceneMaterial& material, const Route& route, bool first_route) {
        DrawPass::Desc desc;
        desc.sort_owner      = m_sort_owner;
        desc.reflection_pass = m_reflection_pass;
        desc.node            = source.node;
        desc.visibility_node = source.visibility_node;
        desc.output          = route.dest;
        desc.camera_override = route.camera;
        const auto camera_name = route.camera.empty() ? source.node->Camera() : route.camera;
        const auto camera = m_scene.cameras.find(camera_name);
        if (m_reflection_pass && (route.dest == kReflectionTarget ||
            (camera != m_scene.cameras.end() && camera->second.get() == m_scene.activeCamera))) {
            // The mirrored camera reverses world winding and WE keeps the same front
            // face (reflection-cull-v7 with ordinary-cull-v1): no flip here.
            desc.camera_override=std::string(kReflectionCamera);
        }
        desc.submesh_index   = submesh;
        desc.material_slot   = slot;
        desc.force_single_sample = m_postprocessing;
        // A layer's own picture into its composite keeps source-over coverage, as
        // the first pass of Wallpaper Engine's chain buffer does (sub_1401EA500);
        // inside a layer without copybackground alpha is MAX; otherwise the
        // material's own alpha factors.
        const bool alpha_max = m_alpha_max_depth > 0;
        if (source.role == PictureRole::PlainCard &&
            std::string_view(route.dest).starts_with(WE_IMAGE_LAYER_COMPOSITE_PREFIX))
            desc.alpha_rule = AlphaBlendRule::SourceOver;
        else if (alpha_max) desc.alpha_rule = AlphaBlendRule::Max;
        else desc.alpha_rule = AlphaBlendRule::Material;
        // Native rgb888 has no stored alpha. Metal's RGBA8 backing keeps the
        // clear's opaque alpha even when a material explicitly writes alpha.
        desc.write_alpha = route.dest != kReflectionTarget &&
            ResolveWriteAlpha(route.dest == SpecTex_Default, material.alpha_writing, alpha_max);
        // What a chain leaves in its layer's composite is its last pass as written.
        desc.replace_target = source.role == PictureRole::ChainFinal &&
                              std::string_view(route.dest).starts_with(WE_IMAGE_LAYER_COMPOSITE_PREFIX);
        desc.textures.assign(material.textures.size(), std::string {});

        std::vector<std::pair<uint32_t, i32>> links;
        bool                                  samples_own_output = false;
        for (std::size_t i = 0; i < material.textures.size(); ++i) {
            const std::string& name = material.textures[i];
            if (name.empty()) continue;
            if (name == kReflectionTarget && !m_scene.reflection.requested) continue;
            if (IsSpecLinkTex(name)) {
                links.emplace_back(static_cast<uint32_t>(i), static_cast<i32>(ParseLinkTex(name)));
                continue;
            }
            const std::string key = resolve(name);
            if(m_reflection_pass && key==kReflectionTarget && route.dest==kReflectionTarget) {
                // The native reflection attachment is not simultaneously bound
                // as an SRV: reads return zero, including alpha. General scene
                // framebuffer feedback still uses its existing snapshot below.
                auto [entry,inserted]=m_scene.textures.try_emplace(kUnboundTextureName);
                if(inserted) {
                    entry->second.url=kUnboundTextureName;
                    entry->second.sample=RuntimeImageSource::UnboundTextureImage()->header.sample;
                }
                desc.textures[i]=kUnboundTextureName;
                continue;
            }
            desc.textures[i]      = key;
            if (std::string_view(key).starts_with(WE_MIP_MAPPED_FRAME_BUFFER))
                m_mip_frame_sampled = true;
            if (! IsSpecTex(name)) {
                const auto texture = m_scene.textures.find(name);
                if (texture != m_scene.textures.end() && texture->second.isSprite)
                    desc.sprites_map[i] = texture->second.spriteAnim;
            }
            if (IsSpecTex(key) && key == route.dest) samples_own_output = true;
        }

        // A target is never read while it is drawn into: the draw reads a copy of it.
        if (samples_own_output) {
            const std::string snapshot = snapshotKey(route.dest);
            addCopy(route.dest, snapshot);
            for (auto& key : desc.textures) {
                if (key == route.dest) key = snapshot;
            }
        }

        TexNode* written = nullptr;
        PassNode* node = m_graph->addPass<DrawPass>(
            material.name, PassNode::Type::CustomShader,
            [&](rg::RenderGraphBuilder& b, DrawPass::Desc& out) {
                out = desc;
                for (const auto& key : desc.textures) {
                    if (key.empty()) continue;
                    b.read(b.createTexNode(texDesc(key, IsSpecTex(key)), false));
                }
                written = b.createTexNode(texDesc(route.dest, true), true);
                b.write(written);
            });
        recordPass(node->ID());
        for (const auto& [index, layer] : links)
            m_consumers.push_back({ node->ID(), index, layer, source.image_id });
        recordPicture(source, route, first_route, written);
    }

    void recordPicture(const DrawSource& source, const Route& route, bool first_route,
                       TexNode* written) {
        const i32 id = source.image_id;
        if (id == 0 || written == nullptr) return;
        // A submesh drawn into its own override target says nothing about the layer's picture.
        if (route.overridden && (referenced(id) || route.dest != SpecTex_Default)) return;
        if (referenced(id)) {
            const bool is_picture =
                source.role == PictureRole::PlainCard || source.role == PictureRole::ChainFinal;
            if (is_picture && first_route) m_picture_composite[id] = written;
        } else if (route.dest == SpecTex_Default && ! m_picture_scene.contains(id)) {
            m_picture_scene[id] = written;
        }
        if (source.role == PictureRole::ChainCard) m_picture_first_buffer[id] = written;
    }

    // ---- copies ------------------------------------------------------------------

    // A copy of `source` (its latest version, or the given one) into `destination`.
    PassNode* addCopy(const std::string& source, const std::string& destination,
                      TexNode* source_version = nullptr, TexNode** written = nullptr) {
        PassNode* node = m_graph->addPass<CopyPass>(
            "copy", PassNode::Type::Copy, [&](rg::RenderGraphBuilder& b, CopyPass::Desc& desc) {
                TexNode* in = source_version != nullptr
                                  ? source_version
                                  : b.createTexNode(texDesc(source, IsSpecTex(source)), false);
                b.read(in);
                TexNode* out = b.createTexNode(texDesc(destination, true), true);
                b.write(out);
                desc.sort_owner = m_sort_owner;
                desc.reflection_pass=m_reflection_pass;
                desc.src = source;
                desc.dst = destination;
                if (written != nullptr) *written = out;
            });
        recordPass(node->ID());
        return node;
    }

    // The picture of layer `id` that a link copies, chosen by what the layer drew.
    TexNode* picture(i32 id) const {
        if (referenced(id)) {
            const auto found = m_picture_composite.find(id);
            if (found != m_picture_composite.end()) return found->second;
        } else {
            const auto found = m_picture_scene.find(id);
            if (found != m_picture_scene.end()) return found->second;
        }
        if (! m_has_effect_graph.contains(id)) {
            const auto found = m_picture_first_buffer.find(id);
            if (found != m_picture_first_buffer.end()) return found->second;
        }
        return nullptr;
    }

    void resolveLinks() {
        // References where the producer was emitted before the consumer follow the
        // scene's draw order and are linked first; a reference in the other direction
        // then sees whether the later layer already depends on the earlier one and,
        // when it does, reads the later layer's composite from the previous frame.
        const auto in_scene_order = [&](const LinkConsumer& consumer) {
            const TexNode* source = picture(consumer.layer);
            return source != nullptr && source->writer() != nullptr &&
                   source->writer()->ID() < consumer.pass;
        };
        std::vector<const LinkConsumer*> ordered;
        ordered.reserve(m_consumers.size());
        for (const LinkConsumer& consumer : m_consumers) {
            if (in_scene_order(consumer)) ordered.push_back(&consumer);
        }
        for (const LinkConsumer& consumer : m_consumers) {
            if (! in_scene_order(consumer)) ordered.push_back(&consumer);
        }

        struct LinkTarget {
            TexNode* history { nullptr };
            TexNode* current { nullptr };
        };
        std::unordered_map<i32, LinkTarget> links;

        for (const LinkConsumer* item : ordered) {
            const LinkConsumer& consumer = *item;
            TexNode*            source   = picture(consumer.layer);
            if (source == nullptr) {
                // A reflected reader can name a layer excluded from this phase.
                // Its persistent composite still holds the previous scene picture.
                const auto initial = m_initial_composites.find(consumer.layer);
                if (m_reflection_pass && initial != m_initial_composites.end()) {
                    auto* version = initial->second;
                    m_graph->afterBuild(consumer.pass, [&](rg::RenderGraphBuilder& b, rg::Pass&) {
                        b.read(version);
                        return true;
                    });
                    if (auto* draw = dynamic_cast<DrawPass*>(m_graph->getPass(consumer.pass))) {
                        draw->setDescTex(consumer.slot, version->key());
                        if (m_scene.shaderValueUpdater)
                            m_scene.shaderValueUpdater->SetRenderTargetBinding(
                                draw->desc().node, draw->desc().material_slot,
                                consumer.slot, version->key());
                    }
                    m_ordered_link_sources.insert(std::string(version->key()));
                    continue;
                }
                logOnce("layer " + std::to_string(consumer.layer) + " produced no picture to link");
                continue;
            }
            auto* consumer_draw = dynamic_cast<DrawPass*>(m_graph->getPass(consumer.pass));
            const auto* source_draw = source->writer() != nullptr
                ? dynamic_cast<const DrawPass*>(m_graph->getPass(source->writer()->ID())) : nullptr;
            if (consumer_draw != nullptr && source_draw != nullptr &&
                consumer_draw->desc().sort_owner != nullptr &&
                std::string_view(source->key()).starts_with(WE_IMAGE_LAYER_COMPOSITE_PREFIX) &&
                consumer.owner != consumer.layer && consumer_draw->desc().output != source->key()) {
                // A sorted object observes the retained picture at its position in
                // the frame: earlier producers are current, later ones are previous.
                // Layer composites are already persistent, so no snapshot is needed.
                TexNode* version = source;
                if (!in_scene_order(consumer)) {
                    const auto initial = m_initial_composites.find(consumer.layer);
                    if (initial != m_initial_composites.end()) version = initial->second;
                }
                m_graph->afterBuild(consumer.pass, [&](rg::RenderGraphBuilder& b, rg::Pass&) {
                    b.read(version);
                    return true;
                });
                consumer_draw->setDescTex(consumer.slot, source->key());
                if (m_scene.shaderValueUpdater)
                    m_scene.shaderValueUpdater->SetRenderTargetBinding(
                        consumer_draw->desc().node, consumer_draw->desc().material_slot,
                        consumer.slot, source->key());
                m_ordered_link_sources.insert(std::string(source->key()));
                continue;
            }
            const std::string link   = GenLinkTex(consumer.layer);
            LinkTarget&       target = links[consumer.layer];
            if (target.history == nullptr) {
                rg::RenderGraphBuilder builder(*m_graph);
                target.history = builder.createTexNode(texDesc(link, true), false);
                builder.markSelfWrite(target.history);
            }

            // Producer, copy, consumer would be a cycle when the consumer (or its layer's
            // composite) is, or has to run before, what the copy waits for: then the link
            // is last frame's picture.
            std::vector<rg::NodeID> after { consumer.pass };
            if (const TexNode* own = picture(consumer.owner);
                own != nullptr && own->writer() != nullptr)
                after.push_back(own->writer()->ID());
            if (const TexNode* next = source->nextVer(); next != nullptr && next->writer() != nullptr)
                after.push_back(next->writer()->ID());
            std::vector<rg::NodeID> before;
            if (source->writer() != nullptr) before.push_back(source->writer()->ID());
            for (const PassNode* reader : target.history->readers()) before.push_back(reader->ID());
            bool history = false;
            for (const rg::NodeID a : after) {
                for (const rg::NodeID b : before) {
                    if (a == b || m_graph->mustPrecede(a, b)) history = true;
                }
            }

            if (target.current == nullptr) {
                // A self-link retains its separate previous picture; refresh that
                // snapshot at the end of the producing object's atomic group.
                SceneNode* saved_owner = m_sort_owner;
                m_sort_owner = source_draw != nullptr ? source_draw->desc().sort_owner : nullptr;
                addCopy(std::string(source->key()), link, source, &target.current);
                m_sort_owner = saved_owner;
            }
            TexNode* read_version = history ? target.history : target.current;
            m_graph->afterBuild(consumer.pass, [&](rg::RenderGraphBuilder& b, rg::Pass&) {
                b.read(read_version);
                return true;
            });
            if (auto* draw = dynamic_cast<DrawPass*>(m_graph->getPass(consumer.pass))) {
                draw->setDescTex(consumer.slot, link);
                if (m_scene.shaderValueUpdater)
                    m_scene.shaderValueUpdater->SetRenderTargetBinding(
                        draw->desc().node, draw->desc().material_slot, consumer.slot, link);
            }
        }
    }

    void recordPass(rg::NodeID pass) {
        m_emitted_passes.push_back(pass);
        if (m_sort_owner != nullptr &&
            std::find(sortedOwners().begin(), sortedOwners().end(), m_sort_owner) ==
                sortedOwners().end()) sortedOwners().push_back(m_sort_owner);
    }

    // The order belongs to complete scene objects, not individual draw targets.
    // Keep every effect/copy/clear of one object contiguous, including a self-link
    // snapshot added during link resolution. Fixed shadows and postprocessing stay
    // on their respective sides of the sorted objects.
    //
    // Only a scene sorted by depth needs that while it runs: the renderer then moves each
    // object's passes as one block whenever the camera or a layer moves (see the Metal
    // backend's draw order). Elsewhere the object order is fixed when the graph is built and
    // every pass already declares what it reads and writes, which orders it against the other
    // objects wherever their pictures meet: the draws into the scene's image follow one
    // another, a reader of a layer's picture follows (or, reading the previous frame's,
    // precedes) the layer that draws it, a shared buffer passes from one object to the next.
    // What else the block order adds is a split of the scene's render pass around a layer's
    // own buffers, which the scheduler can draw ahead of the scene draws instead.
    void sequenceSortedPasses() {
        if (m_sorted_owners.empty() && m_reflected_owners.empty()) return;
        if (!m_scene.transparent_sorting && ScenePassMergeEnabled()) return;
        const auto owner = [&](rg::NodeID id) -> SceneNode* {
            const auto* pass = m_graph->getPass(id);
            if (const auto* draw = dynamic_cast<const DrawPass*>(pass)) return draw->desc().sort_owner;
            if (const auto* copy = dynamic_cast<const CopyPass*>(pass)) return copy->desc().sort_owner;
            if (const auto* clear = dynamic_cast<const ClearPass*>(pass)) return clear->desc().sort_owner;
            return nullptr;
        };
        const auto reflection=[&](rg::NodeID id) {
            const auto* pass=m_graph->getPass(id);
            if(const auto* draw=dynamic_cast<const DrawPass*>(pass)) return draw->desc().reflection_pass;
            if(const auto* copy=dynamic_cast<const CopyPass*>(pass)) return copy->desc().reflection_pass;
            if(const auto* clear=dynamic_cast<const ClearPass*>(pass)) return clear->desc().reflection_pass;
            return false;
        };
        std::vector<rg::NodeID> order;
        order.reserve(m_emitted_passes.size());
        order.insert(order.end(), m_emitted_passes.begin(),
                     m_emitted_passes.begin() + static_cast<std::ptrdiff_t>(m_sorted_prefix_size));
        for(bool reflected_phase:{true,false}) {
            for(const auto* node:reflected_phase?m_reflected_owners:m_sorted_owners)
                for(const auto id:m_emitted_passes)
                    if(owner(id)==node && reflection(id)==reflected_phase) order.push_back(id);
        }
        for (std::size_t i = m_sorted_prefix_size; i < m_emitted_passes.size(); ++i)
            if (owner(m_emitted_passes[i]) == nullptr) order.push_back(m_emitted_passes[i]);
        for (std::size_t i = 1; i < order.size(); ++i)
            m_graph->orderBefore(order[i - 1], order[i]);
    }

    // ---- history targets ---------------------------------------------------------

    void declareHistory() {
        const std::vector<rg::NodeID> order   = m_graph->topologicalOrder();
        const std::string             output  = resolve(SpecTex_Default);
        for (const std::string& key : m_graph->getCarriedOverKeys(order)) {
            if (resolve(key) == output) continue;
            if (SceneRenderTarget* record = m_scene.FindRenderTarget(key)) {
                record->carriesPreviousFrame = true;
                if (!m_ordered_link_sources.contains(resolve(key))) record->allowReuse = false;
                continue;
            }
            if (! IsSpecLinkTex(key)) continue;
            const CopyPass* first_writer = nullptr;
            for (const rg::NodeID id : order) {
                const auto* copy = dynamic_cast<const CopyPass*>(m_graph->getPass(id));
                if (copy != nullptr && copy->desc().dst == key) {
                    first_writer = copy;
                    break;
                }
            }
            if (first_writer == nullptr) continue;
            const SceneRenderTarget* from = m_scene.FindRenderTarget(first_writer->desc().src);
            if (from == nullptr) continue;
            SceneRenderTarget declared  = *from;
            declared.allowReuse         = false;
            declared.carriesPreviousFrame = true;
            m_scene.renderTargets[key]  = declared;
        }
    }

    // ---- load actions ------------------------------------------------------------

    void applyLoadActions() {
        std::unordered_map<std::string, TargetHistory> history;
        for (const rg::NodeID id : m_graph->topologicalOrder()) {
            rg::Pass* pass = m_graph->getPass(id);
            if (auto* clear = dynamic_cast<ClearPass*>(pass)) {
                TargetHistory& state    = history[clear->desc().result];
                state.written           = true;
                state.transparent_clear = clear->desc().transparent;
                // An early scene read clears the same MS attachment that later
                // scene draws continue. Effect-buffer clears remain single-sample.
                const auto* target = m_scene.FindRenderTarget(clear->desc().result);
                state.single_sample = clear->desc().result != SpecTex_Default ||
                    target == nullptr || target->sample_count <= 1;
            } else if (auto* copy = dynamic_cast<CopyPass*>(pass)) {
                TargetHistory& state    = history[copy->desc().dst];
                state.written           = true;
                state.transparent_clear = false;
                state.single_sample     = true;
            } else if (auto* draw = dynamic_cast<DrawPass*>(pass)) {
                // A shadow caster says itself whether it opens the atlas with a clear.
                if (draw->desc().depth_only) history[draw->desc().output].written = true;
                else loadActionOf(draw->desc(), history[draw->desc().output]);
            }
        }
    }

    void loadActionOf(DrawPass::Desc& desc, TargetHistory& state) {
        const std::string&       key    = desc.output;
        const bool               output = key == SpecTex_Default || key==kReflectionTarget;
        const SceneRenderTarget* record = m_scene.FindRenderTarget(key);
        const uint32_t           samples = desc.force_single_sample ? 1u :
            record != nullptr ? rg::NormalizeSampleCount(record->sample_count) : 1u;
        const bool force = record != nullptr && record->forceClear && ! output;

        desc.clear_on_first_use       = false;
        desc.preserve_target_contents = false;
        if (! state.written || force) {
            if (output) {
                desc.clear_on_first_use = m_scene.clearEnabled;
                desc.preserve_target_contents = ! m_scene.clearEnabled;
            } else {
                desc.clear_on_first_use = record != nullptr && (record->allowReuse || record->forceClear);
            }
            desc.samples        = samples;
            state.single_sample = false;
        } else {
            if (! output && state.transparent_clear) desc.clear_on_first_use = true;
            else desc.preserve_target_contents = true;
            desc.samples = state.single_sample ? 1u : samples;
        }
        state.written           = true;
        state.transparent_clear = false;
        state.single_sample     = desc.samples == 1;
    }

    // ---- state -------------------------------------------------------------------

    Scene&                           m_scene;
    std::unique_ptr<rg::RenderGraph> m_graph;
    bool                             m_custom_sort { false };
    bool                             m_ordered_objects { false };
    bool                             m_postprocessing { false };

    bool        m_compose_enabled { false };
    std::string m_active_camera_key;

    std::unordered_map<const SceneNode*, bool> m_producing;
    std::unordered_set<const void*>            m_cleared;
    std::unordered_set<std::string>            m_logged;

    bool m_mip_frame_sampled { false };
    std::vector<std::weak_ptr<SceneNode>> m_next_transparent_order;
    std::size_t m_snapshot_count { 0 };
    // How many layers without copybackground enclose the draws being emitted.
    int m_alpha_max_depth { 0 };

    SceneNode* m_sort_owner { nullptr };
    int m_compose_depth { 0 };
    std::size_t m_sorted_prefix_size { 0 };
    std::vector<SceneNode*> m_sorted_owners;
    std::vector<SceneNode*> m_reflected_owners;
    bool m_reflection_pass { false };
    std::vector<rg::NodeID> m_emitted_passes;
    std::unordered_map<i32, TexNode*> m_initial_composites;
    std::unordered_set<std::string> m_ordered_link_sources;
    std::vector<LinkConsumer> m_consumers;
    // The version of a layer's picture, by the rule that applies to the layer.
    std::unordered_map<i32, TexNode*> m_picture_composite;
    std::unordered_map<i32, TexNode*> m_picture_scene;
    std::unordered_map<i32, TexNode*> m_picture_first_buffer;
    std::unordered_set<i32>           m_has_effect_graph;
};

} // namespace

std::unique_ptr<rg::RenderGraph> sceneToRenderGraph(Scene& scene)
{
    return GraphBuilder(scene).build();
}

bool ScenePassMergeEnabled() { return ScenePassMergeSwitch().load(std::memory_order_relaxed); }

bool SetScenePassMergeForTests(bool enabled) { return ScenePassMergeSwitch().exchange(enabled); }

} // namespace wallpaper
