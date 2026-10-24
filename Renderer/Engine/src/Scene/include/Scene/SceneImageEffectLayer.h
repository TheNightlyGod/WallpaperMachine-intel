// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#pragma once
#include <vector>
#include <list>
#include <memory>
#include <optional>
#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
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
    ~SceneImageEffectLayer();
    SceneImageEffectLayer(const SceneImageEffectLayer&)            = delete;
    SceneImageEffectLayer& operator=(const SceneImageEffectLayer&) = delete;

    void AddEffect(const std::shared_ptr<SceneImageEffect>& node);
    std::size_t EffectCount() const;
    std::shared_ptr<SceneImageEffect>& GetEffect(std::size_t index);
    const std::string& FirstTarget() const;
    const std::string& SecondTarget() const;
    SceneMesh&  FinalMesh() const;
    SceneNode&  FinalNode() const;
    SceneNode*  ResolvedFinalRenderNode() const;
    void        SetFinalMeshDynamic(MeshUpdate update);
    void        SetFinalBlend(BlendMode m);
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

    void ResolveEffect(const SceneMesh& defualt_mesh, std::string_view effect_cam);

private:
    std::string                                    m_pingpong_a;
    std::string                                    m_pingpong_b;
    std::vector<std::shared_ptr<SceneImageEffect>> m_effects;
    std::unique_ptr<SceneMesh>                     m_final_mesh;
    std::unique_ptr<SceneNode>                     m_final_node;
    BlendMode                                      m_final_blend { BlendMode::Normal };
    SceneNode*                                     m_resolved_final { nullptr };
    /// Which authored names `ResolveEffect` has recorded already: nodes by address,
    /// and for each effect how many of its commands.
    std::unordered_set<const SceneImageEffectNode*>      m_recorded_nodes;
    std::unordered_map<const SceneImageEffect*, std::size_t> m_recorded_commands;
    bool                                           m_logged_missing_material { false };

    std::string m_final_camera;
    std::optional<BlendMode>   m_idle_final_blend;

    /// The depth test and write the last pass is drawn with; empty keeps the
    /// ones its own material authored.
    std::optional<SceneDepthState> m_final_depth;
};
} // namespace wallpaper
