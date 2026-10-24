#include "MetalRender/MetalCapability.hpp"

#include "MetalRender/MetalBackendRouter.hpp"

#include "MetalRender/MetalShaderReflection.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "MetalRender/SceneMetalProgram.hpp"

#include "RenderCommon/ScenePass.hpp"
#include "RenderGraph/Pass.hpp"
#include "RenderGraph/PassNode.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneImageEffectLayer.h"
#include "SpecTexs.hpp"
#include "Particle/ParticleSystem.h"

#include <functional>
#include <variant>
#include <vector>

namespace wallpaper::metal
{
namespace
{

/// Uniform whose presence means the shader is driven by skeletal transforms.
/// Read from reflection, never from shader source text. Presence is not a
/// refusal: the runtime writes one 4x4 float matrix (64 bytes) per bone
/// through the reflected array stride, and only a layout that cannot hold
/// that is rejected.
constexpr std::string_view kBonesUniform { "g_Bones" };

/// Name and type together: a puppet's blend indices occupy the same slot a
/// float4 would, and a rope's `a_TexCoordVec3C2` is stored as a float4.
bool HasAttribute(const SceneVertexArray& vertices, std::string_view name, VertexType type)
{
    for (const auto& attribute : vertices.Attributes()) {
        if (attribute.name == name && attribute.type == type) return true;
    }
    return false;
}

const SceneCamera* FindCamera(const Scene& scene, const std::string& name)
{
    if (name.empty()) return nullptr;
    const auto found = scene.cameras.find(name);
    if (found == scene.cameras.end()) return nullptr;
    return found->second.get();
}

/// The scene nodes an image effect chain draws with, which are not children of
/// the layer they belong to and so are missed by a plain scene-graph walk. They
/// carry ordinary meshes, materials and translated shaders, and every structural
/// limit that applies to a layer applies to them too.
std::vector<SceneNode*> EffectNodes(const Scene& scene, const SceneNode* node)
{
    std::vector<SceneNode*> nodes;
    const auto* camera = FindCamera(scene, node->Camera());
    if (camera == nullptr || ! camera->HasImgEffect()) return nodes;
    auto& layer = *const_cast<SceneCamera*>(camera)->GetImgEffect();
    for (std::size_t i = 0; i < layer.EffectCount(); ++i) {
        const auto& effect = layer.GetEffect(i);
        if (effect == nullptr) continue;
        for (const auto& effect_node : effect->nodes) {
            if (effect_node.sceneNode != nullptr) nodes.push_back(effect_node.sceneNode.get());
        }
    }
    return nodes;
}

/// The geometry an effect chain's last drawing node ends up with, when `node` is
/// that node.
///
/// A layer under an effect chain is parsed with its real geometry set aside as
/// the chain's final mesh; `ResolveEffect` moves it onto the last node that
/// writes the chain's output only when the render graph is built, which is
/// after this gate has run. A puppet is the case that matters: its skinning
/// material sits on that last node from the start while the bone weights it
/// reads are still in the final mesh. The node is found by the same rule
/// `ResolveEffect` uses, so every other effect node -- which is given the plain
/// full-target quad -- is still judged by the mesh it has.
const SceneMesh* ResolvedEffectGeometry(const Scene& scene, const SceneNode* owner,
                                        const SceneNode* node)
{
    const auto* camera = FindCamera(scene, owner->Camera());
    if (camera == nullptr || ! camera->HasImgEffect()) return nullptr;
    auto&            layer = *const_cast<SceneCamera*>(camera)->GetImgEffect();
    const SceneNode* last  = nullptr;
    for (std::size_t i = 0; i < layer.EffectCount(); ++i) {
        const auto& effect = layer.GetEffect(i);
        if (effect == nullptr) continue;
        for (const auto& effect_node : effect->nodes) {
            if (effect_node.sceneNode == nullptr) continue;
            if (effect_node.output.rfind(WE_EFFECT_PPONG_PREFIX_B, 0) == 0 ||
                effect_node.output == SpecTex_Default) {
                last = effect_node.sceneNode.get();
            }
        }
    }
    return last == node ? &layer.FinalMesh() : nullptr;
}

/// The nodes the scene's post-process chain draws with. Like effect nodes they
/// live outside the scene graph, and the render graph lowers them into ordinary
/// custom-shader passes, so they are checked as ordinary layers.
std::vector<SceneNode*> PostProcessNodes(const Scene& scene)
{
    std::vector<SceneNode*> nodes;
    for (const auto& post_process : scene.post_processes) {
        if (post_process == nullptr) continue;
        for (const auto& step : post_process->steps) {
            const auto* pass = std::get_if<ScenePostProcessPass>(&step);
            if (pass != nullptr && pass->node != nullptr) nodes.push_back(pass->node.get());
        }
    }
    return nodes;
}

/// Walks the scene graph, stopping at the first rejection.
std::string RejectNodes(const Scene& scene, const SceneNode* node)
{
    if (node == nullptr) return {};

    if (auto* mesh = const_cast<SceneNode*>(node)->Mesh(); mesh != nullptr) {
        if (mesh->Primitive() != MeshPrimitive::TRIANGLE) {
            return "the scene draws a primitive the native renderer does not support";
        }
        for (const auto& slot : mesh->MaterialSlots()) {
            if (slot == nullptr) continue;
            const auto* shader = slot->customShader.shader.get();
            if (shader == nullptr) return "a layer has no shader";
        }
    }

    // Link textures and a material that samples the target it draws into are
    // deliberately NOT rejected here. Both are ordinary same-frame inputs once
    // the render graph exists: the graph names the producing pass's output and
    // breaks a read-while-write with its own copy. Whether an input is genuine
    // cross-frame history is a question only the lowered graph can answer, and
    // `MetalGraphRejection` answers it there.

    for (auto* effect_node : EffectNodes(scene, node)) {
        auto reason = RejectNodes(scene, effect_node);
        if (! reason.empty()) return reason;
    }
    for (const auto& child : node->GetChildren()) {
        auto reason = RejectNodes(scene, child.get());
        if (! reason.empty()) return reason;
    }
    return {};
}

/// Shader-translation rejection, checked only after the structural ones.
std::string RejectShaders(const Scene& scene, const SceneNode* node, bool& saw_any_attempt,
                          const SceneMesh* resolved_geometry = nullptr)
{
    if (node == nullptr) return {};

    if (auto* mesh = const_cast<SceneNode*>(node)->Mesh(); mesh != nullptr) {
        const auto& slots = mesh->MaterialSlots();
        for (std::size_t slot_index = 0; slot_index < slots.size(); ++slot_index) {
            const auto& slot = slots[slot_index];
            if (slot == nullptr) continue;
            const auto* shader = slot->customShader.shader.get();
            if (shader == nullptr) continue;
            const auto* program = shader->metal_program.get();
            if (program == nullptr) continue;
            saw_any_attempt = true;
            if (! program->ok()) {
                return "a shader could not be translated to Metal";
            }
            MetalShaderReflection reflection;
            std::string           error;
            if (! ParseMetalShaderReflection(program->reflection_json, reflection, &error)) {
                return "a shader could not be translated to Metal";
            }
            const auto* bones = reflection.member(kBonesUniform);
            if (bones != nullptr) {
                // One 4x4 float matrix is 64 bytes; a tighter stride has nowhere
                // to write it, and a non-array member is not the `g_Bones[N]`
                // the author's vertex shader reads.
                if (bones->array_count == 0 || bones->array_stride < 64) {
                    return "a puppet shader lays out its bone matrices in a way the native "
                           "renderer cannot fill";
                }
                const MetalVertexInput* blend_indices = nullptr;
                const MetalVertexInput* blend_weights = nullptr;
                for (const auto& input : reflection.inputs) {
                    if (input.name == WE_IN_BLENDINDICES) blend_indices = &input;
                    if (input.name == WE_IN_BLENDWEIGHTS) blend_weights = &input;
                }
                if (blend_indices == nullptr || blend_weights == nullptr) {
                    return "a puppet shader does not read bone weights";
                }
                if (blend_indices->format != "r32g32b32a32_uint" ||
                    blend_weights->format != "r32g32b32a32_sfloat") {
                    return "a puppet shader reads bone weights in a format the native renderer "
                           "does not bind";
                }
                // The streams this material will really be drawn with: the
                // node's own, or the effect chain's final mesh when the node
                // has not been given it yet.
                bool has_streams = false;
                for (const auto& submesh : mesh->Submeshes()) {
                    has_streams = has_streams || submesh.VertexCount() > 0;
                }
                const SceneMesh& geometry =
                    ! has_streams && resolved_geometry != nullptr ? *resolved_geometry : *mesh;
                bool matched_slot = false;
                for (const auto& submesh : geometry.Submeshes()) {
                    if (submesh.material_slot == slot_index) {
                        matched_slot = true;
                        break;
                    }
                }
                bool any_checked = false;
                for (const auto& submesh : geometry.Submeshes()) {
                    if (matched_slot && submesh.material_slot != slot_index) continue;
                    any_checked = true;
                    bool has_weights = false;
                    for (std::size_t i = 0; i < submesh.VertexCount(); ++i) {
                        const auto& vertices = submesh.GetVertexArray(i);
                        if (HasAttribute(vertices, WE_IN_BLENDINDICES, VertexType::UINT4) &&
                            HasAttribute(vertices, WE_IN_BLENDWEIGHTS, VertexType::FLOAT4)) {
                            has_weights = true;
                            break;
                        }
                    }
                    if (! has_weights) {
                        return "a puppet shader is bound to a mesh without bone weights";
                    }
                }
                // No vertex stream at all still has nothing to bind the bone
                // weights against.
                if (! any_checked) {
                    return "a puppet shader is bound to a mesh without bone weights";
                }
            }
        }
    }

    for (auto* effect_node : EffectNodes(scene, node)) {
        auto reason = RejectShaders(scene, effect_node, saw_any_attempt,
                                    ResolvedEffectGeometry(scene, node, effect_node));
        if (! reason.empty()) return reason;
    }
    for (const auto& child : node->GetChildren()) {
        auto reason = RejectShaders(scene, child.get(), saw_any_attempt);
        if (! reason.empty()) return reason;
    }
    return {};
}

} // namespace

std::string SceneMetalStructuralRejection(const Scene& scene)
{
    if (scene.sceneGraph == nullptr) return "the scene has no drawable content";
    // Emitters are not refused. The simulation is the shared runtime's -- this
    // backend never emits, ages or kills a particle -- and the geometry it
    // produces is only ever the card, sprite and rope layouts the parser builds,
    // which the dynamic upload path writes whatever its vertex layout.
    // Lights are not refused. Wallpaper Engine lighting is the author's own
    // shader reading `g_LightsPosition` and `g_LightsColorPremultiplied`, which
    // the shared value updater writes through reflection.
    for (const auto& [name, texture] : scene.textures) {
        // A sprite sheet is one uploaded image whose frame rectangle arrives as
        // a uniform, so it is not refused any more. A sheet that is also a
        // video still is, below: that would need both paths at once.
        if (texture.isVideo) {
            if (auto reason = MetalVideoTextureRejection(scene, name); ! reason.empty()) {
                return reason;
            }
        }
    }

    // A perspective camera is not a refusal on its own. The node's camera --
    // named, overridden per pass, or the scene's active camera -- is the one
    // the value updater already writes, and an unused entry in `scene.cameras`
    // does not change what is drawn.

    // Effect chains and post-processing are ordinary multi-pass work here, so
    // neither is rejected wholesale any more. What this backend can execute is
    // decided pass by pass once the render graph exists.
    if (auto reason = RejectNodes(scene, scene.sceneGraph.get()); ! reason.empty()) return reason;
    for (auto* node : PostProcessNodes(scene)) {
        if (auto reason = RejectNodes(scene, node); ! reason.empty()) return reason;
    }
    return {};
}

SceneBackendSelection EvaluateMetalSupport(const Scene& scene)
{
    // First: the cause. A shader that did not compile took its layer or effect
    // out of the scene, and whatever else looks wrong about the rest follows
    // from that.
    if (! scene.shader_compile_error.empty()) return NativeRefusal(scene.shader_compile_error);
    if (! scene.layer_texture_error.empty()) return NativeRefusal(scene.layer_texture_error);
    if (auto reason = SceneMetalStructuralRejection(scene); ! reason.empty()) {
        return NativeRefusal(std::move(reason));
    }

    bool saw_any_attempt = false;
    if (auto reason = RejectShaders(scene, scene.sceneGraph.get(), saw_any_attempt);
        ! reason.empty()) {
        return NativeRefusal(std::move(reason));
    }
    for (auto* node : PostProcessNodes(scene)) {
        if (auto reason = RejectShaders(scene, node, saw_any_attempt); ! reason.empty()) {
            return NativeRefusal(std::move(reason));
        }
    }

    // No shader carries a translation at all. That is not the author's fault
    // and must not be reported as one: it means the parser did not run the
    // Metal translation for this scene.
    if (! saw_any_attempt) {
        return NativeRefusal("the wallpaper was parsed without the Metal translation of its shaders");
    }

    return SceneBackendSelection {};
}

MetalPassKind ClassifyMetalPassKind(int pass_node_type)
{
    switch (pass_node_type) {
    case static_cast<int>(rg::PassNode::Type::CustomShader): return MetalPassKind::CustomShader;
    case static_cast<int>(rg::PassNode::Type::Copy): return MetalPassKind::Copy;
    case static_cast<int>(rg::PassNode::Type::Clear): return MetalPassKind::Clear;
    case static_cast<int>(rg::PassNode::Type::Virtual): return MetalPassKind::Virtual;
    default: return MetalPassKind::Unsupported;
    }
}

std::string MetalGraphRejection(const Scene& scene, const rg::RenderGraph& graph)
{
    constexpr std::string_view kUnrecognised =
        "the render graph contains a step the native renderer does not recognise";

    // One step per pass that produces pixels, in execution order.
    //
    // A target read before anything this frame writes it, and written later,
    // is history: the reader sees the previous frame's result (a motion-blur
    // trail, a ripple or fluid simulation). That is not a refusal.
    // The graph flags such a target `carriesPreviousFrame`, and this backend
    // already gives every target name an image of its own that lives as long as
    // the compiled graph, so last frame's pixels are still there to read. The
    // optimisations that could disturb that keep their hands off it: the copy
    // planner never aliases a destination read before its copy, the reuse
    // cache calls a read-write loop feedback and never reuses it, and the
    // texture trade carries the copy's pixels with the texture.
    struct GraphStep
    {
        std::string              writes;
        std::vector<std::string> reads;
    };
    std::vector<GraphStep> steps;

    for (const auto node_id : graph.topologicalOrder()) {
        const auto* pass_node = graph.getPassNode(node_id);
        auto*       pass      = graph.getPass(node_id);
        if (pass_node == nullptr || pass == nullptr) return std::string(kUnrecognised);

        GraphStep step;
        switch (ClassifyMetalPassKind(static_cast<int>(pass_node->type()))) {
        case MetalPassKind::Virtual: continue;
        case MetalPassKind::Unsupported: return std::string(kUnrecognised);
        case MetalPassKind::Clear: {
            const auto* clear = dynamic_cast<const rg::ClearPass*>(pass);
            if (clear == nullptr) return std::string(kUnrecognised);
            step.writes = scene.ResolveRenderTargetName(clear->desc().result);
            break;
        }
        case MetalPassKind::Copy: {
            const auto* copy = dynamic_cast<const rg::CopyPass*>(pass);
            if (copy == nullptr) return std::string(kUnrecognised);
            step.writes = scene.ResolveRenderTargetName(copy->desc().dst);
            step.reads.push_back(scene.ResolveRenderTargetName(copy->desc().src));
            break;
        }
        case MetalPassKind::CustomShader: {
            const auto* custom = dynamic_cast<const rg::DrawPass*>(pass);
            if (custom == nullptr) return std::string(kUnrecognised);
            step.writes = scene.ResolveRenderTargetName(custom->desc().output);
            for (const auto& texture : custom->desc().textures) {
                if (texture.empty()) continue;
                step.reads.push_back(scene.ResolveRenderTargetName(texture));
            }
            break;
        }
        }
        steps.push_back(std::move(step));
    }

    // Targets the parser builds are single-sample, and a depth buffer is only ever
    // an attachment of the scene's own target, never a texture a pass reads
    // (`ParserBuildsOnlyTargetsTheDrawPathCanAllocate` pins both), so no target is
    // refused for its shape here.
    for (std::size_t i = 0; i < steps.size(); ++i) {
        for (const auto& read : steps[i].reads) {
            // The graph breaks a read-while-write by copying the target first,
            // so a pass still naming its own output has a cycle nothing broke.
            if (! read.empty() && read == steps[i].writes) {
                return "an effect reads the image it is drawing into";
            }
        }
    }
    return {};
}

} // namespace wallpaper::metal
