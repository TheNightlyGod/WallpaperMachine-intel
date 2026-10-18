#include "MetalRender/MetalCapability.hpp"

#include "MetalRender/MetalShaderReflection.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "MetalRender/SceneMetalProgram.hpp"

#include "CopyPass.hpp"
#include "CustomShaderPass.hpp"
#include "PrePass.hpp"
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

/// Whether this per-frame mesh is the four-corner card a text layer's relayout
/// or a pass-through layer's move rewrites.
///
/// A positive statement about the geometry, not about who owns it: one submesh
/// holding one vertex array of exactly a float3 position and a float2 texture
/// coordinate, four vertices of fixed capacity and no index array. That is what
/// `ResizeCardMesh` writes when the runtime re-lays out a text layer -- for the
/// layer's own card, for an effect chain's final card and for the node an
/// effect chain resolves its last pass onto -- and what `PassthroughCard`
/// writes when a pass-through layer is drawn somewhere else, and it is exactly
/// the upload the native backend's dynamic path performs. Anything with a
/// second stream, a different attribute set or a growing vertex count is not
/// this shape and is judged by the particle rules below.
bool IsDynamicCardMesh(const SceneMesh& mesh)
{
    if (mesh.MaterialSlots().size() != 1 || mesh.Submeshes().size() != 1) return false;
    const auto& submesh = mesh.Submeshes().front();
    if (submesh.VertexCount() != 1 || submesh.IndexCount() != 0) return false;
    const auto& vertices = submesh.GetVertexArray(0);
    const auto& attributes = vertices.Attributes();
    if (attributes.size() != 2) return false;
    if (attributes[0].name != WE_IN_POSITION || attributes[0].type != VertexType::FLOAT3) {
        return false;
    }
    if (attributes[1].name != WE_IN_TEXCOORD || attributes[1].type != VertexType::FLOAT2) {
        return false;
    }
    if (vertices.OneSize() == 0) return false;
    return vertices.CapacitySize() / vertices.OneSize() == 4;
}

/// Name and type together: a puppet's blend indices occupy the same slot a
/// float4 would, and a rope's `a_TexCoordVec3C2` is stored as a float4.
bool HasAttribute(const SceneVertexArray& vertices, std::string_view name, VertexType type)
{
    for (const auto& attribute : vertices.Attributes()) {
        if (attribute.name == name && attribute.type == type) return true;
    }
    return false;
}

