// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#include <algorithm>
#include <stdexcept>
#include <tuple>
#include <utility>
#include "SceneImageEffectLayer.h"
#include "SceneNode.h"
#include "SpecTexs.hpp"
#include "Utils/Logging.h"

using namespace wallpaper;

namespace
{
bool IsPlaceholder(std::string_view name) {
    return sstart_with(name, WE_EFFECT_PPONG_PREFIX_A) || sstart_with(name, WE_EFFECT_PPONG_PREFIX_B) ||
           name == SpecTex_Default;
}

// Puts the authored name back wherever the chain had put a buffer name in its place.
void Restore(std::string& current, const std::string& authored) {
    if (IsPlaceholder(authored)) current = authored;
}

SceneMaterial* MaterialOf(SceneNode* node) {
    if (node == nullptr || node->Mesh() == nullptr) return nullptr;
    return node->Mesh()->Material();
}

// Whether an effect takes part in this resolution: a fallback stands in only while
// nothing else runs, every other effect follows its own visibility.
bool Participates(const SceneImageEffect& effect, bool anyRunning) {
    if (! effect.fallback) return effect.visible;
    return ! anyRunning;
}

// What every pass of an included effect starts from, before the chain touches it.
struct PassBaseline {
    const SceneMesh& geometry;
    std::string_view camera;
};

void ApplyBaseline(SceneNode& node, SceneMaterial& material, const PassBaseline& base) {
    node.Mesh()->ChangeMeshDataFrom(base.geometry);
    static const SceneNode identity;
    node.CopyTrans(identity);
    node.SetCamera(std::string(base.camera));
    material.blenmode = BlendMode::Normal;
}

// The blend the closing pass takes: the idle one while the whole chain is idle and
// one was given, the ordinary final blend otherwise.
BlendMode PickFinalBlend(bool idle, const std::optional<BlendMode>& idleBlend, BlendMode finalBlend) {
    if (idle && idleBlend.has_value()) return *idleBlend;
    return finalBlend;
}
} // namespace

SceneImageEffectLayer::SceneImageEffectLayer(SceneNode* node, float w, float h,
                                             std::string_view pingpong_a,
                                             std::string_view pingpong_b)
    : m_pingpong_a(pingpong_a),
      m_pingpong_b(pingpong_b),
      m_final_mesh(std::make_unique<SceneMesh>(MeshUpdate::Fixed)),
      m_final_node(std::make_unique<SceneNode>()) {
    // The owner and the extent are not used by anything the layer does.
    (void)node;
    (void)w;
    (void)h;
}

SceneImageEffectLayer::~SceneImageEffectLayer() = default;

void SceneImageEffectLayer::AddEffect(const std::shared_ptr<SceneImageEffect>& node) {
    m_effects.push_back(node);
}

std::size_t SceneImageEffectLayer::EffectCount() const { return m_effects.size(); }

std::shared_ptr<SceneImageEffect>& SceneImageEffectLayer::GetEffect(std::size_t index) {
    return m_effects.at(index);
}

const std::string& SceneImageEffectLayer::FirstTarget() const { return m_pingpong_a; }

const std::string& SceneImageEffectLayer::SecondTarget() const { return m_pingpong_b; }

SceneMesh& SceneImageEffectLayer::FinalMesh() const { return *m_final_mesh; }

SceneNode& SceneImageEffectLayer::FinalNode() const { return *m_final_node; }

SceneNode* SceneImageEffectLayer::ResolvedFinalRenderNode() const { return m_resolved_final; }

void SceneImageEffectLayer::SetFinalBlend(BlendMode m) { m_final_blend = m; }

void SceneImageEffectLayer::SetFinalMeshDynamic(MeshUpdate update) {
    auto fresh = std::make_unique<SceneMesh>(update);
    fresh->ChangeMeshDataFrom(*m_final_mesh);
    if (const SceneMaterial* material = m_final_mesh->Material(); material != nullptr) {
        fresh->AddMaterial(SceneMaterial(*material));
    }
    m_final_mesh = std::move(fresh);
}

