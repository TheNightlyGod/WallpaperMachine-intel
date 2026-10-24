// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#include "RenderCommon/SceneToRenderGraph.hpp"

#include "RenderCommon/ScenePass.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "SpecTexs.hpp"
#include "Utils/Logging.h"

#include <algorithm>
#include <cstdint>
#include <memory>
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
    explicit GraphBuilder(Scene& scene): m_scene(scene), m_graph(std::make_unique<rg::RenderGraph>()) {}

    std::unique_ptr<rg::RenderGraph> build() {
        m_scene.render_excluded_nodes.clear();
        m_compose_enabled = m_scene.activeCamera != nullptr;
        if (m_compose_enabled) {
            for (const auto& [name, camera] : m_scene.cameras) {
                if (camera.get() != m_scene.activeCamera) continue;
                if (m_active_camera_key.empty() || name < m_active_camera_key)
                    m_active_camera_key = name;
            }
        }
        if (m_scene.sceneGraph != nullptr) {
            if (m_scene.opaque_first) prewalk(m_scene.sceneGraph);
            walk(m_scene.sceneGraph);
        }
        postProcesses();
        resolveLinks();
        if (m_mip_frame_sampled) {
            addCopy(std::string(SpecTex_Default), resolve(WE_MIP_MAPPED_FRAME_BUFFER));
        }
        declareHistory();
        applyLoadActions();
        return std::move(m_graph);
    }

