#include <algorithm>
#include <cassert>
#include "SceneImageEffectLayer.h"
#include "SceneNode.h"

#include "SpecTexs.hpp"
#include "Core/StringHelper.hpp"

using namespace wallpaper;

SceneImageEffectLayer::SceneImageEffectLayer(SceneNode* node, float w, float h,
                                             std::string_view pingpong_a,
                                             std::string_view pingpong_b)
    : m_worldNode(node),
      m_pingpong_a(pingpong_a),
      m_pingpong_b(pingpong_b),
      m_final_mesh(std::make_unique<SceneMesh>()),
      m_final_node(std::make_unique<SceneNode>()) {};

void SceneImageEffectLayer::SetFinalMeshDynamic(MeshUpdate update) {
    auto replacement = std::make_unique<SceneMesh>(update);
    replacement->ChangeMeshDataFrom(*m_final_mesh);
    if (m_final_mesh->Material() != nullptr) {
        replacement->AddMaterial(SceneMaterial(*m_final_mesh->Material()));
    }
    m_final_mesh = std::move(replacement);
}

void SceneImageEffectLayer::ResolveEffect(const SceneMesh& default_mesh,
                                          std::string_view effect_cam) {
    // The placeholders are resolved in place, so the first call keeps what the
    // parser wrote and every call starts again from it: which buffer an effect
    // reads and writes depends on how many effects before it run.
    if (! m_authored_captured) {
        for (auto& eff : m_effects) {
            for (auto& cmd : eff->commands) {
                cmd.authored_src = cmd.src;
                cmd.authored_dst = cmd.dst;
            }
            for (auto& node : eff->nodes) {
                node.authored_output = node.output;
                if (node.sceneNode->HasMaterial()) {
                    node.authored_textures = node.sceneNode->Mesh()->Material()->textures;
                }
            }
        }
        m_authored_captured = true;
    }
    const bool any_visible =
        std::any_of(m_effects.begin(), m_effects.end(), [](const auto& eff) {
            return eff->visible && ! eff->fallback;
        });
    // Only what held a chain placeholder goes back: any other texture of an
    // effect's material is left as the runtime has it.
    const auto chain_name = [](std::string_view name) {
        return sstart_with(name, WE_EFFECT_PPONG_PREFIX_A) ||
               sstart_with(name, WE_EFFECT_PPONG_PREFIX_B) || name == SpecTex_Default;
    };
    for (auto& eff : m_effects) {
        eff->included = eff->fallback ? ! any_visible : eff->visible;
        for (auto& cmd : eff->commands) {
            if (chain_name(cmd.authored_src)) cmd.src = cmd.authored_src;
            if (chain_name(cmd.authored_dst)) cmd.dst = cmd.authored_dst;
        }
        for (auto& node : eff->nodes) {
            if (chain_name(node.authored_output)) node.output = node.authored_output;
            if (! node.sceneNode->HasMaterial()) continue;
            auto& textures = node.sceneNode->Mesh()->Material()->textures;
            for (std::size_t i = 0; i < node.authored_textures.size() && i < textures.size(); ++i) {
                if (chain_name(node.authored_textures[i])) textures[i] = node.authored_textures[i];
            }
        }
    }

    m_resolved_final_render_node = nullptr;
    std::string_view ppong_a = m_pingpong_a, ppong_b = m_pingpong_b;
    auto             swap_pp = [&ppong_a, &ppong_b]() {
        std::swap(ppong_a, ppong_b);
    };
    auto default_node = SceneNode();

    SceneImageEffectNode* last_output { nullptr };
    for (auto& eff : m_effects) {
        if (! eff->included) continue;
        for (auto& cmd : eff->commands) {
            if (sstart_with(cmd.src, WE_EFFECT_PPONG_PREFIX_A)) cmd.src = ppong_a;

            if (sstart_with(cmd.dst, WE_EFFECT_PPONG_PREFIX_A)) cmd.dst = ppong_a;
        }
        for (auto it = eff->nodes.begin(); it != eff->nodes.end(); it++) {
            if (sstart_with(it->output, WE_EFFECT_PPONG_PREFIX_B) ||
                it->output == SpecTex_Default) {
                it->output  = ppong_b;
                last_output = &(*it);
            }

            assert(it->sceneNode->HasMaterial());

            auto& material = *(it->sceneNode->Mesh()->Material());
            {
                material.blenmode = BlendMode::Normal;
                it->sceneNode->SetCamera(effect_cam.data());
                it->sceneNode->CopyTrans(default_node);
                it->sceneNode->SetCompositeOnly(false);
                it->sceneNode->Mesh()->ChangeMeshDataFrom(default_mesh);
            }

            auto& texs = material.textures;
            std::replace_if(
                texs.begin(),
                texs.end(),
                [](auto& t) {
                    return sstart_with(t, WE_EFFECT_PPONG_PREFIX_A);
                },
                ppong_a);
        }
        swap_pp();
    }
    if (last_output != nullptr) {
        last_output->output = SpecTex_Default;
        m_resolved_final_render_node = last_output->sceneNode.get();
        if (last_output->sceneNode->Mesh() != nullptr &&
            last_output->sceneNode->Mesh()->UpdateDriver() != m_final_mesh->UpdateDriver()) {
            auto replacement = std::make_shared<SceneMesh>(m_final_mesh->UpdateDriver());
            if (last_output->sceneNode->Mesh()->Material() != nullptr) {
                replacement->AddMaterial(SceneMaterial(*last_output->sceneNode->Mesh()->Material()));
            }
            last_output->sceneNode->AddMesh(std::move(replacement));
        }
        auto& mesh          = *(last_output->sceneNode->Mesh());
        auto& material      = *mesh.Material();
        {
            material.blenmode = ! any_visible && m_idle_final_blend.has_value() ? *m_idle_final_blend
                                                                                 : m_final_blend;
            if (m_final_depth.has_value()) {
                material.depth_test  = m_final_depth->test;
                material.depth_write = m_final_depth->write;
            }
            last_output->sceneNode->SetCamera(m_final_camera);
            last_output->sceneNode->CopyTrans(*m_final_node);
            last_output->sceneNode->SetCompositeOnly(m_final_composite_only);
            mesh.ChangeMeshDataFrom(*m_final_mesh);
        }
    }
}