/// Whether a mesh the runtime rewrites every frame is one this backend knows
/// how to feed, and why not when it is not.
///
/// A text layer's card is accepted first: its shape is checked above and the
/// dynamic upload path writes exactly it. Everything else must be one material,
/// one submesh, one vertex stream and one index stream. Sprite and rope are
/// exclusive; a rope-trail flag without both rope and trail is not a layout
/// this path fills. A sprite trail is the thick sprite-particle mesh, stretched
/// from the velocity in `a_TexCoordVec4C1`. A rope -- and a rope trail, which
/// is always thick -- must carry the vertex layout `SetRopeParticleMesh` writes.
/// Capacity, not current size, decides whether there is anywhere to put a
/// frame. Anything else that rebuilds its geometry per frame is still refused.
std::string RejectDynamicMesh(SceneMesh& mesh)
{
    constexpr std::string_view kNotParticles = "the scene rebuilds mesh geometry every frame";

    if (IsDynamicCardMesh(mesh)) return {};

    const auto* material = mesh.MaterialForSlot(0);
    if (material == nullptr) return std::string(kNotParticles);
    if (mesh.MaterialSlots().size() != 1 || mesh.Submeshes().size() != 1) {
        return std::string(kNotParticles);
    }
    const auto& submesh = mesh.Submeshes().front();
    // One vertex stream and one index stream is what the particle generator
    // writes. A second of either would be a shape this upload path has not
    // been written against.
    if (submesh.VertexCount() != 1 || submesh.IndexCount() != 1) {
        return std::string(kNotParticles);
    }
    const auto& vertices   = submesh.GetVertexArray(0);
    const bool  sprite     = vertices.GetOption(WE_PRENDER_SPRITE);
    const bool  rope       = vertices.GetOption(WE_PRENDER_ROPE);
    const bool  trail      = vertices.GetOption(WE_PRENDER_TRAIL);
    const bool  rope_trail = vertices.GetOption(WE_PRENDER_ROPETRAIL);
    const bool  thick      = vertices.GetOption(WE_CB_THICK_FORMAT);
    if (sprite == rope) return std::string(kNotParticles);
    if (rope_trail && ! (rope && trail)) return std::string(kNotParticles);
    if (sprite && trail) {
        // The author shader stretches the quad from the velocity the thick
        // sprite record already carries; without it there is nothing to read.
        if (! thick || ! HasAttribute(vertices, WE_IN_TEXCOORDVEC4C1, VertexType::FLOAT4)) {
            return "a sprite trail's mesh carries no particle velocity";
        }
    }
    if (rope) {
        // The shared runtime fills this layout; a sprite-shaped buffer would
        // draw the right number of triangles with the wrong geometry.
        bool has_layout =
            HasAttribute(vertices, WE_IN_POSITIONVEC4, VertexType::FLOAT4) &&
            HasAttribute(vertices, WE_IN_TEXCOORDVEC4, VertexType::FLOAT4) &&
            HasAttribute(vertices, WE_IN_TEXCOORDVEC4C1, VertexType::FLOAT4) &&
            HasAttribute(vertices, WE_IN_COLOR, VertexType::FLOAT4);
        if (thick) {
            has_layout = has_layout &&
                         HasAttribute(vertices, WE_IN_TEXCOORDVEC4C2, VertexType::FLOAT4) &&
                         HasAttribute(vertices, WE_IN_TEXCOORDVEC4C3, VertexType::FLOAT4) &&
                         HasAttribute(vertices, WE_IN_TEXCOORDC4, VertexType::FLOAT4);
        } else {
            has_layout = has_layout &&
                         HasAttribute(vertices, WE_IN_TEXCOORDVEC3C2, VertexType::FLOAT4) &&
                         HasAttribute(vertices, WE_IN_TEXCOORDC3, VertexType::FLOAT4);
        }
        // A rope trail's shader is always compiled with the thick format, so a
        // thin buffer under it would be read two attributes short.
        if (rope_trail && ! thick) return "a rope trail's mesh is not in the thick rope format";
        if (! has_layout) return "a rope particle mesh does not have the rope vertex layout";
    }
    // Capacity, not current size: a particle mesh is legitimately empty until
    // the first emission, and a zero-capacity one has nowhere to put a frame.
    if (vertices.CapacitySizeOf() == 0 || vertices.OneSizeOf() == 0) {
        return std::string(kNotParticles);
    }
    if (submesh.GetIndexArray(0).CapacitySizeof() == 0) return std::string(kNotParticles);
    return {};
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
        if (mesh->Dynamic()) {
            if (auto reason = RejectDynamicMesh(*mesh); ! reason.empty()) return reason;
        }
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
    // Emitters are no longer refused on sight. The simulation is the shared
    // runtime's either way -- this backend never emits, ages or kills a
    // particle -- so what decides is whether the geometry that simulation
    // produces is a shape the draw path can consume, which `RejectDynamicMesh`
    // answers per mesh while the scene graph is walked below.
    // Lights are not refused. Wallpaper Engine lighting is the author's own
    // shader reading `g_LightsPosition` and `g_LightsColorPremultiplied`, which
    // the shared value updater writes for either backend through reflection.
    // A plain video wallpaper is not a scene this backend competes for: the
    // host has a dedicated path for it.
    if (scene.single_video_source) return "the wallpaper is a video";

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
    if (! scene.layer_texture_error.empty()) {
        return SceneBackendSelection { SceneBackend::LegacyVulkan, scene.layer_texture_error };
    }
    if (auto reason = SceneMetalStructuralRejection(scene); ! reason.empty()) {
        return SceneBackendSelection { SceneBackend::LegacyVulkan, std::move(reason) };
    }

    bool saw_any_attempt = false;
    if (auto reason = RejectShaders(scene, scene.sceneGraph.get(), saw_any_attempt);
        ! reason.empty()) {
        return SceneBackendSelection { SceneBackend::LegacyVulkan, std::move(reason) };
    }
    for (auto* node : PostProcessNodes(scene)) {
        if (auto reason = RejectShaders(scene, node, saw_any_attempt); ! reason.empty()) {
            return SceneBackendSelection { SceneBackend::LegacyVulkan, std::move(reason) };
        }
    }

    // No shader carries a translation at all. That is not the author's fault
    // and must not be reported as one: it is what every scene looks like when
    // it was parsed while the compatibility renderer was selected, because the
    // second compile is only run when the native renderer is asked for.
    if (! saw_any_attempt) {
        return SceneBackendSelection {
            SceneBackend::LegacyVulkan,
            "the wallpaper was loaded before the native renderer was selected",
        };
    }

    return SceneBackendSelection { SceneBackend::NativeMetal, {} };
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
            const auto* clear = dynamic_cast<const vulkan::PrePass*>(pass);
            if (clear == nullptr) return std::string(kUnrecognised);
            step.writes = scene.ResolveRenderTargetName(clear->desc().result);
            break;
        }
        case MetalPassKind::Copy: {
            const auto* copy = dynamic_cast<const vulkan::CopyPass*>(pass);
            if (copy == nullptr) return std::string(kUnrecognised);
            step.writes = scene.ResolveRenderTargetName(copy->desc().dst);
            step.reads.push_back(scene.ResolveRenderTargetName(copy->desc().src));
            break;
        }
        case MetalPassKind::CustomShader: {
            const auto* custom = dynamic_cast<const vulkan::CustomShaderPass*>(pass);
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

    // Multisampled attachments are the target shape this backend has no
    // allocation for. A depth buffer is created only for passes that actually
    // depth-test, so `withDepth` on a target is not itself a refusal -- sampling
    // that depth as a texture still is, below. Checked against the targets the
    // graph actually names, so an unused declaration cannot reject a scene.
    const auto unrenderable = [&scene](const std::string& key) {
        const auto* target = scene.FindRenderTarget(key);
        return target != nullptr && target->sample_count > 1;
    };
    const auto samples_depth = [&scene](const std::string& key) {
        const auto* target = scene.FindRenderTarget(key);
        // A colour target may carry a depth attachment for its own draws; that
        // colour is still a colour sample. A target that is only a depth buffer
        // has no colour to sample, which this backend cannot bind.
        return target != nullptr && target->withDepth && target->width <= 0;
    };

    for (std::size_t i = 0; i < steps.size(); ++i) {
        if (unrenderable(steps[i].writes)) {
            return "an effect uses a render-target format the native renderer cannot create";
        }
        for (const auto& read : steps[i].reads) {
            if (unrenderable(read)) {
                return "an effect uses a render-target format the native renderer cannot create";
            }
            if (samples_depth(read)) {
                return "an effect samples a depth buffer";
            }
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