void SceneImageEffectLayer::ResolveEffect(const SceneMesh& default_mesh,
                                          std::string_view effect_cam) {
    // 1. Record the authored names once, then put back every placeholder the last
    //    resolution replaced, so the same chain can be laid out again.
    for (const auto& effect : m_effects) {
        if (effect == nullptr) continue;
        std::size_t& recorded = m_recorded_commands[effect.get()];
        for (std::size_t i = 0; i < effect->commands.size(); ++i) {
            auto& command = effect->commands[i];
            if (i >= recorded) {
                command.authored_src = command.src;
                command.authored_dst = command.dst;
            } else {
                Restore(command.src, command.authored_src);
                Restore(command.dst, command.authored_dst);
            }
        }
        recorded = effect->commands.size();

        for (auto& pass : effect->nodes) {
            SceneMaterial* material = MaterialOf(pass.sceneNode.get());
            if (m_recorded_nodes.insert(&pass).second) {
                pass.authored_output = pass.output;
                pass.authored_textures.clear();
                if (material != nullptr) pass.authored_textures = material->textures;
                continue;
            }
            Restore(pass.output, pass.authored_output);
            if (material != nullptr) {
                const std::size_t n = std::min(material->textures.size(), pass.authored_textures.size());
                for (std::size_t i = 0; i < n; ++i) {
                    Restore(material->textures[i], pass.authored_textures[i]);
                }
            }
        }
    }

    // 2. Which effects take part.
    const bool any_running = std::any_of(m_effects.begin(), m_effects.end(), [](const auto& e) {
        return e != nullptr && ! e->fallback && e->visible;
    });
    for (const auto& effect : m_effects) {
        if (effect != nullptr) effect->included = Participates(*effect, any_running);
    }

    // 3. Lay the included effects out over the two buffers; the buffers swap once
    //    per included effect.
    m_resolved_final = nullptr;
    SceneImageEffectNode*  last_writer = nullptr;
    const PassBaseline     baseline { default_mesh, effect_cam };
    std::size_t            swaps = 0;
    for (const auto& effect : m_effects) {
        if (effect == nullptr || ! effect->included) continue;
        const std::string& input  = (swaps % 2 == 0) ? m_pingpong_a : m_pingpong_b;
        const std::string& output = (swaps % 2 == 0) ? m_pingpong_b : m_pingpong_a;
        ++swaps;

        for (auto& command : effect->commands) {
            if (sstart_with(command.src, WE_EFFECT_PPONG_PREFIX_A)) command.src = input;
            if (sstart_with(command.dst, WE_EFFECT_PPONG_PREFIX_A)) command.dst = input;
        }
        for (auto& pass : effect->nodes) {
            SceneMaterial* material = MaterialOf(pass.sceneNode.get());
            if (material == nullptr) {
                if (! std::exchange(m_logged_missing_material, true)) {
                    LOG_ERROR("An effect pass has no material; the pass is skipped");
                }
                continue;
            }
            if (sstart_with(pass.output, WE_EFFECT_PPONG_PREFIX_B) || pass.output == SpecTex_Default) {
                pass.output = output;
            }
            for (auto& texture : material->textures) {
                if (sstart_with(texture, WE_EFFECT_PPONG_PREFIX_A)) texture = input;
            }
            if (pass.output == output) last_writer = &pass;
            ApplyBaseline(*pass.sceneNode, *material, baseline);
        }
    }

    // 4. The last pass that wrote the output buffer closes the chain onto the layer.
    if (last_writer == nullptr) return;
    SceneNode& closing = *last_writer->sceneNode;
    last_writer->output = std::string(SpecTex_Default);

    // The closing pass draws with the card's update driver, on a copy of its own material.
    if (closing.Mesh()->UpdateDriver() != m_final_mesh->UpdateDriver()) {
        auto swapped = std::make_shared<SceneMesh>(m_final_mesh->UpdateDriver());
        swapped->AddMaterial(SceneMaterial(*closing.Mesh()->Material()));
        closing.AddMesh(std::move(swapped));
    }
    SceneMaterial& material = *closing.Mesh()->Material();
    material.blenmode       = PickFinalBlend(! any_running, m_idle_final_blend, m_final_blend);
    if (m_final_depth.has_value()) {
        std::tie(material.depth_test, material.depth_write) =
            std::tie(m_final_depth->test, m_final_depth->write);
    }
    closing.Mesh()->ChangeMeshDataFrom(*m_final_mesh);
    closing.CopyTrans(*m_final_node);
    closing.SetCamera(m_final_camera);
    m_resolved_final = &closing;
}