private:
    // ---- names and small queries -------------------------------------------------

    std::string resolve(std::string_view name) const { return m_scene.ResolveRenderTargetName(name); }

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

    static bool subtreeHasMesh(SceneNode* node) {
        if (node->Mesh() != nullptr) return true;
        for (const auto& child : node->GetChildren()) {
            if (child != nullptr && subtreeHasMesh(child.get())) return true;
        }
        return false;
    }

    void noteWrite(const std::string& key) {
        if (key == SpecTex_Default) m_screen_has_content = true;
    }

    // A hidden layer that would have been the first thing drawn onto the scene output
    // is remembered: the output then has to keep what it already holds.
    void noteBypassedContender(SceneNode* node) {
        if (! m_screen_has_content && subtreeHasMesh(node)) m_phantom_first_draw = true;
    }

    // ---- walking the tree --------------------------------------------------------

    static bool opaqueCard(SceneNode* node) {
        SceneMesh* mesh = node->Mesh();
        if (mesh == nullptr || node->SkipRenderPass()) return false;
        if (mesh->MaterialSlots().empty()) return false;
        for (const auto& material : mesh->MaterialSlots()) {
            if (material == nullptr) return false;
            const bool plain =
                material->blenmode == BlendMode::Disable || material->blenmode == BlendMode::Normal;
            if (! plain || ! material->depth_test) return false;
        }
        return true;
    }

    // Opaque layers go first when the scene asks for it: depth-tested solid cards that
    // are not part of an effect or compose subgraph.
    void prewalk(const std::shared_ptr<SceneNode>& handle) {
        SceneNode* node = handle.get();
        if (node == nullptr) return;
        if (leftOut(node)) {
            noteBypassedContender(node);
            return;
        }
        if (isCompose(node) || chainOf(node) != nullptr) return;
        if (opaqueCard(node)) {
            drawCard(node, nullptr, false);
            m_prewalk_drawn.insert(node);
        }
        for (const auto& child : node->GetChildren()) prewalk(child);
    }

    void walk(const std::shared_ptr<SceneNode>& handle) {
        SceneNode* node = handle.get();
        if (node == nullptr) return;
        if (leftOut(node)) {
            m_scene.render_excluded_nodes.push_back(handle);
            noteBypassedContender(node);
            return;
        }
        const auto children = [&] {
            for (const auto& child : node->GetChildren()) walk(child);
        };
        if (node->Mesh() == nullptr) {
            children();
            return;
        }
        SceneImageEffectLayer* layer = chainOf(node);
        if (layer == nullptr) {
            if (! node->SkipRenderPass() && ! m_prewalk_drawn.contains(node))
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
    }

    void clearChainInput(SceneImageEffectLayer* layer) {
        if (! m_cleared.insert(layer).second) return;
        const std::string key = resolve(layer->FirstTarget());
        m_graph->addPass<ClearPass>(
            "clear effect input", PassNode::Type::Clear,
            [&](rg::RenderGraphBuilder& b, ClearPass::Desc& desc) {
                desc.result      = key;
                desc.transparent = true;
                b.write(b.createTexNode(texDesc(key, true), true));
            });
        noteWrite(key);
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
                source.destination     = resolve(step.output);
                source.redirect_from   = owner->Parent();
                source.role = source.node == final_node ? PictureRole::ChainFinal : PictureRole::None;
                drawNode(source);
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
        SceneMaterial* material = source.node->Mesh()->MaterialForSlot(slot);
        if (material == nullptr) return;

        std::vector<Route> routes;
        const Route        plain = redirect(source);
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

    void emitPass(const DrawSource& source, std::size_t submesh, uint32_t slot,
                  const SceneMaterial& material, const Route& route, bool first_route) {
        DrawPass::Desc desc;
        desc.node            = source.node;
        desc.visibility_node = source.visibility_node;
        desc.output          = route.dest;
        desc.camera_override = route.camera;
        desc.submesh_index   = submesh;
        desc.material_slot   = slot;
        desc.write_alpha     = route.dest != SpecTex_Default;
        // What a chain leaves in its layer's composite is its last pass as written.
        desc.replace_target = source.role == PictureRole::ChainFinal &&
                              std::string_view(route.dest).starts_with(WE_IMAGE_LAYER_COMPOSITE_PREFIX);
        desc.textures.assign(material.textures.size(), std::string {});

        std::vector<std::pair<uint32_t, i32>> links;
        bool                                  samples_own_output = false;
        for (std::size_t i = 0; i < material.textures.size(); ++i) {
            const std::string& name = material.textures[i];
            if (name.empty()) continue;
            if (IsSpecLinkTex(name)) {
                links.emplace_back(static_cast<uint32_t>(i), static_cast<i32>(ParseLinkTex(name)));
                continue;
            }
            const std::string key = resolve(name);
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
        for (const auto& [index, layer] : links) m_consumers.push_back({ node->ID(), index, layer });
        noteWrite(route.dest);
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
                desc.src = source;
                desc.dst = destination;
                if (written != nullptr) *written = out;
            });
        noteWrite(destination);
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

    // The newest version of the link that the consumer can read without having to run
    // after the copy that follows it.
    TexNode* historyVersion(TexNode* latest, rg::NodeID consumer) const {
        TexNode* version = latest;
        for (;;) {
            bool safe = true;
            if (const PassNode* writer = version->writer();
                writer != nullptr && writer->type() != PassNode::Type::Virtual &&
                (writer->ID() == consumer || m_graph->mustPrecede(consumer, writer->ID())))
                safe = false;
            if (const TexNode* next = version->nextVer(); next != nullptr && next->writer() != nullptr &&
                m_graph->mustPrecede(next->writer()->ID(), consumer))
                safe = false;
            if (safe || version->preVer() == nullptr) return version;
            version = version->preVer();
        }
    }

    void resolveLinks() {
        for (const LinkConsumer& consumer : m_consumers) {
            TexNode* source = picture(consumer.layer);
            if (source == nullptr) {
                logOnce("layer " + std::to_string(consumer.layer) + " produced no picture to link");
                continue;
            }
            const std::string link = GenLinkTex(consumer.layer);
            rg::RenderGraphBuilder builder(*m_graph);
            TexNode*               latest = builder.createTexNode(texDesc(link, true), false);

            // Producer, copy, consumer would be a cycle when the consumer is (or has to
            // run before) what the copy waits for: then the link is last frame's picture.
            std::vector<rg::NodeID> after { consumer.pass };
            if (const TexNode* next = source->nextVer(); next != nullptr && next->writer() != nullptr)
                after.push_back(next->writer()->ID());
            std::vector<rg::NodeID> before;
            if (source->writer() != nullptr) before.push_back(source->writer()->ID());
            for (const PassNode* reader : latest->readers()) before.push_back(reader->ID());
            bool history = false;
            for (const rg::NodeID a : after) {
                for (const rg::NodeID b : before) {
                    if (a == b || m_graph->mustPrecede(a, b)) history = true;
                }
            }

            const std::string source_key(source->key());
            TexNode*          read_version = nullptr;
            if (history) {
                read_version = historyVersion(latest, consumer.pass);
                m_graph->afterBuild(consumer.pass, [&](rg::RenderGraphBuilder& b, rg::Pass&) {
                    b.read(read_version);
                    return true;
                });
                addCopy(source_key, link, source);
            } else {
                addCopy(source_key, link, source, &read_version);
                m_graph->afterBuild(consumer.pass, [&](rg::RenderGraphBuilder& b, rg::Pass&) {
                    b.read(read_version);
                    return true;
                });
            }
            if (auto* draw = dynamic_cast<DrawPass*>(m_graph->getPass(consumer.pass)))
                draw->setDescTex(consumer.slot, link);
        }
    }

    // ---- history targets ---------------------------------------------------------

    void declareHistory() {
        const std::vector<rg::NodeID> order   = m_graph->topologicalOrder();
        const std::string             output  = resolve(SpecTex_Default);
        for (const std::string& key : m_graph->getCarriedOverKeys(order)) {
            if (resolve(key) == output) continue;
            if (SceneRenderTarget* record = m_scene.FindRenderTarget(key)) {
                record->carriesPreviousFrame = true;
                record->allowReuse           = false;
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
                state.single_sample     = true;
            } else if (auto* copy = dynamic_cast<CopyPass*>(pass)) {
                TargetHistory& state    = history[copy->desc().dst];
                state.written           = true;
                state.transparent_clear = false;
                state.single_sample     = true;
            } else if (auto* draw = dynamic_cast<DrawPass*>(pass)) {
                loadActionOf(draw->desc(), history[draw->desc().output]);
            }
        }
    }

    void loadActionOf(DrawPass::Desc& desc, TargetHistory& state) {
        const std::string&       key    = desc.output;
        const bool               output = key == SpecTex_Default;
        const SceneRenderTarget* record = m_scene.FindRenderTarget(key);
        const uint32_t           samples =
            record != nullptr ? rg::NormalizeSampleCount(record->sample_count) : 1u;
        const bool force = record != nullptr && record->forceClear && ! output;

        desc.write_alpha = ! output;
        desc.clear_on_first_use       = false;
        desc.preserve_target_contents = false;
        if (! state.written || force) {
            if (output) {
                desc.clear_on_first_use = m_scene.clearEnabled;
                desc.preserve_target_contents =
                    ! m_scene.clearEnabled && m_phantom_first_draw;
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
    }

    // ---- state -------------------------------------------------------------------

    Scene&                           m_scene;
    std::unique_ptr<rg::RenderGraph> m_graph;

    bool        m_compose_enabled { false };
    std::string m_active_camera_key;

    std::unordered_map<const SceneNode*, bool> m_producing;
    std::unordered_set<const SceneNode*>       m_prewalk_drawn;
    std::unordered_set<const void*>            m_cleared;
    std::unordered_set<std::string>            m_logged;

    bool m_screen_has_content { false };
    bool m_phantom_first_draw { false };
    bool m_mip_frame_sampled { false };
    std::size_t m_snapshot_count { 0 };

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

} // namespace wallpaper
