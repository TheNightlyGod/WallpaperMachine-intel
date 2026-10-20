#pragma once
#include <vector>
#include <list>
#include <memory>
#include <optional>
#include <cstdint>
#include <string>
#include "Core/Literals.hpp"
#include "SceneMaterial.h"
#include "Type.hpp"

namespace wallpaper
{

class SceneNode;
class SceneMesh;
/// Defined with `SceneMesh`; declared here so the header does not have to pull
/// the mesh in for one parameter.
enum class MeshUpdate : uint8_t;

struct SceneImageEffectNode {
    std::string                output; // render target
    std::shared_ptr<SceneNode> sceneNode;
    /// `output` and the material's textures as the parser wrote them, with the
    /// chain's ping-pong placeholders still in, so the chain can be resolved
    /// again when the set of visible effects changes.
    std::string                authored_output;
    std::vector<std::string>   authored_textures;
};

struct SceneImageEffect {
    enum class CmdType
    {
        Copy,
    };
    struct Command {
        CmdType     cmd { CmdType::Copy };
        std::string dst;
        std::string src;
        i32         afterpos { 0 }; // start at 1, 0 for begin at all
        std::string authored_dst;
        std::string authored_src;
    };
    std::vector<Command>            commands;
    std::list<SceneImageEffectNode> nodes;
    /// Whether the effect runs: a script can switch it while the scene runs
    /// (`SceneRuntimeContext::RegisterEffectVisibility`), and the chain is then
    /// resolved again over the effects that run.
    bool visible { true };
    /// A passthrough that closes the chain only while no other effect runs, so
    /// a layer whose effects a script has all switched off is still drawn.
    bool fallback { false };
    /// Set by `SceneImageEffectLayer::ResolveEffect`: the effect is part of the
    /// chain as last resolved.
    bool included { true };
};

class SceneImageEffectLayer {
public:
    SceneImageEffectLayer(SceneNode* node, float w, float h, std::string_view pingpong_a,
                          std::string_view pingpong_b);

    void AddEffect(const std::shared_ptr<SceneImageEffect>& node) { m_effects.push_back(node); }
    std::size_t EffectCount() const { return m_effects.size(); }
    auto&       GetEffect(std::size_t index) { return m_effects.at(index); }
    const auto& FirstTarget() const { return m_pingpong_a; }
    SceneMesh&  FinalMesh() const { return *m_final_mesh; }
    SceneNode&  FinalNode() const { return *m_final_node; }
    SceneNode*  ResolvedFinalRenderNode() const { return m_resolved_final_render_node; }
    void        SetFinalMeshDynamic(MeshUpdate update);
    void        SetFinalBlend(BlendMode m) { m_final_blend = m; }
    /// The depth test and depth write the last pass draws with. The chain's
    /// last pass is what puts the layer into the scene, and Wallpaper Engine
    /// draws it with the ones the layer authored for its own material, as it
    /// does with the layer's blending, not with the state its effect pass
    /// authored; the parser leaves the write out for a layer Wallpaper Engine
    /// sorts, which this engine draws in scene order. A layer that never sets
    /// them keeps the pass's own.
    void        SetFinalDepth(bool test, bool write) { m_final_depth = SceneDepthState { test, write }; }
    /// How the last pass is drawn instead of the final blend while no effect of the chain runs
    /// and the chain ends in its passthrough fallback (a script has switched every effect off).
    /// Without it the final blend applies then too.
    void        SetIdleFinalBlend(BlendMode m) { m_idle_final_blend = m; }
    /// The camera the chain's last pass draws its result through. Empty is the
    /// scene's active camera, which is right for a layer that sits in the
    /// scene; a fullscreen layer's result is the screen and must cover it
    /// however a camera layer frames the scene.
    void        SetFinalCamera(std::string camera) { m_final_camera = std::move(camera); }
    /// The chain's result goes only into the layer's own composite, which
    /// another layer samples, and never onto the scene: the layer's card has
    /// no area on screen (`SceneNode::CompositeOnly` on the last pass).
    void        SetFinalCompositeOnly(bool only) { m_final_composite_only = only; }

    void ResolveEffect(const SceneMesh& defualt_mesh, std::string_view effect_cam);

private:
    SceneNode*  m_worldNode;
    std::string m_pingpong_a;
    std::string m_pingpong_b;

    std::string m_final_camera;
    //    std::vector<float> m_size;
    std::unique_ptr<SceneMesh> m_final_mesh;
    std::unique_ptr<SceneNode> m_final_node;
    SceneNode*                 m_resolved_final_render_node { nullptr };
    BlendMode                  m_final_blend;
    std::optional<BlendMode>   m_idle_final_blend;

    /// The depth test and write the last pass is drawn with; empty keeps the
    /// ones its own material authored.
    std::optional<SceneDepthState> m_final_depth;
    bool                           m_final_composite_only { false };

    std::vector<std::shared_ptr<SceneImageEffect>> m_effects;
    bool                                           m_authored_captured { false };
};
} // namespace wallpaper
