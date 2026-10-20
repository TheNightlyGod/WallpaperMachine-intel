#include "WPSceneParser.hpp"
#include "LayerParallax.hpp"
#include "PassthroughCard.hpp"
#include "WPJson.hpp"
#include "Scene/SceneIndexArray.h"

#include "Utils/String.h"
#include "Utils/Logging.h"
#include "Utils/Algorism.h"
#include "Core/Visitors.hpp"
#include "Core/StringHelper.hpp"
#include "Core/ArrayHelper.hpp"
#include "SpecTexs.hpp"
#include "Scene/SceneLayerReference.hpp"

#include "WPShaderParser.hpp"
#include "WPTexImageParser.hpp"
#include "WPParticleParser.hpp"
#include "WPSoundParser.hpp"
#include "WPMdlParser.hpp"

#include "Particle/WPParticleRawGener.h"
#include "Particle/ParticleSystem.h"

#include "WPShaderValueUpdater.hpp"
#include "Shader/TextureFormatCombos.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scripting/ScriptModuleSyntax.hpp"
#include "Text/SystemFontResolver.hpp"
#include "Text/TextLayer.hpp"
#include "wpscene/WPImageObject.h"
#include "wpscene/WPParticleObject.h"
#include "wpscene/WPSoundObject.h"
#include "wpscene/WPLightObject.hpp"
#include "wpscene/WPMiscObject.hpp"
#include "wpscene/WPScene.h"

#include "Fs/VFS.h"
#include "MetalRender/MetalCapability.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "MetalRender/SceneMetalProgram.hpp"
#include "Scene/SceneBackendSelection.hpp"
#include "Shader/RustShaderBridge.hpp"

#include <algorithm>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <random>
#include <cmath>
#include <optional>
#include <regex>
#include <span>
#include <limits>
#include <variant>
#include <Eigen/Dense>

using namespace wallpaper;
using namespace Eigen;

std::string getAddr(void* p) { return std::to_string(reinterpret_cast<intptr_t>(p)); }

namespace
{

/// One material's shader, captured with everything a Metal translation needs.
///
/// Metal Shading Language can only be produced here. It needs the final combo
/// set, the preprocessed units and the texture info the SPIR-V compile settled
/// on, and none of those outlive `LoadMaterial`. The translation itself is
/// deferred to the end of the parse so a scene that has already disqualified
/// itself structurally -- a particle emitter, a puppet, a video texture --
/// never pays for a second full shader compile it would not have used.
struct PendingMetalTranslation {
    std::shared_ptr<SceneShader>      shader;
    std::string                       shader_name;
    std::string                       scene_id;
    std::vector<WPShaderUnit>         units;
    WPShaderInfo                      shader_info;
    std::vector<WPShaderTexInfo>      texinfos;
    /// The material's texture keys, in slot order, so the flush can ask the
    /// scene which slot is a video without re-deriving the list.
    std::vector<std::string>          texture_keys;
    fs::VFS*                          vfs { nullptr };
};

/// Parsing is single-threaded per scene but several scenes may parse at once,
/// so the queue is per-thread rather than global.
thread_local std::vector<PendingMetalTranslation> g_pending_metal_translations;
thread_local const LayerObjectIndex* g_parse_layer_index { nullptr };

bool MetalTranslationRequested() {
    return CurrentSceneRendererPreference() == SceneRendererPreference::NativeMetalPreferred;
}

/// The one material texture slot a direct NV12 variant could be compiled for,
/// or nothing.
///
/// Exactly one candidate, deliberately: two video slots in one material would
/// need a variant per combination, and this round compiles one extra program
/// per material, never a matrix of them. A slot the native video path itself
/// refuses -- a sprite sheet, a texture with no media -- is not a candidate
/// either, because that material is not going to reach this backend at all.
std::optional<uint32_t> ResolveVideoPlaneCandidate(const Scene& scene,
                                                   const std::vector<std::string>& texture_keys) {
    std::optional<uint32_t> candidate;
    for (usize slot = 0; slot < texture_keys.size(); ++slot) {
        const auto& key = texture_keys[slot];
        if (key.empty()) continue;
        const auto found = scene.textures.find(key);
        if (found == scene.textures.end() || ! found->second.isVideo) continue;
        if (! metal::MetalVideoTextureRejection(scene, key).empty()) return std::nullopt;
        if (candidate.has_value()) return std::nullopt;
        candidate = static_cast<uint32_t>(slot);
    }
    return candidate;
}

SceneMetalSlotKind ToSceneMetalSlotKind(shader::RustShaderMetalSlotKind kind) {
    switch (kind) {
    case shader::RustShaderMetalSlotKind::Texture: return SceneMetalSlotKind::Texture;
    case shader::RustShaderMetalSlotKind::Sampler: return SceneMetalSlotKind::Sampler;
    case shader::RustShaderMetalSlotKind::Buffer: break;
    }
    return SceneMetalSlotKind::Buffer;
}

/// Records what the direct plane-sampling variant of one already-translated
/// program would be compiled from, if this material has exactly one candidate
/// video slot.
///
/// Nothing is compiled here. The combos, the preprocessed units, the texture
/// info and the includes the ordinary translation read are all still available
/// at this point and nowhere else, so they are copied into a snapshot that owns
/// itself; whether the variant is ever wanted is a question for the renderer
/// and the user's setting, long after this parse has finished. A wallpaper must
/// not pay for an optional program before it has drawn a single frame.
void CaptureVideoPlaneInputs(Scene& scene, PendingMetalTranslation& request,
                             SceneMetalProgram& program, WPShaderIncludeMap includes) {
    const auto slot = ResolveVideoPlaneCandidate(scene, request.texture_keys);
    if (! slot.has_value()) return;

    auto inputs              = std::make_shared<SceneMetalVariantInputs>();
    inputs->scene_id         = request.scene_id;
    inputs->shader_name      = request.shader_name;
    inputs->units            = request.units;
    inputs->shader_info      = request.shader_info;
    inputs->texinfos         = request.texinfos;
    inputs->includes         = std::move(includes);
    inputs->nv12_plane_slot  = *slot;
    program.video_plane_inputs = std::move(inputs);
}

/// Runs the queued translations, if the scene is still a candidate.
///
/// A failure here never fails the parse: the wallpaper loads and draws on the
/// compatibility backend, and the recorded error is what the capability gate
/// turns into a user-readable reason. A wallpaper must not stop working
/// because someone ticked a renderer preference.
void FlushPendingMetalTranslations(Scene& scene) {
    auto pending = std::move(g_pending_metal_translations);
    g_pending_metal_translations.clear();
    g_parse_layer_index = nullptr;
    if (pending.empty()) return;
    if (! metal::SceneMetalStructuralRejection(scene).empty()) return;

    for (auto& request : pending) {
        if (request.shader == nullptr || request.vfs == nullptr) continue;
        auto program = std::make_shared<SceneMetalProgram>();

        std::vector<shader::RustShaderMetalStage> stages;
        std::string                               reflection_json;
        WPShaderIncludeMap                        includes;
        bool                                      compiled = false;
        // The units this compile is handed are the ones the snapshot below has
        // to describe, so the snapshot is taken from a copy made before the
        // compile merges its results into them.
        const auto captured_units       = request.units;
        const auto captured_shader_info = request.shader_info;
        try {
            compiled = WPShaderParser::CompileToMslRust(request.scene_id,
                                                        request.shader_name,
                                                        request.units,
                                                        stages,
                                                        *request.vfs,
                                                        &request.shader_info,
                                                        request.texinfos,
                                                        &reflection_json,
                                                        std::nullopt,
                                                        &includes);
        } catch (const std::exception& e) {
            program->error = e.what();
        }
        if (! compiled && program->error.empty()) {
            program->error = shader::LastRustShaderError();
            if (program->error.empty()) program->error = "metal translation failed";
        }

        if (compiled) {
            program->reflection_json = std::move(reflection_json);
            for (const auto& stage : stages) {
                SceneMetalStage out;
                out.kind             = stage.kind == ShaderType::FRAGMENT
                                           ? SceneMetalStageKind::Fragment
                                           : SceneMetalStageKind::Vertex;
                out.source           = stage.source;
                out.entry_point      = stage.entry_point;
                out.language_version = stage.language_version;
                out.bindings.reserve(stage.bindings.size());
                for (const auto& binding : stage.bindings) {
                    out.bindings.push_back(SceneMetalBinding {
                        .name      = binding.name,
                        .set       = binding.set,
                        .binding   = binding.binding,
                        .slot_kind = ToSceneMetalSlotKind(binding.slot_kind),
                        .slot      = binding.slot,
                    });
                }
                program->stages.push_back(std::move(out));
            }
            if (program->stages.empty() || program->reflection_json.empty()) {
                program->error = "metal translation produced no usable shader";
            }
        }
        if (! program->error.empty()) {
            LOG_ERROR("metal translation of '%s' failed: %s",
                      request.shader_name.c_str(),
                      program->error.c_str());
        }
        if (compiled) {
            request.units       = captured_units;
            request.shader_info = captured_shader_info;
            CaptureVideoPlaneInputs(scene, request, *program, std::move(includes));
            if (program->hasVideoPlaneCandidate()) {
                scene.metal_variant_candidates.push_back(program);
            }
        }
        // Stored either way: a recorded failure is what distinguishes "tried
        // and could not" from "never tried", and only the first is a fault in
        // the shader.
        request.shader->metal_program = std::move(program);
    }
}

} // namespace

struct ParseContext {
    std::shared_ptr<Scene>                                  scene;
    WPShaderValueUpdater*                                   shader_updater;
    i32                                                     ortho_w;
    i32                                                     ortho_h;
    fs::VFS*                                                vfs;
    const SceneParseRequest*                                request;
    const nlohmann::json*                                   object_list { nullptr };
    std::unordered_map<int32_t, std::shared_ptr<SceneNode>> layer_nodes;
    std::unordered_map<int32_t, int32_t>                    layer_parent_ids;
    std::unordered_map<int32_t, std::shared_ptr<WPPuppet>>  layer_puppets;
    std::unordered_map<int32_t, WPPuppetLayer>              layer_puppet_animations;
    std::unordered_set<int32_t>                             attached_layer_nodes;
    std::vector<int32_t>                                    layer_node_order;
    /// Particle systems that have a prewarm to run, a child's before its parent's.
    /// It waits for the finished scene graph: the matrix a system is born by is
    /// its layer's world matrix, parent groups included, and a layer joins its
    /// group only once every object exists.
    std::vector<ParticleSubSystem*>                         pending_prewarms;
    std::vector<std::pair<std::string, std::string>>        pending_scene_scripts;
    std::unordered_map<std::string, uint32_t>               layer_name_counts;
    std::unordered_map<int32_t, std::string>                object_runtime_names;
    std::unordered_map<std::string, uint32_t>               text_name_counts;
    /// Sound objects the scene builds. Each is a layer scripts list and address
    /// like a plain group, with its sound registered under the same key.
    std::unordered_set<int32_t>                             sound_layer_ids;
    std::unordered_set<int32_t>                             referenced_layer_ids;
    /// The card each text layer shows, for a composite registered only once
    /// a later consumer turns out to sample the layer.
    std::unordered_map<int32_t, TextLayerRenderFrame>       text_cards;
    /// Pass-through layers drawn through effects. Each card copies the part of
    /// the screen its layer is drawn over, which the layer's groups decide, so
    /// it is laid out again once every layer is under its parent.
    struct PendingPassthroughCard {
        std::shared_ptr<SceneNode>       node;
        std::shared_ptr<SceneMesh>       mesh;
        std::shared_ptr<PassthroughCard> card;
    };
    std::vector<PendingPassthroughCard>                     passthrough_cards;

    ShaderValueMap             global_base_uniforms;
    std::shared_ptr<SceneNode> effect_camera_node;
    std::shared_ptr<SceneNode> global_camera_node;
    std::shared_ptr<SceneNode> global_perspective_camera_node;
    bool                       uses_models { false };
    // `orthogonalprojection` present and not null. The scene is then projected
    // by that canvas, which is the space every 2D layer's geometry, origin and
    // alignment is authored in.
    bool                       is_ortho { true };
    // The canvas has a pixel size: particle files then default omitted keys in
    // pixel units.
    bool                       pixel_canvas { true };
};

using WPObjectVar =
    std::variant<wpscene::WPImageObject, wpscene::WPParticleObject, wpscene::WPSoundObject,
                 wpscene::WPLightObject, wpscene::WPTextObject, wpscene::WPModelObject,
                 wpscene::WPCameraObject, wpscene::WPShapeObject>;

struct RawLayerObject {
    int32_t              id { 0 };
    int32_t              parent_id { -1 };
    std::string          name;
    std::array<float, 3> origin { 0.0f, 0.0f, 0.0f };
    std::array<float, 3> scale { 1.0f, 1.0f, 1.0f };
    std::array<float, 3> angles { 0.0f, 0.0f, 0.0f };
    bool                 visible { true };
    bool                 dynamic_origin { false };
    bool                 dynamic_visible { false };
    bool                 schema_placeholder { false };
    nlohmann::json       origin_setting;
    nlohmann::json       scale_setting;
    nlohmann::json       angles_setting;
    nlohmann::json       visible_setting;
};

namespace
{
std::vector<uint8_t> ReadVfsBytes(fs::VFS& vfs, std::string_view path) {
    auto stream = vfs.Open(path);
    if (stream == nullptr) return {};

    std::vector<uint8_t> data(stream->Usize());
    if (data.empty()) return data;

    const auto bytes_read = stream->Read(data.data(), data.size());
    data.resize(bytes_read);
    return data;
}

bool MaterialUsesAudioResponse(const wpscene::WPMaterial& material) {
    const auto combo = material.combos.find("AUDIOPROCESSING");
    return combo != material.combos.end() && combo->second != 0;
}

void MarkSceneRequiresAudioResponse(Scene* scene) {
    if (scene != nullptr && scene->runtime != nullptr) {
        scene->runtime->MarkSceneRequiresAudioResponse();
    }
}

void LogUnsupportedParticleAudioModeOnce(uint32_t mode) {
    static std::unordered_set<uint32_t> logged_modes;
    if (logged_modes.insert(mode).second) {
        LOG_INFO(
            "particle audio processing mode %u is not supported yet; ignoring particle modulation",
            mode);
    }
}

const nlohmann::json& UnwrapSettingValue(const nlohmann::json& value) {
    if (value.is_object() && value.contains("value")) return value.at("value");
    return value;
}

bool HasDynamicSetting(const nlohmann::json& value) {
    return value.is_object() && (value.contains("script") || value.contains("user"));
}

/// A visibility only a reload changes: the authored value, or one of the
/// wallpaper's own properties, which reparse the scene when they change.
/// Anything handed to a script can change from one frame to the next.
bool VisibilitySettledBy(const nlohmann::json& setting) {
    return ! setting.is_object() || ! setting.contains("script");
}

bool HasUpdateScript(const nlohmann::json& value) {
    if (! value.is_object() || ! value.contains("script") || ! value.at("script").is_string()) {
        return false;
    }

    return ExportsFunction(value.at("script").get<std::string>(), "update");
}

bool HasRuntimeTextValueBinding(const nlohmann::json& value) {
    return value.is_object() && (value.contains("user") || HasUpdateScript(value));
}

void ReadVec3Setting(const nlohmann::json& json, const char* key, std::array<float, 3>* destination,
                     nlohmann::json* setting, bool* dynamic) {
    if (! json.contains(key) || destination == nullptr || setting == nullptr) return;

    *setting = json.at(key);
    if (dynamic != nullptr) *dynamic = HasDynamicSetting(*setting);
    const auto& source = UnwrapSettingValue(*setting);

    if (source.is_array() && source.size() >= 3) {
        (*destination)[0] = source.at(0).get<float>();
        (*destination)[1] = source.at(1).get<float>();
        (*destination)[2] = source.at(2).get<float>();
        return;
    }
    if (source.is_number()) {
        const float scalar = source.get<float>();
        *destination       = { scalar, scalar, scalar };
        return;
    }
    if (source.is_string()) {
        std::istringstream stream(source.get<std::string>());
        stream >> (*destination)[0] >> (*destination)[1] >> (*destination)[2];
    }
}

bool IsSceneScriptSetting(const nlohmann::json& setting) {
    if (! setting.is_object() || ! setting.contains("script") ||
        ! setting.at("script").is_string()) {
        return false;
    }

    if (HasUpdateScript(setting)) {
        return false;
    }

    const auto script = setting.at("script").get<std::string>();
    return script.find("engine.on(") != std::string::npos ||
           script.find("scene.on(") != std::string::npos ||
           script.find("thisScene.on(") != std::string::npos;
}

void QueueSceneScriptIfNeeded(ParseContext& context, std::string_view layer_name,
                              const nlohmann::json& setting) {
    if (! IsSceneScriptSetting(setting)) return;
    context.pending_scene_scripts.emplace_back(std::string(layer_name),
                                               setting.at("script").get<std::string>());
}

bool IsLayerObject(const nlohmann::json& object) {
    return ! object.contains("image") && ! object.contains("particle") &&
           ! object.contains("sound") && ! object.contains("light") && ! object.contains("text") &&
           ! object.contains("model") && ! object.contains("camera");
}

bool IsSchemaOnlyObject(const nlohmann::json& object) {
    return (object.contains("text") && ! object.at("text").is_null()) ||
           (object.contains("model") && ! object.at("model").is_null()) ||
           (object.contains("camera") && ! object.at("camera").is_null());
}

bool HasChildObject(const nlohmann::json& objects, int32_t parent_id) {
    for (const auto& object : objects) {
        if (! object.contains("parent")) continue;
        const auto& parent = object.at("parent");
        if (! parent.is_number_integer()) continue;
        if (parent.get<int32_t>() == parent_id) return true;
    }
    return false;
}

std::string LayerRuntimeName(const ParseContext& context, const RawLayerObject& layer) {
    if (! layer.name.empty()) {
        const auto count = context.layer_name_counts.find(layer.name);
        if (count == context.layer_name_counts.end() || count->second <= 1u) return layer.name;
    }
    return "__we_layer_" + std::to_string(layer.id);
}

template<typename T>
std::string LayerRuntimeName(const ParseContext& context, const T& object) {
    if (const auto iterator = context.object_runtime_names.find(object.id);
        iterator != context.object_runtime_names.end()) {
        return iterator->second;
    }
    if (! object.name.empty()) return object.name;
    return "__we_layer_" + std::to_string(object.id);
}

class RuntimeNodeRegistrationRollback {
public:
    RuntimeNodeRegistrationRollback(
        SceneRuntimeContext* runtime, std::string name, SceneNode* node,
        std::unordered_map<int32_t, std::shared_ptr<SceneNode>>* layer_nodes = nullptr,
        int32_t                                                  layer_id    = 0,
        std::vector<std::pair<std::string, std::string>>*        pending_scene_scripts = nullptr)
        : m_runtime(runtime),
          m_name(std::move(name)),
          m_node(node),
          m_previous(runtime != nullptr ? runtime->CaptureNodeRegistration(m_name) : nullptr),
          m_layer_nodes(layer_nodes),
          m_layer_id(layer_id),
          m_pending_scene_scripts(pending_scene_scripts),
          m_pending_scene_script_size(
              pending_scene_scripts != nullptr ? pending_scene_scripts->size() : 0u) {}

    ~RuntimeNodeRegistrationRollback() {
        if (! m_committed && m_runtime != nullptr && ! m_name.empty()) {
            m_runtime->RollbackNodeRegistration(m_name, m_node, m_previous);
        }
        if (! m_committed && m_layer_nodes != nullptr) {
            m_layer_nodes->erase(m_layer_id);
        }
        if (! m_committed && m_pending_scene_scripts != nullptr) {
            m_pending_scene_scripts->resize(m_pending_scene_script_size);
        }
    }

    void Commit() { m_committed = true; }

private:
    SceneRuntimeContext*                                     m_runtime { nullptr };
    std::string                                              m_name;
    SceneNode*                                               m_node { nullptr };
    std::shared_ptr<SceneRuntimeContext::NodeRegistrationSnapshot> m_previous;
    std::unordered_map<int32_t, std::shared_ptr<SceneNode>>* m_layer_nodes { nullptr };
    int32_t                                                  m_layer_id { 0 };
    std::vector<std::pair<std::string, std::string>>*        m_pending_scene_scripts { nullptr };
    std::size_t                                              m_pending_scene_script_size { 0 };
    bool                                                     m_committed { false };
};

void AttachLayerNode(ParseContext& context, int32_t layer_id) {
    if (context.attached_layer_nodes.contains(layer_id)) return;

    auto node_iterator = context.layer_nodes.find(layer_id);
    if (node_iterator == context.layer_nodes.end() || node_iterator->second == nullptr) return;

    const auto    parent_id_iterator = context.layer_parent_ids.find(layer_id);
    const int32_t parent_id =
        parent_id_iterator != context.layer_parent_ids.end() ? parent_id_iterator->second : -1;

    if (auto parent_iterator = context.layer_nodes.find(parent_id);
        parent_iterator != context.layer_nodes.end() && parent_iterator->second != nullptr) {
        parent_iterator->second->AppendChild(node_iterator->second);
    } else {
        context.scene->sceneGraph->AppendChild(node_iterator->second);
    }
    context.attached_layer_nodes.insert(layer_id);
}

void RegisterLayerAttachments(ParseContext& context) {
    if (context.object_list == nullptr) return;
    std::unordered_map<int32_t, std::vector<WPShaderValueUpdater::PuppetAttachment>> groups;
    for (const auto& object : *context.object_list) {
        if (!object.contains("attachment") || !object["attachment"].is_string() ||
            !object.contains("parent") || !object["parent"].is_number_integer() ||
            !object.contains("id") || !object["id"].is_number_integer()) continue;
        const auto parent_id = object["parent"].get<int32_t>();
        const auto node = context.layer_nodes.find(object["id"].get<int32_t>());
        const auto puppet = context.layer_puppets.find(parent_id);
        if (node == context.layer_nodes.end() || puppet == context.layer_puppets.end()) continue;
        const auto name = object["attachment"].get<std::string>();
        const auto& model = *puppet->second;
        const auto attachment = std::find_if(model.attachments.begin(), model.attachments.end(),
            [&name](const auto& item) { return item.name == name; });
        if (attachment == model.attachments.end() || attachment->bone_index >= model.bones.size())
            continue;
        // genFrame returns skinning matrices (animated world * inverse bind).
        // Restore the bind frame before applying the attachment's local affine.
        groups[parent_id].push_back({ node->second.get(), attachment->bone_index,
            model.bones[attachment->bone_index].world_bind * attachment->local_xform });
    }
    for (auto& [parent_id, attachments] : groups) {
        // Copies share playback state with the parent's render passes.
        context.shader_updater->RegisterPuppetAttachments(
            context.layer_puppet_animations.at(parent_id), std::move(attachments));
    }
}

void AttachRemainingLayerNodes(ParseContext& context) {
    for (const auto layer_id : context.layer_node_order) {
        AttachLayerNode(context, layer_id);
    }
}

// Runs the prewarms the particle layers queued, now that every layer sits under
// its parent.
void PrewarmParticleSystems(ParseContext& context) {
    for (auto* system : context.pending_prewarms) system->Prewarm();
    context.pending_prewarms.clear();
}

// `node_kind` takes an object of a kind that has no node of its own (a sound)
// as a plain group.
bool ParseLayerObject(const nlohmann::json& json, const nlohmann::json& objects,
                      RawLayerObject& layer, bool node_kind = false) {
    GET_JSON_NAME_VALUE_NOWARN(json, "id", layer.id);
    if (! node_kind && ! IsLayerObject(json) &&
        (! IsSchemaOnlyObject(json) || layer.id == 0 || ! HasChildObject(objects, layer.id)))
        return false;

    layer.schema_placeholder = IsSchemaOnlyObject(json);
    GET_JSON_NAME_VALUE_NOWARN(json, "parent", layer.parent_id);
    GET_JSON_NAME_VALUE_NOWARN(json, "name", layer.name);
    ReadVec3Setting(json, "origin", &layer.origin, &layer.origin_setting, &layer.dynamic_origin);
    ReadVec3Setting(json, "scale", &layer.scale, &layer.scale_setting, nullptr);
    ReadVec3Setting(json, "angles", &layer.angles, &layer.angles_setting, nullptr);
    GET_JSON_NAME_VALUE_NOWARN(json, "visible", layer.visible);
    if (json.contains("visible")) {
        layer.visible_setting = json.at("visible");
        layer.dynamic_visible = HasDynamicSetting(layer.visible_setting);
    }

    return layer.id != 0;
}

void ParseLayerNodes(ParseContext& context, const nlohmann::json& objects) {
    std::vector<RawLayerObject> layers;
    for (const auto& object : objects) {
        int32_t object_id = 0;
        GET_JSON_NAME_VALUE_NOWARN(object, "id", object_id);
        if (object_id != 0) {
            context.layer_node_order.push_back(object_id);
        }

        RawLayerObject layer;
        if (ParseLayerObject(
                object, objects, layer, context.sound_layer_ids.contains(object_id))) {
            layers.push_back(std::move(layer));
        }
    }

    for (const auto& layer : layers) {
        const auto runtime_name = LayerRuntimeName(context, layer);
        auto       node         = std::make_shared<SceneNode>(Vector3f(layer.origin.data()),
                                                Vector3f(layer.scale.data()),
                                                Vector3f(layer.angles.data()),
                                                runtime_name);
        if (context.scene->runtime != nullptr) {
            context.scene->runtime->RegisterNode(runtime_name, node.get());
            // A plain group, or a layer of a kind not parsed yet, is never
            // hit-tested for the cursor.
            context.scene->runtime->SetNodeCursorTarget(runtime_name, false, true, false);
            context.scene->runtime->RegisterNodeVisibility(
                runtime_name,
                node.get(),
                ResolveBoolSetting(*context.scene->runtime,
                                   layer.dynamic_visible ? layer.visible_setting
                                                         : nlohmann::json(layer.visible),
                                   runtime_name));
            node->SetVisibilitySettled(VisibilitySettledBy(layer.visible_setting));
            // Typed parents get their timeline when their real object is
            // parsed; registering it on the placeholder creates a second clock.
            RegisterNodeTransformSettings(*context.scene->runtime, node.get(), runtime_name,
                                          layer.origin_setting, layer.scale_setting,
                                          layer.angles_setting, !layer.schema_placeholder);
        } else {
            node->SetVisible(layer.visible);
        }
        QueueSceneScriptIfNeeded(context, runtime_name, layer.visible_setting);
        QueueSceneScriptIfNeeded(context, runtime_name, layer.origin_setting);
        QueueSceneScriptIfNeeded(context, runtime_name, layer.scale_setting);
        QueueSceneScriptIfNeeded(context, runtime_name, layer.angles_setting);
        context.layer_nodes[layer.id]      = node;
        context.layer_parent_ids[layer.id] = layer.parent_id;
    }
}

i32 EffectiveProjectionDimension(i32 base_dimension, float zoom) {
    if (! std::isfinite(zoom) || zoom <= 0.0f) zoom = 1.0f;
    return std::max(1, static_cast<i32>(static_cast<float>(base_dimension) / zoom));
}

std::array<int32_t, 2> ResolveImageRenderExtent(const wpscene::WPImageObject& object,
                                                const ParseContext&           context) {
    const auto object_width  = std::isfinite(object.size[0])
                                   ? static_cast<int32_t>(std::lround(object.size[0]))
                                   : 0;
    const auto object_height = std::isfinite(object.size[1])
                                   ? static_cast<int32_t>(std::lround(object.size[1]))
                                   : 0;
    if (object_width > 2 && object_height > 2) {
        return { object_width, object_height };
    }

    // Invisible utility sources in Wallpaper Engine scenes often carry one
    // invalid size axis while effects still use the valid axis as authored.
    // Fill only invalid axes from the scene projection, then clamp FBOs later.
    return {
        object_width > 2 ? object_width : std::max(4, context.ortho_w),
        object_height > 2 ? object_height : std::max(4, context.ortho_h),
    };
}

int32_t ResolveRenderTargetDimension(float base_dimension, uint32_t scale) {
    if (scale == 0) scale = 1;
    if (! std::isfinite(base_dimension)) base_dimension = 0.0f;
    return std::max(
        4,
        static_cast<int32_t>(std::lround(base_dimension / static_cast<float>(scale))));
}

int32_t ResolveTextEffectRenderTargetDimension(float base_dimension, uint32_t /* scale */) {
    return ResolveRenderTargetDimension(base_dimension, 1);
}

// The format Wallpaper Engine gives an effect buffer. Float buffers hold signed
// values, such as a fluid simulation's velocity and pressure, which an 8-bit
// target would clamp at zero; the back-buffer formats follow the scene. A
// single- or two-channel float buffer takes the four-channel float target, the
// narrowest float format both renderers allocate.
TextureFormat EffectFboFormat(std::string_view format, bool hdr) {
    if (format == "r16f" || format == "rg1616f" || format == "rgba16161616f" ||
        format == "r32f" || format == "rg3232f" || format == "rgba32323232f") {
        return TextureFormat::RGBA16F;
    }
    if (format == "rgba8888" || format == "rgb888" || format == "rg88" || format == "r8") {
        return TextureFormat::RGBA8;
    }
    return hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8;
}

// An effect buffer with a `width`, `height` or `fit` of its own has a fixed
// size, as in Wallpaper Engine: its own size where given (else the layer's),
// shrunk so its longer side is at most `fit` with its aspect kept, then divided
// by `scale`. Wallpaper Engine ignores sizes above 4096. Without any of them
// the buffer follows the layer, scaled.
std::optional<std::array<int32_t, 2>> FixedEffectFboExtent(const wpscene::WPEffectFbo& fbo,
                                                           float layer_width,
                                                           float layer_height) {
    constexpr uint32_t kLargest = 4096;
    const bool own_width  = fbo.width > 0 && fbo.width <= kLargest;
    const bool own_height = fbo.height > 0 && fbo.height <= kLargest;
    const bool fits       = fbo.fit > 0 && fbo.fit <= kLargest;
    if (! own_width && ! own_height && ! fits) return std::nullopt;
    float width  = own_width ? static_cast<float>(fbo.width) : layer_width;
    float height = own_height ? static_cast<float>(fbo.height) : layer_height;
    if (fits && width > 0.0f && height > 0.0f) {
        const float fit = static_cast<float>(fbo.fit);
        if (width < height) {
            const float fitted = std::min(fit, height);
            width              = width / height * fitted;
            height             = fitted;
        } else {
            const float fitted = std::min(fit, width);
            height             = height / width * fitted;
            width              = fitted;
        }
    }
    return std::array { ResolveRenderTargetDimension(width, fbo.scale),
                        ResolveRenderTargetDimension(height, fbo.scale) };
}

// Whether, running on from just after pass `from` and round to the start of
// the next frame, the effect reads `fbo` before it draws into it.
bool EffectReadsBeforeWriting(const wpscene::WPImageEffect& effect, std::string_view fbo,
                              std::size_t from) {
    for (const auto& command : effect.commands) {
        if (command.source == fbo) return true;
    }
    const auto count = effect.passes.size();
    for (std::size_t step = 0; step < count; ++step) {
        const auto& pass = effect.passes[(from + step) % count];
        for (const auto& bind : pass.bind) {
            if (bind.name == fbo) return true;
        }
        if (pass.target == fbo) return false;
    }
    return false;
}

// An effect's `copy` and `swap` commands as copies between its buffers. A
// `swap` exchanges two buffers after a pass: the first then holds what was
// drawn into the second, and the second what the first held. When the effect
// draws into the second before it reads it again, that half of the exchange is
// never seen and one copy is the whole swap; otherwise it goes through a
// temporary buffer of the second's size.
void LowerEffectCommands(const wpscene::WPImageEffect& effect,
                         const std::unordered_map<std::string, std::string>& fbo_map, Scene& scene,
                         std::vector<SceneImageEffect::Command>& commands) {
    for (const auto& command : effect.commands) {
        const bool swap = command.command == "swap";
        if (command.command != "copy" && ! swap) {
            LOG_ERROR("Unknown effect command: %s", command.command.c_str());
            continue;
        }
        const auto target = fbo_map.find(command.target);
        const auto source = fbo_map.find(command.source);
        if (target == fbo_map.end() || source == fbo_map.end()) {
            LOG_ERROR("Unknown effect command dst or src: %s %s",
                      command.target.c_str(),
                      command.source.c_str());
            continue;
        }
        const auto copy = [&commands, &command](const std::string& dst, const std::string& src) {
            commands.push_back({ .cmd      = SceneImageEffect::CmdType::Copy,
                                 .dst      = dst,
                                 .src      = src,
                                 .afterpos = command.afterpos });
        };
        if (! swap) {
            copy(target->second, source->second);
            continue;
        }
        const auto after = static_cast<std::size_t>(std::max(0, command.afterpos));
        if (! EffectReadsBeforeWriting(effect, command.target, after)) {
            copy(source->second, target->second);
            continue;
        }
        const auto temporary = target->second + "_swap";
        scene.renderTargets[temporary] = scene.renderTargets.at(target->second);
        copy(temporary, source->second);
        copy(source->second, target->second);
        copy(target->second, temporary);
    }
}

// mapRate < 1.0
void GenCardMesh(SceneMesh& mesh, const std::array<uint16_t, 2> size,
                 const std::array<float, 2> mapRate = { 1.0f, 1.0f }) {
    float left   = -(size[0] / 2.0f);
    float right  = size[0] / 2.0f;
    float bottom = -(size[1] / 2.0f);
    float top    = size[1] / 2.0f;
    float z      = 0.0f;

    float tw = mapRate[0], th = mapRate[1];

    // clang-format off
	const std::array pos = {
		left, bottom, z,
		left,  top, z,
		right, bottom, z,
		right,  top, z,
	};
	const std::array texCoord = {
		0.0f, th,
		0.0f, 0.0f,
		tw, th,
		tw, 0.0f,
	};
    // clang-format on

    SceneVertexArray vertex(
        {
            { WE_IN_POSITION.data(), VertexType::FLOAT3 },
            { WE_IN_TEXCOORD.data(), VertexType::FLOAT2 },
        },
        4);
    vertex.SetVertex(WE_IN_POSITION, pos);
    vertex.SetVertex(WE_IN_TEXCOORD, texCoord);
    mesh.AddVertexArray(std::move(vertex));
}

void GenTextCardMesh(SceneMesh& mesh, TextLayerRenderBounds bounds,
                     const std::array<float, 2> mapRate = { 1.0f, 1.0f }) {
    float z = 0.0f;

    float tw = mapRate[0], th = mapRate[1];

    // clang-format off
	const std::array pos = {
		bounds.left,  bounds.bottom, z,
		bounds.left,  bounds.top,    z,
		bounds.right, bounds.bottom, z,
		bounds.right, bounds.top,    z,
	};
	const std::array texCoord = {
		0.0f, th,
		0.0f, 0.0f,
		tw, th,
		tw, 0.0f,
	};
    // clang-format on

    SceneVertexArray vertex(
        {
            { WE_IN_POSITION.data(), VertexType::FLOAT3 },
            { WE_IN_TEXCOORD.data(), VertexType::FLOAT2 },
        },
        4);
    vertex.SetVertex(WE_IN_POSITION, pos);
    vertex.SetVertex(WE_IN_TEXCOORD, texCoord);
    mesh.AddVertexArray(std::move(vertex));
}

void AddParticleIndexArray(SceneMesh& mesh, uint32_t count) {
    const auto layout = PlanParticleIndexLayout(count);
    mesh.AddIndexArray(SceneIndexArray(count, layout.width));
}

void SetParticleMesh(SceneMesh& mesh, const wpscene::Particle& particle, uint32_t count,
                     bool thick_format) {
    (void)particle;
    std::vector<SceneVertexArray::SceneVertexAttribute> attrs {
        { WE_IN_POSITION.data(), VertexType::FLOAT3 },
        { WE_IN_TEXCOORDVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_COLOR.data(), VertexType::FLOAT4 },
    };
    if (thick_format) {
        attrs.push_back({ WE_IN_TEXCOORDVEC4C1.data(), VertexType::FLOAT4 });
    }
    attrs.push_back({ WE_IN_TEXCOORDC2.data(), VertexType::FLOAT2 });
    const auto layout = PlanParticleIndexLayout(count);
    mesh.AddVertexArray(SceneVertexArray(attrs, static_cast<std::size_t>(layout.vertex_count)));
    AddParticleIndexArray(mesh, count);
    mesh.GetVertexArray(0).SetOption(WE_PRENDER_SPRITE, true);
    mesh.GetVertexArray(0).SetOption(WE_CB_THICK_FORMAT, thick_format);
}

void SetRopeParticleMesh(SceneMesh& mesh, const wpscene::Particle& particle, uint32_t count,
                         bool thick_format) {
    (void)particle;
    std::vector<SceneVertexArray::SceneVertexAttribute> attrs {
        { WE_IN_POSITIONVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4.data(), VertexType::FLOAT4 },
        { WE_IN_TEXCOORDVEC4C1.data(), VertexType::FLOAT4 },
    };
    if (thick_format) {
        attrs.push_back({ WE_IN_TEXCOORDVEC4C2.data(), VertexType::FLOAT4 });
        attrs.push_back({ WE_IN_TEXCOORDVEC4C3.data(), VertexType::FLOAT4 });
        attrs.push_back({ WE_IN_TEXCOORDC4.data(), VertexType::FLOAT4 });
    } else {
        attrs.push_back({ WE_IN_TEXCOORDVEC3C2.data(), VertexType::FLOAT4 });
        attrs.push_back({ WE_IN_TEXCOORDC3.data(), VertexType::FLOAT4 });
    }
    attrs.push_back({ WE_IN_COLOR.data(), VertexType::FLOAT4 });
    const auto layout = PlanParticleIndexLayout(count);
    mesh.AddVertexArray(SceneVertexArray(attrs, static_cast<std::size_t>(layout.vertex_count)));
    AddParticleIndexArray(mesh, count);
    mesh.GetVertexArray(0).SetOption(WE_PRENDER_ROPE, true);
    mesh.GetVertexArray(0).SetOption(WE_CB_THICK_FORMAT, thick_format);
}

ParticleAnimationMode ToAnimMode(const std::string& str) {
    if (str == "randomframe")
        return ParticleAnimationMode::RANDOMONE;
    else if (str == "sequence")
        return ParticleAnimationMode::SEQUENCE;
    else {
        return ParticleAnimationMode::SEQUENCE;
    }
}

void LoadControlPoint(ParticleSubSystem& pSys, const wpscene::Particle& wp) {
    std::span<ParticleControlpoint> pcs = pSys.Controlpoints();
    usize                           s   = std::min(pcs.size(), wp.controlpoints.size());
    for (usize i = 0; i < s; i++) {
        pcs[i].base_offset =
            Eigen::Vector3d { array_cast<double>(wp.controlpoints[i].offset).data() };
        pcs[i].offset = pcs[i].base_offset;
        pcs[i].link_mouse =
            wp.controlpoints[i].flags[wpscene::ParticleControlpoint::FlagEnum::link_mouse];
        pcs[i].worldspace =
            wp.controlpoints[i].flags[wpscene::ParticleControlpoint::FlagEnum::worldspace];
        pcs[i].prev_offset = pcs[i].offset;
    }
}

/// What the generators of one particle file read besides their own JSON.
ParticleParseContext MakeParticleParseContext(
    ParticleSubSystem& pSys, const wpscene::Particle& wp,
    const std::shared_ptr<const wpscene::ParticleInstanceoverride>& over, Scene* scene,
    bool pixel_canvas) {
    ParticleParseContext ctx;
    ctx.over  = over;
    ctx.spawn = pSys.SpawnContext();
    ctx.color = WPParticleParser::analyzeColorSources(wp.initializers, wp.operators);
    ctx.ortho = pixel_canvas;
    ctx.speed_override = wp.AppliesSpeedOverride();
    ctx.size_override  = wp.AppliesSizeOverride();
    if (scene != nullptr) {
        ctx.spectrum = [scene]() {
            return scene->runtime != nullptr ? scene->runtime->CurrentAudioSpectrumSnapshot()
                                             : audio::AudioSpectrumSnapshot {};
        };
        ctx.requires_audio = [scene]() { MarkSceneRequiresAudioResponse(scene); };
    }
    return ctx;
}
void LoadInitializer(ParticleSubSystem& pSys, const wpscene::Particle& wp,
                     const std::shared_ptr<wpscene::ParticleInstanceoverride>& over, Scene* scene,
                     bool pixel_canvas) {
    const auto ctx = MakeParticleParseContext(pSys, wp, over, scene, pixel_canvas);
    for (const auto& ini : wp.initializers) {
        pSys.AddInitializer(WPParticleParser::genParticleInitOp(ini, ctx));
    }
    if (over->enabled) {
        pSys.AddInitializer(
            WPParticleParser::genOverrideInitOp(over, ctx.color, ctx.speed_override,
                                                ctx.size_override));
    }
}
void LoadOperator(ParticleSubSystem& pSys, const wpscene::Particle& wp,
                  const std::shared_ptr<wpscene::ParticleInstanceoverride>& over, Scene* scene,
                  bool pixel_canvas) {
    const auto ctx = MakeParticleParseContext(pSys, wp, over, scene, pixel_canvas);
    for (const auto& op : wp.operators) {
        pSys.AddOperator(WPParticleParser::genParticleOperatorOp(op, ctx));
        if (! op.is_object() || ! op.contains("name") || ! op.at("name").is_string()) continue;
        const std::string name  = op.at("name").get<std::string>();
        const bool        flag1 = op.contains("flags") && op.at("flags").is_number_integer() &&
                           (op.at("flags").get<int>() & 1) != 0;
        // A movement operator whose bit 1 is set keeps gravity aligned to the screen.
        if (name == "movement" && flag1) pSys.SetNeedsWorldAxes(true);
        // A control point attraction that removes the particles it passes reads
        // where the movement operator found each particle.
        if (name == "controlpointattract" && flag1) pSys.SetTracksPreviousPosition(true);
    }
}
void LoadEmitter(ParticleSubSystem& pSys, const wpscene::Particle& wp,
                 const std::shared_ptr<const wpscene::ParticleInstanceoverride>& over,
                 bool ordered_slots, Scene* scene, i32 cp_start_index = 0,
                 Eigen::Vector3f world_scale = Eigen::Vector3f::Ones(),
                 bool in_scene_units = false) {
    bool sort = ordered_slots;
    for (const auto& em : wp.emitters) {
        if (em.audioprocessingmode != 0) {
            MarkSceneRequiresAudioResponse(scene);
            if (em.audioprocessingmode > 3 ||
                (em.name != "boxrandom" && em.name != "sphererandom")) {
                LogUnsupportedParticleAudioModeOnce(em.audioprocessingmode);
            }
        }
        auto newEm = em;
        if (newEm.controlpoint >= 0) newEm.controlpoint += cp_start_index;
        // A system lives in its layer's space, so the layer's model matrix
        // scales the emitter origin along with everything else the system
        // makes, as Wallpaper Engine draws it. A worldspace file adds the origin
        // unscaled, in world units: a layer's own worldspace system is already
        // measured in them, a system inside its layer's space is held at the
        // scaled-down value the matrix brings back.
        if (wp.flags[wpscene::Particle::FlagEnum::wordspace] && ! in_scene_units) {
            for (int i = 0; i < 3; ++i) {
                const float scale = world_scale[i];
                if (std::abs(scale) > 1.0e-6f) newEm.origin[i] /= scale;
            }
        }
        pSys.AddEmitter(WPParticleParser::genParticleEmittOp(
            newEm, sort, over,
            [scene]() {
                return scene != nullptr && scene->runtime != nullptr
                           ? scene->runtime->CurrentAudioSpectrumSnapshot()
                           : audio::AudioSpectrumSnapshot {};
            },
            pSys.SpawnContext()));
    }
}

ParticleSubSystem::SpawnType ParseSpawnType(std::string_view str) {
    using ST = ParticleSubSystem::SpawnType;
    ST type { ST::STATIC };
    if (str == "eventfollow") {
        type = ST::EVENT_FOLLOW;
    } else if (str == "eventspawn") {
        type = ST::EVENT_SPAWN;
    } else if (str == "eventdeath") {
        type = ST::EVENT_DEATH;
    }
    return type;
};

BlendMode ParseBlendMode(std::string_view str) {
    BlendMode bm;
    if (str == "translucent") {
        bm = BlendMode::Translucent;
    } else if (str == "additive") {
        bm = BlendMode::Additive;
    } else if (str == "alphatocoverage") {
        bm = BlendMode::AlphaToCoverage;
    } else if (str == "normal") {
        bm = BlendMode::Normal;
    } else if (str == "disabled") {
        // seems disabled is normal
        bm = BlendMode::Normal;
    } else {
        bm = BlendMode::Normal;
        LOG_ERROR("unknown blending: %s", str.data());
    }
    return bm;
}

// Whether Wallpaper Engine draws an image layer among the ones sorted back to
// front, after the rest, in a scene that turns `transparentsorting` on. Its
// image object marks the layer for the sort unless the blending its material
// authors is the first entry of the blending enum, `normal`, or the fourth,
// `alphatocoverage`: the layers that blend, `translucent` and `additive`, sort;
// the others stay in scene order in the set drawn first. `Normal` also covers
// `disabled` and an unknown value, which it reads as the enum's first entry.
bool ImageLayerIsSorted(BlendMode authored) {
    return authored == BlendMode::Translucent || authored == BlendMode::Additive;
}

// Wallpaper Engine reads a pass's `depthtest`, `depthwrite` and `cullmode` as
// two-value enums ("disabled"/"enabled", "normal"/"nocull") and gives a value
// outside the list the list's first entry: no depth test, no depth write, back
// faces culled. There is no depth compare to choose; a depth-tested draw always
// compares the same way.
void ApplyMaterialDepth(SceneMaterial& material, const wpscene::WPMaterial& wpmat) {
    material.depth_test  = wpmat.depthtest == "enabled";
    material.depth_write = wpmat.depthwrite == "enabled";
}

CullMode ParseSceneCullMode(std::string_view value) {
    return value == "nocull" ? CullMode::None : CullMode::Back;
}

// `general.lightconfig` names how many lights of each kind lit shaders are
// compiled for. Wallpaper Engine packs each count into four bits; its shadow
// and cookie subsets are not drawn here, so those lights count as plain ones.
SceneLightConfig ParseSceneLightConfig(const nlohmann::json& config) {
    SceneLightConfig lights;
    if (! config.is_object()) return lights;
    const auto count = [&config](const char* key) -> uint32_t {
        const auto found = config.find(key);
        if (found == config.end() || ! found->is_number()) return 0;
        return static_cast<uint32_t>(std::clamp(found->get<double>(), 0.0, 15.0));
    };
    lights.point       = count("point");
    lights.spot        = count("spot");
    lights.tube        = count("tube");
    lights.directional = count("directional");
    return lights;
}

void ParseSpecTexName(std::string& name, Scene& scene, fs::VFS& vfs,
                      const wpscene::WPMaterial& wpmat, const WPShaderInfo& sinfo) {
    static const LayerObjectIndex kEmptyIndex;
    const auto& index = g_parse_layer_index != nullptr ? *g_parse_layer_index : kEmptyIndex;
    auto resolved = ResolveLayerTextureName(name, index, &vfs);
    if (resolved.is_layer) {
        LOG_INFO("link tex \"%s\"", name.c_str());
        if (resolved.source_id != 0) scene.layer_texture_sources.insert(resolved.source_id);
        name = resolved.resolved;
        return;
    }
    if (IsSpecTex(name)) {
        if (sstart_with(name, WE_ALIAS_PREFIX)) {
        } else if (name == "_rt_FullFrameBuffer") {
            name = SpecTex_Default;
            if (wpmat.shader == "genericimage2" && ! exists(sinfo.combos, "BLENDMODE")) name = "";
            /*
            if(wpmat.shader == "genericparticle") {
                name = "_rt_ParticleRefract";
            }
            */
        } else if (sstart_with(name, WE_MIP_MAPPED_FRAME_BUFFER)) {
        } else if (sstart_with(name, WE_EFFECT_PPONG_PREFIX)) {
        } else if (sstart_with(name, WE_HALF_COMPO_BUFFER_PREFIX)) {
        } else if (sstart_with(name, WE_QUARTER_COMPO_BUFFER_PREFIX)) {
        } else if (sstart_with(name, WE_FULL_COMPO_BUFFER_PREFIX)) {
        } else if (sstart_with(name, WE_SPEC_PREFIX)) {
        } else if (IsImplicitSpecTex(name)) {
        } else {
            LOG_ERROR("unknown tex \"%s\"", name.c_str());
        }
    }
}

void ApplyDefaultTextures(std::vector<std::string>& textures, const WPDefaultTexs& default_textures) {
    for (const auto& [slot, texture] : default_textures) {
        if (slot < 0) continue;
        const auto index = static_cast<usize>(slot);
        if (textures.size() > index) {
            if (! textures.at(index).empty()) continue;
        } else {
            textures.resize(index + 1);
        }
        textures[index] = texture;
    }
}

void DeduplicateDefaultTextures(WPDefaultTexs& default_textures) {
    WPDefaultTexs deduped;
    deduped.reserve(default_textures.size());
    for (const auto& item : default_textures) {
        const auto exists = std::find(deduped.begin(), deduped.end(), item);
        if (exists == deduped.end()) deduped.push_back(item);
    }
    default_textures = std::move(deduped);
}

std::vector<std::string> BuildMaterialTextureList(const std::vector<std::string>& base_textures,
                                                  const WPDefaultTexs& default_textures) {
    auto textures = base_textures;
    ApplyDefaultTextures(textures, default_textures);
    return textures;
}

WPShaderTexInfo BuildShaderTexInfo(Scene& scene,
                                   std::unordered_map<std::string, ImageHeader>& texHeaders,
                                   const std::string& name) {
    if (name.empty()) return {};
    if (IsSpecTex(name)) return { true, true, TextureFormat::RGBA8 };

    const ImageHeader& texh =
        texHeaders.count(name) == 0 ? scene.imageParser->ParseHeader(name) : texHeaders.at(name);
    texHeaders[name] = texh;
    if (texh.extraHeader.count("compo1") == 0) return { true, false, texh.format };

    return {
        true,
        true,
        texh.format,
        {
            (bool)texh.extraHeader.at("compo1").val,
            (bool)texh.extraHeader.at("compo2").val,
            (bool)texh.extraHeader.at("compo3").val,
            texh.extraHeader.contains("compo4") && texh.extraHeader.at("compo4").val != 0,
        },
    };
}

std::vector<WPShaderTexInfo> BuildShaderTexInfos(
    Scene& scene,
    std::unordered_map<std::string, ImageHeader>& texHeaders,
    const std::vector<std::string>& textures) {
    std::vector<WPShaderTexInfo> texinfos;
    texinfos.reserve(textures.size());
    for (const auto& texture : textures) {
        texinfos.push_back(BuildShaderTexInfo(scene, texHeaders, texture));
    }
    return texinfos;
}

void RegisterMaterialTexture(Scene& scene, fs::VFS& vfs, SceneMaterial& material,
                             SceneMaterialCustomShader& materialShader,
                             WPShaderValueData& svData, const wpscene::WPMaterial& wpmat,
                             WPShaderInfo& shader_info,
                             std::unordered_map<std::string, ImageHeader>& texHeaders,
                             std::string name, usize slot) {
    ParseSpecTexName(name, scene, vfs, wpmat, shader_info);
    svData.renderTargets.erase(
        std::remove_if(
            svData.renderTargets.begin(),
            svData.renderTargets.end(),
            [slot](const auto& render_target) { return render_target.first == slot; }),
        svData.renderTargets.end());
    if (material.textures.size() <= slot) material.textures.resize(slot + 1);
    if (material.defines.size() <= slot) material.defines.resize(slot + 1);
    material.textures[slot] = name;
    material.defines[slot]  = "g_Texture" + std::to_string(slot);
    if (name.empty()) {
        return;
    }

    const std::string gResolution = WE_GLTEX_RESOLUTION_NAMES[slot];
    // Only a size known now is folded in. Another layer's composite is copied
    // into its link texture while the graph is built, and the value updater
    // reports that size every frame. A zero folded here is not a size: the
    // card padding in ParseImageObj divides by it, and so does
    // `uv * size.z / size.x` in every shader that maps coordinates through it.
    std::optional<std::array<i32, 4>> resolution;
    if (IsSpecTex(name)) {
        if (IsSpecLinkTex(name)) {
            svData.renderTargets.push_back({ slot, name });
        } else if (! scene.HasRenderTarget(name)) {
            LOG_ERROR("%s not found in render targes", name.c_str());
        } else {
            name = scene.ResolveRenderTargetName(name);
            svData.renderTargets.push_back({ slot, name });
            const auto& rt = *scene.FindRenderTarget(name);
            resolution     = { rt.width, rt.height, rt.width, rt.height };
        }
    } else {
        const ImageHeader& texh =
            texHeaders.count(name) == 0 ? scene.imageParser->ParseHeader(name) : texHeaders.at(name);
        texHeaders[name] = texh;
        wallpaper::shader::ApplyTextureFormatCombo(shader_info.combos, slot, texh.format);
        if (texh.mipmap_larger) {
            resolution = { texh.width, texh.height, texh.mapWidth, texh.mapHeight };
        } else {
            resolution = { texh.mapWidth, texh.mapHeight, texh.mapWidth, texh.mapHeight };
        }

        if (scene.textures.count(name) == 0) {
            SceneTexture stex;
            stex.sample  = texh.sample;
            stex.url     = name;
            stex.isVideo = texh.isVideo;
            if (texh.isSprite) {
                stex.isSprite   = texh.isSprite;
                stex.spriteAnim = texh.spriteAnim;
            }
            scene.textures[name] = stex;
        }
        if ((scene.textures.at(name)).isSprite) {
            material.hasSprite = true;
            const auto& f1     = texh.spriteAnim.GetCurFrame();
            if (wpmat.shader == "genericparticle" || wpmat.shader == "genericropeparticle") {
                shader_info.combos["SPRITESHEET"] = "1";
                shader_info.combos["THICKFORMAT"] = "1";
                if (algorism::IsPowOfTwo((u32)texh.width) &&
                    algorism::IsPowOfTwo((u32)texh.height)) {
                    shader_info.combos["SPRITESHEETBLENDNPOT"] = "1";
                    (*resolution)[2] = (*resolution)[0] - (*resolution)[0] % (int)f1.width;
                    (*resolution)[3] = (*resolution)[1] - (*resolution)[1] % (int)f1.height;
                }
                materialShader.constValues["g_RenderVar1"] = std::array {
                    f1.xAxis[0], f1.yAxis[1], (float)(texh.spriteAnim.numFrames()), f1.rate
                };
            }
        }
    }
    const std::string gTexel = WE_GLTEX_TEXEL_NAMES[slot];
    if (resolution.has_value()) {
        materialShader.constValues[gResolution] = array_cast<float>(*resolution);
        // The texture's own size, which is what a tap one texel over steps.
        const float width  = static_cast<float>((*resolution)[2]);
        const float height = static_cast<float>((*resolution)[3]);
        if (width > 0.0f && height > 0.0f) {
            materialShader.constValues[gTexel] =
                std::array { 1.0f / width, 1.0f / height, width, height };
        } else {
            materialShader.constValues.erase(gTexel);
        }
    } else {
        materialShader.constValues.erase(gResolution);
        materialShader.constValues.erase(gTexel);
    }
}

void RegisterMaterialTextures(Scene& scene, fs::VFS& vfs, SceneMaterial& material,
                              SceneMaterialCustomShader& materialShader, WPShaderValueData& svData,
                              const wpscene::WPMaterial& wpmat, WPShaderInfo& shader_info,
                              std::unordered_map<std::string, ImageHeader>& texHeaders,
                              const std::vector<std::string>& textures) {
    material.textures.resize(textures.size());
    material.defines.resize(textures.size());
    for (usize i = 0; i < textures.size(); i++) {
        RegisterMaterialTexture(scene,
                                vfs,
                                material,
                                materialShader,
                                svData,
                                wpmat,
                                shader_info,
                                texHeaders,
                                textures.at(i),
                                i);
    }
}

bool LoadMaterial(fs::VFS& vfs, const wpscene::WPMaterial& wpmat, Scene* pScene, SceneNode* pNode,
                  SceneMaterial* pMaterial, WPShaderValueData* pSvData,
                  WPShaderInfo* pWPShaderInfo = nullptr) {
    (void)pNode;

    auto& svData   = *pSvData;
    auto& material = *pMaterial;

    if (MaterialUsesAudioResponse(wpmat)) {
        MarkSceneRequiresAudioResponse(pScene);
    }

    std::unique_ptr<WPShaderInfo> upWPShaderInfo(nullptr);
    if (pWPShaderInfo == nullptr) {
        upWPShaderInfo = std::make_unique<WPShaderInfo>();
        pWPShaderInfo  = upWPShaderInfo.get();
    }

    SceneMaterialCustomShader materialShader;

    auto& shader = materialShader.shader;
    shader       = std::make_shared<SceneShader>();
    shader->name = wpmat.shader;

    std::string shaderPath("/assets/shaders/" + wpmat.shader);

    std::array sd_units { WPShaderUnit {
                              .stage           = ShaderType::VERTEX,
                              .src             = fs::GetFileContent(vfs, shaderPath + ".vert"),
                              .preprocess_info = {},
                          },
                          WPShaderUnit {
                              .stage           = ShaderType::FRAGMENT,
                              .src             = fs::GetFileContent(vfs, shaderPath + ".frag"),
                              .preprocess_info = {},
                          } };

    auto base_textures = wpmat.textures;
    // A parse with no property table — a schema test, a project without
    // properties — leaves delegated slots on the texture the author shipped.
    const ProjectProperties* properties =
        pScene != nullptr && pScene->runtime != nullptr ? &pScene->runtime->projectProperties()
                                                        : nullptr;
    std::vector<std::string> texture_covers;
    ApplySystemUserTextures(base_textures,
                            wpmat.usertextures,
                            properties,
                            pScene != nullptr
                                ? dynamic_cast<RuntimeImageSource*>(pScene->imageParser.get())
                                : nullptr,
                            &texture_covers);
    // The slot is decided here and a built material is not rebuilt, so a running
    // scene holds the property at this value.
    if (pScene != nullptr && pScene->runtime != nullptr) {
        for (const auto& user_texture : wpmat.usertextures) {
            pScene->runtime->NoteLoadOnlyProperty(UserTexturePropertyName(user_texture));
        }
    }

    std::unordered_map<std::string, ImageHeader> texHeaders;

    for (const auto& el : wpmat.combos) {
        pWPShaderInfo->combos[el.first] = std::to_string(el.second);
    }
    pWPShaderInfo->combos["HDR"] = pScene->hdr ? "1" : "0";
    // This describes the authored scene, not an effect pass's local camera.
    // Lit 2D layers use a fixed view direction; a perspective eye on their
    // plane makes their normal/view dot product zero.
    pWPShaderInfo->combos["SCENE_ORTHO"] = pScene->display_sized ? "0" : "1";
    // How many lights of each kind a lit pass's `#require LightingV1` block is
    // written for. Left out when the scene declares none, so an unlit scene's
    // shaders compile exactly as before.
    if (! pScene->light_config.empty()) {
        const auto& lights                    = pScene->light_config;
        pWPShaderInfo->combos["LIGHTS_POINT"]       = std::to_string(lights.point);
        pWPShaderInfo->combos["LIGHTS_SPOT"]        = std::to_string(lights.spot);
        pWPShaderInfo->combos["LIGHTS_TUBE"]        = std::to_string(lights.tube);
        pWPShaderInfo->combos["LIGHTS_DIRECTIONAL"] = std::to_string(lights.directional);
    }

    if (exists(pWPShaderInfo->combos, "LIGHTING")) {
        // pWPShaderInfo->combos["PRELIGHTING"] =
        // pWPShaderInfo->combos.at("LIGHTING");
    }
    if (wpmat.blending == "alphatocoverage") {
        pWPShaderInfo->combos["ALPHATOCOVERAGE"] = "1";
    }

    const auto base_material_textures     = material.textures;
    const auto base_material_defines      = material.defines;
    const auto base_material_has_sprite   = material.hasSprite;
    const auto base_material_const_values = materialShader.constValues;
    const auto base_render_targets        = svData.renderTargets;
    const auto base_svs     = pWPShaderInfo->svs;
    const auto base_alias   = pWPShaderInfo->alias;
    const auto base_defTexs = pWPShaderInfo->defTexs;
    auto       base_combos  = pWPShaderInfo->combos;
    // Fog is compiled into a pass only once its effective `FOG` combo -- the
    // material's or the shader's own default -- is known to be on, which the
    // first compile tells; the pass is then compiled again with fog. A pass
    // that asks for no fog (`defer_fog`) is left as the first compile made it,
    // and `fog_deferred` tells the caller it would have taken it.
    const bool scene_fog = pScene->fog_distance || pScene->fog_height;
    bool       fog_applied = false;
    pWPShaderInfo->fog_deferred = false;

    std::string reflection_json;
    auto        textures = BuildMaterialTextureList(base_textures, pWPShaderInfo->defTexs);
    constexpr usize kMaxDefaultTextureCompilePasses = 8;
    for (usize pass = 0; pass < kMaxDefaultTextureCompilePasses; ++pass) {
        shader->codes.clear();
        reflection_json.clear();
        for (auto& unit : sd_units) {
            unit.preprocess_info = {};
        }
        material.textures           = base_material_textures;
        material.defines            = base_material_defines;
        material.hasSprite          = base_material_has_sprite;
        materialShader.constValues  = base_material_const_values;
        svData.renderTargets        = base_render_targets;
        pWPShaderInfo->svs          = base_svs;
        pWPShaderInfo->alias        = base_alias;
        pWPShaderInfo->defTexs      = base_defTexs;
        pWPShaderInfo->combos       = base_combos;

        RegisterMaterialTextures(*pScene,
                                 vfs,
                                 material,
                                 materialShader,
                                 svData,
                                 wpmat,
                                 *pWPShaderInfo,
                                 texHeaders,
                                 textures);

        auto texinfos = BuildShaderTexInfos(*pScene, texHeaders, textures);
        // A slot filled only by the shader's own annotation default is bound,
        // but nobody bound it: the default exists so an unused sampler still
        // reads something sane. Its combo asks whether the material supplied a
        // texture, and answering yes turns the shader's optional feature on
        // permanently -- `rounded_mask` then takes its radius from a white
        // default instead of `u_Radius` and masks every layer to a circle.
        for (usize slot = 0; slot < texinfos.size(); ++slot) {
            const bool author_bound = slot < base_textures.size() && ! base_textures[slot].empty();
            if (! author_bound && ! textures[slot].empty()) texinfos[slot].present = false;
        }
        // Captured before the compile that consumes them, so the record holds
        // the exact input the SPIR-V compile saw rather than the state it left
        // behind. Overwritten on every iteration, so the last one to run is the
        // one that stabilised.
        if (MetalTranslationRequested()) {
            PendingMetalTranslation pending;
            pending.shader      = shader;
            pending.shader_name = wpmat.shader;
            pending.scene_id    = pScene->scene_id;
            pending.units.assign(sd_units.begin(), sd_units.end());
            pending.shader_info = *pWPShaderInfo;
            pending.texinfos.assign(texinfos.begin(), texinfos.end());
            pending.texture_keys = textures;
            pending.vfs = &vfs;
            if (! g_pending_metal_translations.empty() &&
                g_pending_metal_translations.back().shader == shader) {
                g_pending_metal_translations.back() = std::move(pending);
            } else {
                g_pending_metal_translations.push_back(std::move(pending));
            }
        }
        if (! WPShaderParser::CompileToSpvRust(
                pScene->scene_id, wpmat.shader, sd_units, shader->codes, vfs, pWPShaderInfo, texinfos, &reflection_json)) {
            return false;
        }
        DeduplicateDefaultTextures(pWPShaderInfo->defTexs);

        auto next_textures = BuildMaterialTextureList(base_textures, pWPShaderInfo->defTexs);
        if (scene_fog && ! fog_applied) {
            fog_applied     = true;
            const auto fog  = pWPShaderInfo->combos.find("FOG");
            if (fog != pWPShaderInfo->combos.end() && fog->second != "0") {
                if (pWPShaderInfo->defer_fog) {
                    pWPShaderInfo->fog_deferred = true;
                } else {
                    base_combos["FOG_DIST"]     = pScene->fog_distance ? "1" : "0";
                    base_combos["FOG_HEIGHT"]   = pScene->fog_height ? "1" : "0";
                    base_combos["FOG_COMPUTED"] = "1";
                    textures                    = std::move(next_textures);
                    continue;
                }
            }
        }
        if (next_textures == textures) {
            break;
        }
        if (pass + 1 == kMaxDefaultTextureCompilePasses) {
            LOG_ERROR("Rust shader default texture list did not stabilize after %zu compile passes for '%s'",
                      static_cast<std::size_t>(kMaxDefaultTextureCompilePasses),
                      wpmat.shader.c_str());
            return false;
        }
        textures = std::move(next_textures);
    }
    shader->rust_reflection_json = std::move(reflection_json);
    shader->default_uniforms = pWPShaderInfo->svs;

    material.blenmode = ParseBlendMode(wpmat.blending);
    ApplyMaterialDepth(material, wpmat);
    material.cull_mode = ParseSceneCullMode(wpmat.cullmode);

    for (uint i = 0; i < material.textures.size(); i++) {
        if (! exists(sd_units[1].preprocess_info.active_tex_slots, i)) material.textures[i].clear();
    }
    // Only a slot that still samples its render target can show a cover over it.
    texture_covers.resize(material.textures.size());
    for (usize i = 0; i < texture_covers.size(); ++i) {
        if (material.textures[i].empty()) texture_covers[i].clear();
    }
    if (std::any_of(texture_covers.begin(), texture_covers.end(),
                    [](const std::string& cover) { return ! cover.empty(); })) {
        material.texture_covers = std::move(texture_covers);
    }

    for (const auto& el : pWPShaderInfo->baseConstSvs) {
        materialShader.constValues[el.first] = el.second;
    }
    material.customShader = materialShader;
    material.name         = wpmat.shader;

    return true;
}

bool AlignmentHasAnchorOffset(std::string_view align) {
    for (const auto edge : { "top", "bottom", "left", "right" }) {
        if (align.find(edge) != std::string_view::npos) return true;
    }
    return false;
}

void LoadAlignment(SceneNode& node, std::string_view align, Vector2f size) {
    Vector3f trans = node.Translate();
    size *= 0.5f;
    size.y() *= 1.0f;

    auto contains = [&](std::string_view s) {
        return align.find(s) != std::string::npos;
    };

    // topleft top center ...
    if (contains("top")) trans.y() -= size.y();
    if (contains("left")) trans.x() += size.x();
    if (contains("right")) trans.x() -= size.x();
    if (contains("bottom")) trans.y() += size.y();

    node.SetTranslate(trans);
}

std::string JsonStringOrObjectValue(const nlohmann::json& value, std::string_view fallback_key) {
    if (value.is_string()) return value.get<std::string>();
    if (! value.is_object()) return {};
    if (value.contains("value") && value.at("value").is_string()) {
        return value.at("value").get<std::string>();
    }
    if (! fallback_key.empty() && value.contains(fallback_key) &&
        value.at(fallback_key).is_string()) {
        return value.at(fallback_key).get<std::string>();
    }
    return {};
}

std::string TextRuntimeName(const ParseContext& context, const wpscene::WPTextObject& obj) {
    if (! obj.name.empty()) {
        const auto count = context.text_name_counts.find(obj.name);
        // Images, models and plain groups share `layer_name_counts`. A text
        // label that repeats one of those names has to keep its own key, or
        // scene scripts such as getLayer("s") move the label instead of the body.
        const auto other = context.layer_name_counts.find(obj.name);
        const bool used_by_other_layer =
            other != context.layer_name_counts.end() && other->second > 0;
        if (! used_by_other_layer &&
            (count == context.text_name_counts.end() || count->second <= 1u)) {
            return obj.name;
        }
    }
    return "__we_text_" + std::to_string(obj.id);
}

/// The program a text card draws with. `composite` is the card of a text layer that goes
/// through effects: where Wallpaper Engine first overwrites the layer's composite with the
/// scene behind it (alpha 0) and then blends the glyphs into it, this does both in the one
/// pass, because the card covers the whole composite: it samples the scene (`g_Texture1`, at
/// the screen position of the fragment) and writes `mix(scene, glyph, alpha)` with alpha
/// `alpha ^ kTextCompositeAlphaExponent`. While `g_Composite` is 0 -- every effect switched
/// off -- it writes the glyph and its alpha as a card that is drawn directly does.
///
/// `filled` is the card of a text object with an opaque background. Wallpaper Engine paints
/// the card's rectangle with the background colour at the layer's alpha before the glyphs, or,
/// when the card is a composite, clears the composite to that colour and alpha where it would
/// otherwise seed it from the scene. The card here covers the rectangle and the room the style
/// reaches around it, so this paints inside `g_CardInset` (the fraction of the card that lies
/// outside the rectangle, on each side) the glyph over the fill as the two quads one after the
/// other would leave the scene -- straight "over", colour and alpha -- or, for a composite, the
/// glyph blended into the cleared card.
///
/// `colour_blend_mode` is the layer's colour blend when its passthrough pass follows the card.
/// Wallpaper Engine's `ApplyBlending` weighs every mode by the card's alpha but two: Darker
/// Color (5) and Lighter Color (10) are the per-channel min and max of the screen and the
/// card's colour, and look at no alpha. There the card's colour must by itself leave the
/// screen alone wherever the glyphs do not cover it, which Wallpaper Engine gets from a
/// composite seeded with the scene. The card here is written without one, so it holds the
/// colour that min or max passes the screen by (white for 5, black for 10) at no coverage and
/// the glyph's colour at full coverage, the colour mixed with it by the alpha in between: a
/// card that kept the glyph's colour where nothing is drawn paints a box of it over the card.
std::shared_ptr<SceneShader> BuildTextSceneShader(fs::VFS& vfs, std::string_view scene_id,
                                                  const std::string& texture_key, bool styled,
                                                  bool outlined, bool composite, bool filled,
                                                  int colour_blend_mode = 0) {
    std::string vertex_src =
        "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
        "in vec3 a_Position;\n"
        "in vec2 a_TexCoord;\n"
        "out vec2 v_TexCoord;\n"
        "void main() {\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
        "  v_TexCoord = a_TexCoord;\n"
        "}\n";
    if (composite) {
        // Where the card lies on the screen, for the scene behind it: `g_EffectModelViewProjectionMatrix`
        // is the scene camera's view-projection over the layer's own transform, whatever camera the
        // card is drawn through. Direct3D's screen coordinate runs the other way up.
        vertex_src =
            "uniform mat4 g_ModelViewProjectionMatrix;\n"
            "uniform mat4 g_EffectModelViewProjectionMatrix;\n"
            "in vec3 a_Position;\n"
            "in vec2 a_TexCoord;\n"
            "out vec2 v_TexCoord;\n"
            "out vec3 v_ScreenCoord;\n"
            "void main() {\n"
            "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
            "  v_TexCoord = a_TexCoord;\n"
            "  v_ScreenCoord = (g_EffectModelViewProjectionMatrix * vec4(a_Position, 1.0)).xyw;\n"
            "#if HLSL\n"
            "  v_ScreenCoord.y = -v_ScreenCoord.y;\n"
            "#endif\n"
            "}\n";
    }
    // What the glyph is: its colour and its alpha, straight (not premultiplied).
    std::string uniforms = "uniform sampler2D g_Texture0;\n"
                           "uniform vec3 g_Color;\n"
                           "uniform float g_Alpha;\n"
                           "uniform float g_Brightness;\n";
    std::string body;
    if (! styled) {
        body = "  vec4 glyph = texture(g_Texture0, v_TexCoord);\n"
               "  vec4 result = vec4(glyph.rgb * g_Color * g_Brightness, glyph.a * g_Alpha);\n";
    } else {
        // The font shader's mix of a glyph, its outline and its shadow, from the
        // three coverage masks the rasteriser leaves in the texture's channels:
        // red the glyph, green the glyph with its outline, blue the shadow. Only
        // the glyph takes the layer's colour; the outline and shadow keep theirs.
        // Without an outline the glyph is the layer's colour whatever its
        // coverage, as the reference shader's path without `OUTLINE_ENABLED`
        // returns it: mixing in an outline colour nobody asked for would darken
        // every partly covered pixel of the glyph and of its blur.
        const std::string glyph_colour =
            outlined ? "  vec3 glyph = mix(g_OutlineColor, g_Color * g_Brightness, mask.r);\n"
                     : "  vec3 glyph = g_Color * g_Brightness;\n";
        if (outlined) uniforms += "uniform vec3 g_OutlineColor;\n";
        uniforms += "uniform vec3 g_ShadowColor;\n";
        body = std::string("  vec3 mask = texture(g_Texture0, v_TexCoord).rgb;\n") + glyph_colour +
               "  float glyph_alpha = mask.g * g_Alpha;\n"
               "  float shadow_alpha = mask.b * g_Alpha;\n"
               "  float alpha = glyph_alpha + shadow_alpha * (1.0 - glyph_alpha);\n"
               "  vec3 rgb = (glyph * glyph_alpha + g_ShadowColor * shadow_alpha * (1.0 - glyph_alpha)) / max(alpha, 0.000001);\n"
               "  vec4 result = vec4(rgb, alpha);\n";
    }
    std::string varyings = "in vec2 v_TexCoord;\n";
    // What the card writes where it is drawn straight onto the scene (or, off a composite, into
    // a layer's target to be put there): the glyph, over the fill where there is one.
    std::string direct = "result";
    if (filled) {
        uniforms += "uniform vec3 g_Background;\n"
                    "uniform float g_BackgroundBrightness;\n"
                    "uniform vec2 g_CardInset;\n";
        body += "  vec2 within = step(g_CardInset, v_TexCoord) * step(v_TexCoord, 1.0 - g_CardInset);\n"
                "  float fill = within.x * within.y;\n"
                "  vec3 plate = g_Background * g_BackgroundBrightness;\n"
                "  float plate_alpha = fill * g_Alpha;\n"
                "  float over_alpha = result.a + plate_alpha * (1.0 - result.a);\n"
                "  vec4 over = vec4(over_alpha > 0.0\n"
                "                       ? (result.rgb * result.a + plate * plate_alpha * (1.0 - result.a)) / over_alpha\n"
                "                       : result.rgb,\n"
                "                   over_alpha);\n";
        direct = "over";
    }
    std::string finish = "  gl_FragColor = " + direct + ";\n";
    // The colour a card without coverage holds when the passthrough's blend ignores the alpha.
    const bool colour_blend_ignores_alpha = colour_blend_mode == 5 || colour_blend_mode == 10;
    if (colour_blend_ignores_alpha && ! composite) {
        finish = "  vec4 drawn = " + direct + ";\n"
                 "  gl_FragColor = vec4(mix(vec3(" + std::string(colour_blend_mode == 5 ? "1.0" : "0.0") +
                 "), drawn.rgb, drawn.a), drawn.a);\n";
    }
    if (composite) {
        uniforms += "uniform sampler2D g_Texture1;\n"
                    "uniform float g_Composite;\n";
        varyings += "in vec3 v_ScreenCoord;\n";
        // The composite starts as the scene behind the card with no alpha, or as the fill's colour
        // and the layer's alpha inside the fill; the glyph is blended into it on colour and on alpha.
        finish = "  vec2 screen = v_ScreenCoord.xy / v_ScreenCoord.z * 0.5 + 0.5;\n"
                 "  vec3 behind = texture(g_Texture1, screen).rgb;\n" +
                 std::string(filled ? "  vec3 below = mix(behind, plate, fill);\n"
                                      "  float below_alpha = plate_alpha;\n"
                                    : "  vec3 below = behind;\n"
                                      "  float below_alpha = 0.0;\n") +
                 "  vec4 composed = vec4(mix(below, result.rgb, result.a),\n"
                 "                       pow(result.a, " + std::to_string(kTextCompositeAlphaExponent) +
                 ") + below_alpha * (1.0 - result.a));\n"
                 "  gl_FragColor = g_Composite > 0.5 ? composed : " + direct + ";\n";
    }
    std::string fragment_src = uniforms + varyings + "void main() {\n" + body + finish + "}\n";
    std::string shader_name = composite ? "text_composite" : "text";
    if (styled) shader_name += outlined ? "_styled_outline" : "_styled";
    if (filled) shader_name += "_filled";
    if (colour_blend_ignores_alpha && ! composite) {
        shader_name += colour_blend_mode == 5 ? "_over_white" : "_over_black";
    }

    WPShaderInfo                 shader_info;
    std::vector<WPShaderTexInfo> tex_infos(composite ? 2 : 1);
    for (auto& tex_info : tex_infos) tex_info.enabled = true;

    std::array units {
        WPShaderUnit {
            .stage           = ShaderType::VERTEX,
            .src             = std::move(vertex_src),
            .preprocess_info = {},
        },
        WPShaderUnit {
            .stage           = ShaderType::FRAGMENT,
            .src             = std::move(fragment_src),
            .preprocess_info = {},
        },
    };

    auto shader              = std::make_shared<SceneShader>();
    shader->name             = shader_name;
    std::string reflection_json;
    // Captured before the SPIR-V compile consumes the units and merges its
    // results into `shader_info`, exactly as a material's translation is. A
    // text layer is an ordinary scene layer to both backends, so it needs the
    // same second translation; without it the native backend has no program for
    // the card and the whole scene falls back.
    if (MetalTranslationRequested()) {
        PendingMetalTranslation pending;
        pending.shader      = shader;
        pending.shader_name = shader_name;
        pending.scene_id    = std::string(scene_id);
        pending.units.assign(units.begin(), units.end());
        pending.shader_info  = shader_info;
        pending.texinfos.assign(tex_infos.begin(), tex_infos.end());
        pending.texture_keys = { texture_key };
        if (composite) pending.texture_keys.push_back(std::string(SpecTex_Default));
        pending.vfs          = &vfs;
        g_pending_metal_translations.push_back(std::move(pending));
    }
    if (! WPShaderParser::CompileToSpvRust(
            scene_id, shader_name, units, shader->codes, vfs, &shader_info, tex_infos, &reflection_json)) {
        return nullptr;
    }
    shader->rust_reflection_json = std::move(reflection_json);
    shader->default_uniforms = shader_info.svs;

    return shader;
}

void RegisterTextTexture(Scene& scene, const std::string& texture_name,
                         const TextLayerState& state, Eigen::Vector2f size) {
    if (scene.textures.contains(texture_name)) return;

    auto* runtime_images = dynamic_cast<RuntimeImageSource*>(scene.imageParser.get());
    if (runtime_images == nullptr) return;

    const uint32_t width =
        std::clamp(static_cast<uint32_t>(std::ceil(std::max(1.0f, size.x()))), 1u, 4096u);
    const uint32_t height =
        std::clamp(static_cast<uint32_t>(std::ceil(std::max(1.0f, size.y()))), 1u, 4096u);
    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);

    runtime_images->SetRgbaImage(texture_name, width, height, rgba.data(), rgba.size());

    SceneTexture texture;
    texture.url                  = texture_name;
    texture.sample.wrapS         = TextureWrap::CLAMP_TO_EDGE;
    texture.sample.wrapT         = TextureWrap::CLAMP_TO_EDGE;
    texture.sample.minFilter     = TextureFilter::LINEAR;
    texture.sample.magFilter     = TextureFilter::LINEAR;
    scene.textures[texture_name] = std::move(texture);
}

/// A layer another layer samples draws into a composite of its own, `extent`
/// texels, through a camera that frames the layer's card in its own texture
/// space: the card fills the target, and where the layer sits in the scene --
/// its transform, the scene camera, parallax -- does not reach the image.
/// `camera_node` puts that camera on the card's centre.
SceneCamera& RegisterLayerComposite(ParseContext& context, int32_t id, SceneNode& node,
                                    std::array<int32_t, 2> extent, bool clamp_uvs,
                                    std::shared_ptr<SceneNode> camera_node,
                                    TextureFilter filter = TextureFilter::LINEAR) {
    node.SetMustProduce(true);
    const auto key = LayerCompositeTargetKey(id);
    if (! context.scene->HasRenderTarget(key)) {
        // A consumer may tile a layer texture across a model (UVs far outside
        // 0..1). Clamping that smears the edge texels into solid bands; the
        // layer's own `clampuvs` decides, like a packaged texture's flag. A layer
        // that point-samples (`nointerpolation`) is read the same way.
        const auto wrap = clamp_uvs ? TextureWrap::CLAMP_TO_EDGE : TextureWrap::REPEAT;
        context.scene->renderTargets[key] = SceneRenderTarget {
            .width = extent[0], .height = extent[1], .allowReuse = true,
            .sample = { wrap, wrap, filter, filter },
            .format = context.scene->hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8,
        };
    }
    auto camera = std::make_shared<SceneCamera>(extent[0], extent[1], -1.0f, 1.0f);
    camera->SetLayerLocal(true);
    camera->AttatchNode(std::move(camera_node));
    auto& registered = context.scene->cameras[LayerCompositeCameraKey(id)];
    registered = std::move(camera);
    return *registered;
}

/// A sampled text layer's composite is the card it shows: its text, or with
/// effects the final card of the chain. Aligned to one side of a box the text
/// overflows, that card is not centred on the layer's origin, and every relayout
/// may move and resize it (`SceneRuntimeContext::FitTextLayerComposite`), so the
/// camera has a node of its own and frames the card exactly.
void RegisterTextComposite(ParseContext& context, const wpscene::WPTextObject& object,
                           SceneNode& node, const TextLayerRenderFrame& card) {
    auto camera_node = std::make_shared<SceneNode>();
    camera_node->SetTranslate(Eigen::Vector3f(card.center.x(), card.center.y(), 0.0f));
    auto& camera = RegisterLayerComposite(context,
                                          object.id,
                                          node,
                                          TextCardTexelExtent(card.size),
                                          object.clampuvs,
                                          std::move(camera_node));
    camera.SetWidth(std::max(1.0f, card.size.x()));
    camera.SetHeight(std::max(1.0f, card.size.y()));
    camera.Update();
}

/// An effect of layer `layer_id` naming the layer's own `_a` or `_b` composite
/// reads the chain's current buffer, `chain_input`, as `previous` does: the
/// layer's composite is what this chain is about to produce. A clock's outline
/// bound that way otherwise sampled an empty link every frame and drew nothing.
void BindOwnEffectChainInput(wpscene::WPMaterial& material, int32_t layer_id,
                             const std::string& chain_input) {
    for (auto& texture : material.textures) {
        if (IsOwnEffectChainInput(texture, layer_id)) texture = chain_input;
    }
}

/// The colour blend mode Wallpaper Engine draws additively onto the scene
/// instead of blending in the passthrough shader.
constexpr int32_t kAdditiveColorBlendMode = 31;

/// The pass that mixes a layer with the screen behind it for a colour blend
/// mode: Wallpaper Engine's passthrough material, `effectpassthrough`, with the
/// mode as its `BLENDMODE`. It is appended as the layer's last effect, writes
/// without blending, and a layer's own colour and alpha are already in what it
/// blends (the caller binds a white `g_Color4`). Image and text layers share it.
std::optional<wpscene::WPImageEffect> MakeColorBlendEffect(fs::VFS& vfs, int32_t color_blend_mode) {
    wpscene::WPImageEffect effect;
    wpscene::WPMaterial    material;
    nlohmann::json         json;
    if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/materials/util/effectpassthrough.json"), json))
        return std::nullopt;
    material.FromJson(json);
    material.combos["BONECOUNT"] = 1;
    material.combos["BLENDMODE"] = color_blend_mode;
    material.blending            = "disabled";
    effect.materials.push_back(material);
    return effect;
}

/// The pass a layer's effect chain ends in so that scene fog falls on the layer
/// where it sits: Wallpaper Engine's passthrough material for a device that draws
/// fog, `effectpassthrough_4` (the generic image shader, which takes the scene's
/// fog like any pass). The chain before it runs in the layer's own card, from an
/// ortho camera and with no transform, where a point's distance from the eye is
/// its place in the card; this last pass is drawn at the layer's model matrix, so
/// the fog it measures is the layer's. It copies what the chain made, with a white
/// `g_Color4`: the layer's own colour and alpha are already in it. Without the
/// material (assets from before it) there is no pass, and the layer keeps its fog
/// where it was.
std::optional<wpscene::WPImageEffect> MakeFogCompositeEffect(fs::VFS& vfs) {
    wpscene::WPImageEffect effect;
    wpscene::WPMaterial    material;
    nlohmann::json         json;
    if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/materials/util/effectpassthrough_4.json"), json))
        return std::nullopt;
    material.FromJson(json);
    material.combos["BONECOUNT"] = 1;
    effect.materials.push_back(material);
    return effect;
}

/// Builds the effect chain of a layer, and returns the effects it put in it. `final_blend` is how
/// the chain's last pass is drawn onto the scene; `idle_final_blend`, when given, replaces it while
/// a script has every effect off and the chain ends in the passthrough that draws the layer as it
/// is.
std::vector<std::shared_ptr<SceneImageEffect>>
AttachEffectsToNode(ParseContext& context,
                    SceneNode& node,
                    int32_t layer_id,
                    SceneMesh& final_mesh,
                    std::span<const wpscene::WPImageEffect> effects,
                    const std::string& runtime_name,
                    std::array<int32_t, 2> render_extent,
                    Eigen::Vector2f render_center,
                    BlendMode final_blend,
                    const ShaderValueMap& base_const_svs,
                    std::array<float, 2> parallax_depth,
                    bool copy_background,
                    bool preserve_effect_fbo_resolution,
                    const wpscene::WPImageEffect* screen_blend_effect = nullptr,
                    std::optional<BlendMode> idle_final_blend = std::nullopt);

// The font fields of `state` for an installed face.
void SetSystemFont(TextLayerState& state, const SystemFontFace& face, std::string identity) {
    state.resolved_font_kind     = "system";
    state.resolved_font_identity = std::move(identity);
    state.resolved_font_path     = face.path;
    state.resolved_font_face     = face.postscript_name;
    state.resolved_font_fit      = face.fit;
    state.resolved_font_data     = SharedFontData {};
}

// Fills the font fields of `state` for the font the scene (or a script) names, as
// Wallpaper Engine finds it: one of its eight `systemfont_` keys, the whole string and in
// lower case, is a font of the Windows Fonts folder; anything else is a path to a font file,
// which the wallpaper ships; and a font it cannot load is drawn in Arial. A family named by
// its name alone ("Arial", "Helvetica") is a path to a file that is not there.
void ResolveTextLayerFont(TextLayerState& state, fs::VFS& vfs, const std::string& font_key) {
    state.font_key = font_key;
    constexpr std::string_view system_prefix = "systemfont_";
    if (IsSceneFontKey(font_key)) {
        SetSystemFont(state, ResolveSceneFont(font_key), font_key.substr(system_prefix.size()));
        return;
    }

    if (! font_key.empty()) {
        std::string candidate = font_key;
        if (candidate.starts_with("assets/")) candidate = "/" + candidate;
        if (! candidate.starts_with('/')) candidate = "/assets/" + candidate;
        if (vfs.Contains(candidate)) {
            state.resolved_font_kind     = "asset";
            state.resolved_font_identity = font_key;
            state.resolved_font_path     = candidate;
            state.resolved_font_face.clear();
            state.resolved_font_fit      = {};
            state.resolved_font_data     = ReadVfsBytes(vfs, candidate);
            return;
        }
        if (font_key.starts_with('/') && vfs.Contains(font_key)) {
            state.resolved_font_kind     = "asset";
            state.resolved_font_identity = font_key;
            state.resolved_font_path     = font_key;
            state.resolved_font_face.clear();
            state.resolved_font_fit      = {};
            state.resolved_font_data     = ReadVfsBytes(vfs, font_key);
            return;
        }
    }

    SetSystemFont(state, ResolveSceneFont(kDefaultSceneFontKey),
                  std::string(kDefaultSceneFontKey).substr(system_prefix.size()));
}

// Whether an effect is part of the chain a layer is built with: one that is
// visible, or one a script may switch on later. Wallpaper Engine keeps every
// effect of a layer and runs the ones its effect object says are visible.
bool EffectIsBuilt(const wpscene::WPImageEffect& effect) {
    return effect.visible || effect.scripted_visible;
}

/// The padding a text object's file gives, on each axis: capped at 512 pixels from above and not
/// floored, since Wallpaper Engine lets a negative padding take the card in around the text.
Eigen::Vector2f AuthoredTextCardPadding(const wpscene::WPTextObject& obj) {
    constexpr float kMaxCardPadding = 512.0f;
    const auto lane = [=](float value) {
        return std::isfinite(value) ? std::min(value, kMaxCardPadding) : 0.0f;
    };
    return { lane(obj.padding[0]), lane(obj.padding[1]) };
}

/// Whether an effect is visible as the scene loads: a fixed one by its value (a property's is
/// resolved into it already), a scripted one by the value its script starts from.
bool EffectStartsVisible(const wpscene::WPImageEffect& effect) {
    return effect.scripted_visible ? InitialBoolSetting(effect.visible_setting) : effect.visible;
}

/// Whether an effect is one of the passes Wallpaper Engine counts for a text layer as the scene
/// loads: one that is visible, and has a pass to draw. The effects the chain is built with are
/// these (`EffectIsBuilt` and a material), and the runtime counts the visible ones among them
/// afresh as a script switches them, so the margin and the composite start from the same count.
bool EffectCountsForText(const wpscene::WPImageEffect& effect) {
    return ! effect.materials.empty() && EffectStartsVisible(effect);
}

/// Whether Wallpaper Engine keeps a text card's margin whatever its effects do: the layer
/// composites with a colour blend (any mode but none and "add") or an LED source, paints an
/// opaque background, or sits in a scene that enables distance fog or height fog (the renderer
/// then composites every text layer, to fog it).
bool TextCardIsPaddedRegardless(const wpscene::WPTextObject& obj, bool scene_fog) {
    const bool composites = (obj.colorBlendMode != 0 && obj.colorBlendMode != kAdditiveColorBlendMode) ||
                            obj.ledsource;
    return composites || obj.opaquebackground || scene_fog;
}

/// Whether Wallpaper Engine pads a text card as the scene loads: with `padding * 2` around
/// the text and the text inset by `padding`, on each axis. Besides the cases above that is
/// a layer that has a visible effect, which it counts afresh whenever an effect's visibility
/// changes (`SceneRuntimeContext::TextEffectGate`); a plain text layer has no margin whatever
/// its `padding` says.
bool TextCardIsPadded(const wpscene::WPTextObject& obj, bool scene_fog) {
    return TextCardIsPaddedRegardless(obj, scene_fog) ||
           std::any_of(obj.effects.begin(), obj.effects.end(), EffectCountsForText);
}

TextLayerState ResolveTextLayerState(const wpscene::WPTextObject& obj, fs::VFS& vfs,
                                     std::string text, std::string font_key,
                                     std::string layer_key, bool scene_fog) {
    const Eigen::Vector2f authored_padding = AuthoredTextCardPadding(obj);
    const bool            padded           = TextCardIsPadded(obj, scene_fog);
    TextLayerState state {
        .text             = std::move(text),
        .layer_key        = std::move(layer_key),
        .font_key         = font_key,
        .point_size       = obj.pointsize,
        .padding          = padded ? authored_padding : Eigen::Vector2f::Zero().eval(),
        .authored_padding = authored_padding,
        .padding_applies  = padded,
        .spacing          = Eigen::Vector2f(obj.spacing[0], obj.spacing[1]),
        .color            = Eigen::Vector3f(obj.color.data()),
        .alpha            = obj.alpha,
        .brightness       = obj.brightness,
        .horizontal_align = std::string(
            TextHorizontalAlignWord(ParseTextHorizontalAlign(obj.horizontalalign))),
        .vertical_align   = std::string(
            TextVerticalAlignWord(ParseTextVerticalAlign(obj.verticalalign))),
        .max_width        = obj.maxwidth,
        .max_rows         = obj.maxrows,
        .limit_width      = obj.limitwidth,
        .limit_rows       = obj.limitrows,
        .use_ellipsis     = obj.limituseellipsis,
        .block_align      = obj.blockalign,
        .style            = TextStyle {
            .outline           = obj.outline,
            .outline_thickness = obj.outlinethickness,
            .outline_color     = Eigen::Vector3f(obj.outlinecolor.data()),
            .blur              = obj.blur,
            .blur_size         = obj.blursize,
            .drop_shadow       = obj.dropshadow,
            .shadow_size       = obj.dropshadowsize,
            .shadow_opacity    = obj.dropshadowopacity,
            .shadow_offset     = Eigen::Vector2f(obj.dropshadowoffset[0], obj.dropshadowoffset[1]),
            .shadow_color      = Eigen::Vector3f(obj.dropshadowcolor.data()),
        },
    };

    ResolveTextLayerFont(state, vfs, font_key);
    return state;
}

// A layer's alpha reaches every material that takes it: its own, and the
// `g_Color4` and `g_Alpha` of each effect pass (an effect's `g_UserAlpha` is the
// effect's own, `SceneMaterial::own_user_alpha`, and keeps the alpha it started
// with). A timeline, a script or a user property drives each of them. An alpha
// none of those owns is the one another script writes (`thisLayer.alpha`), and
// the materials it reaches are collected in `written` for the caller to hand to
// `RegisterNodeAlpha` once, all of them: registered one at a time a write would
// reach only the last.
void RegisterLayerAlpha(ParseContext& context, std::string_view runtime_name,
                         const nlohmann::json& setting, float alpha,
                         std::shared_ptr<SceneMaterial> material,
                         std::vector<std::shared_ptr<SceneMaterial>>& written) {
    if (context.scene->runtime == nullptr || material == nullptr) return;
    auto& runtime = *context.scene->runtime;
    if (auto animation = ResolveScalarAnimation(setting)) {
        runtime.RegisterMaterialAlphaAnimation(
            material, runtime.RegisterScalarAnimation(runtime_name, std::move(*animation)));
    } else if (HasUpdateScript(setting) || (setting.is_object() && setting.contains("user"))) {
        runtime.BindMaterialAlpha(material, ResolveFloatSetting(runtime, setting, runtime_name));
    } else {
        written.push_back(std::move(material));
    }
}

// An effect a user property switches on or off is built only when the
// property's current value -- a preset or the user's choice, by the same rule
// as a layer's visibility -- says so. The scene file's value is the editor's
// default. It is decided here, when the scene loads: building every hidden
// effect would cost passes and memory, so a running scene holds the property at
// this value (SceneRuntimeContext::NoteLoadOnlyProperty) and a changed one
// takes a reload. An effect a script switches is built whatever its value, and
// follows the script while the scene runs (`RegisterScriptedEffectVisibility`).
void ResolveUserEffectVisibility(ParseContext& context,
                                 std::vector<wpscene::WPImageEffect>& effects,
                                 std::string_view runtime_name) {
    if (context.scene->runtime == nullptr) return;
    auto& runtime = *context.scene->runtime;
    for (auto& effect : effects) {
        if (effect.visible_setting.is_null() || effect.scripted_visible) continue;
        effect.visible =
            ResolveBoolSetting(runtime, effect.visible_setting, runtime_name)->getBool();
        runtime.NoteLoadOnlyProperty(UserPropertyName(effect.visible_setting));
    }
}

// Hands a built effect its visibility: fixed, or followed from the script that
// decides it.
void RegisterScriptedEffectVisibility(ParseContext& context,
                                      const wpscene::WPImageEffect& source,
                                      const std::shared_ptr<SceneImageEffect>& effect,
                                      std::string_view runtime_name) {
    effect->visible = source.visible;
    if (! source.scripted_visible || context.scene->runtime == nullptr) return;
    auto& runtime = *context.scene->runtime;
    // The script's `thisObject` is the effect: the `visible` it writes is this
    // effect's, not its layer's.
    runtime.RegisterEffectVisibility(
        effect, ResolveBoolSetting(runtime, source.visible_setting, runtime_name,
                                   PropertyScriptObject { .effect_visibility = true }));
}

// The keys of a text object that are baked into the card's pixels when the layer
// is laid out: the outline, blur and shadow switches, sizes and opacity. A
// property bound to one is read once, as the scene loads, with the value the user
// has chosen rather than the editor's default in the scene file, and noted as
// load-only so a running scene holds it there (SceneRuntimeContext::
// NoteLoadOnlyProperty). A key a script drives keeps the scene file's value.
// (The colours are uniforms of the card's shader and follow their property live;
// the offset, `padding` and `spacing` are two-number keys, which no property type
// of a project can supply.)
void ResolveLoadTimeTextStyle(ParseContext& context, wpscene::WPTextObject& obj,
                              std::string_view runtime_name) {
    if (context.scene->runtime == nullptr) return;
    auto& runtime = *context.scene->runtime;
    const auto bound = [&](const char* key) -> const nlohmann::json* {
        const auto setting = obj.field_bindings.find(key);
        if (setting == obj.field_bindings.end() || ! setting->is_object() ||
            ! setting->contains("user") || setting->contains("script")) {
            return nullptr;
        }
        runtime.NoteLoadOnlyProperty(UserPropertyName(*setting));
        return &*setting;
    };
    for (const auto& [key, field] : { std::pair<const char*, bool*> { "outline", &obj.outline },
                                      { "blur", &obj.blur },
                                      { "dropshadow", &obj.dropshadow } }) {
        if (const auto* setting = bound(key)) {
            *field = ResolveBoolSetting(runtime, *setting, runtime_name)->getBool();
        }
    }
    for (const auto& [key, field] :
         { std::pair<const char*, float*> { "outlinethickness", &obj.outlinethickness },
           { "blursize", &obj.blursize },
           { "dropshadowsize", &obj.dropshadowsize },
           { "dropshadowopacity", &obj.dropshadowopacity } }) {
        if (const auto* setting = bound(key)) {
            *field = ResolveFloatSetting(runtime, *setting, runtime_name)->getFloat();
        }
    }
}

void ParseTextObj(ParseContext& context, wpscene::WPTextObject& obj) {
    const auto runtime_name = TextRuntimeName(context, obj);
    ResolveUserEffectVisibility(context, obj.effects, runtime_name);
    ResolveLoadTimeTextStyle(context, obj, runtime_name);
    // A text layer shares an image layer's colour blend: the text card is drawn
    // first, and the passthrough pass appended after any effects mixes it with
    // the screen. Mode 31 ("add") is drawn additively straight onto the scene.
    const bool additive_color_blend = obj.colorBlendMode == kAdditiveColorBlendMode;
    std::optional<std::size_t> color_blend_effect;
    if (obj.colorBlendMode != 0 && ! additive_color_blend) {
        if (auto effect = MakeColorBlendEffect(*context.vfs, obj.colorBlendMode)) {
            obj.effects.push_back(std::move(*effect));
            color_blend_effect = obj.effects.size() - 1;
        } else {
            LOG_ERROR("failed to parse the colour blend passthrough material for '%s'",
                      obj.name.c_str());
        }
    }
    // Whether the card goes through an effect chain at all: an effect that is
    // off (in the file, or by a property as the scene loads) builds nothing, so
    // a text whose every effect is off is drawn as plain text, as Wallpaper
    // Engine draws it. One a script may switch on later still counts.
    const bool through_effects =
        std::any_of(obj.effects.begin(), obj.effects.end(), [](const wpscene::WPImageEffect& effect) {
            return EffectIsBuilt(effect) && ! effect.materials.empty();
        });
    // Such a text is drawn through a composite of its own, whose glyph pass blends over the
    // scene behind the card (`BuildTextSceneShader`). A layer with a colour blend keeps
    // drawing as it did, a card without that seed: how the blend's passthrough treats a seeded
    // card is not known. Modes 5 and 10 look at no alpha, so their card holds the colour the
    // blend passes the screen by wherever nothing is drawn (`BuildTextSceneShader`).
    const bool composites_over_scene = through_effects && ! color_blend_effect.has_value();
    const bool scene_fog = context.scene->fog_distance || context.scene->fog_height;
    auto       text         = JsonStringOrObjectValue(obj.text, "text");
    const auto font_key     = JsonStringOrObjectValue(obj.font, {});
    std::unique_ptr<DynamicValue> runtime_text_value;
    if (context.scene->runtime != nullptr && HasRuntimeTextValueBinding(obj.text)) {
        runtime_text_value =
            ResolveStringSetting(*context.scene->runtime, obj.text, runtime_name);
        if (runtime_text_value != nullptr) {
            text = runtime_text_value->toString();
        }
    }
    auto       text_state   = ResolveTextLayerState(obj,
                                            *context.vfs,
                                            text,
                                            font_key,
                                            runtime_name,
                                            scene_fog);
    // Cache glyph coverage, not animated styling. A fade or colour change only
    // updates uniforms; it must never measure, rasterize or upload the text again.
    text_state.color = Eigen::Vector3f::Ones();
    text_state.alpha = 1.0f;
    text_state.brightness = 1.0f;
    // Measured once: the card, the texture and the layer's runtime state all start from it.
    const auto layout              = MeasureTextLayerLayout(text_state);
    const auto raster_size         = TextLayerRasterSizeForLayout(text_state, layout);
    auto       render_frame        = TextLayerRenderFrameForLayout(text_state, layout);
    // The effect chain draws into buffers that are the card, as Wallpaper Engine's are: its
    // width and height with the fraction cut off, whatever the scene's size or the box the
    // editor drew. The chain's `v_TexCoord` then runs 0 to 1 across the card, and the final
    // card is all of the last buffer.
    const auto effect_frame         = TextLayerEffectFrame(render_frame);
    const auto effect_render_extent = TextCardTexelExtent(effect_frame.size);

    auto       node_iterator = context.layer_nodes.find(obj.id);
    auto       node = node_iterator != context.layer_nodes.end() && node_iterator->second != nullptr
                          ? node_iterator->second
                          : std::make_shared<SceneNode>();
    const auto previous_runtime_name = node->Name();
    node->SetName(runtime_name);
    // The node is where the scene put the layer: its alignment hangs the card from this
    // origin (the mesh is off it by the layout's offset) and never moves the node, so what
    // is parented to the layer stays on its origin.
    node->SetTranslate(Vector3f(obj.origin.data()));
    node->SetScale(Vector3f(obj.scale.data()));
    node->SetRotation(Vector3f(obj.angles.data()));
    node->SetVisible(obj.visible);
    node->ID() = obj.id;

    // Both cards are rewritten only by `ResizeCardMesh`, which the runtime
    // calls when a relayout produced a different raster size. Between two
    // relayouts the four corners are the same four corners, so the geometry is
    // dynamic without the scene having anything to do.
    auto mesh = std::make_shared<SceneMesh>(MeshUpdate::OnEvent);
    GenTextCardMesh(*mesh, render_frame.bounds);
    node->AddMesh(mesh);
    SceneMesh effect_final_mesh(MeshUpdate::OnEvent);
    GenTextCardMesh(effect_final_mesh, effect_frame.bounds);

    if (context.scene->runtime != nullptr) {
        const auto texture_name = TextTextureName(runtime_name);
        RegisterTextTexture(*context.scene, texture_name, text_state, raster_size);
        SceneMaterial material;
        material.name                = "text";
        material.textures            = { texture_name };
        material.defines             = { "g_Texture0" };
        if (composites_over_scene) {
            // The scene behind the card, which the card's pass seeds the composite from.
            material.textures.push_back(std::string(SpecTex_Default));
            material.defines.push_back("g_Texture1");
        }
        material.blenmode = through_effects ? BlendMode::Disable
                            : additive_color_blend ? BlendMode::Additive
                                                   : BlendMode::Translucent;
        const bool styled   = TextStyleActive(text_state.style);
        const bool outlined = styled && text_state.style.outline;
        // An opaque background fills the card's rectangle with the background colour at the layer's
        // alpha (`BuildTextSceneShader`).
        const bool filled = obj.opaquebackground;
        material.customShader.shader = BuildTextSceneShader(
            *context.vfs, context.scene->scene_id, texture_name, styled, outlined,
            composites_over_scene, filled,
            color_blend_effect.has_value() ? obj.colorBlendMode : 0);
        material.customShader.constValues["g_Color"] = obj.color;
        material.customShader.constValues["g_Alpha"] = obj.alpha;
        // Wallpaper Engine multiplies the colour by the brightness only in its HDR
        // pipeline: a text layer authored dark is still drawn in its colour in any
        // other scene.
        const bool brightness_applies = context.scene->hdr;
        material.customShader.constValues["g_Brightness"] = brightness_applies ? obj.brightness : 1.0f;
        if (filled) {
            // The background's brightness is held to the same pipeline as the text's.
            material.customShader.constValues["g_Background"]           = obj.backgroundcolor;
            material.customShader.constValues["g_BackgroundBrightness"] =
                brightness_applies ? obj.backgroundbrightness : 1.0f;
            const auto inset = TextCardInsetInRaster(text_state, layout);
            material.customShader.constValues["g_CardInset"] = std::array<float, 2> { inset.x(), inset.y() };
        }
        if (outlined) material.customShader.constValues["g_OutlineColor"] = obj.outlinecolor;
        if (styled) material.customShader.constValues["g_ShadowColor"] = obj.dropshadowcolor;
        // Whether the card is a composite follows the layer's visible effects as they are
        // switched (the gate registered below); it starts as they stand as the scene loads.
        const float composite_start =
            std::any_of(obj.effects.begin(), obj.effects.end(), EffectCountsForText) ? 1.0f : 0.0f;
        if (composites_over_scene) material.customShader.constValues["g_Composite"] = composite_start;
        if (material.customShader.shader != nullptr) {
            mesh->AddMaterial(std::move(material));
        }
        DynamicValue* composite_value = nullptr;
        if (composites_over_scene && mesh->MaterialSlotPtr() != nullptr) {
            auto value      = std::make_unique<DynamicValue>(composite_start);
            composite_value = value.get();
            context.scene->runtime->RegisterMaterialConstant(mesh->MaterialSlotPtr(), "g_Composite",
                                                             std::move(value));
        }
        // Where the card lies in the raster moves with the text (the style's room around it is
        // fixed in pixels, the raster is not), so the runtime keeps the constant up to date.
        DynamicValue* card_inset_value = nullptr;
        if (filled && mesh->MaterialSlotPtr() != nullptr) {
            const auto inset  = TextCardInsetInRaster(text_state, layout);
            auto       value  = std::make_unique<DynamicValue>(inset);
            card_inset_value  = value.get();
            context.scene->runtime->RegisterMaterialConstant(mesh->MaterialSlotPtr(), "g_CardInset",
                                                             std::move(value));
        }

        if (! previous_runtime_name.empty() && previous_runtime_name != runtime_name) {
            context.scene->runtime->UnregisterNode(previous_runtime_name);
        }
        context.scene->runtime->RegisterNode(runtime_name, node.get());
        context.scene->runtime->RegisterNodeVisibility(
            runtime_name,
            node.get(),
            ResolveBoolSetting(*context.scene->runtime,
                               obj.dynamic_visible ? obj.visible_setting
                                                   : nlohmann::json(obj.visible),
                               runtime_name));
        node->SetVisibilitySettled(VisibilitySettledBy(obj.visible_setting));
        context.scene->runtime->RegisterTextLayer(runtime_name, std::move(text_state), layout);
        std::vector<std::shared_ptr<SceneMaterial>> alpha_materials;
        RegisterLayerAlpha(context, runtime_name,
                           obj.field_bindings.contains("alpha") ? obj.field_bindings.at("alpha")
                                                               : nlohmann::json(obj.alpha),
                           obj.alpha, mesh->MaterialSlotPtr(), alpha_materials);
        context.scene->runtime->RegisterNodeAlpha(std::string(runtime_name),
                                                  std::move(alpha_materials), obj.alpha);
        if (const auto setting = obj.field_bindings.find("color");
            setting != obj.field_bindings.end()) {
            context.scene->runtime->RegisterMaterialConstant(
                mesh->MaterialSlotPtr(), "g_Color",
                ResolveVec3Setting(*context.scene->runtime, *setting, runtime_name));
            QueueSceneScriptIfNeeded(context, runtime_name, *setting);
        }
        if (const auto setting = obj.field_bindings.find("brightness");
            setting != obj.field_bindings.end()) {
            auto value = ResolveFloatSetting(*context.scene->runtime, *setting, runtime_name);
            if (brightness_applies) {
                context.scene->runtime->RegisterMaterialConstant(
                    mesh->MaterialSlotPtr(), "g_Brightness", std::move(value));
            } else {
                // Nothing draws with it, but a script that drives it still runs.
                context.scene->runtime->BindMaterialBrightness({}, std::move(value));
            }
            QueueSceneScriptIfNeeded(context, runtime_name, *setting);
        }
        if (filled) {
            for (const auto& [key, uniform] :
                 { std::pair<const char*, const char*> { "backgroundcolor", "g_Background" },
                   { "backgroundbrightness", "g_BackgroundBrightness" } }) {
                const auto setting = obj.field_bindings.find(key);
                if (setting == obj.field_bindings.end()) continue;
                const bool brightness = std::string_view(key) == "backgroundbrightness";
                if (brightness && ! brightness_applies) {
                    // Nothing draws with it, but a script that drives it still runs.
                    context.scene->runtime->BindMaterialBrightness(
                        {}, ResolveFloatSetting(*context.scene->runtime, *setting, runtime_name));
                } else {
                    context.scene->runtime->RegisterMaterialConstant(
                        mesh->MaterialSlotPtr(), uniform,
                        brightness ? ResolveFloatSetting(*context.scene->runtime, *setting, runtime_name)
                                   : ResolveVec3Setting(*context.scene->runtime, *setting, runtime_name));
                }
                QueueSceneScriptIfNeeded(context, runtime_name, *setting);
            }
        }
        // The outline and shadow colours are uniforms of the card's shader, so a
        // property or script bound to one drives it live, like the layer's colour.
        // (Their sizes, offsets and opacity are baked into the card's pixels and
        // are read once, as the scene loads; see `ResolveLoadTimeTextStyle`.)
        for (const auto& [key, uniform, wanted] :
             { std::tuple<const char*, const char*, bool> { "outlinecolor", "g_OutlineColor", outlined },
               std::tuple<const char*, const char*, bool> { "dropshadowcolor", "g_ShadowColor", styled } }) {
            const auto setting = obj.field_bindings.find(key);
            if (! wanted || setting == obj.field_bindings.end()) continue;
            context.scene->runtime->RegisterMaterialConstant(
                mesh->MaterialSlotPtr(), uniform,
                ResolveVec3Setting(*context.scene->runtime, *setting, runtime_name));
            QueueSceneScriptIfNeeded(context, runtime_name, *setting);
        }
        if (const auto setting = obj.field_bindings.find("alpha");
            setting != obj.field_bindings.end()) {
            QueueSceneScriptIfNeeded(context, runtime_name, *setting);
        }
        if (runtime_text_value != nullptr) {
            context.scene->runtime->RegisterTextValue(
                runtime_name, std::move(runtime_text_value), false);
        }
        context.scene->runtime->SetNodeCursorTarget(runtime_name, true, obj.solid,
                                                    obj.disablepropagation);
        // Pinned to the edge of what the display shows, where that differs from
        // the canvas; the runtime moves it as the presentation changes.
        context.scene->runtime->SetNodeScreenAnchor(runtime_name,
                                                    ParseTextScreenAnchor(obj.anchor));
        RegisterNodeTransformSettings(*context.scene->runtime, node.get(), runtime_name,
                                      obj.origin_setting, obj.scale_setting, obj.angles_setting);
        const auto register_gate = [&](std::vector<std::shared_ptr<SceneImageEffect>> built) {
            // The margin and the composite follow the effects that are visible, as they
            // are switched.
            context.scene->runtime->RegisterTextEffectGate(
                runtime_name,
                SceneRuntimeContext::TextEffectGate {
                    .padded_regardless = TextCardIsPaddedRegardless(obj, scene_fog),
                    .effects           = std::move(built),
                    .composite         = composite_value,
                    .card_inset        = card_inset_value,
                });
        };
        if (! through_effects && card_inset_value != nullptr) register_gate({});
        if (through_effects) {
            // The last pass is drawn translucent onto the scene whatever the colour blend
            // mode: Wallpaper Engine forces it, "add" included, while an effect runs. A layer
            // without effects, and so one whose effects a script has all off, is drawn
            // directly, which "add" does additively.
            //
            // The card carries the layer's colour and alpha already, so the effects and the
            // passthrough that ends a chain whose every effect is off take a white `g_Color4`:
            // an unbound one is zero and draws nothing, as an image layer's carries its own.
            ShaderValueMap effect_uniforms = context.global_base_uniforms;
            effect_uniforms["g_Color4"]    = std::array<float, 4> { 1.0f, 1.0f, 1.0f, 1.0f };
            auto built = AttachEffectsToNode(context,
                                             *node,
                                             obj.id,
                                             effect_final_mesh,
                                             obj.effects,
                                             runtime_name,
                                             effect_render_extent,
                                             effect_frame.center,
                                             BlendMode::Translucent,
                                             effect_uniforms,
                                             { obj.parallaxDepth[0], obj.parallaxDepth[1] },
                                             /* copy_background */ true,
                                             /* preserve_effect_fbo_resolution */ true,
                                             color_blend_effect.has_value() ? &obj.effects[*color_blend_effect]
                                                                            : nullptr,
                                             additive_color_blend ? std::optional<BlendMode> { BlendMode::Additive }
                                                                  : std::nullopt);
            register_gate(std::move(built));
        } else {
            // Camera parallax moves a layer through the model matrix of the draw, and
            // the value updater adds it to a draw that has a record with the layer's
            // depth. A text layer drawn through effects has it on its effect passes
            // (`AttachEffectsToNode`); one the card draws straight onto the scene has
            // none unless it is made here, and stood still while every other layer of
            // its depth moved. A depth a script writes finds this record and changes it.
            WPShaderValueData shader_value_data;
            shader_value_data.parallaxDepth = { obj.parallaxDepth[0], obj.parallaxDepth[1] };
            context.shader_updater->SetNodeData(node.get(), shader_value_data);
        }
        const auto& card = through_effects ? effect_frame : render_frame;
        context.text_cards[obj.id] = card;
        if (context.referenced_layer_ids.contains(obj.id)) {
            RegisterTextComposite(context, obj, *node, card);
        }
    }

    QueueSceneScriptIfNeeded(context, runtime_name, obj.visible_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, obj.origin_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, obj.scale_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, obj.angles_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, obj.text);

    context.layer_nodes[obj.id] = node;
    context.layer_parent_ids[obj.id] = obj.parent_id;
}

void SetNodeTransformFromMatrix(SceneNode& node, const Matrix4d& transform) {
    const Vector3d translation = transform.block<3, 1>(0, 3);
    const Matrix3d linear      = transform.block<3, 3>(0, 0);

    Vector3d scale {
        linear.col(0).norm(),
        linear.col(1).norm(),
        linear.col(2).norm(),
    };

    Matrix3d rotation = Matrix3d::Identity();
    for (int column = 0; column < 3; ++column) {
        if (scale(column) > 1e-8) {
            rotation.col(column) = linear.col(column) / scale(column);
        }
    }

    const Vector3d zyx = rotation.eulerAngles(2, 1, 0);
    node.SetTranslate(translation.cast<float>());
    node.SetScale(scale.cast<float>());
    node.SetRotation(Vector3f(
        static_cast<float>(zyx[2]), static_cast<float>(zyx[1]), static_cast<float>(zyx[0])));
}

void CopyResolvedWorldTransform(SceneNode& destination, SceneNode& source) {
    source.UpdateTrans();
    SetNodeTransformFromMatrix(destination, source.ModelTrans());
}

void ResolveEffectFinalTransform(SceneNode& destination, SceneNode& effect_render_node) {
    effect_render_node.UpdateTrans();
    const Matrix4d resolved = effect_render_node.ModelTrans() * destination.GetLocalTrans();
    SetNodeTransformFromMatrix(destination, resolved);
}

std::string ResolveConstvalueGlName(const std::string& name, const WPShaderInfo& info) {
    if (info.alias.count(name) != 0) return info.alias.at(name);

    for (const auto& el : info.alias) {
        if (el.second.substr(2) == name) return el.second;
    }

    return {};
}

bool IsCompositeMaterialShaderValue(std::string_view name, const WPAliasValueDict& aliases,
                                    const wpscene::WPMaterial& material) {
    const std::string prefix { name };
    return aliases.contains(prefix + "Start") && aliases.contains(prefix + "End") &&
           material.constantshadervalues.contains(prefix + "Start") &&
           material.constantshadervalues.contains(prefix + "End");
}

std::unique_ptr<DynamicValue>
MakeMaterialConstantValue(const wpscene::WPConstantShaderValue& source) {
    const auto& value = source.value;

    if (value.size() >= 4) {
        return std::make_unique<DynamicValue>(
            Eigen::Vector4f(value[0], value[1], value[2], value[3]));
    }
    if (value.size() == 3) {
        return std::make_unique<DynamicValue>(Eigen::Vector3f(value[0], value[1], value[2]));
    }
    if (value.size() == 2) {
        return std::make_unique<DynamicValue>(Eigen::Vector2f(value[0], value[1]));
    }
    if (value.size() == 1) return std::make_unique<DynamicValue>(value[0]);

    return std::make_unique<DynamicValue>(0.0f);
}

nlohmann::json MaterialConstantSettingJson(const wpscene::WPConstantShaderValue& source) {
    nlohmann::json setting;
    if (source.value.size() == 1) {
        setting["value"] = source.value[0];
    } else if (! source.value.empty()) {
        setting["value"] = source.value;
    } else {
        setting["value"] = 0.0f;
    }
    if (! source.user.empty()) setting["user"] = source.user;
    if (! source.script.empty()) setting["script"] = source.script;
    if (! source.scriptproperties.is_null()) {
        setting["scriptproperties"] = source.scriptproperties;
    }
    if (! source.animation.is_null()) setting["animation"] = source.animation;
    return setting;
}

std::unique_ptr<DynamicValue>
MakeMaterialConstantDynamicValue(SceneRuntimeContext& context,
                                 const wpscene::WPConstantShaderValue& source,
                                 std::string_view current_layer_name,
                                 PropertyScriptObject object = {}) {
    if (source.script.empty()) return MakeMaterialConstantValue(source);
    const auto setting = MaterialConstantSettingJson(source);
    // Without an authored value there is no component count to preserve.
    if (source.value.empty()) {
        return ResolveStringSetting(context, setting, current_layer_name, object);
    }
    return ResolveVectorSetting(context, setting, source.value.size(), current_layer_name, object);
}

void LoadMaterialConstantShaderValuesImpl(SceneMaterial& material, const wpscene::WPMaterial& wpmat,
                                          const WPShaderInfo& info) {
    // load glname from alias and load to constvalue
    for (const auto& cs : wpmat.constantshadervalues) {
        const auto& name   = cs.first;
        const auto& value  = cs.second;
        const auto  glname = ResolveConstvalueGlName(name, info);
        if (glname.empty()) {
            if (! IsCompositeMaterialShaderValue(name, info.alias, wpmat)) {
                LOG_ERROR("ShaderValue: %s not found in glsl", name.c_str());
            }
        } else {
            material.customShader.constValues[glname] = value.value;
        }
    }
}

void LoadConstvalue(SceneMaterial& material, const wpscene::WPMaterial& wpmat,
                    const WPShaderInfo& info) {
    LoadMaterialConstantShaderValuesImpl(material, wpmat, info);
}

void AddConstantValue(wpscene::WPMaterial& material, std::string name, std::vector<float> value) {
    material.constantshadervalues[std::move(name)] = wpscene::WPConstantShaderValue {
        .value = std::move(value),
    };
}

// Vector shader constants carry one curve per component, and an author can drive
// several of them from one timeline through `options.parent`. Both the curves and
// the relations are read per material pass: a corner of the same name in another
// pass is a different parameter and must never join this group.
struct MaterialConstantAnimationSource {
    std::array<ScalarAnimation, 4> components;
    std::size_t                    component_count { 0 };
    std::size_t                    first_curve { 4 };
    double                         last_frame { 0.0 };
    std::string                    parent_key;
};

std::unordered_map<std::string, MaterialConstantAnimationSource>
CollectMaterialConstantAnimations(const wpscene::WPMaterial& wpmat) {
    std::unordered_map<std::string, MaterialConstantAnimationSource> collected;
    for (const auto& [name, value] : wpmat.constantshadervalues) {
        if (! value.animation.is_object()) continue;
        if (value.value.empty() || value.value.size() > 4) continue;

        const auto                      setting = MaterialConstantSettingJson(value);
        MaterialConstantAnimationSource source;
        source.component_count = value.value.size();
        for (std::size_t index = 0; index < source.component_count; ++index) {
            auto curve = ResolveScalarAnimation(setting, index);
            if (! curve.has_value()) {
                // A component the author left unanimated keeps its own value.
                source.components[index].initial_value = value.value[index];
                continue;
            }
            if (source.first_curve == source.components.size()) source.first_curve = index;
            source.last_frame = std::max(source.last_frame, curve->keyframes.back().frame);
            source.components[index] = std::move(*curve);
        }
        if (source.first_curve == source.components.size()) continue;

        const auto options = value.animation.find("options");
        if (options != value.animation.end() && options->is_object()) {
            const auto parent = options->find("parent");
            if (parent != options->end() && parent->is_object()) {
                const auto key = parent->find("key");
                if (key != parent->end() && key->is_string()) {
                    source.parent_key = key->get<std::string>();
                }
            }
        }
        collected.emplace(name, std::move(source));
    }
    return collected;
}

void RegisterMaterialConstants(ParseContext& context, std::shared_ptr<SceneMaterial> material,
                               const wpscene::WPMaterial& wpmat, const WPShaderInfo& info,
                               std::string_view runtime_name = {}) {
    if (material == nullptr || context.scene->runtime == nullptr) return;

    const auto animations = CollectMaterialConstantAnimations(wpmat);
    // Constants arrive in hash order, so every relation is walked to its root
    // with memoized results; an empty root marks a group that cannot be played.
    std::unordered_map<std::string, std::string> roots;
    const auto resolve_root = [&](const std::string& start) {
        std::vector<std::string> chain;
        std::string              current = start;
        while (true) {
            if (const auto known = roots.find(current); known != roots.end()) {
                const std::string resolved = known->second;
                for (const auto& key : chain) roots[key] = resolved;
                return resolved;
            }
            const bool cycle = std::find(chain.begin(), chain.end(), current) != chain.end();
            if (cycle || animations.find(current) == animations.end()) {
                LOG_ERROR("invalid material animation parent for '%s': '%s'",
                          (chain.empty() ? start : chain.back()).c_str(), current.c_str());
                // The unusable parent is memoized too, so every sibling that
                // names it joins this group instead of reporting it again.
                roots[current] = std::string();
                for (const auto& key : chain) roots[key] = std::string();
                return std::string();
            }
            chain.push_back(current);
            const auto& source = animations.at(current);
            if (source.parent_key.empty()) {
                for (const auto& key : chain) roots[key] = current;
                return current;
            }
            current = source.parent_key;
        }
    };
    for (const auto& [name, source] : animations) {
        (void)source;
        resolve_root(name);
    }

    // One clock per root, long enough for the whole group unless the author
    // gave the root an explicit length.
    std::unordered_map<std::string, double> group_last_frame;
    for (const auto& [name, source] : animations) {
        const auto root = roots.find(name);
        if (root == roots.end() || root->second.empty()) continue;
        auto& last_frame = group_last_frame[root->second];
        last_frame = std::max(last_frame, source.last_frame);
    }
    std::unordered_map<std::string, std::shared_ptr<ScalarAnimationPlayback>> clocks;
    for (const auto& [root_key, last_frame] : group_last_frame) {
        const auto&     source = animations.at(root_key);
        ScalarAnimation clock  = source.components[source.first_curve];
        if (! (clock.length_frames > 0.0)) clock.length_frames = last_frame;
        clocks.emplace(root_key,
                       context.scene->runtime->RegisterScalarAnimation(runtime_name, std::move(clock)));
    }

    for (const auto& cs : wpmat.constantshadervalues) {
        const auto& name  = cs.first;
        const auto& value = cs.second;
        if (value.user.empty() && value.script.empty() && value.animation.is_null()) continue;

        const auto glname = ResolveConstvalueGlName(name, info);
        if (glname.empty()) continue;

        std::shared_ptr<const MaterialConstantAnimation> animation;
        if (const auto source = animations.find(name); source != animations.end()) {
            auto resolved             = std::make_shared<MaterialConstantAnimation>();
            resolved->component_count = source->second.component_count;
            resolved->components      = source->second.components;
            // Only the shared clock advances, loops and restarts; the component
            // copies just read its frame, so none of them wraps a second time.
            for (auto& component : resolved->components) {
                component.mode = ScalarAnimationMode::Single;
            }
            if (const auto root = roots.find(name); root != roots.end()) {
                if (const auto clock = clocks.find(root->second); clock != clocks.end()) {
                    resolved->playback = clock->second;
                }
            }
            animation = std::move(resolved);
        }
        // A script on a keyed constant reaches the constant's own timeline as
        // `thisObject.getAnimation()`, not the first unnamed one of its layer
        // (an origin or another constant).
        PropertyScriptObject object;
        if (animation != nullptr && animation->playback != nullptr && ! value.script.empty()) {
            object.property_animation =
                context.scene->runtime->RegisterPropertyAnimation(animation->playback);
        }
        auto dynamic_value = MakeMaterialConstantDynamicValue(*context.scene->runtime, value,
                                                              runtime_name, object);
        if (value.script.empty()) {
            if (auto* property_value = context.scene->runtime->FindPropertyValue(value.user);
                property_value != nullptr) {
                dynamic_value->connect(property_value);
            }
        }
        context.scene->runtime->RegisterMaterialConstant(
            material, glname, std::move(dynamic_value), std::move(animation));
    }
}

// An effect that draws a chain's input through unchanged with Wallpaper
// Engine's passthrough material, writing the chain's output. `slot`, when given,
// receives the material slot, for a layer colour that tints every pass.
std::shared_ptr<SceneImageEffect> MakePassthroughEffect(
    ParseContext& context, const std::string& input, const ShaderValueMap& base_const_svs,
    const std::string& runtime_name, std::string_view layer_name,
    std::shared_ptr<SceneMaterial>* slot = nullptr) {
    auto&               vfs    = *context.vfs;
    auto                effect = std::make_shared<SceneImageEffect>();
    auto                node   = std::make_shared<SceneNode>();
    wpscene::WPMaterial wp_material;
    nlohmann::json      json;
    if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/materials/util/effectpassthrough.json"), json) ||
        ! wp_material.FromJson(json)) {
        LOG_ERROR("failed to parse the passthrough material for '%s'",
                  std::string(layer_name).c_str());
        return nullptr;
    }
    if (wp_material.textures.empty()) wp_material.textures.resize(1);
    wp_material.textures[0] = input;
    SceneMaterial     material;
    WPShaderValueData sv_data;
    WPShaderInfo      shader_info;
    shader_info.baseConstSvs = base_const_svs;
    if (! LoadMaterial(vfs, wp_material, context.scene.get(), node.get(), &material, &sv_data,
                       &shader_info)) {
        LOG_ERROR("failed to load the passthrough material for '%s'",
                  std::string(layer_name).c_str());
        return nullptr;
    }
    LoadConstvalue(material, wp_material, shader_info);
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(std::move(material));
    if (slot != nullptr) *slot = mesh->MaterialSlotPtr();
    RegisterMaterialConstants(context, mesh->MaterialSlotPtr(), wp_material, shader_info, runtime_name);
    node->AddMesh(mesh);
    context.shader_updater->SetNodeData(node.get(), sv_data);
    effect->nodes.push_back({ std::string(SpecTex_Default), node });
    return effect;
}

std::vector<std::shared_ptr<SceneImageEffect>>
AttachEffectsToNode(ParseContext& context,
                    SceneNode& node,
                    int32_t layer_id,
                    SceneMesh& final_mesh,
                    std::span<const wpscene::WPImageEffect> effects,
                    const std::string& runtime_name,
                    std::array<int32_t, 2> render_extent,
                    Eigen::Vector2f render_center,
                    BlendMode final_blend,
                    const ShaderValueMap& base_const_svs,
                    std::array<float, 2> parallax_depth,
                    bool copy_background,
                    bool preserve_effect_fbo_resolution,
                    const wpscene::WPImageEffect* screen_blend_effect,
                    std::optional<BlendMode> idle_final_blend) {
    std::vector<std::shared_ptr<SceneImageEffect>> built;
    if (effects.empty()) return built;

    auto& scene    = *context.scene;
    auto& vfs      = *context.vfs;
    const auto nodeAddr = getAddr(&node);
    auto  camera   = std::make_shared<SceneCamera>(render_extent[0], render_extent[1], -1.0f, 1.0f);
    auto camera_node = std::make_shared<SceneNode>();
    camera_node->SetTranslate(Eigen::Vector3f(render_center.x(), render_center.y(), 0.0f));
    camera->AttatchNode(camera_node);
    scene.sceneGraph->AppendChild(camera_node);
    scene.cameras[nodeAddr] = camera;
    node.SetCamera(nodeAddr);

    const auto effect_ppong_a = std::string(WE_EFFECT_PPONG_PREFIX_A.data()) + nodeAddr;
    const auto effect_ppong_b = std::string(WE_EFFECT_PPONG_PREFIX_B.data()) + nodeAddr;
    auto       effect_layer   = std::make_shared<SceneImageEffectLayer>(
        &node,
        static_cast<float>(render_extent[0]),
        static_cast<float>(render_extent[1]),
        effect_ppong_a,
        effect_ppong_b);
    effect_layer->SetFinalBlend(final_blend);
    if (idle_final_blend.has_value()) effect_layer->SetIdleFinalBlend(*idle_final_blend);
    effect_layer->FinalMesh().ChangeMeshDataFrom(final_mesh);
    effect_layer->SetFinalMeshDynamic(final_mesh.UpdateDriver());
    effect_layer->FinalNode().CopyTrans(node);
    node.SetRenderTransformOverride(Eigen::Matrix4d::Identity());
    if (! copy_background) node.SetSkipRenderPass(true);
    scene.cameras.at(nodeAddr)->AttatchImgEffect(effect_layer);
    if (scene.runtime != nullptr) {
        scene.runtime->RegisterNodeEffectFinal(
            runtime_name,
            &node,
            effect_layer.get(),
            TextLayerRenderFrame {
                .bounds = {
                    .left = render_center.x() - static_cast<float>(render_extent[0]) * 0.5f,
                    .right = render_center.x() + static_cast<float>(render_extent[0]) * 0.5f,
                    .bottom = render_center.y() - static_cast<float>(render_extent[1]) * 0.5f,
                    .top = render_center.y() + static_cast<float>(render_extent[1]) * 0.5f,
                },
                .size = Eigen::Vector2f(static_cast<float>(render_extent[0]),
                                        static_cast<float>(render_extent[1])),
                .center = render_center,
            });
    }

    scene.renderTargets[effect_ppong_a] = {
        .width      = render_extent[0],
        .height     = render_extent[1],
        .allowReuse = true,
        .format = scene.hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8,
    };
    scene.renderTargets[effect_ppong_b] = scene.renderTargets.at(effect_ppong_a);
    scene.renderTargets[effect_ppong_b].bind = { .enable = true, .name = effect_ppong_a };

    int scripted_effects = 0, fixed_effects = 0;
    for (const auto& effect : effects) {
        // An effect with no pass is not one Wallpaper Engine counts: it draws nothing, so it
        // must neither stand for a visible effect nor keep the passthrough fallback away.
        if (! EffectIsBuilt(effect) || effect.materials.empty()) continue;

        auto image_effect = std::make_shared<SceneImageEffect>();
        const std::string inRT { effect_ppong_a };
        const std::string effaddr = getAddr(effect_layer.get());

        std::unordered_map<std::string, std::string> fboMap;
        fboMap["previous"] = inRT;
        for (const auto& fbo : effect.fbos) {
            const auto rtname = EnsureSpecTexName(fbo.name + "_" + effaddr);
            const auto resolve_dimension = preserve_effect_fbo_resolution
                                               ? ResolveTextEffectRenderTargetDimension
                                               : ResolveRenderTargetDimension;
            scene.renderTargets[rtname] = {
                .width      = resolve_dimension(static_cast<float>(render_extent[0]), fbo.scale),
                .height     = resolve_dimension(static_cast<float>(render_extent[1]), fbo.scale),
                .allowReuse = true,
                .bind = { .enable = true, .name = effect_ppong_a,
                          .scale = preserve_effect_fbo_resolution ? 1.0
                                                                 : 1.0 / std::max(1u, fbo.scale) },
                .format = EffectFboFormat(fbo.format, scene.hdr),
            };
            if (const auto fixed = FixedEffectFboExtent(fbo,
                                                        static_cast<float>(render_extent[0]),
                                                        static_cast<float>(render_extent[1]))) {
                auto& target  = scene.renderTargets[rtname];
                target.width  = (*fixed)[0];
                target.height = (*fixed)[1];
                target.bind   = {};
            }
            fboMap[fbo.name] = rtname;
        }

        LowerEffectCommands(effect, fboMap, scene, image_effect->commands);

        bool effect_materials_ok = true;
        for (usize i_mat = 0; i_mat < effect.materials.size(); ++i_mat) {
            auto wpmat = effect.materials.at(i_mat);
            std::string matOutRT { WE_EFFECT_PPONG_PREFIX_B };
            if (effect.passes.size() > i_mat) {
                const auto& pass = effect.passes.at(i_mat);
                wpmat.MergePass(pass);
                for (const auto& bind : pass.bind) {
                    if (fboMap.count(bind.name) == 0) {
                        LOG_ERROR("fbo %s not found", bind.name.c_str());
                        continue;
                    }
                    if (wpmat.textures.size() <= static_cast<usize>(bind.index)) {
                        wpmat.textures.resize(static_cast<usize>(bind.index) + 1u);
                    }
                    wpmat.textures[static_cast<usize>(bind.index)] = fboMap[bind.name];
                }
                if (! pass.target.empty()) {
                    if (fboMap.count(pass.target) == 0) {
                        LOG_ERROR("fbo %s not found", pass.target.c_str());
                    } else {
                        matOutRT = fboMap.at(pass.target);
                    }
                }
            }
            BindOwnEffectChainInput(wpmat, layer_id, inRT);
            if (wpmat.textures.empty()) wpmat.textures.resize(1);
            if (wpmat.textures.at(0).empty()) wpmat.textures[0] = inRT;

            auto              effect_node = std::make_shared<SceneNode>();
            WPShaderInfo      shader_info;
            SceneMaterial     material;
            WPShaderValueData shader_value_data;
            shader_info.baseConstSvs = base_const_svs;
            shader_info.baseConstSvs["g_EffectTextureProjectionMatrix"] =
                ShaderValue::fromMatrix(Eigen::Matrix4f::Identity());
            shader_info.baseConstSvs["g_EffectTextureProjectionMatrixInverse"] =
                ShaderValue::fromMatrix(Eigen::Matrix4f::Identity());
            // The pass that blends the layer onto the screen draws it with a
            // white colour: the layer's own colour and alpha are in what it blends.
            if (&effect == screen_blend_effect) {
                shader_info.baseConstSvs["g_Color4"] = std::array<float, 4> { 1.0f, 1.0f, 1.0f, 1.0f };
            }

            if (! LoadMaterial(vfs,
                               wpmat,
                               context.scene.get(),
                               effect_node.get(),
                               &material,
                               &shader_value_data,
                               &shader_info)) {
                effect_materials_ok = false;
                break;
            }

            LoadConstvalue(material, wpmat, shader_info);
            shader_value_data.parallaxDepth  = parallax_depth;
            shader_value_data.parallax_layer = &node;
            auto mesh = std::make_shared<SceneMesh>();
            mesh->AddMaterial(std::move(material));
            RegisterMaterialConstants(context, mesh->MaterialSlotPtr(), wpmat, shader_info, runtime_name);
            effect_node->AddMesh(mesh);
            context.shader_updater->SetNodeData(effect_node.get(), shader_value_data);
            image_effect->nodes.push_back({ matOutRT, effect_node });
        }

        if (effect_materials_ok) {
            RegisterScriptedEffectVisibility(context, effect, image_effect, runtime_name);
            effect_layer->AddEffect(image_effect);
            built.push_back(image_effect);
            (effect.scripted_visible ? scripted_effects : fixed_effects)++;
        } else {
            LOG_ERROR("effect '%s' failed to load", effect.name.c_str());
        }
    }
    // As for an image layer: while a script has every effect off, the chain
    // ends in a passthrough so the layer is still drawn.
    if (scripted_effects > 0 && fixed_effects == 0) {
        if (auto fallback = MakePassthroughEffect(context, effect_ppong_a, base_const_svs,
                                                  runtime_name, node.Name())) {
            fallback->fallback = true;
            effect_layer->AddEffect(fallback);
        }
    }
    return built;
}

/// The four corners `point0` to `point3` of the first effect's first pass, in the
/// 0..1 square of the shape, if all four are there.
std::optional<std::array<Eigen::Vector2f, 4>>
ShapeCornerPoints(const wpscene::WPShapeObject& obj) {
    if (obj.effects.empty() || obj.effects.front().materials.empty()) return std::nullopt;
    auto material = obj.effects.front().materials.front();
    if (! obj.effects.front().passes.empty()) material.MergePass(obj.effects.front().passes.front());
    std::array<Eigen::Vector2f, 4> points;
    for (std::size_t index = 0; index < points.size(); ++index) {
        const auto value = material.constantshadervalues.find("point" + std::to_string(index));
        if (value == material.constantshadervalues.end() || value->second.value.size() < 2) {
            return std::nullopt;
        }
        points[index] = Eigen::Vector2f(value->second.value[0], value->second.value[1]);
    }
    return points;
}

/// A shape's geometry: with its four corners the quad they make, a corner at
/// `(p.x, 1 - p.y)` of a square `size` on a side centred on the layer, with
/// texture coordinates `p`; without them the whole square.
void GenShapeMesh(SceneMesh& mesh, float size, const std::optional<std::array<Eigen::Vector2f, 4>>& corners) {
    if (! corners.has_value()) {
        const auto side = static_cast<uint16_t>(std::clamp(std::lround(size), 1l, 65535l));
        GenCardMesh(mesh, { side, side });
        return;
    }
    // One strip covers the quad whichever way its corners wind, since the
    // texture coordinates are an affine function of position over the square.
    constexpr std::array<std::size_t, 4> kStripOrder { 3, 0, 2, 1 };
    std::array<float, 12> positions {};
    std::array<float, 8>  texcoords {};
    for (std::size_t slot = 0; slot < kStripOrder.size(); ++slot) {
        const auto& corner   = (*corners)[kStripOrder[slot]];
        positions[slot * 3 + 0] = size * corner.x() - size * 0.5f;
        positions[slot * 3 + 1] = size * (1.0f - corner.y()) - size * 0.5f;
        positions[slot * 3 + 2] = 0.0f;
        texcoords[slot * 2 + 0] = corner.x();
        texcoords[slot * 2 + 1] = corner.y();
    }
    SceneVertexArray vertex(
        {
            { WE_IN_POSITION.data(), VertexType::FLOAT3 },
            { WE_IN_TEXCOORD.data(), VertexType::FLOAT2 },
        },
        4);
    vertex.SetVertex(WE_IN_POSITION, positions);
    vertex.SetVertex(WE_IN_TEXCOORD, texcoords);
    mesh.AddVertexArray(std::move(vertex));
}

/// A `shape` object draws its last effect, every pass of it, straight onto the
/// scene as the layer's own geometry, additively, with the effect's `DIRECTDRAW`
/// combo forced on in every pass: there is no layer texture and no composite to
/// process. The layer is the group node `ParseLayerNodes` made for it, which keeps
/// the transform, parent chain, visibility and scripts of any layer; this gives it
/// the mesh and the material. An effect of more than one pass would draw into
/// buffers first, which a mesh drawn onto the scene cannot, and is left out.
void ParseShapeObj(ParseContext& context, wpscene::WPShapeObject& obj) {
    const auto node_iterator = context.layer_nodes.find(obj.id);
    if (node_iterator == context.layer_nodes.end() || node_iterator->second == nullptr) return;
    SceneNode& node = *node_iterator->second;
    const std::string runtime_name = node.Name();
    ResolveUserEffectVisibility(context, obj.effects, runtime_name);

    const wpscene::WPImageEffect* last = nullptr;
    for (const auto& effect : obj.effects) {
        if (effect.visible && ! effect.materials.empty()) last = &effect;
    }
    if (last == nullptr) return;
    if (last->materials.size() != 1) {
        LOG_ERROR("shape '%s': an effect of more than one pass is not drawn", obj.name.c_str());
        return;
    }

    auto wpmat = last->materials.front();
    if (! last->passes.empty()) wpmat.MergePass(last->passes.front());
    wpmat.combos["DIRECTDRAW"] = 1;

    auto& vfs = *context.vfs;
    SceneMaterial     material;
    WPShaderValueData shader_value_data;
    WPShaderInfo      shader_info;
    shader_info.baseConstSvs = context.global_base_uniforms;
    shader_info.baseConstSvs["g_EffectTextureProjectionMatrix"] =
        ShaderValue::fromMatrix(Eigen::Matrix4f::Identity());
    shader_info.baseConstSvs["g_EffectTextureProjectionMatrixInverse"] =
        ShaderValue::fromMatrix(Eigen::Matrix4f::Identity());
    if (! LoadMaterial(vfs, wpmat, context.scene.get(), &node, &material, &shader_value_data,
                       &shader_info)) {
        LOG_ERROR("shape '%s': its effect failed to load", obj.name.c_str());
        return;
    }
    LoadConstvalue(material, wpmat, shader_info);
    // Wallpaper Engine forces the effect's final pass additive for the draw, whatever
    // its material says.
    material.blenmode                = BlendMode::Additive;
    shader_value_data.parallaxDepth  = { obj.parallaxDepth[0], obj.parallaxDepth[1] };
    shader_value_data.parallax_layer = &node;

    auto mesh = std::make_shared<SceneMesh>();
    GenShapeMesh(*mesh, static_cast<float>(context.ortho_h), ShapeCornerPoints(obj));
    mesh->AddMaterial(std::move(material));
    if (context.scene->runtime != nullptr) {
        RegisterMaterialConstants(context, mesh->MaterialSlotPtr(), wpmat, shader_info, runtime_name);
    }
    node.AddMesh(mesh);
    context.shader_updater->SetNodeData(&node, shader_value_data);
}

void RegisterNodeVideoTextureRuntime(ParseContext& context, const std::string& runtime_name,
                                     const SceneMaterial* material) {
    if (context.scene->runtime == nullptr || material == nullptr) return;

    for (const auto& texture_name : material->textures) {
        if (texture_name.empty()) continue;
        const auto texture_iterator = context.scene->textures.find(texture_name);
        if (texture_iterator == context.scene->textures.end()) continue;
        if (! texture_iterator->second.isVideo) continue;
        context.scene->runtime->RegisterNodeVideoTexture(runtime_name, texture_name);
        const ImageHeader header = context.scene->imageParser->ParseHeader(texture_name);
        if (header.durationSeconds > 0.0) {
            context.scene->runtime->SetVideoTextureDuration(texture_name, header.durationSeconds);
        }
    }
}

bool ScriptHandlesCursor(std::string_view script) {
    return script.find("cursor") != std::string_view::npos;
}

bool SettingHandlesCursor(const nlohmann::json& setting) {
    if (! setting.is_object() || ! setting.contains("script") ||
        ! setting.at("script").is_string()) {
        return false;
    }
    return ScriptHandlesCursor(setting.at("script").get_ref<const std::string&>());
}

// True when any script bound to this image object can receive cursor events,
// so the layer needs a coverage mask for hit testing.
bool ImageObjectHandlesCursorEvents(const wpscene::WPImageObject& wpimgobj) {
    if (SettingHandlesCursor(wpimgobj.visible_setting) ||
        SettingHandlesCursor(wpimgobj.origin_setting) ||
        SettingHandlesCursor(wpimgobj.scale_setting) ||
        SettingHandlesCursor(wpimgobj.angles_setting) ||
        SettingHandlesCursor(wpimgobj.alpha_setting)) {
        return true;
    }
    for (const auto& [name, constant] : wpimgobj.material.constantshadervalues) {
        (void)name;
        if (ScriptHandlesCursor(constant.script)) return true;
    }
    for (const auto& effect : wpimgobj.effects) {
        for (const auto& material : effect.materials) {
            for (const auto& [name, constant] : material.constantshadervalues) {
                (void)name;
                if (ScriptHandlesCursor(constant.script)) return true;
            }
        }
    }
    return false;
}

// Alpha of one texel from the mip-0 payload, or 255 for formats without alpha.
uint8_t TexelAlpha(const ImageData& mip, TextureFormat format, i32 x, i32 y) {
    const auto* data = mip.data.get();
    switch (format) {
    case TextureFormat::RGBA8: {
        const isize offset = (static_cast<isize>(y) * mip.width + x) * 4 + 3;
        return offset < mip.size ? data[offset] : 0;
    }
    case TextureFormat::BC2: {
        // 16-byte blocks; the first 8 bytes hold sixteen 4-bit alphas.
        const isize blocks_per_row = (mip.width + 3) / 4;
        const isize block          = (static_cast<isize>(y) / 4) * blocks_per_row + x / 4;
        const isize offset         = block * 16 + ((y % 4) * 4 + (x % 4)) / 2;
        if (offset >= mip.size) return 0;
        const uint8_t pair = data[offset];
        const uint8_t nib  = (x % 2) == 0 ? (pair & 0x0F) : (pair >> 4);
        return static_cast<uint8_t>(nib * 17);
    }
    case TextureFormat::BC3: {
        // 16-byte blocks; the first 8 bytes are a DXT5 interpolated alpha block.
        const isize blocks_per_row = (mip.width + 3) / 4;
        const isize block          = (static_cast<isize>(y) / 4) * blocks_per_row + x / 4;
        const isize offset         = block * 16;
        if (offset + 8 > mip.size) return 0;
        const uint8_t a0 = data[offset];
        const uint8_t a1 = data[offset + 1];
        uint64_t      bits = 0;
        for (int i = 0; i < 6; ++i) bits |= static_cast<uint64_t>(data[offset + 2 + i]) << (8 * i);
        const unsigned index = static_cast<unsigned>((bits >> (3 * ((y % 4) * 4 + (x % 4)))) & 0x7);
        if (index == 0) return a0;
        if (index == 1) return a1;
        if (a0 > a1) {
            return static_cast<uint8_t>(((8 - index) * a0 + (index - 1) * a1) / 7);
        }
        if (index == 6) return 0;
        if (index == 7) return 255;
        return static_cast<uint8_t>(((6 - index) * a0 + (index - 1) * a1) / 5);
    }
    default:
        return 255;
    }
}

// Builds a coverage mask for an image object's albedo texture. Returns nullopt
// for textures the runtime should keep hit testing by rectangle: videos,
// sprite sheets, opaque formats and anything the parser cannot decode.
std::optional<NodeHitMask> BuildImageHitMask(ParseContext& context,
                                             const wpscene::WPImageObject& wpimgobj) {
    constexpr uint32_t kMaxMaskSide = 256;
    // Puppet meshes are cut-up sprites deformed by bones, not a card over the
    // albedo, so their authored rectangle stays the hit area.
    if (wpimgobj.material.textures.empty() || ! wpimgobj.puppet.empty()) return std::nullopt;
    const auto& texture_name = wpimgobj.material.textures[0];
    if (texture_name.empty() || IsSpecTex(texture_name)) return std::nullopt;
    const auto texture_iterator = context.scene->textures.find(texture_name);
    if (texture_iterator != context.scene->textures.end() &&
        (texture_iterator->second.isVideo || texture_iterator->second.isSprite)) {
        return std::nullopt;
    }
    const auto image = context.scene->imageParser->Parse(texture_name);
    if (image == nullptr || image->header.isVideo || image->header.isSprite ||
        image->slots.empty() || image->slots[0].mipmaps.empty()) {
        return std::nullopt;
    }
    const auto format = image->header.format;
    if (format != TextureFormat::RGBA8 && format != TextureFormat::BC2 &&
        format != TextureFormat::BC3) {
        return std::nullopt;
    }
    const auto& mip = image->slots[0].mipmaps[0];
    if (mip.data == nullptr || mip.width <= 0 || mip.height <= 0) return std::nullopt;
    // The authored image occupies the top-left mapWidth x mapHeight texels of
    // a possibly padded texture; card meshes only sample that region.
    const i32 map_width  = std::clamp<i32>(image->header.mapWidth, 1, mip.width);
    const i32 map_height = std::clamp<i32>(image->header.mapHeight, 1, mip.height);

    NodeHitMask mask;
    const i32 longest = std::max(map_width, map_height);
    const i32 step    = std::max<i32>(1, (longest + static_cast<i32>(kMaxMaskSide) - 1) /
                                          static_cast<i32>(kMaxMaskSide));
    mask.width  = static_cast<uint32_t>((map_width + step - 1) / step);
    mask.height = static_cast<uint32_t>((map_height + step - 1) / step);
    mask.alpha.resize(static_cast<std::size_t>(mask.width) * mask.height);
    for (uint32_t y = 0; y < mask.height; ++y) {
        const i32 texel_y = std::min<i32>(static_cast<i32>(y) * step + step / 2, map_height - 1);
        for (uint32_t x = 0; x < mask.width; ++x) {
            const i32 texel_x = std::min<i32>(static_cast<i32>(x) * step + step / 2, map_width - 1);
            mask.alpha[static_cast<std::size_t>(y) * mask.width + x] =
                TexelAlpha(mip, format, texel_x, texel_y);
        }
    }
    return mask;
}

// Binds each authored animation layer's visible/rate/blend to user properties
// (and scripts) so the shared puppet state follows the wallpaper settings. A
// script bound there is about that animation layer: its `thisObject` is it.
template <typename Object>
void BindPuppetAnimationLayerSettings(ParseContext& context, const std::string& runtime_name,
                                      const Object& wpimgobj,
                                      WPPuppetLayer layer) {
    auto& runtime = *context.scene->runtime;
    const auto count = std::min(wpimgobj.puppet_layer_settings.size(), layer.layerCount());
    for (std::size_t index = 0; index < count; ++index) {
        const auto& setting = wpimgobj.puppet_layer_settings[index];
        if (! setting.is_object()) continue;
        const i32 layer_index = static_cast<i32>(index);
        const PropertyScriptObject animation_layer { .animation_layer_index = layer_index };
        const auto is_dynamic = [](const nlohmann::json& value) {
            return value.is_object() && (value.contains("user") || value.contains("script"));
        };
        if (setting.contains("visible") && is_dynamic(setting.at("visible"))) {
            runtime.RegisterDynamicValueListener(
                ResolveBoolSetting(runtime, setting.at("visible"), runtime_name, animation_layer),
                [layer, layer_index](const DynamicValue& value) mutable {
                    layer.setVisible(layer_index, value.getBool());
                });
        }
        if (setting.contains("rate") && is_dynamic(setting.at("rate"))) {
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, setting.at("rate"), runtime_name, animation_layer),
                [layer, layer_index](const DynamicValue& value) mutable {
                    layer.setRate(layer_index, value.getFloat());
                });
        }
        if (setting.contains("blend") && is_dynamic(setting.at("blend"))) {
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, setting.at("blend"), runtime_name, animation_layer),
                [layer, layer_index](const DynamicValue& value) mutable {
                    layer.setBlend(layer_index, value.getFloat());
                });
        }
    }
}

void RemapSubmeshesToMaterialSlot(SceneMesh& mesh, uint32_t material_slot) {
    for (auto& submesh : mesh.Submeshes()) {
        submesh.material_slot = material_slot;
    }
}

bool LoadWPMaterialFromPath(fs::VFS& vfs, const std::string& material_path,
                            wpscene::WPMaterial& material) {
    nlohmann::json json;
    if (! PARSE_JSON(fs::GetFileContent(vfs, "/assets/" + material_path), json)) {
        LOG_ERROR("load material '%s' failed", material_path.c_str());
        return false;
    }
    return material.FromJson(json);
}

struct LoadedMaterialSlot {
    SceneMaterial       material;
    wpscene::WPMaterial source;
    WPShaderInfo        shader_info;
    WPShaderValueData   shader_value_data;
};

bool PuppetHasBones(const WPMdl& puppet) {
    return puppet.puppet != nullptr && ! puppet.puppet->bones.empty();
}

bool PuppetHasMeshData(const WPMdl& puppet) {
    for (const auto& mesh : puppet.meshes) {
        if (! mesh.positions.empty()) return true;
    }
    return false;
}

bool PuppetHasClipMasks(const WPMdl& puppet) {
    for (const auto& mesh : puppet.meshes) {
        if (! mesh.masks.empty()) return true;
    }
    return false;
}

constexpr std::string_view kPuppetMaskRenderTarget = "_rt_puppet_mask";

void GenPuppetMeshSubmeshes(SceneMesh& mesh, const WPMdl& puppet, const bool include_masks) {
    WPMdlParser::GenPuppetMesh(mesh, puppet, include_masks);
}

void EnsurePuppetMaskRenderTarget(Scene& scene) {
    if (scene.renderTargets.count(std::string(kPuppetMaskRenderTarget)) != 0) return;

    scene.renderTargets[std::string(kPuppetMaskRenderTarget)] = SceneRenderTarget {
        .width      = 2,
        .height     = 2,
        .allowReuse = true,
        .forceClear = true,
        .bind       = { .enable = true, .screen = true, .scale = 0.5 },
    };
}

std::string PuppetBaseTexture(const wpscene::WPImageObject& wpimgobj) {
    if (! wpimgobj.material.textures.empty()) return wpimgobj.material.textures[0];
    return {};
}

LoadedMaterialSlot MakePuppetMaterialSlot(const wpscene::WPMaterial& source,
                                          const WPShaderInfo& shader_info,
                                          const WPShaderValueData& shader_value_data) {
    return LoadedMaterialSlot {
        .material          = {},
        .source            = source,
        .shader_info       = shader_info,
        .shader_value_data = shader_value_data,
    };
}

bool LoadPuppetMaterialSlot(ParseContext& context, SceneNode* node,
                            LoadedMaterialSlot& slot) {
    if (! LoadMaterial(*context.vfs,
                       slot.source,
                       context.scene.get(),
                       node,
                       &slot.material,
                       &slot.shader_value_data,
                       &slot.shader_info)) {
        return false;
    }
    LoadConstvalue(slot.material, slot.source, slot.shader_info);
    return true;
}

std::optional<std::vector<LoadedMaterialSlot>>
TryLoadPuppetMaterialSlots(ParseContext& context, SceneNode* node, wpscene::WPImageObject& wpimgobj,
                           const WPMdl& puppet, const ShaderValueMap& base_const_svs,
                           const WPShaderValueData& image_shader_value_data) {
    if (puppet.meshes.empty()) return std::nullopt;
    const bool has_bones = PuppetHasBones(puppet);
    if (PuppetHasClipMasks(puppet)) EnsurePuppetMaskRenderTarget(*context.scene);

    std::vector<LoadedMaterialSlot> slots;
    std::size_t slot_count = puppet.meshes.size();
    for (const auto& mesh : puppet.meshes) slot_count += mesh.masks.size() * 2;
    slots.reserve(slot_count);
    std::vector<std::optional<wpscene::WPMaterial>> mesh_sources;
    mesh_sources.reserve(puppet.meshes.size());

    auto make_shader_info = [&base_const_svs, &puppet, has_bones]() {
        WPShaderInfo shader_info;
        if (has_bones) WPMdlParser::AddPuppetShaderInfo(shader_info, puppet);
        shader_info.baseConstSvs = base_const_svs;
        return shader_info;
    };

    // The image's shader value data already carries the node's shared puppet
    // layer; the copy keeps every slot on the same playback state.
    auto make_shader_value_data = [&image_shader_value_data]() {
        auto shader_value_data = image_shader_value_data;
        shader_value_data.renderTargets.clear();
        return shader_value_data;
    };

    auto load_slot = [&](LoadedMaterialSlot slot, const std::string& material_path) {
        if (! LoadPuppetMaterialSlot(context, node, slot)) {
            LOG_ERROR("load puppet mesh material '%s' failed", material_path.c_str());
            return false;
        }
        slots.push_back(std::move(slot));
        return true;
    };

    for (std::size_t slot_index = 0; slot_index < puppet.meshes.size(); ++slot_index) {
        const auto& mesh = puppet.meshes[slot_index];
        if (mesh.positions.empty()) {
            mesh_sources.push_back(std::nullopt);
            continue;
        }
        if (mesh.mat_json_file.empty()) {
            LOG_ERROR("puppet mesh %zu has no material json file", slot_index);
            return std::nullopt;
        }

        wpscene::WPMaterial source;
        if (! LoadWPMaterialFromPath(*context.vfs, mesh.mat_json_file, source)) {
            LOG_ERROR("load puppet mesh material '%s' failed", mesh.mat_json_file.c_str());
            return std::nullopt;
        }
        if (has_bones) {
            WPMdlParser::AddPuppetMatInfo(source, puppet);
        }
        mesh_sources.push_back(std::move(source));
    }

    for (std::size_t mesh_index = 0; mesh_index < puppet.meshes.size(); ++mesh_index) {
        const auto& mesh        = puppet.meshes[mesh_index];
        auto&       mesh_source = mesh_sources[mesh_index];
        if (mesh.positions.empty() || ! mesh_source) continue;

        auto base_slot = MakePuppetMaterialSlot(
            *mesh_source, make_shader_info(), make_shader_value_data());
        if (! load_slot(std::move(base_slot), mesh.mat_json_file)) {
            return std::nullopt;
        }

        const auto  base_texture = mesh_source->textures.empty()
            ? PuppetBaseTexture(wpimgobj)
            : mesh_source->textures[0];
        for (const auto& mask : mesh.masks) {
            wpscene::WPMaterial mask_source;
            mask_source.shader     = "clippingmaskimage4";
            mask_source.blending   = "translucent";
            mask_source.depthtest  = "disabled";
            mask_source.depthwrite = "disabled";
            mask_source.cullmode   = "nocull";
            mask_source.textures.resize(2);
            mask_source.textures[0] = base_texture;
            mask_source.textures[1] = mask.mat_json_file;
            if (has_bones) WPMdlParser::AddPuppetMatInfo(mask_source, puppet);

            auto mask_slot = MakePuppetMaterialSlot(
                mask_source, make_shader_info(), make_shader_value_data());
            if (! load_slot(std::move(mask_slot), mask.mat_json_file)) return std::nullopt;

            auto clipped_source = *mesh_source;
            clipped_source.combos["CLIPPINGTARGET"] = 1;
            clipped_source.combos["CLIPPINGUVS"]    = 1;
            if (clipped_source.textures.size() < 9) clipped_source.textures.resize(9);
            clipped_source.textures[8] = "_rt_puppet_mask";
            if (has_bones) WPMdlParser::AddPuppetMatInfo(clipped_source, puppet);

            auto clipped_slot = MakePuppetMaterialSlot(
                clipped_source, make_shader_info(), make_shader_value_data());
            if (! load_slot(std::move(clipped_slot), mesh.mat_json_file)) return std::nullopt;
        }
    }

    return slots;
}

// parse

// The field of view of a scene with a perspective projection: a shot's own, else
// the scene's `fov`. `perspectiveoverridefov` belongs to a 2D scene's perspective
// layers (below) and plays no part here, whatever the package version.
float ResolvePerspectiveFov(const wpscene::WPSceneGeneral& general, float object_fov = 0.0f) {
    if (object_fov > 0.0f) return object_fov;
    if (general.fov > 0.0f) return general.fov;
    return 50.0f;
}

// The lens Wallpaper Engine puts in front of a 2D scene's perspective layers --
// particles and models with the `perspective` flag -- is the scene's
// `perspectiveoverridefov`, 95 degrees when the file leaves it out. `fov`
// belongs to scenes with a perspective projection and plays no part here.
// Every field of view is held between 0.1 and 179.9 degrees.
float ResolveCanvasPerspectiveFov(const wpscene::WPSceneGeneral& general) {
    constexpr float kDefaultFov = 95.0f;
    const float     fov = general.perspectiveoverridefov > 0.0f ? general.perspectiveoverridefov
                                                                : kDefaultFov;
    return std::clamp(fov, 0.1f, 179.9f);
}

void PlacePerspectiveCameraNode(SceneNode& node, const wpscene::WPSceneCamera& camera) {
    const Vector3d eye(camera.eye[0], camera.eye[1], camera.eye[2]);
    const Vector3d center(camera.center[0], camera.center[1], camera.center[2]);
    Vector3d       up(camera.up[0], camera.up[1], camera.up[2]);
    if (up.squaredNorm() < 1e-12) up = Vector3d::UnitY();

    Vector3d camDir = center - eye;
    if (camDir.squaredNorm() < 1e-12) camDir = -Vector3d::UnitZ();
    const Vector3d zAxis = -camDir.normalized();
    Vector3d       xAxis = up.cross(zAxis);
    if (xAxis.squaredNorm() < 1e-12) xAxis = Vector3d::UnitX();
    xAxis.normalize();
    const Vector3d yAxis = zAxis.cross(xAxis).normalized();

    Affine3d world = Affine3d::Identity();
    world.linear().col(0) = xAxis;
    world.linear().col(1) = yAxis;
    world.linear().col(2) = zAxis;
    world.translation()   = eye;
    SetNodeTransformFromMatrix(node, world.matrix());
}

void ParseCamera(ParseContext& context, wpscene::WPScene& sc) {
    auto&     general           = sc.general;
    auto&     scene             = *context.scene;
    const i32 projection_width  = EffectiveProjectionDimension(context.ortho_w, general.zoom);
    const i32 projection_height = EffectiveProjectionDimension(context.ortho_h, general.zoom);
    // effect camera
    scene.cameras["effect"]    = std::make_shared<SceneCamera>(2, 2, -1.0f, 1.0f);
    context.effect_camera_node = std::make_shared<SceneNode>(); // at 0,0,0
    scene.cameras.at("effect")->AttatchNode(context.effect_camera_node);
    scene.sceneGraph->AppendChild(context.effect_camera_node);

    // global camera
    scene.cameras["global"] =
        std::make_shared<SceneCamera>(projection_width, projection_height, -5000.0f, 5000.0f);
    scene.activeCamera = scene.cameras.at("global").get();
    Vector3f cori { (float)context.ortho_w / 2.0f, (float)context.ortho_h / 2.0f, 0 },
        cscale { 1.0f, 1.0f, 1.0f }, cangle(Vector3f::Zero());

    context.global_camera_node = std::make_shared<SceneNode>(cori, cscale, cangle);
    scene.cameras.at("global")->AttatchNode(context.global_camera_node);
    scene.sceneGraph->AppendChild(context.global_camera_node);

    const float authored_fov = ResolvePerspectiveFov(general);
    scene.cameras["global_perspective"] = std::make_shared<SceneCamera>(
        (float)projection_width / (float)projection_height,
        general.nearz,
        general.farz,
        general.isOrtho ? ResolveCanvasPerspectiveFov(general) : authored_fov);

    // Fullscreen effects live in screen space even when the scene camera is
    // perspective. Projecting their canvas-sized card through that camera
    // clips the result to a quadrant instead of covering the scene.
    scene.cameras[std::string(FullscreenLayerCamera)] =
        std::make_shared<SceneCamera>(context.ortho_w, context.ortho_h, -5000.0f, 5000.0f);
    auto fullscreen_node = std::make_shared<SceneNode>(cori, cscale, cangle);
    scene.cameras.at(std::string(FullscreenLayerCamera))->AttatchNode(fullscreen_node);
    scene.sceneGraph->AppendChild(fullscreen_node);

    if (general.isOrtho) {
        // Over the canvas centre; its distance from the canvas plane follows
        // from its field of view and the canvas it looks at.
        context.global_perspective_camera_node = std::make_shared<SceneNode>(cori, cscale, cangle);
        auto& perspective                      = *scene.cameras["global_perspective"];
        perspective.AttatchNode(context.global_perspective_camera_node);
        FitCanvasPerspective(perspective, *scene.cameras.at("global"));
        perspective.Update();
        scene.sceneGraph->AppendChild(context.global_perspective_camera_node);
        return;
    }

    context.global_perspective_camera_node = std::make_shared<SceneNode>();
    PlacePerspectiveCameraNode(*context.global_perspective_camera_node, sc.camera);
    scene.cameras["global_perspective"]->AttatchNode(context.global_perspective_camera_node);
    scene.cameras["global_perspective"]->LockFov(true);
    scene.activeCamera = scene.cameras.at("global_perspective").get();
    scene.sceneGraph->AppendChild(context.global_perspective_camera_node);
}

void AddScreenRenderTarget(Scene& scene, std::string name, i32 render_width, i32 render_height,
                           double scale) {
    scene.renderTargets[std::move(name)] = {
        .width      = std::max(1, static_cast<i32>(static_cast<double>(render_width) * scale)),
        .height     = std::max(1, static_cast<i32>(static_cast<double>(render_height) * scale)),
        .allowReuse = true,
        .bind       = { .enable = true, .screen = true, .scale = scale },
        .format = scene.hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8,
    };
}

struct StagedPostProcessNode {
    std::shared_ptr<SceneNode> node;
    WPShaderValueData          shader_value_data;
    wpscene::WPMaterial        material;
    WPShaderInfo               shader_info;
};

class BloomRenderTargetRollback {
public:
    explicit BloomRenderTargetRollback(Scene& scene): m_scene(scene) {
        for (const auto& name : kBloomRenderTargets) Track(std::string(name));
    }

    ~BloomRenderTargetRollback() {
        if (m_committed) return;
        for (const auto& [name, render_target] : m_previous) {
            if (render_target.has_value()) {
                m_scene.renderTargets[name] = *render_target;
            } else {
                m_scene.renderTargets.erase(name);
            }
        }
    }

    void Commit() { m_committed = true; }
    void Track(std::string name) {
        const auto it = m_scene.renderTargets.find(name);
        m_previous.emplace_back(std::move(name),
            it == m_scene.renderTargets.end() ? std::nullopt
                                             : std::optional<SceneRenderTarget>(it->second));
    }

private:
    static constexpr std::array<std::string_view, 4> kBloomRenderTargets {
        "_rt_bloom_mip1",
        "_rt_bloom_mip2",
        "_rt_bloom_blur",
        "_rt_bloom_combine",
    };

    Scene&                                                                m_scene;
    bool                                                                  m_committed { false };
    std::vector<std::pair<std::string, std::optional<SceneRenderTarget>>> m_previous;
};

std::optional<StagedPostProcessNode> BuildPostProcessNode(ParseContext&      context,
                                                          const std::string& material_path,
                                                          const std::vector<std::string>& textures,
                                                          const wpscene::WPSceneGeneral& general,
                                                          const ShaderValueMap* uniforms = nullptr) {
    nlohmann::json json;
    if (! PARSE_JSON(fs::GetFileContent(*context.vfs, "/assets/" + material_path), json)) {
        LOG_ERROR("load bloom material '%s' failed", material_path.c_str());
        return std::nullopt;
    }

    wpscene::WPMaterial wpmat;
    if (! wpmat.FromJson(json)) return std::nullopt;
    wpmat.textures = textures;
    if (material_path == "materials/util/downsample_quarter_bloom.json") {
        AddConstantValue(wpmat, "bloomstrength", { general.bloomstrength });
        AddConstantValue(wpmat, "bloomthreshold", { general.bloomthreshold });
        AddConstantValue(wpmat,
                         "bloomtint",
                         { general.bloomtint[0], general.bloomtint[1], general.bloomtint[2] });
    }

    SceneMaterial     material;
    WPShaderValueData sv_data;
    WPShaderInfo      shader_info;
    shader_info.baseConstSvs = context.global_base_uniforms;
    if (uniforms != nullptr) {
        for (const auto& [name, value] : *uniforms) shader_info.baseConstSvs[name] = value;
    }

    auto node = std::make_shared<SceneNode>();
    node->SetName("__bloom_" + wpmat.shader);
    node->SetCamera("effect");
    if (! LoadMaterial(*context.vfs,
                       wpmat,
                       context.scene.get(),
                       node.get(),
                       &material,
                       &sv_data,
                       &shader_info)) {
        LOG_ERROR("load bloom material '%s' failed", material_path.c_str());
        return std::nullopt;
    }
    LoadConstvalue(material, wpmat, shader_info);

    auto mesh = std::make_shared<SceneMesh>();
    mesh->ChangeMeshDataFrom(context.scene->default_effect_mesh);
    mesh->AddMaterial(std::move(material));
    node->AddMesh(std::move(mesh));
    return StagedPostProcessNode {
        .node              = std::move(node),
        .shader_value_data = std::move(sv_data),
        .material          = std::move(wpmat),
        .shader_info       = std::move(shader_info),
    };
}

std::array<float, 4> HDRBloomBlend(float threshold, float feather) {
    const float knee = std::max(0.0f, threshold * feather);
    return { threshold, threshold - knee, 2.0f * knee, 0.25f / (knee + 1.0e-5f) };
}

// Wallpaper Engine's extraction strength: the scene's strength over one more
// than the scatter raised to the number of levels past the second.
float HDRBloomExtractionStrength(float strength, float scatter, int levels) {
    return strength / (std::pow(scatter, static_cast<float>(std::max(levels - 2, 0))) + 1.0f);
}

// As many half-size levels as the frame's shorter side allows, at most eight,
// and at most the scene's iterations.
int HDRBloomLevels(int iterations, int width, int height) {
    const int shorter = std::max(2, std::min(width, height));
    int available = 0;
    for (int k = 0; k < 8; ++k) {
        if ((shorter >> (k + 1)) >= 1) ++available;
    }
    return std::max(1, std::min(available, iterations));
}

void BuildHDRBloomPostProcess(ParseContext& context, const wpscene::WPSceneGeneral& general) {
    auto& scene = *context.scene;
    const int width = std::max(1, scene.ortho[0]), height = std::max(1, scene.ortho[1]);
    const int levels = HDRBloomLevels(general.bloomhdriterations, width, height);
    BloomRenderTargetRollback rollback(scene);
    std::vector<std::string> targets;
    targets.reserve(levels);
    for (int i = 0; i < levels; ++i) {
        targets.push_back("_rt_hdr_bloom_" + std::to_string(i));
        rollback.Track(targets.back());
        AddScreenRenderTarget(scene, targets.back(), width, height, std::ldexp(1.0, -i - 1));
    }
    AddScreenRenderTarget(scene, "_rt_bloom_combine", width, height, 1.0);

    auto bloom = std::make_shared<ScenePostProcess>();
    bloom->name = "__hdr_bloom";
    std::vector<StagedPostProcessNode> staged;
    staged.reserve(levels * 2);
    // Extraction and downsampling read one texel of their source either side,
    // upsampling half of one; the size is kept current as targets resize.
    const auto append = [&](const char* material, std::vector<std::string> inputs,
                            const std::string& output, const ShaderValueMap& uniforms,
                            float texel_radius, const char* fallback = nullptr) {
        auto node = BuildPostProcessNode(context, material, inputs, general, &uniforms);
        if (!node && fallback != nullptr)
            node = BuildPostProcessNode(context, fallback, inputs, general, &uniforms);
        if (!node) throw std::runtime_error("Unable to compile authored HDR bloom material");
        bloom->steps.push_back(ScenePostProcessPass {
            .node = node->node, .output = output, .source_texel_radius = texel_radius });
        staged.push_back(std::move(*node));
    };
    const ShaderValueMap extract {
        { "g_BloomStrength", HDRBloomExtractionStrength(
            general.bloomhdrstrength, general.bloomhdrscatter, levels) },
        { "g_BloomBlendParams", HDRBloomBlend(general.bloomhdrthreshold, general.bloomhdrfeather) },
        { "g_BloomTint", general.bloomtint },
        { "g_RenderVar0", std::array<float, 4>{0, 0, 0, 0} },
    };
    append("materials/util/hdr_downsample_bloom.json", {SpecTex_Default.data()}, targets.front(),
           extract, 1.0f);
    for (int i = 1; i < levels; ++i)
        append("materials/util/hdr_downsample.json", {targets[i - 1]}, targets[i],
               {{"g_RenderVar0", std::array<float, 4>{0, 0, 0, 0}}}, 1.0f);
    const ShaderValueMap scatter {
        { "g_BloomScatter", general.bloomhdrscatter },
        { "g_RenderVar0", std::array<float, 4>{0, 0, 0, 0} },
    };
    // The two coarsest levels are upsampled bicubically, the rest bilinearly.
    for (int i = levels - 1; i > 0; --i) {
        if (i >= levels - 2) {
            append("materials/util/hdr_upsample_cubic.json", {targets[i]}, targets[i - 1], scatter,
                   0.5f, "materials/util/hdr_upsample.json");
        } else {
            append("materials/util/hdr_upsample.json", {targets[i]}, targets[i - 1], scatter, 0.5f);
        }
    }
    append("materials/util/combine_hdr_upsample_linear.json",
           {SpecTex_Default.data(), targets.front()}, "_rt_bloom_combine", {}, 0.0f);
    bloom->steps.push_back(ScenePostProcessCopy {
        .src = "_rt_bloom_combine", .dst = SpecTex_Default.data(),
    });
    for (auto& node : staged)
        context.shader_updater->SetNodeData(node.node.get(), node.shader_value_data);

    if (scene.runtime != nullptr) {
        auto& runtime = *scene.runtime;
        const auto setting = [](const nlohmann::json& value, float fallback) {
            return value.is_null() ? nlohmann::json(fallback) : value;
        };
        const auto first = staged.front().node->Mesh()->MaterialSlotPtr();
        auto amount = std::make_shared<std::array<float, 2>>(
            std::array<float, 2>{general.bloomhdrstrength, general.bloomhdrscatter});
        std::vector<std::shared_ptr<SceneMaterial>> upsample_materials;
        for (int i = levels; i < levels * 2 - 1; ++i)
            upsample_materials.push_back(staged[i].node->Mesh()->MaterialSlotPtr());
        runtime.RegisterDynamicValueListener(
            ResolveFloatSetting(runtime, setting(general.bloomhdrstrength_setting,
                                                 general.bloomhdrstrength)),
            [first, amount, levels](const DynamicValue& value) {
                (*amount)[0] = value.getFloat();
                first->customShader.constValues["g_BloomStrength"] =
                    HDRBloomExtractionStrength((*amount)[0], (*amount)[1], levels);
            });
        runtime.RegisterDynamicValueListener(
            ResolveFloatSetting(runtime, setting(general.bloomhdrscatter_setting,
                                                 general.bloomhdrscatter)),
            [first, amount, levels, materials = std::move(upsample_materials)](const DynamicValue& value) {
                (*amount)[1] = value.getFloat();
                first->customShader.constValues["g_BloomStrength"] =
                    HDRBloomExtractionStrength((*amount)[0], (*amount)[1], levels);
                for (const auto& material : materials)
                    material->customShader.constValues["g_BloomScatter"] = (*amount)[1];
            });
        auto blend = std::make_shared<std::array<float, 2>>(
            std::array<float, 2>{general.bloomhdrthreshold, general.bloomhdrfeather});
        for (std::size_t i = 0; i < 2; ++i) {
            const auto& source = i == 0 ? general.bloomhdrthreshold_setting
                                        : general.bloomhdrfeather_setting;
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, setting(source, (*blend)[i])),
                [first, blend, i](const DynamicValue& value) {
                    (*blend)[i] = value.getFloat();
                    first->customShader.constValues["g_BloomBlendParams"] =
                        HDRBloomBlend((*blend)[0], (*blend)[1]);
                });
        }
        if (general.dynamic_bloomtint) {
            runtime.RegisterDynamicValueListener(
                ResolveVec3Setting(runtime, general.bloomtint_setting),
                [first](const DynamicValue& value) {
                    const auto tint = value.getVec3();
                    first->customShader.constValues["g_BloomTint"] =
                        std::array<float, 3> { tint.x(), tint.y(), tint.z() };
                });
        }
    }
    scene.post_processes.push_back(std::move(bloom));
    rollback.Commit();
}

void BuildBloomPostProcess(ParseContext& context, const wpscene::WPScene& sc) {
    if (! sc.general.bloom) return;
    if (sc.general.hdr) {
        BuildHDRBloomPostProcess(context, sc.general);
        return;
    }

    const auto render_width =
        std::max(1, static_cast<i32>(context.scene->cameras.at("global")->Width()));
    const auto render_height =
        std::max(1, static_cast<i32>(context.scene->cameras.at("global")->Height()));

    BloomRenderTargetRollback bloom_render_target_rollback(*context.scene);
    AddScreenRenderTarget(*context.scene, "_rt_bloom_mip1", render_width, render_height, 0.25);
    AddScreenRenderTarget(*context.scene, "_rt_bloom_mip2", render_width, render_height, 0.125);
    // Wallpaper Engine blurs into an eighth-size image of its own: the
    // horizontal blur touches a quarter of the pixels writing back into the
    // quarter-size one would.
    AddScreenRenderTarget(*context.scene, "_rt_bloom_blur", render_width, render_height, 0.125);
    AddScreenRenderTarget(*context.scene, "_rt_bloom_combine", render_width, render_height, 1.0);

    auto bloom  = std::make_shared<ScenePostProcess>();
    bloom->name = "__bloom";

    auto downsample_quarter = BuildPostProcessNode(context,
                                                   "materials/util/downsample_quarter_bloom.json",
                                                   { SpecTex_Default.data() },
                                                   sc.general);
    auto downsample_eighth  = BuildPostProcessNode(
        context, "materials/util/downsample_eighth_blur_v.json", { "_rt_bloom_mip1" }, sc.general);
    auto blur_horizontal = BuildPostProcessNode(
        context, "materials/util/blur_h_bloom.json", { "_rt_bloom_mip2" }, sc.general);
    auto combine = BuildPostProcessNode(context,
                                        "materials/util/combine_ldr.json",
                                        { SpecTex_Default.data(), "_rt_bloom_blur" },
                                        sc.general);

    if (! downsample_quarter.has_value() || ! downsample_eighth.has_value() ||
        ! blur_horizontal.has_value() || ! combine.has_value()) {
        return;
    }

    context.shader_updater->SetNodeData(downsample_quarter->node.get(),
                                        downsample_quarter->shader_value_data);
    context.shader_updater->SetNodeData(downsample_eighth->node.get(),
                                        downsample_eighth->shader_value_data);
    context.shader_updater->SetNodeData(blur_horizontal->node.get(),
                                        blur_horizontal->shader_value_data);
    context.shader_updater->SetNodeData(combine->node.get(), combine->shader_value_data);

    RegisterMaterialConstants(context,
                              downsample_quarter->node->Mesh()->MaterialSlotPtr(),
                              downsample_quarter->material,
                              downsample_quarter->shader_info);
    RegisterMaterialConstants(context,
                              downsample_eighth->node->Mesh()->MaterialSlotPtr(),
                              downsample_eighth->material,
                              downsample_eighth->shader_info);
    RegisterMaterialConstants(context,
                              blur_horizontal->node->Mesh()->MaterialSlotPtr(),
                              blur_horizontal->material,
                              blur_horizontal->shader_info);
    RegisterMaterialConstants(
        context, combine->node->Mesh()->MaterialSlotPtr(), combine->material, combine->shader_info);
    if (context.scene->runtime != nullptr) {
        // Strength, threshold and tint follow their user properties live, as
        // Wallpaper Engine pushes them into the bloom material when they change.
        auto&      runtime  = *context.scene->runtime;
        const auto material = downsample_quarter->node->Mesh()->MaterialSlotPtr();
        const auto& general = sc.general;
        for (const auto& [setting, uniform] :
             { std::pair { &general.bloomstrength_setting, "g_BloomStrength" },
               std::pair { &general.bloomthreshold_setting, "g_BloomThreshold" } }) {
            if (! HasDynamicSetting(*setting)) continue;
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, *setting),
                [material, name = std::string(uniform)](const DynamicValue& value) {
                    material->customShader.constValues[name] = value.getFloat();
                });
        }
        if (general.dynamic_bloomtint) {
            runtime.RegisterDynamicValueListener(
                ResolveVec3Setting(runtime, general.bloomtint_setting),
                [material](const DynamicValue& value) {
                    const auto tint = value.getVec3();
                    material->customShader.constValues["g_BloomTint"] =
                        std::array<float, 3> { tint.x(), tint.y(), tint.z() };
                });
        }
    }

    bloom->steps.push_back(ScenePostProcessPass {
        .node   = std::move(downsample_quarter->node),
        .output = "_rt_bloom_mip1",
    });
    bloom->steps.push_back(ScenePostProcessPass {
        .node   = std::move(downsample_eighth->node),
        .output = "_rt_bloom_mip2",
    });
    bloom->steps.push_back(ScenePostProcessPass {
        .node   = std::move(blur_horizontal->node),
        .output = "_rt_bloom_blur",
    });
    bloom->steps.push_back(ScenePostProcessPass {
        .node   = std::move(combine->node),
        .output = "_rt_bloom_combine",
    });
    bloom->steps.push_back(ScenePostProcessCopy {
        .src = "_rt_bloom_combine",
        .dst = SpecTex_Default.data(),
    });
    context.scene->post_processes.push_back(std::move(bloom));
    bloom_render_target_rollback.Commit();
}

/// The filter Wallpaper Engine gives the render targets of an image layer: points
/// when the layer asks (`nointerpolation`) or when the header of its primary
/// texture does, and linear otherwise. A layer with no texture of its own, a
/// composition layer, only has its own flag to go by. The header is read from the
/// texture's file, not from what an earlier layer happened to load, so the answer
/// does not depend on the order the layers are parsed in -- the composite of a
/// layer another layer reads is registered before its own material is loaded.
TextureFilter LayerRenderTargetFilter(const Scene& scene, const wpscene::WPImageObject& image) {
    if (image.nointerpolation) return TextureFilter::NEAREST;
    const auto& textures = image.material.textures;
    if (textures.empty() || textures.front().empty()) return TextureFilter::LINEAR;
    const auto& primary = textures.front();
    if (const auto texture = scene.textures.find(primary); texture != scene.textures.end()) {
        return texture->second.sample.magFilter == TextureFilter::NEAREST ? TextureFilter::NEAREST
                                                                          : TextureFilter::LINEAR;
    }
    // A render target or a link texture has no header; neither does a file that
    // could not be read, whose default sample is not a request for points.
    if (IsSpecTex(primary) || scene.imageParser == nullptr) return TextureFilter::LINEAR;
    const ImageHeader header = scene.imageParser->ParseHeader(primary);
    if (header.mapWidth <= 0 || header.mapHeight <= 0) return TextureFilter::LINEAR;
    return header.sample.magFilter == TextureFilter::NEAREST ? TextureFilter::NEAREST
                                                             : TextureFilter::LINEAR;
}

/// How the pair of ping-pong targets an image layer's effects run through is
/// sampled by the passes that read them, the layer's last draw among them:
/// `LayerRenderTargetFilter`, and clamped or wrapped by `clampuvs`.
TextureSample LayerRenderTargetSample(const Scene& scene, const wpscene::WPImageObject& image) {
    const auto wrap   = image.clampuvs ? TextureWrap::CLAMP_TO_EDGE : TextureWrap::REPEAT;
    const auto filter = LayerRenderTargetFilter(scene, image);
    return { wrap, wrap, filter, filter };
}

void RegisterImageComposite(ParseContext& context, const wpscene::WPImageObject& object,
                             SceneNode& node) {
    RegisterLayerComposite(context, object.id, node, ResolveImageRenderExtent(object, context),
                           object.clampuvs, context.effect_camera_node,
                           LayerRenderTargetFilter(*context.scene, object));
}

// A scene setting bound to a user property takes the property's current value
// when the scene loads. Those that decide what the scene is built with -- the
// bloom passes, which passes follow the cursor -- are read only then, and a
// change to their property reloads the scene.
template <typename T>
void ResolveLoadOnlySceneSetting(SceneRuntimeContext& runtime, const nlohmann::json& setting,
                                 T& value) {
    if (! HasDynamicSetting(setting)) return;
    if constexpr (std::is_same_v<T, bool>) {
        value = ResolveBoolSetting(runtime, setting)->getBool();
    } else if constexpr (std::is_same_v<T, std::array<float, 3>>) {
        const auto vector = ResolveVec3Setting(runtime, setting)->getVec3();
        value = { vector.x(), vector.y(), vector.z() };
    } else {
        value = ResolveFloatSetting(runtime, setting)->getFloat();
    }
    runtime.NoteLoadOnlyProperty(UserPropertyName(setting));
}

void InitContext(ParseContext& context, fs::VFS& vfs, wpscene::WPScene& sc) {
    context.scene = std::make_shared<Scene>();
    context.vfs   = &vfs;
    auto& scene   = *context.scene;
    scene.imageParser =
        std::make_unique<RuntimeImageSource>(std::make_unique<WPTexImageParser>(&vfs));
    scene.paritileSys->gener = std::make_unique<WPParticleRawGener>();
    scene.shaderValueUpdater = std::make_unique<WPShaderValueUpdater>(&scene);
    GenCardMesh(scene.default_effect_mesh, { 2, 2 });
    context.shader_updater = static_cast<WPShaderValueUpdater*>(scene.shaderValueUpdater.get());

    scene.clearColor   = sc.general.clearcolor;
    scene.clearEnabled = sc.general.clearenabled;
    scene.ortho[0]     = sc.general.orthogonalprojection.width;
    scene.ortho[1]     = sc.general.orthogonalprojection.height;
    scene.display_sized = ! sc.general.isOrtho;
    scene.opaque_first = ! sc.general.isOrtho && sc.general.transparentsorting;
    scene.light_config = ParseSceneLightConfig(sc.general.lightconfig);
    scene.fog_distance = sc.general.fogdistance;
    if (context.request != nullptr && context.request->project_properties != nullptr) {
        SceneRuntimeBootstrap bootstrap {
            .canvas_width       = scene.ortho[0],
            .canvas_height      = scene.ortho[1],
            .project_properties = *context.request->project_properties,
        };
        if (context.request->authored_project_properties != nullptr) {
            bootstrap.authored_project_properties = *context.request->authored_project_properties;
        }
        scene.runtime = CreateSceneRuntimeContext(std::move(bootstrap));
        scene.runtime->AttachScene(&scene);
        if (sc.general.dynamic_clearcolor) {
            scene.runtime->RegisterSceneClearColor(ResolveVec3Setting(
                *scene.runtime, sc.general.clearcolor_setting, {}, Vec3SettingSemantic::Generic));
        }
        auto& g = sc.general;
        const auto lighting = [&](const char* key, auto& value) {
            const auto setting = g.lighting_settings.find(key);
            if (setting != g.lighting_settings.end()) {
                ResolveLoadOnlySceneSetting(*scene.runtime, *setting, value);
            }
        };
        lighting("ambientcolor", g.ambientcolor);
        lighting("skylightcolor", g.skylightcolor);
        lighting("fogheight", g.fogheight);
        lighting("fogheightstart", g.fogheightstart);
        lighting("fogheightend", g.fogheightend);
        lighting("fogheightcolor", g.fogheightcolor);
        lighting("fogheightstartdensity", g.fogheightstartdensity);
        lighting("fogheightenddensity", g.fogheightenddensity);
        ResolveLoadOnlySceneSetting(*scene.runtime, g.bloom_setting, g.bloom);
        ResolveLoadOnlySceneSetting(*scene.runtime, g.cameraparallax_setting, g.cameraparallax);
        ResolveLoadOnlySceneSetting(*scene.runtime, g.cameraparallaxamount_setting,
                                    g.cameraparallaxamount);
        ResolveLoadOnlySceneSetting(*scene.runtime, g.cameraparallaxmouseinfluence_setting,
                                    g.cameraparallaxmouseinfluence);
        // Read live below; the scene is first built with the current value.
        if (HasDynamicSetting(g.zoom_setting)) {
            g.zoom = ResolveFloatSetting(*scene.runtime, g.zoom_setting)->getFloat();
        }
        if (g.camerashake || HasDynamicSetting(g.camerashake_setting)) {
            const auto setting = [](const nlohmann::json& authored, auto value) {
                return authored.is_null() ? nlohmann::json(value) : authored;
            };
            auto& runtime = *scene.runtime;
            runtime.RegisterCameraShake(
                ResolveBoolSetting(runtime, setting(g.camerashake_setting, g.camerashake)),
                ResolveFloatSetting(runtime,
                                    setting(g.camerashakeamplitude_setting, g.camerashakeamplitude)),
                ResolveFloatSetting(runtime, setting(g.camerashakespeed_setting, g.camerashakespeed)),
                ResolveFloatSetting(runtime,
                                    setting(g.camerashakeroughness_setting, g.camerashakeroughness)));
        }
    }
    scene.fog_height = sc.general.fogheight;
    // Wallpaper Engine renders in HDR only when the scene asks for HDR and has
    // bloom on (its bloom switch read above, a bound one at its property's
    // value); an HDR scene without bloom is drawn as an ordinary one.
    scene.hdr = sc.general.hdr && sc.general.bloom;
    context.ortho_w = scene.ortho[0];
    context.ortho_h = scene.ortho[1];
    context.is_ortho = sc.general.isOrtho;
    context.pixel_canvas = sc.general.pixelCanvas;

    {
        auto& gb              = context.global_base_uniforms;
        gb["g_ViewUp"]        = std::array { 0.0f, 1.0f, 0.0f };
        gb["g_ViewRight"]     = std::array { 1.0f, 0.0f, 0.0f };
        gb["g_ViewForward"]   = std::array { 0.0f, 0.0f, -1.0f };
        gb["g_EyePosition"]   = std::array { 0.0f, 0.0f, 0.0f };
        gb["g_TexelSize"]     = std::array { 1.0f / 1920.0f, 1.0f / 1080.0f };
        gb["g_TexelSizeHalf"] = std::array { 1.0f / 1920.0f / 2.0f, 1.0f / 1080.0f / 2.0f };

        gb["g_LightAmbientColor"]  = sc.general.ambientcolor;
        gb["g_LightSkylightColor"] = sc.general.skylightcolor;
        // Fog runs from its start to its end, density from its start density
        // to its end density: (start, end - start, start density, density span).
        const auto& g              = sc.general;
        gb["g_FogDistanceColor"]   = g.fogdistancecolor;
        gb["g_FogDistanceParams"]  = std::array { g.fogdistancestart,
                                                  g.fogdistanceend - g.fogdistancestart,
                                                  g.fogdistancestartdensity,
                                                  g.fogdistanceenddensity - g.fogdistancestartdensity };
        gb["g_FogHeightColor"]     = g.fogheightcolor;
        gb["g_FogHeightParams"]    = std::array { g.fogheightstart,
                                                  g.fogheightend - g.fogheightstart,
                                                  g.fogheightstartdensity,
                                                  g.fogheightenddensity - g.fogheightstartdensity };
        // std140 mat3 is three vec4 columns (48 bytes). A mat4 identity is 64
        // bytes and spills into the following view-projection uniform.
        gb["g_NormalModelMatrix"] = std::array<float, 12> {
            1.0f, 0.0f, 0.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 0.0f,
            0.0f, 0.0f, 1.0f, 0.0f,
        };
    }

    {
        WPCameraParallax cam_para;
        cam_para.enable         = sc.general.cameraparallax;
        cam_para.amount         = sc.general.cameraparallaxamount;
        cam_para.delay          = sc.general.cameraparallaxdelay;
        cam_para.mouseinfluence = sc.general.cameraparallaxmouseinfluence;
        cam_para.canvas_scene   = context.is_ortho;
        context.shader_updater->SetCameraParallax(cam_para);
        if (context.scene->runtime != nullptr &&
            HasDynamicSetting(sc.general.cameraparallaxdelay_setting)) {
            context.scene->runtime->RegisterDynamicValueListener(
                ResolveFloatSetting(*context.scene->runtime,
                                    sc.general.cameraparallaxdelay_setting),
                [updater = context.shader_updater, cam_para](const DynamicValue& value) {
                    auto parallax  = cam_para;
                    parallax.delay = value.getFloat();
                    updater->SetCameraParallax(parallax);
                });
        }
    }
}

/// Wallpaper Engine composes a layer from the flags and shader of its model, not
/// from the model's path. These are the editor's two models of that kind: the
/// composition layer, and the one that also tests depth.
bool IsComposeLayerModel(std::string_view image) {
    return image == "models/util/composelayer.json" ||
           image == "models/util/composelayer_depthtest.json";
}

// Whether a picture the project's properties choose takes a slot of a solid
// instance layer's placeholder, resolved exactly as its material will be.
bool PropertyPictureReplacesPlaceholder(const wpscene::WPImageObject& layer,
                                        const ProjectProperties&      properties) {
    if (layer.instance_usertextures.empty()) return false;
    auto textures = layer.material.textures;
    ApplySystemUserTextures(textures, layer.instance_usertextures, &properties);
    return textures != layer.material.textures;
}

void ParseImageObj(ParseContext& context, wpscene::WPImageObject& img_obj) {
    auto& wpimgobj = img_obj;
    const auto runtime_name = LayerRuntimeName(context, wpimgobj);

    auto& vfs = *context.vfs;

    // A solid placeholder's colour paints its `util/white`, not a picture that
    // replaces it: Wallpaper Engine shows a picture chosen for the slot (a
    // preset's `files/...`, or the user's own) as it is. Left on, a dark scheme
    // colour multiplied a whole background to black. A cover the runtime
    // supplies was settled by the layer itself; a property is settled here, by
    // the values the scene loads with, which a running scene holds (the slot is
    // load-only). With no picture chosen the layer stays a solid colour.
    if (context.scene->runtime != nullptr &&
        PropertyPictureReplacesPlaceholder(wpimgobj,
                                           context.scene->runtime->projectProperties())) {
        wpimgobj.color = { 1.0f, 1.0f, 1.0f };
        if (wpimgobj.field_bindings.is_object()) wpimgobj.field_bindings.erase("color");
    }

    const bool isCompose = IsComposeLayerModel(wpimgobj.image);
    ResolveUserEffectVisibility(context, wpimgobj.effects, runtime_name);

    // A colour blend mode mixes the layer with the screen behind it through
    // Wallpaper Engine's passthrough material, appended as the last effect.
    // Mode 31 ("add") is the exception: Wallpaper Engine draws that layer with
    // additive blending straight onto the scene, with no passthrough and no
    // copy of the screen.
    const bool additive_color_blend = wpimgobj.colorBlendMode == kAdditiveColorBlendMode;
    bool color_blend_passthrough = false;
    std::optional<usize> color_blend_effect;
    // The skinned pass of a puppet that has effects is a pass of the layer's own
    // material, appended to the effects: it draws the layer, with its alpha.
    std::optional<usize> puppet_layer_effect;
    if (wpimgobj.colorBlendMode != 0 && ! additive_color_blend) {
        auto colorEffect = MakeColorBlendEffect(vfs, wpimgobj.colorBlendMode);
        if (! colorEffect) return;
        wpimgobj.effects.push_back(std::move(*colorEffect));
        color_blend_passthrough = true;
        color_blend_effect      = wpimgobj.effects.size() - 1;
    }

    int32_t count_eff = 0;
    for (const auto& wpeffobj : wpimgobj.effects) {
        if (EffectIsBuilt(wpeffobj)) {
            count_eff++;
        }
    }
    // A layer that draws through effects is first drawn into a card of its own,
    // from an ortho camera and with no transform, where fog measured from the
    // eye would follow the place in the card and not the layer's. Wallpaper
    // Engine fogs it where it sits, in the pass that composites it onto the
    // scene: the chain ends in `effectpassthrough_4` with the scene's fog, and
    // the passes before it carry none. Only a layer whose own material takes
    // fog gets that pass (added below, once the material has told), and a layer
    // drawn at its own place, with no card, is unchanged. Compose, fullscreen
    // and puppet layers and the one that blends onto the screen keep their fog
    // where it was.
    std::optional<wpscene::WPImageEffect> fog_composite;
    std::optional<usize>                  fog_composite_effect;
    if ((context.scene->fog_distance || context.scene->fog_height) && count_eff > 0 &&
        ! isCompose && ! wpimgobj.fullscreen && wpimgobj.puppet.empty() &&
        ! color_blend_passthrough) {
        fog_composite = MakeFogCompositeEffect(vfs);
    }
    const bool has_child_content =
        context.object_list != nullptr && HasChildObject(*context.object_list, wpimgobj.id);
    // A post-processing layer holds the layers saved below it in its own picture
    // and runs its effects over all of it, as a composition layer does over its
    // children, but over the whole screen.
    const bool fullscreen_holds_children =
        wpimgobj.fullscreen && wpimgobj.config.passthrough && has_child_content && count_eff > 0;
    const bool render_as_compose =
        (isCompose && has_child_content && (! wpimgobj.copybackground || count_eff > 0)) ||
        fullscreen_holds_children;
    bool hasEffect = count_eff > 0 || render_as_compose || (isCompose && ! wpimgobj.copybackground);

    bool hasPuppet = ! wpimgobj.puppet.empty();
    (void)hasPuppet;

    std::unique_ptr<WPMdl> puppet;
    bool                   has_puppet_bones = false;
    bool                   has_puppet_mesh  = false;
    if (! wpimgobj.puppet.empty()) {
        puppet = std::make_unique<WPMdl>();
        if (! WPMdlParser::Parse(wpimgobj.puppet, vfs, *puppet)) {
            LOG_ERROR("parse puppet failed: %s", wpimgobj.puppet.c_str());
            puppet = nullptr;
        } else {
            has_puppet_bones = PuppetHasBones(*puppet);
            has_puppet_mesh  = PuppetHasMeshData(*puppet);
            if (! has_puppet_bones && ! has_puppet_mesh) {
                LOG_ERROR("puppet has no mesh data: %s", wpimgobj.puppet.c_str());
                puppet = nullptr;
            } else if (puppet->puppet != nullptr) {
                context.layer_puppets[wpimgobj.id] = puppet->puppet;
                // Single playback state per image object: every render pass,
                // attachment group and the runtime take copies of this one.
                auto layer = WPPuppetLayer(puppet->puppet);
                layer.prepared(wpimgobj.puppet_layers);
                context.layer_puppet_animations.emplace(wpimgobj.id, std::move(layer));
            }
        }
    }

    // What the scene saved for a fullscreen layer places its children; the layer
    // itself is drawn over the whole screen, whatever that is.
    const Vector3f fullscreen_saved_origin(wpimgobj.origin.data());
    const Vector3f fullscreen_saved_scale(wpimgobj.scale.data());
    const Vector3f fullscreen_saved_angles(wpimgobj.angles.data());
    if (wpimgobj.fullscreen) {
        wpimgobj.size[0]   = static_cast<float>(context.ortho_w);
        wpimgobj.size[1]   = static_cast<float>(context.ortho_h);
        wpimgobj.origin[0] = static_cast<float>(context.ortho_w) * 0.5f;
        wpimgobj.origin[1] = static_cast<float>(context.ortho_h) * 0.5f;
        wpimgobj.scale  = { 1.0f, 1.0f, 1.0f };
        wpimgobj.angles = { 0.0f, 0.0f, 0.0f };
        // Nor does camera parallax move it: it copies the screen and draws it
        // back over the whole screen, wherever the cursor is. The file's depth
        // is never read for it, and the depth a layer has when none is saved
        // drew that copy shifted over the scene it copied. The layers below it
        // take their tree's depth from the scene file (ResolveLayerParallax).
        wpimgobj.parallaxDepth = { 0.0f, 0.0f };
    } else if (wpimgobj.autosize && wpimgobj.projectlayer) {
        // A project layer is as large as the scene's canvas, whatever size the
        // scene file saved for it; where it sits is the scene file's.
        wpimgobj.size[0] = static_cast<float>(context.ortho_w);
        wpimgobj.size[1] = static_cast<float>(context.ortho_h);
    }

    // wpimgobj.origin[1] = context.ortho_h - wpimgobj.origin[1];
    auto       spImgNode = std::make_shared<SceneNode>(Vector3f(wpimgobj.origin.data()),
                                                 Vector3f(wpimgobj.scale.data()),
                                                 Vector3f(wpimgobj.angles.data()),
                                                 runtime_name);
    context.layer_nodes[wpimgobj.id] = spImgNode;
    spImgNode->SetVisible(wpimgobj.visible);
    // Wallpaper Engine lays a fullscreen layer over the whole screen, whichever
    // group it sits in: the group decides whether it shows, never where.
    spImgNode->SetIgnoreParentTransform(wpimgobj.fullscreen);
    // The layers below it are placed from the transform saved for the layer
    // (none saved, none added), under the groups it sits in: a picture saved at
    // the middle of the canvas under a post-processing layer with no origin is
    // at the middle of the canvas, not a whole canvas away.
    if (wpimgobj.fullscreen) {
        spImgNode->SetChildFrame(fullscreen_saved_origin, fullscreen_saved_scale,
                                 fullscreen_saved_angles);
    }
    RuntimeNodeRegistrationRollback runtime_node_registration(
        context.scene->runtime.get(),
        runtime_name,
        spImgNode.get(),
        &context.layer_nodes,
        wpimgobj.id,
        &context.pending_scene_scripts);
    auto registerImageNode = [&context, &wpimgobj, &spImgNode]() {
        context.layer_parent_ids[wpimgobj.id] = wpimgobj.parent_id;
    };
    // A colour bound to a user property or a script, or keyed on a timeline, and
    // the materials it has to reach: every one that takes the layer's `g_Color4`,
    // as its alpha does. The brightness multiplies that colour where the scene
    // renders HDR, and is followed the same way when a property or a script
    // drives it. A binding is the colour's only writer; a timeline plays only
    // where there is none.
    std::unique_ptr<DynamicValue>               bound_color;
    std::vector<std::shared_ptr<SceneMaterial>> bound_color_materials;
    std::shared_ptr<const NodeVec3Animation>    color_animation;
    std::vector<std::shared_ptr<SceneMaterial>> color_animation_materials;
    std::unique_ptr<DynamicValue>               bound_brightness;
    std::vector<std::shared_ptr<SceneMaterial>> bound_brightness_materials;
    float                                       tint_brightness = 1.0f;
    const auto tintLayerMaterial = [&wpimgobj, &bound_color, &bound_color_materials, &color_animation,
                                    &color_animation_materials, &bound_brightness,
                                    &bound_brightness_materials,
                                    &tint_brightness](const std::shared_ptr<SceneMaterial>& material) {
        if (material == nullptr) return;
        material->tint = SceneMaterialTint { wpimgobj.color, tint_brightness };
        if (bound_color != nullptr) bound_color_materials.push_back(material);
        if (color_animation != nullptr) color_animation_materials.push_back(material);
        if (bound_brightness != nullptr) bound_brightness_materials.push_back(material);
    };
    std::vector<std::shared_ptr<SceneMaterial>> alpha_materials;
    const auto registerImageLayerMaterial = [&context, &wpimgobj, &runtime_name, &tintLayerMaterial,
                                             &alpha_materials](std::shared_ptr<SceneMaterial> material) {
        tintLayerMaterial(material);
        RegisterLayerAlpha(context, runtime_name, wpimgobj.alpha_setting, wpimgobj.alpha,
                           std::move(material), alpha_materials);
    };
    // A scripted or user-bound origin replaces the node translate every tick, so
    // an anchor baked into the translate is lost. Hand the anchor to the runtime
    // instead, which re-derives the offset from the current origin, scale and size.
    const bool runtime_owns_anchor =
        context.scene->runtime != nullptr && AlignmentHasAnchorOffset(wpimgobj.alignment);
    if (context.scene->runtime != nullptr) {
        context.scene->runtime->RegisterNode(runtime_name, spImgNode.get());
        context.scene->runtime->SetNodeCursorTarget(runtime_name, true, wpimgobj.solid,
                                                    wpimgobj.disablepropagation);
        if (const auto layer = context.layer_puppet_animations.find(wpimgobj.id);
            layer != context.layer_puppet_animations.end()) {
            context.scene->runtime->RegisterPuppetLayer(runtime_name, layer->second);
            BindPuppetAnimationLayerSettings(context, runtime_name, wpimgobj, layer->second);
        }
        context.scene->runtime->RegisterNodeSize(
            runtime_name,
            Eigen::Vector2f(static_cast<float>(wpimgobj.size[0]),
                            static_cast<float>(wpimgobj.size[1])));
        if (runtime_owns_anchor) {
            context.scene->runtime->SetNodeAnchorAlignment(
                runtime_name, wpimgobj.alignment, Vector3f(wpimgobj.origin.data()));
        }
        context.scene->runtime->RegisterNodeVisibility(
            runtime_name,
            spImgNode.get(),
            ResolveBoolSetting(*context.scene->runtime,
                               wpimgobj.dynamic_visible ? wpimgobj.visible_setting
                                                        : nlohmann::json(wpimgobj.visible),
                               runtime_name));
        spImgNode->SetVisibilitySettled(VisibilitySettledBy(wpimgobj.visible_setting));
        RegisterNodeTransformSettings(*context.scene->runtime, spImgNode.get(), runtime_name,
                                      wpimgobj.origin_setting, wpimgobj.scale_setting,
                                      wpimgobj.angles_setting);
    }
    QueueSceneScriptIfNeeded(context, runtime_name, wpimgobj.visible_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, wpimgobj.origin_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, wpimgobj.scale_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, wpimgobj.angles_setting);
    if (const auto setting = wpimgobj.field_bindings.find("color");
        setting != wpimgobj.field_bindings.end()) {
        QueueSceneScriptIfNeeded(context, runtime_name, *setting);
    }
    if (! runtime_owns_anchor) {
        LoadAlignment(*spImgNode, wpimgobj.alignment, { wpimgobj.size[0], wpimgobj.size[1] });
    }
    spImgNode->ID() = wpimgobj.id;
    if (context.referenced_layer_ids.contains(wpimgobj.id)) {
        RegisterImageComposite(context, wpimgobj, *spImgNode);
    }

    // A card with no area (a size of 0 on one axis) draws nothing on screen.
    // A layer that draws into targets of its own -- its effects' buffers, the
    // composite another layer samples -- fills them all the same, as any card
    // fills the targets made at its render extent: an audio widget's spectrum
    // buffer, 64 wide and 0 high, carried nothing into the composite its bars
    // read. Such a card takes the render extent and is drawn only there.
    const bool card_has_no_area = ! (wpimgobj.size[0] > 0.0f) || ! (wpimgobj.size[1] > 0.0f);
    const bool card_fills_own_targets =
        card_has_no_area && (hasEffect || context.referenced_layer_ids.contains(wpimgobj.id));
    // A compose layer that only copies the background behind it adds nothing on
    // screen. Sampled by another layer, though, its card is that background --
    // a mask over later layers paints it back -- so it is drawn there alone.
    // With effects, it is the chain's last pass that is drawn there alone.
    const bool composite_only =
        ! hasEffect && ((isCompose && context.referenced_layer_ids.contains(wpimgobj.id)) ||
                        card_fills_own_targets);
    spImgNode->SetCompositeOnly(composite_only);
    const bool skipComposeRender = isCompose && ! hasEffect && ! composite_only;
    if (skipComposeRender) {
        registerImageNode();
        runtime_node_registration.Commit();
        return;
    }

    if (wpimgobj.config.passthrough && ! hasEffect && ! isCompose) {
        registerImageNode();
        runtime_node_registration.Commit();
        return;
    }

    // The scene file's colour is only the property's default: a preset or the
    // user's own choice replaces it, so the layer is built with that value. A
    // script's value replaces it from the first tick on, as it does on a text
    // layer, and until then the layer holds the scene file's. With neither, a
    // colour keyed on a timeline is built with its first colour and follows the
    // clock from there.
    if (context.scene->runtime != nullptr) {
        if (const auto setting = wpimgobj.field_bindings.find("color");
            setting != wpimgobj.field_bindings.end()) {
            if (HasDynamicSetting(*setting)) {
                bound_color = ResolveVec3Setting(*context.scene->runtime, *setting, runtime_name);
                const auto color = bound_color->getVec3();
                wpimgobj.color   = { color.x(), color.y(), color.z() };
            } else if ((color_animation = ResolveVec3Animation(*context.scene->runtime,
                                                                runtime_name, *setting))) {
                wpimgobj.color = color_animation->Value();
            }
        }
    }
    // Likewise the brightness: a property's value replaces the scene file's, and
    // a script's runs with the scene. Wallpaper Engine multiplies it into the
    // layer's colour only where it renders HDR; elsewhere it is 1, and a bound
    // brightness has no material to follow.
    if (context.scene->runtime != nullptr) {
        if (const auto setting = wpimgobj.field_bindings.find("brightness");
            setting != wpimgobj.field_bindings.end()) {
            bound_brightness = ResolveFloatSetting(*context.scene->runtime, *setting, runtime_name);
            wpimgobj.brightness = bound_brightness->getFloat();
            QueueSceneScriptIfNeeded(context, runtime_name, *setting);
        }
    }
    tint_brightness = context.scene->hdr ? wpimgobj.brightness : 1.0f;
    if (! context.scene->hdr && bound_brightness != nullptr) {
        context.scene->runtime->BindMaterialBrightness({}, std::move(bound_brightness));
    }

    SceneMaterial     material;
    WPShaderValueData svData;

    ShaderValueMap baseConstSvs = context.global_base_uniforms;
    WPShaderInfo   shaderInfo;
    {
        if (! hasEffect) {
            svData.parallaxDepth = { wpimgobj.parallaxDepth[0], wpimgobj.parallaxDepth[1] };
            if (puppet && has_puppet_bones) {
                WPMdlParser::AddPuppetShaderInfo(shaderInfo, *puppet);
            }
        }

        // The layer's brightness reaches the shader here, in the colour, and
        // nowhere else: the `g_Brightness` of the older generic shaders is their
        // material's own constant.
        baseConstSvs["g_Color4"] = std::array<float, 4> {
            wpimgobj.color[0] * tint_brightness,
            wpimgobj.color[1] * tint_brightness,
            wpimgobj.color[2] * tint_brightness,
            wpimgobj.alpha,
        };
        baseConstSvs["g_Color"] =
            std::array<float, 3> { wpimgobj.color[0], wpimgobj.color[1], wpimgobj.color[2] };
        baseConstSvs["g_Alpha"]      = wpimgobj.alpha;
        baseConstSvs["g_UserAlpha"]  = wpimgobj.alpha;

        shaderInfo.baseConstSvs = baseConstSvs;

        // Effects on a puppet run over its unassembled texture sheet. The
        // final skinned pass below uses the authored material in world space;
        // lighting the sheet as well both darkens it twice and bakes different
        // illumination into adjacent cut-out pieces (notably eyelids).
        auto input_material = wpimgobj.material;
        if (hasEffect && has_puppet_bones) {
            input_material.combos["LIGHTING"] = 0;
        }
        shaderInfo.defer_fog = fog_composite.has_value();
        if (! LoadMaterial(vfs,
                           input_material,
                           context.scene.get(),
                           spImgNode.get(),
                           &material,
                           &svData,
                           &shaderInfo)) {
            LOG_ERROR("load imageobj '%s' material faild", wpimgobj.name.c_str());
            return;
        };
        LoadConstvalue(material, wpimgobj.material, shaderInfo);
        if (fog_composite.has_value() && shaderInfo.fog_deferred) {
            wpimgobj.effects.push_back(std::move(*fog_composite));
            fog_composite_effect = wpimgobj.effects.size() - 1;
        }
    }

    // mesh
    // A pass-through layer drawn through effects copies the part of the screen it
    // is drawn over into its card, laid out from where the layer is drawn
    // (PassthroughCard): again once it is under its groups, and by the runtime
    // whenever they move it while the scene runs.
    std::shared_ptr<PassthroughCard> passthrough_card;
    if (! puppet && wpimgobj.config.passthrough && hasEffect && ! (isCompose && count_eff > 0)) {
        passthrough_card = std::make_shared<PassthroughCard>(PassthroughCard {
            .size              = { (uint16_t)wpimgobj.size[0], (uint16_t)wpimgobj.size[1] },
            .clip_space        = material.name == "passthrough",
            .projection_width  = context.ortho_w,
            .projection_height = context.ortho_h,
        });
    }
    SceneMesh                                      effct_final_mesh {};
    auto                                           spMesh = std::make_shared<SceneMesh>(
        passthrough_card != nullptr ? MeshUpdate::OnEvent : MeshUpdate::Fixed);
    auto&                                          mesh   = *spMesh;
    std::optional<std::vector<LoadedMaterialSlot>> puppet_material_slots;

    {
        // deal with pow of 2
        std::array<float, 2> mapRate { 1.0f, 1.0f };
        if (! wpimgobj.nopadding &&
            exists(material.customShader.constValues, WE_GLTEX_RESOLUTION_NAMES[0])) {
            const auto& r = material.customShader.constValues.at(WE_GLTEX_RESOLUTION_NAMES[0]);
            mapRate       = { r[2] / r[0], r[3] / r[1] };
        }

        if (puppet) {
            if (hasEffect) {
                GenCardMesh(
                    mesh, { (uint16_t)wpimgobj.size[0], (uint16_t)wpimgobj.size[1] }, mapRate);
                GenPuppetMeshSubmeshes(effct_final_mesh, *puppet, false);

                if (has_puppet_bones) {
                    wpscene::WPImageEffect puppet_effect;
                    wpscene::WPMaterial    puppet_mat;
                    puppet_mat             = wpimgobj.material;
                    puppet_mat.textures[0] = "";
                    WPMdlParser::AddPuppetMatInfo(puppet_mat, *puppet);
                    // The skinned pass is the one drawn on screen, so it blends
                    // with the screen itself. The passthrough appended above
                    // would run before it, over the texture sheet, and sample
                    // the whole screen squeezed into the layer's bounds.
                    if (color_blend_passthrough) {
                        wpimgobj.effects.pop_back();
                        color_blend_effect.reset();
                        puppet_mat.combos["BLENDMODE"] = wpimgobj.colorBlendMode;
                    }
                    puppet_effect.materials.push_back(puppet_mat);
                    wpimgobj.effects.push_back(puppet_effect);
                    puppet_layer_effect = wpimgobj.effects.size() - 1;
                }
            } else {
                if (has_puppet_bones) {
                    svData.puppet_layer = context.layer_puppet_animations.at(wpimgobj.id);
                }
                GenPuppetMeshSubmeshes(mesh, *puppet, true);
                puppet_material_slots = TryLoadPuppetMaterialSlots(
                    context, spImgNode.get(), wpimgobj, *puppet, baseConstSvs, svData);
            }
        }
        std::array<uint16_t, 2> card { (uint16_t)wpimgobj.size[0], (uint16_t)wpimgobj.size[1] };
        if (card_fills_own_targets) {
            const auto extent = ResolveImageRenderExtent(wpimgobj, context);
            card = { (uint16_t)extent[0], (uint16_t)extent[1] };
        }
        if (! puppet) {
            if (passthrough_card != nullptr) {
                // Laid out from the layer's own transform for now, and again from
                // where its groups put it once it is under them
                // (LayOutPassthroughCards).
                passthrough_card->LayOut(mesh, spImgNode->GetLocalTrans());
                context.passthrough_cards.push_back(ParseContext::PendingPassthroughCard {
                    .node = spImgNode,
                    .mesh = spMesh,
                    .card = passthrough_card,
                });
            } else {
                GenCardMesh(mesh, card, mapRate);
            }
            GenCardMesh(effct_final_mesh, card);
        }
    }
    // material blendmode for last step to use
    auto imgBlendMode = additive_color_blend ? BlendMode::Additive : material.blenmode;
    // And the depth test and write the layer authored: the chain's last pass
    // draws the layer into the scene with them, not with the state its effect
    // pass authored. A layer that Wallpaper Engine sorts, in a scene that sorts,
    // is drawn without the write: it is drawn back to front there, where the
    // write hides nothing that comes after it, and in scene order it would cut
    // the layer's whole card out of every farther layer drawn later. A layer
    // that stays in the scene's first, scene-order set keeps its write, which
    // hides the farther sorted layers drawn after it as it does there.
    const bool imgDepthTest = material.depth_test;
    const bool imgDepthWrite =
        material.depth_write &&
        ! (context.scene->opaque_first && ImageLayerIsSorted(material.blenmode));
    // disable img material blend, as it's the first effect node now
    if (hasEffect) {
        material.blenmode = BlendMode::Normal;
    } else if (additive_color_blend) {
        material.blenmode = BlendMode::Additive;
    }
    if (puppet_material_slots.has_value()) {
        for (auto& slot : *puppet_material_slots) {
            if (additive_color_blend) slot.material.blenmode = BlendMode::Additive;
            mesh.AddMaterial(std::move(slot.material));
            const auto material_slot_index = static_cast<uint32_t>(mesh.MaterialSlots().size() - 1);
            auto        material_slot      = mesh.MaterialSlotPtr(material_slot_index);
            context.shader_updater->SetNodeData(
                spImgNode.get(), material_slot_index, slot.shader_value_data);
            RegisterMaterialConstants(context, material_slot, slot.source, slot.shader_info, runtime_name);
            registerImageLayerMaterial(material_slot);
            RegisterNodeVideoTextureRuntime(context, runtime_name, material_slot.get());
        }
    } else {
        mesh.AddMaterial(std::move(material));
        RemapSubmeshesToMaterialSlot(mesh, 0);
        RegisterMaterialConstants(context, spMesh->MaterialSlotPtr(), wpimgobj.material, shaderInfo, runtime_name);
        registerImageLayerMaterial(spMesh->MaterialSlotPtr());
        RegisterNodeVideoTextureRuntime(context, runtime_name, spMesh->Material());
    }
    spImgNode->AddMesh(spMesh);

    if (! puppet_material_slots.has_value()) {
        context.shader_updater->SetNodeData(spImgNode.get(), svData);
    }
    if (hasEffect) {
        auto& scene = *context.scene;
        // currently use addr for unique
        std::string nodeAddr = getAddr(spImgNode.get());
        const auto render_extent = ResolveImageRenderExtent(wpimgobj, context);
        // set camera to attatch effect
        if (render_as_compose) {
            scene.cameras[nodeAddr] = std::make_shared<SceneCamera>(
                render_extent[0], render_extent[1], -1.0f, 1.0f);
            scene.cameras.at(nodeAddr)->SetComposeLayer(true);
            // A fullscreen layer keeps the scene camera: Wallpaper Engine frames
            // a composition layer's children with a camera of the layer's own
            // only when the layer is not fullscreen.
            scene.cameras.at(nodeAddr)->SetChildrenUseSceneCamera(wpimgobj.fullscreen);
            scene.cameras.at(nodeAddr)->AttatchNode(spImgNode);
        } else {
            // applly scale to crop
            scene.cameras[nodeAddr] =
                std::make_shared<SceneCamera>(render_extent[0], render_extent[1], -1.0f, 1.0f);
            scene.cameras.at(nodeAddr)->AttatchNode(context.effect_camera_node);
        }
        spImgNode->SetCamera(nodeAddr);
        std::string effect_ppong_a, effect_ppong_b;
        effect_ppong_a = WE_EFFECT_PPONG_PREFIX_A.data() + nodeAddr;
        effect_ppong_b = WE_EFFECT_PPONG_PREFIX_B.data() + nodeAddr;
        // set image effect
        auto imgEffectLayer = std::make_shared<SceneImageEffectLayer>(
            spImgNode.get(),
            static_cast<float>(render_extent[0]),
            static_cast<float>(render_extent[1]),
            effect_ppong_a,
            effect_ppong_b);
        {
            imgEffectLayer->SetFinalBlend(imgBlendMode);
            imgEffectLayer->SetFinalDepth(imgDepthTest, imgDepthWrite);
            if (wpimgobj.fullscreen) {
                imgEffectLayer->SetFinalCamera(std::string(FullscreenLayerCamera));
            }
            imgEffectLayer->FinalMesh().ChangeMeshDataFrom(effct_final_mesh);
            imgEffectLayer->FinalNode().CopyTrans(*spImgNode);
            imgEffectLayer->SetFinalCompositeOnly(card_fills_own_targets);
            if (! render_as_compose) {
                spImgNode->SetRenderTransformOverride(Eigen::Matrix4d::Identity());
            } else {
                spImgNode->ClearRenderTransformOverride();
            }
            if (! wpimgobj.copybackground) {
                spImgNode->SetSkipRenderPass(true);
            }
            scene.cameras.at(nodeAddr)->AttatchImgEffect(imgEffectLayer);
            if (context.scene->runtime != nullptr) {
                context.scene->runtime->RegisterNodeEffectFinal(
                    runtime_name, spImgNode.get(), imgEffectLayer.get(), {}, passthrough_card);
            }
        }
        // set renderTarget for ping-pong operate
        {
            scene.renderTargets[effect_ppong_a] = {
                .width      = render_extent[0],
                .height     = render_extent[1],
                .allowReuse = true,
                .sample     = LayerRenderTargetSample(scene, wpimgobj),
                .format = scene.hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8,
            };
            if (wpimgobj.fullscreen) {
                scene.renderTargets[effect_ppong_a].bind = { .enable = true, .screen = true };
            }
            scene.renderTargets[effect_ppong_b] = scene.renderTargets.at(effect_ppong_a);
        }
        // Draws the layer's own picture through unchanged: the whole chain of
        // a compose layer without effects, and the fallback of a chain whose
        // effects a script can all switch off. A compose layer's own pass reads no
        // `g_Color4`, so its colour and alpha land here, once, and follow whatever
        // drives them as the passes of a layer with an image do. On any other layer
        // the first pass has applied them already, and the passthrough draws with
        // white, as the one that blends the layer onto the screen does: the layer
        // is drawn as one without effects.
        const auto make_passthrough_effect = [&]() -> std::shared_ptr<SceneImageEffect> {
            auto passthrough_svs = baseConstSvs;
            if (! render_as_compose) {
                passthrough_svs["g_Color4"] = std::array<float, 4> { 1.0f, 1.0f, 1.0f, 1.0f };
            }
            std::shared_ptr<SceneMaterial> slot;
            auto effect = MakePassthroughEffect(context, effect_ppong_a, passthrough_svs,
                                                runtime_name, wpimgobj.name, &slot);
            if (effect != nullptr && render_as_compose) {
                tintLayerMaterial(slot);
                RegisterLayerAlpha(context, runtime_name, wpimgobj.alpha_setting,
                                   wpimgobj.alpha, slot, alpha_materials);
            }
            return effect;
        };
        if (render_as_compose && wpimgobj.effects.empty()) {
            if (auto passthrough = make_passthrough_effect()) imgEffectLayer->AddEffect(passthrough);
        }

        int32_t i_eff = -1;
        int     scripted_effects = 0, fixed_effects = 0;
        for (const auto& wpeffobj : wpimgobj.effects) {
            i_eff++;
            // Wallpaper Engine draws the passthrough that blends the layer
            // onto the screen with a white colour: the layer's own colour and
            // alpha are already in what it blends, from the layer's first pass.
            // The pass that fogs the layer is the same copy of the chain.
            const bool is_fog_composite =
                fog_composite_effect.has_value() && &wpeffobj == &wpimgobj.effects[*fog_composite_effect];
            const bool blends_onto_screen =
                is_fog_composite ||
                (color_blend_effect.has_value() && &wpeffobj == &wpimgobj.effects[*color_blend_effect]);
            const bool is_layer_pass =
                puppet_layer_effect.has_value() && &wpeffobj == &wpimgobj.effects[*puppet_layer_effect];
            if (! EffectIsBuilt(wpeffobj)) {
                i_eff--;
                continue;
            }
            std::shared_ptr<SceneImageEffect> imgEffect = std::make_shared<SceneImageEffect>();

            // this will be replace when resolve, use here to get rt info
            const std::string inRT { effect_ppong_a };

            // fbo name map and effect command
            std::string effaddr = getAddr(imgEffectLayer.get());

            std::unordered_map<std::string, std::string> fboMap;
            {
                fboMap["previous"] = inRT;
                for (usize i = 0; i < wpeffobj.fbos.size(); i++) {
                    const auto& wpfbo  = wpeffobj.fbos.at(i);
                    std::string rtname = EnsureSpecTexName(wpfbo.name + "_" + effaddr);
                    if (wpimgobj.fullscreen) {
                        scene.renderTargets[rtname]      = { 2, 2, true };
                        scene.renderTargets[rtname].bind = {
                            .enable = true,
                            .screen = true,
                            .scale  = 1.0 / static_cast<double>(wpfbo.scale),
                        };
                    } else {
                        // i+2 for not override object's rt
                        scene.renderTargets[rtname] = {
                            .width      = ResolveRenderTargetDimension(
                                static_cast<float>(render_extent[0]), wpfbo.scale),
                            .height     = ResolveRenderTargetDimension(
                                static_cast<float>(render_extent[1]), wpfbo.scale),
                            .allowReuse = true
                        };
                    }
                    scene.renderTargets[rtname].format = EffectFboFormat(wpfbo.format, scene.hdr);
                    if (! wpimgobj.fullscreen) {
                        if (const auto fixed =
                                FixedEffectFboExtent(wpfbo,
                                                     static_cast<float>(render_extent[0]),
                                                     static_cast<float>(render_extent[1]))) {
                            scene.renderTargets[rtname].width  = (*fixed)[0];
                            scene.renderTargets[rtname].height = (*fixed)[1];
                        }
                    }
                    fboMap[wpfbo.name] = rtname;
                }
            }
            LowerEffectCommands(wpeffobj, fboMap, scene, imgEffect->commands);

            bool eff_mat_ok { true };

            for (usize i_mat = 0; i_mat < wpeffobj.materials.size(); i_mat++) {
                wpscene::WPMaterial wpmat = wpeffobj.materials.at(i_mat);
                std::string         matOutRT { WE_EFFECT_PPONG_PREFIX_B };
                if (wpeffobj.passes.size() > i_mat) {
                    const auto& wppass = wpeffobj.passes.at(i_mat);
                    wpmat.MergePass(wppass);
                    // Set rendertarget, in and out
                    for (const auto& el : wppass.bind) {
                        if (fboMap.count(el.name) == 0) {
                            LOG_ERROR("fbo %s not found", el.name.c_str());
                            continue;
                        }
                        if (wpmat.textures.size() <= (usize)el.index)
                            wpmat.textures.resize((usize)el.index + 1);
                        wpmat.textures[(usize)el.index] = fboMap[el.name];
                    }
                    if (! wppass.target.empty()) {
                        if (fboMap.count(wppass.target) == 0) {
                            LOG_ERROR("fbo %s not found", wppass.target.c_str());
                        } else {
                            matOutRT = fboMap.at(wppass.target);
                        }
                    }
                }
                BindOwnEffectChainInput(wpmat, wpimgobj.id, inRT);
                if (wpmat.textures.size() == 0) wpmat.textures.resize(1);
                if (wpmat.textures.at(0).empty()) {
                    wpmat.textures[0] = inRT;
                }
                auto         spEffNode  = std::make_shared<SceneNode>();
                std::string  effmataddr = getAddr(spEffNode.get());
                WPShaderInfo wpEffShaderInfo;
                wpEffShaderInfo.baseConstSvs = baseConstSvs;
                wpEffShaderInfo.baseConstSvs["g_EffectTextureProjectionMatrix"] =
                    ShaderValue::fromMatrix(Eigen::Matrix4f::Identity());
                wpEffShaderInfo.baseConstSvs["g_EffectTextureProjectionMatrixInverse"] =
                    ShaderValue::fromMatrix(Eigen::Matrix4f::Identity());
                if (blends_onto_screen) {
                    wpEffShaderInfo.baseConstSvs["g_Color4"] =
                        std::array<float, 4> { 1.0f, 1.0f, 1.0f, 1.0f };
                }
                // The fog is the composite's alone, applied where the layer sits.
                wpEffShaderInfo.defer_fog = fog_composite_effect.has_value() && ! is_fog_composite;
                SceneMaterial     material;
                WPShaderValueData svData;
                svData.effect_owner   = spImgNode.get();
                svData.parallax_layer = spImgNode.get();
                svData.effect_extent = Eigen::Vector2f(
                    float(render_extent[0]), float(render_extent[1]));
                if (! LoadMaterial(vfs,
                                   wpmat,
                                   context.scene.get(),
                                   spEffNode.get(),
                                   &material,
                                   &svData,
                                   &wpEffShaderInfo)) {
                    eff_mat_ok = false;
                    break;
                }

                // load glname from alias and load to constvalue
                LoadConstvalue(material, wpmat, wpEffShaderInfo);
                // An effect's alpha is its own: the one the effect sets, or the
                // layer's authored alpha it starts from when it sets none. What
                // drives the layer's alpha afterwards reaches the layer's own pass.
                material.own_user_alpha = ! is_layer_pass;
                auto spMesh = std::make_shared<SceneMesh>();
                {
                    svData.parallaxDepth = { wpimgobj.parallaxDepth[0], wpimgobj.parallaxDepth[1] };
                    if (puppet && has_puppet_bones && wpmat.use_puppet) {
                        svData.puppet_layer = context.layer_puppet_animations.at(wpimgobj.id);
                    }
                }
                spMesh->AddMaterial(std::move(material));
                RegisterMaterialConstants(context, spMesh->MaterialSlotPtr(), wpmat, wpEffShaderInfo, runtime_name);
                if (! blends_onto_screen) registerImageLayerMaterial(spMesh->MaterialSlotPtr());
                spEffNode->AddMesh(spMesh);

                context.shader_updater->SetNodeData(spEffNode.get(), svData);
                imgEffect->nodes.push_back({ matOutRT, spEffNode });
            }

            if (eff_mat_ok) {
                RegisterScriptedEffectVisibility(context, wpeffobj, imgEffect, runtime_name);
                imgEffectLayer->AddEffect(imgEffect);
                (wpeffobj.scripted_visible ? scripted_effects : fixed_effects)++;
            } else {
                LOG_ERROR("effect \'%s\' failed to load", wpeffobj.name.c_str());
            }
        }
        // A chain whose every effect a script can switch off still has to draw
        // the layer when they are all off: Wallpaper Engine then draws it as a
        // layer without effects. Here the chain ends in a passthrough that runs
        // only while no other effect does (SceneImageEffectLayer::ResolveEffect).
        if (scripted_effects > 0 && fixed_effects == 0) {
            if (auto fallback = make_passthrough_effect()) {
                fallback->fallback = true;
                imgEffectLayer->AddEffect(fallback);
            }
        }
    }
    registerImageNode();
    runtime_node_registration.Commit();
    if (context.scene->runtime != nullptr) {
        context.scene->runtime->RegisterNodeAlpha(runtime_name, std::move(alpha_materials),
                                                  wpimgobj.alpha);
        if (bound_color != nullptr) {
            context.scene->runtime->BindMaterialColor(runtime_name,
                                                      std::move(bound_color_materials),
                                                      std::move(bound_color));
        } else if (color_animation != nullptr) {
            context.scene->runtime->RegisterMaterialColorAnimation(
                std::move(color_animation_materials), std::move(color_animation));
        }
        if (bound_brightness != nullptr) {
            context.scene->runtime->BindMaterialBrightness(std::move(bound_brightness_materials),
                                                           std::move(bound_brightness));
        }
        context.scene->runtime->RegisterLayerTemplate(
            wpimgobj.image,
            spImgNode,
            Eigen::Vector2f(static_cast<float>(wpimgobj.size[0]),
                            static_cast<float>(wpimgobj.size[1])));
        if (ImageObjectHandlesCursorEvents(wpimgobj)) {
            if (auto mask = BuildImageHitMask(context, wpimgobj); mask.has_value()) {
                context.scene->runtime->RegisterNodeHitMask(runtime_name, std::move(*mask));
            }
        }
    }
}

struct ParticleChildPtr {
    wpscene::ParticleChild* child { nullptr };
    SceneNode*              node_parent { nullptr };
    ParticleSubSystem*      particle_parent { nullptr };

    i32 max_instancecount { 1 };
    Eigen::Vector3f world_scale { Eigen::Vector3f::Ones() };
    /// The parent system's file carries the `worldspace` flag: its particles
    /// are in world units, so a child hangs at its authored origin unscaled.
    bool parent_worldspace { false };

    /// Set for a particle file's second and later `renderer` entries: the
    /// system builds another mesh, material and node for that renderer, and
    /// the subsystem it names draws its particles through it. Nothing is
    /// simulated for it.
    ParticleSubSystem* mirror_of { nullptr };
    std::size_t        renderer_index { 0 };
    wpscene::Particle* mirror_particle { nullptr };
};

void ApplyParticleOverrideDynamicValue(wpscene::ParticleInstanceoverride& over,
                                       const std::string& field,
                                       const DynamicValue& value) {
    if (field == "alpha") {
        over.alpha = value.getFloat();
    } else if (field == "size") {
        over.size = value.getFloat();
    } else if (field == "lifetime") {
        over.lifetime = value.getFloat();
    } else if (field == "rate") {
        over.rate = value.getFloat();
    } else if (field == "speed") {
        over.speed = value.getFloat();
    } else if (field == "count") {
        over.count = value.getFloat();
    } else if (field == "color") {
        const auto vec = value.getVec3();
        over.color     = { vec.x(), vec.y(), vec.z() };
        over.overColor = true;
    } else if (field == "colorn") {
        const auto vec  = value.getVec3();
        over.colorn     = { vec.x(), vec.y(), vec.z() };
        over.overColorn = true;
    } else if (field == "brightness") {
        over.brightness = value.getFloat();
    } else if (field.rfind("controlpointangle", 0) == 0 && field.size() == 18) {
        const auto index = static_cast<std::size_t>(field.back() - '0');
        if (index < 8) {
            const auto vec               = value.getVec3();
            over.controlpointangle[index] = { vec.x(), vec.y(), vec.z() };
            over.controlpointangleSet[index] = true;
        }
    } else if (field.rfind("controlpoint", 0) == 0 && field.size() == 13) {
        const auto index = static_cast<std::size_t>(field.back() - '0');
        if (index < 8) {
            const auto vec           = value.getVec3();
            over.controlpoint[index] = { vec.x(), vec.y(), vec.z() };
            over.controlpointSet[index] = true;
        }
    }
}

/// Puts the scene object's own control points over the preset's: a set
/// `controlpointN` replaces the preset's offset, a set `controlpointangleN`
/// turns the control point. Control points that follow the cursor keep their link.
void ApplyParticleOverrideControlpoints(const wpscene::ParticleInstanceoverride& over,
                                        std::span<ParticleControlpoint>          points) {
    if (! over.enabled) return;
    for (std::size_t i = 0; i < points.size() && i < 8; ++i) {
        auto& point = points[i];
        if (over.controlpointSet[i] && ! point.link_mouse) {
            point.base_offset = Eigen::Vector3d(over.controlpoint[i][0],
                                                over.controlpoint[i][1],
                                                over.controlpoint[i][2]);
            // A pinned control point is carried into the layer's space each
            // step; any other is where the scene put it.
            if (! point.worldspace || i == 0) point.offset = point.base_offset;
        }
        if (over.controlpointangleSet[i]) {
            const auto& a = over.controlpointangle[i];
            point.rotation =
                (Eigen::AngleAxisd(a[2], Eigen::Vector3d::UnitZ()) *
                 Eigen::AngleAxisd(a[1], Eigen::Vector3d::UnitY()) *
                 Eigen::AngleAxisd(a[0], Eigen::Vector3d::UnitX()))
                    .toRotationMatrix();
            point.has_rotation = true;
        }
    }
}

std::unique_ptr<DynamicValue>
MakeParticleOverrideDynamicValue(SceneRuntimeContext& runtime,
                                 const wpscene::ParticleInstanceoverride& over,
                                 const std::string& field,
                                 const std::string& user) {
    std::unique_ptr<DynamicValue> value;
    if (field == "color") {
        value = std::make_unique<DynamicValue>(
            Eigen::Vector3f(over.color[0], over.color[1], over.color[2]));
    } else if (field == "colorn") {
        value = std::make_unique<DynamicValue>(
            Eigen::Vector3f(over.colorn[0], over.colorn[1], over.colorn[2]));
    } else if (field == "brightness") {
        value = std::make_unique<DynamicValue>(over.brightness);
    } else if (field.rfind("controlpointangle", 0) == 0 && field.size() == 18 &&
               field.back() >= '0' && field.back() <= '7') {
        const auto& a = over.controlpointangle[static_cast<std::size_t>(field.back() - '0')];
        value = std::make_unique<DynamicValue>(Eigen::Vector3f(a[0], a[1], a[2]));
    } else if (field.rfind("controlpoint", 0) == 0 && field.size() == 13 &&
               field.back() >= '0' && field.back() <= '7') {
        const auto& a = over.controlpoint[static_cast<std::size_t>(field.back() - '0')];
        value = std::make_unique<DynamicValue>(Eigen::Vector3f(a[0], a[1], a[2]));
    } else if (field == "alpha") {
        value = std::make_unique<DynamicValue>(over.alpha);
    } else if (field == "size") {
        value = std::make_unique<DynamicValue>(over.size);
    } else if (field == "lifetime") {
        value = std::make_unique<DynamicValue>(over.lifetime);
    } else if (field == "rate") {
        value = std::make_unique<DynamicValue>(over.rate);
    } else if (field == "speed") {
        value = std::make_unique<DynamicValue>(over.speed);
    } else if (field == "count") {
        value = std::make_unique<DynamicValue>(over.count);
    } else {
        return nullptr;
    }

    if (auto* property_value = runtime.FindPropertyValue(user); property_value != nullptr) {
        if (field == "color" || field == "colorn" || field.rfind("controlpoint", 0) == 0) {
            value->connectVec3(property_value);
        } else {
            value->connect(property_value);
        }
    }
    return value;
}

void ParseParticleObj(ParseContext& context, wpscene::WPParticleObject& wppartobj,
                      ParticleChildPtr child_ptr = {}) {
    struct ChildData {
        ChildData() = default;
        ChildData(const wpscene::ParticleChild& o)
            : type(o.type),
              maxcount(o.maxcount),
              controlpointstartindex(o.controlpointstartindex),
              probability(o.probability) {}
        std::string type { "static" };
        i32         maxcount { 20 };
        i32         controlpointstartindex { 0 };
        float       probability { 1.0f };
    };

    wpscene::Particle*         p_particle_obj { nullptr };
    std::shared_ptr<SceneNode> spNode;
    ChildData                  child_data;

    const bool        is_mirror = child_ptr.mirror_of != nullptr;
    bool              is_child  = child_ptr.child != nullptr || is_mirror;
    const std::string runtime_name =
        is_child ? std::string {} : LayerRuntimeName(context, wppartobj);
    if (is_mirror) {
        p_particle_obj = child_ptr.mirror_particle;
        // Draws in the layer's own place: no offset, scale or turn of its own.
        spNode = std::make_shared<SceneNode>(Vector3f::Zero(), Vector3f::Ones(), Vector3f::Zero());
    } else if (is_child) {
        p_particle_obj = &(child_ptr.child->obj);
        Vector3f child_origin(child_ptr.child->origin.data());
        // The child's origin is its offset inside the parent system, composed
        // with the parent's matrix: a layer-space parent is drawn through the
        // layer's model matrix, which scales the offset with everything else.
        // A worldspace parent's particles are in world units, and the child
        // sits at the authored offset unscaled. An event child follows its
        // parent's flag alone. A static child whose own file is worldspace is
        // built from its bare local matrix in the engine, which no reference
        // scene exercises, so it keeps the authored offset in world units.
        const bool static_child =
            ParseSpawnType(child_ptr.child->type) == ParticleSubSystem::SpawnType::STATIC;
        const bool own_worldspace = p_particle_obj->flags[wpscene::Particle::FlagEnum::wordspace];
        if (child_ptr.parent_worldspace || (static_child && own_worldspace)) {
            for (int i = 0; i < 3; ++i) {
                const float scale = child_ptr.world_scale[i];
                if (std::abs(scale) > 1.0e-6f) child_origin[i] /= scale;
            }
        }
        spNode         = std::make_shared<SceneNode>(child_origin,
                                             Vector3f(child_ptr.child->scale.data()),
                                             Vector3f(child_ptr.child->angles.data()));
        child_data     = ChildData(*child_ptr.child);

        child_ptr.max_instancecount *= child_data.maxcount;

    } else {
        p_particle_obj = &wppartobj.particleObj;
        spNode         = std::make_shared<SceneNode>(Vector3f(wppartobj.origin.data()),
                                             Vector3f(wppartobj.scale.data()),
                                             Vector3f(wppartobj.angles.data()),
                                             runtime_name);
    }

    const Eigen::Vector3f node_world_scale =
        child_ptr.world_scale.cwiseProduct(spNode->Scale());

    RuntimeNodeRegistrationRollback runtime_node_registration(
        is_child ? nullptr : context.scene->runtime.get(),
        runtime_name,
        spNode.get(),
        is_child ? nullptr : &context.layer_nodes,
        wppartobj.id,
        is_child ? nullptr : &context.pending_scene_scripts);

    if (! is_child) {
        if (context.scene->runtime != nullptr) {
            context.scene->runtime->RegisterNode(runtime_name, spNode.get());
            // Particle layers are not hit-tested for the cursor, solid or not.
            context.scene->runtime->SetNodeCursorTarget(runtime_name, false, true, false);
            context.scene->runtime->RegisterNodeVisibility(
                runtime_name,
                spNode.get(),
                ResolveBoolSetting(*context.scene->runtime,
                                   wppartobj.dynamic_visible ? wppartobj.visible_setting
                                                             : nlohmann::json(wppartobj.visible),
                                   runtime_name));
            spNode->SetVisibilitySettled(VisibilitySettledBy(wppartobj.visible_setting));
            RegisterNodeTransformSettings(*context.scene->runtime, spNode.get(), runtime_name,
                                          wppartobj.origin_setting, wppartobj.scale_setting,
                                          wppartobj.angles_setting);
        }
        QueueSceneScriptIfNeeded(context, runtime_name, wppartobj.visible_setting);
        QueueSceneScriptIfNeeded(context, runtime_name, wppartobj.origin_setting);
        QueueSceneScriptIfNeeded(context, runtime_name, wppartobj.scale_setting);
        QueueSceneScriptIfNeeded(context, runtime_name, wppartobj.angles_setting);
    }

    auto override_state =
        std::make_shared<wpscene::ParticleInstanceoverride>(wppartobj.instanceoverride);
    auto& override = *override_state;
    override.hdr   = context.scene->hdr;
    if (context.scene->runtime != nullptr && ! is_mirror) {
        for (const auto& [field, user] : override.bindings) {
            auto value =
                MakeParticleOverrideDynamicValue(*context.scene->runtime, override, field, user);
            if (value == nullptr) continue;
            context.scene->runtime->RegisterDynamicValueListener(
                std::move(value),
                [override_state, field](const DynamicValue& value) {
                    ApplyParticleOverrideDynamicValue(*override_state, field, value);
                });
        }
    }

    auto& particle_obj = *p_particle_obj;
    auto& vfs          = *context.vfs;

    // A file that wrote an empty `renderer` list has nothing to draw. Its system
    // is still simulated and its particles can still spawn children, but it gets
    // no mesh and no material. Every other entry of the list is one renderer.
    const bool has_renderer = child_ptr.renderer_index < particle_obj.renderers.size();
    wpscene::ParticleRender wppartRenderer;
    if (has_renderer) wppartRenderer = particle_obj.renderers[child_ptr.renderer_index];
    bool render_rope    = has_renderer && sstart_with(wppartRenderer.name, "rope");
    bool hastrail       = has_renderer && send_with(wppartRenderer.name, "trail");
    bool rope_trail     = render_rope && hastrail;
    // A plain rope joins consecutive live slots, so the slots of a system that
    // any of its renderers draws as a plain rope must stay in order. The
    // simulated system is the first renderer's, whatever the later entries are.
    const bool ordered_slots = std::any_of(
        particle_obj.renderers.begin(), particle_obj.renderers.end(),
        [](const wpscene::ParticleRender& renderer) {
            return sstart_with(renderer.name, "rope") && ! send_with(renderer.name, "trail");
        });

    // The authored subdivision counts the points added between two connected
    // particles, so a rope is drawn as one more piece than that.
    u32 subdivision    = render_rope ? static_cast<u32>(wppartRenderer.subdivision) + 1u : 1u;
    // A rope trail records `segments` points of its own path; the pieces drawn
    // between them come from the subdivision, not from recording more.
    u32 trail_segments = rope_trail ? std::max(1u, static_cast<u32>(wppartRenderer.segments)) : 0u;

    u32 maxcount = particle_obj.maxcount;
    maxcount     = std::min(maxcount, 20000u);

    uint64_t mesh_maxcount = 0;
    if (! CheckedMulU64(maxcount, uint64_t(child_ptr.max_instancecount), mesh_maxcount)) {
        LOG_ERROR("particle mesh for \"%s\" instance product overflows maxcount=%u instances=%zu",
                  wppartobj.name.c_str(),
                  maxcount,
                  child_ptr.max_instancecount);
        return;
    }
    if (mesh_maxcount == 0) {
        LOG_INFO("skip zero-capacity particle mesh for \"%s\" child type=\"%s\" maxcount=%u "
                 "instances=%zu",
                 wppartobj.name.c_str(),
                 child_data.type.c_str(),
                 maxcount,
                 child_ptr.max_instancecount);
        return;
    }

    // Keep the author's renderer. A rope trail that no longer fits in one
    // 16-bit index buffer is still a rope trail: the mesh uses 32-bit indices
    // rather than becoming a sprite trail or dropping subdivision.
    uint64_t needed_quads = mesh_maxcount;
    if (render_rope) {
        if (rope_trail) {
            if (! CheckedMulU64(needed_quads, trail_segments, needed_quads) ||
                ! CheckedMulU64(needed_quads, subdivision, needed_quads)) {
                LOG_ERROR("rope trail \"%s\" quad count overflows maxcount=%u instances=%zu "
                          "segments=%u subdivision=%u",
                          wppartobj.name.c_str(),
                          maxcount,
                          child_ptr.max_instancecount,
                          trail_segments,
                          subdivision);
                return;
            }
        } else if (! CheckedMulU64(needed_quads, subdivision, needed_quads)) {
            LOG_ERROR("rope \"%s\" quad count overflows maxcount=%u instances=%zu subdivision=%u",
                      wppartobj.name.c_str(),
                      maxcount,
                      child_ptr.max_instancecount,
                      subdivision);
            return;
        }
    }

    // This renderer's own copy of the file's material: a rope draws through the
    // rope shader and any other entry keeps the shader the file names, so the
    // entries of one file cannot change each other's material.
    wpscene::WPMaterial renderer_material = particle_obj.material;
    if (render_rope) renderer_material.shader = "genericropeparticle";

    // wppartobj.origin[1] = context.ortho_h - wppartobj.origin[1];

    if (particle_obj.flags[wpscene::Particle::FlagEnum::perspective]) {
        spNode->SetCamera("global_perspective");
    }

    SceneMaterial     material;
    WPShaderValueData svData;

    if (! is_child) {
        svData.parallaxDepth = { wppartobj.parallaxDepth[0], wppartobj.parallaxDepth[1] };
    }

    WPShaderInfo shaderInfo;
    shaderInfo.baseConstSvs                         = context.global_base_uniforms;
    shaderInfo.baseConstSvs["g_OrientationUp"]      = std::array { 0.0f, 1.0f, 0.0f };
    shaderInfo.baseConstSvs["g_OrientationRight"]   = std::array { 1.0f, 0.0f, 0.0f };
    shaderInfo.baseConstSvs["g_OrientationForward"] = std::array { 0.0f, 0.0f, 1.0f };
    shaderInfo.baseConstSvs["g_ViewUp"]             = std::array { 0.0f, 1.0f, 0.0f };
    shaderInfo.baseConstSvs["g_ViewRight"]          = std::array { 1.0f, 0.0f, 0.0f };
    shaderInfo.baseConstSvs["g_EyePosition"]        = std::array {
        static_cast<float>(context.ortho_w) / 2.0f,
        static_cast<float>(context.ortho_h) / 2.0f,
        // Wallpaper Engine puts a 2D scene's eye 2000 units in front of the canvas.
        kCanvasShaderEyeDepth,
    };

    const u32 samples = rope_trail ? trail_segments : 0u;
    // Points a full trail strip holds once every recorded pair is subdivided.
    const u32 strip_samples = rope_trail ? trail_segments * subdivision : 0u;

    if (hastrail) {
        if (rope_trail) {
            shaderInfo.baseConstSvs["g_RenderVar0"] = std::array {
                (float)samples,
                0.0f,
                0.0f,
                EncodeRopeTrailLength((float)strip_samples, wppartRenderer.uvscale),
            };
        } else {
            shaderInfo.baseConstSvs["g_RenderVar0"] = std::array {
                (float)wppartRenderer.length,
                (float)wppartRenderer.maxlength,
                (float)wppartRenderer.minlength,
                (float)(maxcount - 1),
            };
        }
        shaderInfo.combos["THICKFORMAT"]   = "1";
        shaderInfo.combos["TRAILRENDERER"] = "1";
    } else if (render_rope) {
        // A plain rope carries an end size and colour for every piece, so its
        // width and colour change smoothly along it instead of in steps.
        shaderInfo.combos["THICKFORMAT"] = "1";
    }

    // A `randomframe` particle shows one frame of the sheet chosen at random, so
    // there is no neighbouring frame to blend it with: Wallpaper Engine sets the
    // no-blending flag for it, whether or not the file asks.
    if (particle_obj.BlendsSpriteFrames()) {
        shaderInfo.combos["SPRITESHEETBLEND"] = "1";
    }

    if (has_renderer) {
        bool mat_ok = false;
        try {
            mat_ok = LoadMaterial(vfs,
                                  renderer_material,
                                  context.scene.get(),
                                  spNode.get(),
                                  &material,
                                  &svData,
                                  &shaderInfo);
        } catch (const std::exception& e) {
            LOG_ERROR("load particleobj '%s' material exception: %s",
                      wppartobj.name.c_str(),
                      e.what());
        }
        if (! mat_ok) {
            LOG_ERROR("load particleobj '%s' material faild", wppartobj.name.c_str());
            return;
        }
        if (render_rope && material.hasSprite &&
            (std::abs(wppartRenderer.uvscale - 1.0f) > 1.0e-6f || wppartRenderer.uvscrolling)) {
            LOG_ERROR("rope UV scale/scroll on '%s' cannot stay inside a sprite-sheet frame; "
                      "genericropeparticle samples the whole texture",
                      wppartobj.name.c_str());
        }
        LoadConstvalue(material, renderer_material, shaderInfo);
    }
    // The particle step rewrites every vertex of this mesh on every tick.
    auto  spMesh             = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    auto& mesh               = *spMesh;
    auto  animationmode      = ToAnimMode(particle_obj.animationmode);
    auto  sequencemultiplier = particle_obj.sequencemultiplier;
    bool  hasSprite          = material.hasSprite;
    (void)hasSprite;

    bool thick_format = material.hasSprite || hastrail || render_rope;
    const uint64_t floats_per_vertex =
        render_rope ? (thick_format ? 28ull : 24ull) : (thick_format ? 20ull : 16ull);
    const auto index_layout = PlanParticleIndexLayout(needed_quads);
    if (has_renderer &&
        (! index_layout.ok || needed_quads > std::numeric_limits<uint32_t>::max() ||
         ! ParticleGeometryFits(needed_quads, floats_per_vertex))) {
        LOG_ERROR("particle mesh for \"%s\" exceeds geometry capacity: quads=%llu "
                  "byte_limit=%llu (effect type unchanged)",
                  wppartobj.name.c_str(),
                  (unsigned long long)needed_quads,
                  (unsigned long long)kMaxParticleGeometryBytes);
        return;
    }
    // Without a renderer the mesh stays empty and is never drawn or filled.
    if (has_renderer) {
        if (render_rope)
            SetRopeParticleMesh(mesh, particle_obj, (u32)needed_quads, thick_format);
        else
            SetParticleMesh(mesh, particle_obj, (u32)needed_quads, thick_format);
        // PRENDER_SPRITE / PRENDER_ROPE name the generator; PRENDER_TRAIL marks
        // any trail; PRENDER_ROPETRAIL is a rope trail that follows one
        // particle's recorded path. Combos are gone by the time a renderer runs.
        if (hastrail && mesh.VertexCount() > 0) {
            mesh.GetVertexArray(0).SetOption(WE_PRENDER_TRAIL, true);
            if (rope_trail) mesh.GetVertexArray(0).SetOption(WE_PRENDER_ROPETRAIL, true);
        }
    }

    auto particleSub = std::make_unique<ParticleSubSystem>(
        *context.scene->paritileSys,
        spMesh,
        maxcount,
        1.0,
        child_data.maxcount,
        child_data.probability,
        ParseSpawnType(child_data.type),
        [=](const Particle& p, const ParticleRawGenSpec& spec) {
            auto& lifetime = *(spec.lifetime);
            if (lifetime <= 0.0f) {
                lifetime = 0.0f;
                return;
            }
            switch (animationmode) {
            // The sprite shader picks frame floor(frac(lifetime) * frames).
            // An integral value always selected frame 0.
            case ParticleAnimationMode::RANDOMONE: lifetime = p.init.frame; break;
            case ParticleAnimationMode::SEQUENCE:
                lifetime = (1.0f - (p.lifetime / p.init.lifetime)) * sequencemultiplier;
                break;
            }
        });
    particleSub->SetRopeSubdivision(subdivision);
    particleSub->SetRopeUv(wppartRenderer.uvscale, wppartRenderer.uvscrolling,
                           wppartRenderer.uvsmoothing);
    if (context.scene->runtime != nullptr && render_rope) {
        auto*      sub          = particleSub.get();
        const auto runtime_name = LayerRuntimeName(context, wppartobj);
        auto&      runtime      = *context.scene->runtime;
        const auto is_dynamic   = [](const nlohmann::json& setting) {
            return setting.is_object() &&
                   (setting.contains("user") || setting.contains("script"));
        };
        if (is_dynamic(wppartRenderer.uvscale_setting)) {
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, wppartRenderer.uvscale_setting, runtime_name),
                [sub](const DynamicValue& value) {
                    sub->SetRopeUv(value.getFloat(), sub->UvScrolling(), sub->UvSmoothing());
                });
        }
        if (is_dynamic(wppartRenderer.uvscrolling_setting)) {
            runtime.RegisterDynamicValueListener(
                ResolveBoolSetting(runtime, wppartRenderer.uvscrolling_setting, runtime_name),
                [sub](const DynamicValue& value) {
                    sub->SetRopeUv(sub->UvScale(), value.getBool(), sub->UvSmoothing());
                });
        }
        if (is_dynamic(wppartRenderer.uvsmoothing_setting)) {
            runtime.RegisterDynamicValueListener(
                ResolveBoolSetting(runtime, wppartRenderer.uvsmoothing_setting, runtime_name),
                [sub](const DynamicValue& value) {
                    sub->SetRopeUv(sub->UvScale(), sub->UvScrolling(), value.getBool());
                });
        }
    }
    if (rope_trail && wppartRenderer.length > 0) {
        particleSub->SetTrail({ .samples = samples,
                                .period  = (double)wppartRenderer.length / samples });
    } else if (rope_trail) {
        LOG_INFO("rope trail \"%s\" has non-positive length; keeping no history",
                 wppartobj.name.c_str());
    }
    particleSub->SetRateMultiplier([override_state] {
        return override_state->enabled ? static_cast<double>(override_state->rate) : 1.0;
    });
    particleSub->SetOwnerNode(spNode);
    // A system without a renderer is simulated and draws nothing: no geometry is
    // built for it each frame.
    particleSub->SetDrawn(has_renderer);

    if (! is_mirror) {
        LoadEmitter(*particleSub,
                    particle_obj,
                    override_state,
                    ordered_slots,
                    context.scene.get(),
                    is_child ? child_data.controlpointstartindex : 0,
                    node_world_scale,
                    ! is_child && particle_obj.flags[wpscene::Particle::FlagEnum::wordspace]);
        LoadInitializer(*particleSub, particle_obj, override_state, context.scene.get(),
                        context.pixel_canvas);
        LoadOperator(*particleSub, particle_obj, override_state, context.scene.get(),
                     context.pixel_canvas);
        LoadControlPoint(*particleSub, particle_obj);
        particleSub->SetControlpointSource(
            [override_state](std::span<ParticleControlpoint> points) {
                ApplyParticleOverrideControlpoints(*override_state, points);
            });
        particleSub->SetStartTime(particle_obj.starttime);
        if (! is_child) {
            particleSub->SetWorldSpace(particle_obj.flags[wpscene::Particle::FlagEnum::wordspace]);
        }
    }

    if (has_renderer) {
        mesh.AddMaterial(std::move(material));
        RegisterMaterialConstants(context, spMesh->MaterialSlotPtr(), renderer_material, shaderInfo,
                                  LayerRuntimeName(context, wppartobj));
    }
    if (! is_child && context.scene->runtime != nullptr && spMesh->Material() != nullptr) {
        const auto runtime_name = LayerRuntimeName(context, wppartobj);
        for (const auto& texture_name : spMesh->Material()->textures) {
            if (texture_name.empty()) continue;
            const auto texture_iterator = context.scene->textures.find(texture_name);
            if (texture_iterator == context.scene->textures.end()) continue;
            if (! texture_iterator->second.isVideo) continue;
            context.scene->runtime->RegisterNodeVideoTexture(runtime_name, texture_name);
        }
    }
    if (has_renderer) {
        spNode->AddMesh(spMesh);
        context.shader_updater->SetNodeData(spNode.get(), svData);
    }

    if (! is_mirror) {
        // A file that lists several renderers draws every particle once through
        // each of them. The first is this system's own; each later one gets a
        // mesh and a material of its own and reads the same particles.
        for (std::size_t renderer = 1; renderer < particle_obj.renderers.size(); ++renderer) {
            ParseParticleObj(context,
                             wppartobj,
                             {
                                 .node_parent       = spNode.get(),
                                 .max_instancecount = child_ptr.max_instancecount,
                                 .world_scale       = node_world_scale,
                                 .mirror_of         = particleSub.get(),
                                 .renderer_index    = renderer,
                                 .mirror_particle   = &particle_obj,
                             });
        }
        const bool worldspace = particle_obj.flags[wpscene::Particle::FlagEnum::wordspace];
        for (auto& child : particle_obj.children) {
            ParseParticleObj(context,
                             wppartobj,
                             {
                                 .child             = &child,
                                 .node_parent       = spNode.get(),
                                 .particle_parent   = particleSub.get(),
                                 .max_instancecount = child_ptr.max_instancecount,
                                 .world_scale       = node_world_scale,
                                 .parent_worldspace = worldspace,
                             });
        }
    }

    // A top-level or static system has already lived for its `starttime` when
    // the first frame draws; an event child prewarms each instance it spawns.
    // The layer is not under its parent group yet, so the prewarm is queued for
    // when the scene graph is whole. A mirror has no start time of its own.
    if (! is_mirror) context.pending_prewarms.push_back(particleSub.get());

    if (is_mirror)
        child_ptr.mirror_of->AddMirror(std::move(particleSub));
    else if (is_child)
        child_ptr.particle_parent->AddChild(std::move(particleSub));
    else
        context.scene->paritileSys->subsystems.emplace_back(std::move(particleSub));

    if (! is_child) {
        context.layer_nodes[wppartobj.id] = spNode;
    }

    if (is_child)
        child_ptr.node_parent->AppendChild(spNode);
    else
        context.layer_parent_ids[wppartobj.id] = wppartobj.parent_id;
    runtime_node_registration.Commit();
}

void RegisterCommonNodeBindings(ParseContext& context, SceneNode& node, std::string_view runtime_name,
                                const wpscene::WPMiscObjectBase& obj,
                                const std::string& previous_runtime_name,
                                bool animate_timelines = true) {
    if (context.scene->runtime == nullptr) return;
    if (! previous_runtime_name.empty() && previous_runtime_name != runtime_name) {
        context.scene->runtime->UnregisterNode(previous_runtime_name);
    }
    context.scene->runtime->RegisterNode(std::string(runtime_name), &node);
    context.scene->runtime->RegisterNodeVisibility(
        std::string(runtime_name),
        &node,
        ResolveBoolSetting(*context.scene->runtime,
                           obj.dynamic_visible ? obj.visible_setting : nlohmann::json(obj.visible),
                           std::string(runtime_name)));
    node.SetVisibilitySettled(VisibilitySettledBy(obj.visible_setting));
    RegisterNodeTransformSettings(*context.scene->runtime, &node, runtime_name,
                                  obj.origin_setting, obj.scale_setting,
                                  obj.angles_setting, animate_timelines);
}

std::shared_ptr<SceneNode> ReuseOrCreateLayerNode(ParseContext& context, int32_t id) {
    auto node_iterator = context.layer_nodes.find(id);
    if (node_iterator != context.layer_nodes.end() && node_iterator->second != nullptr) {
        return node_iterator->second;
    }
    return std::make_shared<SceneNode>();
}

void ParseModelObj(ParseContext& context, wpscene::WPModelObject& obj) {
    const auto runtime_name = LayerRuntimeName(context, obj);
    WPMdl      mdl;
    if (obj.model.empty() || ! WPMdlParser::Parse(obj.model, *context.vfs, mdl)) {
        LOG_ERROR("parse model '%s' failed", obj.model.c_str());
        return;
    }
    if (! PuppetHasMeshData(mdl)) {
        LOG_ERROR("model '%s' has no mesh data", obj.model.c_str());
        return;
    }

    auto       node                    = ReuseOrCreateLayerNode(context, obj.id);
    const auto previous_runtime_name   = node->Name();
    node->SetName(runtime_name);
    node->SetTranslate(Vector3f(obj.origin.data()));
    node->SetScale(Vector3f(obj.scale.data()));
    node->SetRotation(Vector3f(obj.angles.data()));
    node->SetVisible(obj.visible);
    node->ID() = obj.id;
    if (obj.perspective ||
        (context.scene->activeCamera != nullptr && context.scene->activeCamera->IsPerspective())) {
        node->SetCamera("global_perspective");
    }

    auto       mesh      = std::make_shared<SceneMesh>();
    const bool has_bones = PuppetHasBones(mdl);
    WPMdlParser::GenPuppetMesh(*mesh, mdl, false);

    WPShaderValueData               svData;
    if (has_bones) {
        auto layer = WPPuppetLayer(mdl.puppet);
        layer.prepared(obj.puppet_layers);
        context.layer_puppets[obj.id] = mdl.puppet;
        context.layer_puppet_animations.emplace(obj.id, layer);
        svData.puppet_layer = layer;
    }
    std::vector<LoadedMaterialSlot> slots;
    auto load_material = [&](const std::string& path) {
        if (path.empty()) return false;
        wpscene::WPMaterial source;
        // Mesh materials omit the ordinary opaque 3D state. Image-layer
        // defaults (alpha blending, no depth, double-sided) expose rear
        // triangles through the front of a model. Explicit author state still
        // wins when FromJson reads the pass below.
        source.blending = "normal";
        source.cullmode = "normal";
        source.depthtest = "enabled";
        source.depthwrite = "enabled";
        if (! LoadWPMaterialFromPath(*context.vfs, path, source)) return false;
        if (has_bones) WPMdlParser::AddPuppetMatInfo(source, mdl);
        WPShaderInfo shader_info;
        if (has_bones) WPMdlParser::AddPuppetShaderInfo(shader_info, mdl);
        shader_info.baseConstSvs = context.global_base_uniforms;
        auto slot = MakePuppetMaterialSlot(source, shader_info, svData);
        if (! LoadPuppetMaterialSlot(context, node.get(), slot)) return false;
        slots.push_back(std::move(slot));
        return true;
    };

    for (const auto& mdl_mesh : mdl.meshes) {
        if (mdl_mesh.positions.empty()) continue;
        if (! load_material(mdl_mesh.mat_json_file)) {
            LOG_ERROR("load model material '%s' failed", mdl_mesh.mat_json_file.c_str());
        }
    }

    for (auto& slot : slots) {
        mesh->AddMaterial(std::move(slot.material));
        const auto index = static_cast<uint32_t>(mesh->MaterialSlots().size() - 1);
        context.shader_updater->SetNodeData(node.get(), index, slot.shader_value_data);
        RegisterMaterialConstants(
            context, mesh->MaterialSlotPtr(index), slot.source, slot.shader_info, runtime_name);
    }
    node->AddMesh(mesh);

    RegisterCommonNodeBindings(context, *node, runtime_name, obj, previous_runtime_name);
    if (context.scene->runtime != nullptr) {
        context.scene->runtime->SetNodeCursorTarget(runtime_name, true, obj.solid,
                                                    obj.disablepropagation);
    }
    if (has_bones && context.scene->runtime != nullptr) {
        const auto& layer = context.layer_puppet_animations.at(obj.id);
        context.scene->runtime->RegisterPuppetLayer(runtime_name, layer);
        BindPuppetAnimationLayerSettings(context, runtime_name, obj, layer);
    }
    QueueSceneScriptIfNeeded(context, runtime_name, obj.visible_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, obj.origin_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, obj.scale_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, obj.angles_setting);

    context.layer_nodes[obj.id]      = node;
    context.layer_parent_ids[obj.id] = obj.parent_id;
    context.uses_models              = true;
}

// A camera layer's authored timeline. The editor links a shot's origin to its
// zoom (`options.parent`), and one playhead drives both, so the shot keeps a
// single clock: the zoom's when that is animated, else the first origin curve's.
// A relative origin timeline is an offset from the authored origin, which is
// how an intro can glide back to exactly where the shot rests.
SceneRuntimeContext::CameraShotTimeline ResolveCameraShotTimeline(
    SceneRuntimeContext& runtime, const wpscene::WPCameraObject& obj, std::string_view runtime_name) {
    SceneRuntimeContext::CameraShotTimeline timeline;
    timeline.zoom = ResolveScalarAnimation(obj.zoom_setting);
    // A scripted or user-bound origin already moves the layer every tick.
    if (! obj.dynamic_origin && obj.origin_setting.is_object()) {
        if (const auto animation = obj.origin_setting.find("animation");
            animation != obj.origin_setting.end() && animation->is_object()) {
            const auto relative      = animation->find("relative");
            timeline.origin_relative = relative != animation->end() && relative->is_boolean() &&
                                       relative->get<bool>();
            timeline.origin_base     = Vector3f(obj.origin.data());
            for (std::size_t index = 0; index < timeline.origin.size(); ++index) {
                auto curve = ResolveScalarAnimation(obj.origin_setting, index);
                // Before its first key a relative curve offsets by nothing.
                if (curve.has_value() && timeline.origin_relative) curve->initial_value = 0.0f;
                timeline.origin[index] = std::move(curve);
            }
        }
    }

    const ScalarAnimation* source     = timeline.zoom.has_value() ? &*timeline.zoom : nullptr;
    double                 last_frame = source != nullptr ? source->keyframes.back().frame : 0.0;
    for (const auto& curve : timeline.origin) {
        if (! curve.has_value()) continue;
        if (source == nullptr) source = &*curve;
        last_frame = std::max(last_frame, curve->keyframes.back().frame);
    }
    if (source != nullptr) {
        ScalarAnimation clock = *source;
        if (! (clock.length_frames > 0.0)) clock.length_frames = last_frame;
        timeline.clock = runtime.RegisterScalarAnimation(runtime_name, std::move(clock));
    }
    return timeline;
}

void ParseCameraObj(ParseContext& context, wpscene::WPCameraObject& obj, float resolved_fov) {
    const auto runtime_name = LayerRuntimeName(context, obj);
    auto       node         = ReuseOrCreateLayerNode(context, obj.id);
    const auto previous_runtime_name = node->Name();
    node->SetName(runtime_name);
    node->SetTranslate(Vector3f(obj.origin.data()));
    node->SetScale(Vector3f(obj.scale.data()));
    node->SetRotation(Vector3f(obj.angles.data()));
    node->SetVisible(obj.visible);
    node->ID() = obj.id;

    // A camera layer is a shot for a scene that is projected by a camera. An
    // orthographic scene is projected by its authored `orthogonalprojection`
    // instead, and every 2D layer's geometry, origin and alignment is written
    // against that canvas. Letting the layer take over reframes the whole
    // scene through a perspective camera placed at the layer origin, which for
    // the usual authored pose -- a few hundred units in front of the canvas,
    // fov 50 -- leaves a magnified sliver of one corner and nothing else. The
    // layer stays a node scripts can read and move; it just does not replace
    // the projection the canvas defines.
    SceneCamera* perspective_camera = nullptr;
    if (! context.is_ortho) {
        const std::string cam_name = obj.camera.empty() || obj.camera == "default"
                                         ? "global_perspective" : obj.camera;
        auto existing = context.scene->cameras.find(cam_name);
        if (existing != context.scene->cameras.end()) {
            perspective_camera = existing->second.get();
        } else if (context.scene->cameras.count("global_perspective") != 0) {
            const auto& source = context.scene->cameras.at("global_perspective");
            auto camera = std::make_shared<SceneCamera>(
                static_cast<float>(source->Aspect()), static_cast<float>(source->NearClip()),
                static_cast<float>(source->FarClip()), resolved_fov);
            camera->AttatchNode(source->GetAttachedNode());
            perspective_camera = camera.get();
            context.scene->cameras[cam_name] = std::move(camera);
        }
        if (perspective_camera) perspective_camera->LockFov(true);
    }

    // Orthographic shots already share an origin/zoom clock below.
    RegisterCommonNodeBindings(context, *node, runtime_name, obj, previous_runtime_name,
                               !context.is_ortho);
    if (context.scene->runtime != nullptr) {
        context.scene->runtime->SetNodeCursorTarget(runtime_name, false, obj.solid,
                                                    obj.disablepropagation);
    }
    QueueSceneScriptIfNeeded(context, runtime_name, obj.visible_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, obj.origin_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, obj.scale_setting);
    QueueSceneScriptIfNeeded(context, runtime_name, obj.angles_setting);

    // A 2D scene keeps the projection its canvas defines, and a camera layer
    // frames that canvas instead: its zoom narrows the view about its centre
    // and its origin, an offset from the canvas centre, moves that centre. The
    // last visible shot in authored order is the one shown, so a shot a user
    // property reveals overrides one that is always there. A perspective scene
    // already spends the layer on the camera above.
    if (context.is_ortho) {
        if (context.scene->runtime != nullptr) {
            auto& runtime = *context.scene->runtime;
            // The slider form keeps naming its property only in the raw
            // setting; the unwrapped float is just its authored default.
            const auto zoom_setting =
                obj.zoom_setting.is_null() ? nlohmann::json(obj.zoom) : obj.zoom_setting;
            auto timeline = ResolveCameraShotTimeline(runtime, obj, runtime_name);
            runtime.RegisterCameraShot(node.get(),
                                       ResolveFloatSetting(runtime, zoom_setting, runtime_name),
                                       std::move(timeline), obj.dynamic_origin);
        } else if (obj.visible) {
            context.scene->FrameCanvas(obj.zoom, Eigen::Vector2f(obj.origin[0], obj.origin[1]));
        }
    } else if (perspective_camera) {
        std::vector<CameraPath> paths;
        if (!obj.path.empty()) {
            nlohmann::json json;
            if (PARSE_JSON(fs::GetFileContent(*context.vfs, "/assets/" + obj.path), json)) {
                paths = ParseCameraPaths(json);
            }
        }
        // Visibility bindings are registered first. Merely parsing a hidden
        // preset must never move the shared camera off the shot that is playing.
        CameraPathPlayback path(std::move(paths), obj.queuemode);
        if (context.scene->runtime) {
            context.scene->runtime->RegisterPerspectiveCameraShot(
                node, perspective_camera, resolved_fov, std::move(path));
        } else if (obj.visible) {
            perspective_camera->AttatchNode(node);
            perspective_camera->SetFov(resolved_fov);
            path.Apply(*node, *perspective_camera);
            context.scene->activeCamera = perspective_camera;
        }
    }

    context.layer_nodes[obj.id]      = node;
    context.layer_parent_ids[obj.id] = obj.parent_id;
}

void ApplyDefaultDepthTarget(ParseContext& context) {
    auto* target = context.scene->FindRenderTarget(SpecTex_Default.data());
    if (target == nullptr) return;
    if (context.uses_models ||
        (context.scene->activeCamera != nullptr && context.scene->activeCamera->IsPerspective())) {
        target->withDepth = true;
    }
}

std::string LightRuntimeName(const ParseContext& context, const wpscene::WPLightObject& obj) {
    if (! obj.name.empty()) {
        const auto count = context.layer_name_counts.find(obj.name);
        if (count == context.layer_name_counts.end() || count->second == 0) return obj.name;
    }
    return "__we_light_" + std::to_string(obj.id);
}

// A light is a node in the scene graph like any layer: it follows its parent,
// its transform and visibility take user properties, scripts and timelines,
// and nothing draws it. Colour, intensity, radius and exponent are re-read
// from their bindings every tick.
void ParseLightObj(ParseContext& context, wpscene::WPLightObject& light_obj) {
    const auto runtime_name = LightRuntimeName(context, light_obj);
    auto       node         = std::make_shared<SceneNode>(Vector3f(light_obj.origin.data()),
                                            Vector3f(light_obj.scale.data()),
                                            Vector3f(light_obj.angles.data()),
                                            runtime_name);
    node->ID() = light_obj.id;

    context.scene->lights.emplace_back(std::make_unique<SceneLight>(
        ParseSceneLightType(light_obj.light), Vector3f(light_obj.color.data()), light_obj.radius,
        light_obj.intensity));
    auto* light = context.scene->lights.back().get();
    light->setExponent(light_obj.exponent);
    light->setCones(light_obj.innercone, light_obj.outercone);
    light->setControlPoint(Vector3f(light_obj.controlpoint.data()));
    light->setNode(node);

    if (context.scene->runtime != nullptr) {
        auto& runtime = *context.scene->runtime;
        runtime.RegisterNode(runtime_name, node.get());
        runtime.SetNodeCursorTarget(runtime_name, false, true, false);
        runtime.RegisterNodeVisibility(
            runtime_name,
            node.get(),
            ResolveBoolSetting(runtime,
                               light_obj.dynamic_visible ? light_obj.visible_setting
                                                         : nlohmann::json(light_obj.visible),
                               runtime_name));
        RegisterNodeTransformSettings(runtime, node.get(), runtime_name,
                                      light_obj.origin_setting, light_obj.scale_setting,
                                      light_obj.angles_setting);
        if (auto animation = ResolveScalarAnimation(light_obj.intensity_setting)) {
            light->setIntensityAnimation(
                runtime.RegisterScalarAnimation(runtime_name, std::move(*animation)));
        } else if (HasDynamicSetting(light_obj.intensity_setting)) {
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, light_obj.intensity_setting, runtime_name),
                [light](const DynamicValue& value) { light->setIntensity(value.getFloat()); });
        }
        if (HasDynamicSetting(light_obj.color_setting)) {
            runtime.RegisterDynamicValueListener(
                ResolveVec3Setting(runtime, light_obj.color_setting, runtime_name),
                [light](const DynamicValue& value) { light->setColor(value.getVec3()); });
        }
        if (HasDynamicSetting(light_obj.radius_setting)) {
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, light_obj.radius_setting, runtime_name),
                [light](const DynamicValue& value) { light->setRadius(value.getFloat()); });
        }
        if (HasDynamicSetting(light_obj.exponent_setting)) {
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, light_obj.exponent_setting, runtime_name),
                [light](const DynamicValue& value) { light->setExponent(value.getFloat()); });
        }
        for (const auto* setting : { &light_obj.visible_setting, &light_obj.origin_setting,
                                     &light_obj.scale_setting, &light_obj.angles_setting,
                                     &light_obj.intensity_setting, &light_obj.color_setting,
                                     &light_obj.radius_setting, &light_obj.exponent_setting }) {
            QueueSceneScriptIfNeeded(context, runtime_name, *setting);
        }
    } else {
        node->SetVisible(light_obj.visible);
    }

    if (light_obj.id != 0) {
        // Attached under its parent with the other objects, once all exist.
        context.layer_nodes[light_obj.id]      = node;
        context.layer_parent_ids[light_obj.id] = light_obj.parent_id;
    } else {
        context.scene->sceneGraph->AppendChild(node);
    }
}

// A pass-through card laid out where its layer is drawn: under its groups, as
// the layer's final card is placed (SyncImageEffectFinalTransforms). From the
// layer's own transform alone, a layer with an origin inside a moved group
// copied the screen from where the group's origin would be. The runtime lays it
// out again when the groups move (SyncEffectFinalNode).
void LayOutPassthroughCards(ParseContext& context) {
    for (const auto& pending : context.passthrough_cards) {
        pending.node->UpdateTrans();
        pending.card->LayOut(*pending.mesh, pending.node->ModelTrans());
    }
    context.passthrough_cards.clear();
}

void SyncImageEffectFinalTransforms(ParseContext& context) {
    for (const auto& [layer_id, node] : context.layer_nodes) {
        (void)layer_id;
        if (node == nullptr || node->Camera().empty()) continue;
        auto camera_iterator = context.scene->cameras.find(node->Camera());
        if (camera_iterator == context.scene->cameras.end() || camera_iterator->second == nullptr ||
            ! camera_iterator->second->HasImgEffect()) {
            continue;
        }
        auto& final_node = camera_iterator->second->GetImgEffect()->FinalNode();
        CopyResolvedWorldTransform(final_node, *node);
    }
}

template<typename T>
bool HasDynamicVisible(const T&) {
    return false;
}

bool HasDynamicVisible(const wpscene::WPImageObject& object) { return object.dynamic_visible; }

bool HasDynamicVisible(const wpscene::WPParticleObject& object) { return object.dynamic_visible; }

bool HasDynamicVisible(const wpscene::WPTextObject&) { return true; }

bool HasDynamicVisible(const wpscene::WPModelObject& object) { return object.dynamic_visible; }

bool HasDynamicVisible(const wpscene::WPCameraObject& object) { return object.dynamic_visible; }

bool HasDynamicVisible(const wpscene::WPShapeObject& object) { return object.dynamic_visible; }

std::unordered_set<int32_t> CollectReachableDependencyIds(const nlohmann::json& objects,
                                                          const LayerObjectIndex& index,
                                                          fs::VFS& vfs) {
    return CollectReachableLayerIds(objects, index, &vfs);
}

// Every `script` string anywhere under `value`: a layer's properties, its
// effects' visibility and constants, a particle's overrides.
void CollectScriptSources(const nlohmann::json& value, std::vector<const std::string*>& out) {
    if (value.is_object()) {
        for (const auto& [key, child] : value.items()) {
            if (key == "script" && child.is_string()) {
                out.push_back(child.get_ptr<const std::string*>());
            } else {
                CollectScriptSources(child, out);
            }
        }
    } else if (value.is_array()) {
        for (const auto& child : value) CollectScriptSources(child, out);
    }
}

// The quoted strings of a script (single, double or backtick quotes, escapes
// skipped; comments are not told apart, which only ever adds names).
void CollectScriptStringLiterals(std::string_view source, std::unordered_set<std::string>& out) {
    for (std::size_t i = 0; i < source.size(); ++i) {
        const char quote = source[i];
        if (quote != '"' && quote != '\'' && quote != '`') continue;
        std::string literal;
        std::size_t j = i + 1;
        for (; j < source.size() && source[j] != quote && source[j] != '\n'; ++j) {
            if (source[j] == '\\' && j + 1 < source.size()) ++j;
            literal.push_back(source[j]);
        }
        if (j < source.size() && source[j] == quote) out.insert(std::move(literal));
        i = j;
    }
}

// The layers a hidden object must be kept for although nothing draws it yet:
// Wallpaper Engine builds every layer, so a hidden layer's own scripts run
// (a hidden controller layer often computes what other layers show) and a
// script can find it by name to show it. An object that carries a script, or
// whose name a script spells out, is kept, hidden. A name a script computes is
// not seen. Sound and light objects are not kept: neither reads its visibility,
// so a kept hidden one would play or shine.
std::unordered_set<int32_t> CollectScriptReachableIds(const nlohmann::json& objects) {
    std::unordered_set<int32_t> ids;
    if (! objects.is_array()) return ids;
    std::vector<const std::string*> sources;
    CollectScriptSources(objects, sources);
    if (sources.empty()) return ids;
    std::unordered_set<std::string> literals;
    for (const auto* source : sources) CollectScriptStringLiterals(*source, literals);
    for (const auto& object : objects) {
        int32_t id = 0;
        GET_JSON_NAME_VALUE_NOWARN(object, "id", id);
        if (id == 0) continue;
        std::vector<const std::string*> own;
        CollectScriptSources(object, own);
        const auto name = object.contains("name") && object.at("name").is_string()
                              ? object.at("name").get<std::string>()
                              : std::string();
        if (! own.empty() || (! name.empty() && literals.contains(name))) ids.insert(id);
    }
    return ids;
}

template<typename T>
void AddWPObject(std::vector<WPObjectVar>&        objs,
                 const nlohmann::json&           json_obj,
                 fs::VFS&                        vfs,
                 const std::unordered_set<int32_t>& dependency_ids = {}) {
    T wpobj;
    if (! wpobj.FromJson(json_obj, vfs)) {
        LOG_ERROR("parse scene object failed, name: %s", wpobj.name.c_str());
        return;
    }
    int32_t object_id = 0;
    GET_JSON_NAME_VALUE_NOWARN(json_obj, "id", object_id);
    const bool keep_invisible_dependency = dependency_ids.contains(object_id);
    if (! wpobj.visible && ! HasDynamicVisible(wpobj) && ! keep_invisible_dependency) return;
    objs.push_back(wpobj);
}
} // namespace

template<typename T>
void CountNodeRuntimeName(std::unordered_map<std::string, uint32_t>& counts, const T& object) {
    if (! object.name.empty()) ++counts[object.name];
}

std::string NodeRuntimeName(std::string name, int32_t id, uint32_t count) {
    if (! name.empty() && count <= 1u) return name;
    return "__we_layer_" + std::to_string(id);
}

// A texture property carries whatever the editor or the picker wrote into it:
// an absolute path to the user's own picture, or a package-relative asset the
// author shipped. The loader addresses packaged textures by bare name, so the
// authored form is reduced to that name.
//
// The property stores the path, not a copy, so an absolute one is only taken
// when that file can actually be opened now: moved, deleted, or out of reach of
// the sandboxed lock-screen extension all leave the slot on the wallpaper's own
// texture instead of on a name that decodes to nothing.
std::optional<std::string> TexturePropertyTextureName(const std::string& value) {
    if (std::filesystem::path(value).is_absolute()) {
        if (! HostLooseAssetIsReadable(value)) return std::nullopt;
        return value;
    }
    std::string name = value;
    if (name.size() > 4 && name.compare(name.size() - 4, 4, ".tex") == 0) {
        name.erase(name.size() - 4);
    }
    constexpr std::string_view kMaterials { "materials/" };
    if (name.compare(0, kMaterials.size(), kMaterials) == 0) name.erase(0, kMaterials.size());
    if (name.empty()) return std::nullopt;
    return name;
}

std::string_view wallpaper::UserTexturePropertyName(const wpscene::WPUserTexture& user_texture) {
    // A typed slot (`system`, ...) names something the runtime supplies.
    return user_texture.type.empty() ? std::string_view(user_texture.name) : std::string_view {};
}

void wallpaper::ApplySystemUserTextures(std::vector<std::string>&                  textures,
                                        const std::vector<wpscene::WPUserTexture>& usertextures,
                                        const ProjectProperties*                   properties,
                                        RuntimeImageSource*                        covers,
                                        std::vector<std::string>* target_covers) {
    // Anything neither the runtime nor the wallpaper's own properties supply is
    // left on the authored texture in that position rather than replaced by a
    // blank one.
    for (std::size_t index = 0; index < usertextures.size(); ++index) {
        const auto& user_texture = usertextures[index];
        std::string replacement;
        if (wpscene::IsSystemUserTexture(user_texture)) {
            replacement = user_texture.name;
            // The authored texture stays in the slot until the runtime has a
            // cover to put there: a cover layer shows its own art while nothing
            // plays. A render target or another layer's composite is not a
            // picture the source can hold, so the slot keeps the target and the
            // renderer binds the cover over it while one is published.
            const bool authored = index < textures.size() && ! textures[index].empty();
            if (authored && IsSpecTex(textures[index]) && target_covers != nullptr) {
                if (target_covers->size() <= index) target_covers->resize(index + 1);
                (*target_covers)[index] = std::move(replacement);
                continue;
            }
            if (covers != nullptr && authored && ! IsSpecTex(textures[index])) {
                replacement = covers->BindCoverSlot(replacement, textures[index]);
            }
        } else if (properties != nullptr && ! UserTexturePropertyName(user_texture).empty()) {
            // The bare-string form names one of this wallpaper's properties. An
            // unset property is the author's own default, so the slot keeps it.
            const auto property = properties->find(user_texture.name);
            if (property == properties->end()) continue;
            const auto& chosen = property->second.asString();
            if (chosen.empty()) continue;
            const auto resolved = TexturePropertyTextureName(chosen);
            if (! resolved) continue;
            replacement = *resolved;
        }
        if (replacement.empty()) continue;
        if (textures.size() <= index) textures.resize(index + 1);
        textures[index] = std::move(replacement);
    }
}

void wallpaper::LoadMaterialConstantShaderValues(SceneMaterial& material,
                                                 const wpscene::WPMaterial& wpmat,
                                                 const WPShaderInfo& info) {
    LoadMaterialConstantShaderValuesImpl(material, wpmat, info);
}

namespace
{
// What a layer made while the scene runs needs of the parse that built the scene.
struct LazyParseInputs {
    ShaderValueMap   globals;
    LayerObjectIndex index;
    bool             is_ortho { true };
    bool             uses_models { false };
};

ParseContext MakeLazyParseContext(const std::shared_ptr<Scene>& scene, fs::VFS& vfs,
                                  const LazyParseInputs& inputs) {
    ParseContext lazy {};
    lazy.scene                    = scene;
    lazy.vfs                      = &vfs;
    lazy.shader_updater           = static_cast<WPShaderValueUpdater*>(scene->shaderValueUpdater.get());
    lazy.ortho_w                  = scene->ortho[0];
    lazy.ortho_h                  = scene->ortho[1];
    lazy.global_base_uniforms     = inputs.globals;
    lazy.is_ortho                 = inputs.is_ortho;
    lazy.uses_models              = inputs.uses_models;
    lazy.effect_camera_node       = scene->cameras.at("effect")->GetAttachedNode();
    lazy.global_camera_node       = scene->cameras.at("global")->GetAttachedNode();
    lazy.global_perspective_camera_node =
        scene->cameras.at("global_perspective")->GetAttachedNode();
    return lazy;
}

// A parse that runs after the scene was built needs the shader compiler up and
// the layer index in place, and leaves both as it found them.
struct LazyShaderParseScope {
    const LayerObjectIndex* previous;
    explicit LazyShaderParseScope(const LayerObjectIndex& index) : previous(g_parse_layer_index) {
        g_parse_layer_index = &index;
        WPShaderParser::InitGlslang();
    }
    ~LazyShaderParseScope() {
        g_pending_metal_translations.clear();
        g_parse_layer_index = previous;
        WPShaderParser::FinalGlslang();
    }
};
} // namespace

std::shared_ptr<Scene> WPSceneParser::Parse(const SceneParseRequest& request,
                                            const std::string& buf, fs::VFS& vfs,
                                            audio::SoundManager& sm) {
    // A previous parse that returned early would otherwise leave records
    // pointing at a VFS that is gone.
    g_pending_metal_translations.clear();
    g_parse_layer_index = nullptr;
    nlohmann::json json;
    if (! PARSE_JSON(buf, json)) return nullptr;
    wpscene::WPScene sc;
    sc.FromJson(json, request.pkg_version);
    //	LOG_INFO(nlohmann::json(sc).dump(4));

    ResolveLayerParallax(json.at("objects"));
    ParseContext context;
    context.request     = &request;
    context.object_list = &json.at("objects");
    auto layer_index = BuildLayerObjectIndex(json.at("objects"));
    const auto layer_refs  = CollectLayerTextureRefs(json.at("objects"), layer_index, &vfs);
    // A layer another samples is kept for its picture, so only image layers are
    // (a hidden layer of another kind would draw nothing into it); a hidden
    // layer a script reaches is kept whatever its kind.
    const auto script_reachable_ids = CollectScriptReachableIds(json.at("objects"));
    auto       reachable_dependency_ids =
        CollectReachableDependencyIds(json.at("objects"), layer_index, vfs);
    reachable_dependency_ids.insert(script_reachable_ids.begin(), script_reachable_ids.end());
    for (const auto& ref : layer_refs) {
        if (ref.source_id != 0) context.referenced_layer_ids.insert(ref.source_id);
    }

    std::vector<WPObjectVar> wp_objs;

    for (auto& obj : json.at("objects")) {
        if (obj.contains("image") && ! obj.at("image").is_null()) {
            AddWPObject<wpscene::WPImageObject>(wp_objs, obj, vfs, reachable_dependency_ids);
        } else if (obj.contains("particle") && ! obj.at("particle").is_null()) {
            AddWPObject<wpscene::WPParticleObject>(wp_objs, obj, vfs, script_reachable_ids);
        } else if (obj.contains("sound") && ! obj.at("sound").is_null()) {
            AddWPObject<wpscene::WPSoundObject>(wp_objs, obj, vfs);
        } else if (obj.contains("light") && ! obj.at("light").is_null()) {
            AddWPObject<wpscene::WPLightObject>(wp_objs, obj, vfs);
        } else if (obj.contains("text") && ! obj.at("text").is_null()) {
            AddWPObject<wpscene::WPTextObject>(wp_objs, obj, vfs, script_reachable_ids);
        } else if (obj.contains("model") && ! obj.at("model").is_null()) {
            AddWPObject<wpscene::WPModelObject>(wp_objs, obj, vfs, script_reachable_ids);
        } else if (obj.contains("camera") && ! obj.at("camera").is_null()) {
            AddWPObject<wpscene::WPCameraObject>(wp_objs, obj, vfs, script_reachable_ids);
        } else if (obj.contains("shape") && obj.at("shape").is_string()) {
            AddWPObject<wpscene::WPShapeObject>(wp_objs, obj, vfs, script_reachable_ids);
        }
    }
    context.layer_name_counts.clear();
    context.object_runtime_names.clear();
    context.text_name_counts.clear();
    context.sound_layer_ids.clear();
    for (const auto& obj : wp_objs) {
        std::visit(visitor::overload {
                       [&context](const wpscene::WPImageObject& object) {
                           CountNodeRuntimeName(context.layer_name_counts, object);
                       },
                       [&context](const wpscene::WPSoundObject& object) {
                           CountNodeRuntimeName(context.layer_name_counts, object);
                           if (object.id != 0) context.sound_layer_ids.insert(object.id);
                       },
                       [&context](const wpscene::WPParticleObject& object) {
                           CountNodeRuntimeName(context.layer_name_counts, object);
                       },
                       [&context](const wpscene::WPTextObject& text) {
                           if (! text.name.empty()) ++context.text_name_counts[text.name];
                       },
                       [&context](const wpscene::WPModelObject& object) {
                           CountNodeRuntimeName(context.layer_name_counts, object);
                       },
                       [&context](const wpscene::WPCameraObject& object) {
                           CountNodeRuntimeName(context.layer_name_counts, object);
                       },
                       [](const auto&) {
                       },
                   },
                   obj);
    }
    if (context.object_list != nullptr) {
        for (const auto& object : *context.object_list) {
            if (! IsLayerObject(object)) continue;

            RawLayerObject layer;
            if (ParseLayerObject(object, *context.object_list, layer)) {
                CountNodeRuntimeName(context.layer_name_counts, layer);
            }
        }
    }
    for (const auto& obj : wp_objs) {
        std::visit(visitor::overload {
                       [&context](const wpscene::WPImageObject& object) {
                           const auto count = object.name.empty()
                                                  ? 0u
                                                  : context.layer_name_counts[object.name];
                           context.object_runtime_names[object.id] =
                               NodeRuntimeName(object.name, object.id, count);
                       },
                       [&context](const wpscene::WPParticleObject& object) {
                           const auto count = object.name.empty()
                                                  ? 0u
                                                  : context.layer_name_counts[object.name];
                           context.object_runtime_names[object.id] =
                               NodeRuntimeName(object.name, object.id, count);
                       },
                       [&context](const wpscene::WPModelObject& object) {
                           const auto count = object.name.empty()
                                                  ? 0u
                                                  : context.layer_name_counts[object.name];
                           context.object_runtime_names[object.id] =
                               NodeRuntimeName(object.name, object.id, count);
                       },
                       [&context](const wpscene::WPCameraObject& object) {
                           const auto count = object.name.empty()
                                                  ? 0u
                                                  : context.layer_name_counts[object.name];
                           context.object_runtime_names[object.id] =
                               NodeRuntimeName(object.name, object.id, count);
                       },
                       [&context](const wpscene::WPSoundObject& object) {
                           if (object.id == 0) return;
                           const auto count = object.name.empty()
                                                  ? 0u
                                                  : context.layer_name_counts[object.name];
                           context.object_runtime_names[object.id] =
                               NodeRuntimeName(object.name, object.id, count);
                       },
                       [](const auto&) {
                       },
                   },
                   obj);
    }

    if (sc.general.orthogonalprojection.auto_) {
        i32 w = 0, h = 0;
        for (auto& obj : wp_objs) {
            auto* img = std::get_if<wpscene::WPImageObject>(&obj);
            if (img == nullptr) continue;
            i32 size = (i32)(img->size.at(0) * img->size.at(1));
            if (size > w * h) {
                w = (i32)img->size.at(0);
                h = (i32)img->size.at(1);
            }
        }
        sc.general.orthogonalprojection.width  = w;
        sc.general.orthogonalprojection.height = h;
    }

    InitContext(context, vfs, sc);
    // Keep the unique keys used by bindings and thisLayer, while exposing
    // duplicate authored names to cross-layer scripts in declaration order.
    // Register before compiling scripts so module-level lookups work too.
    if (context.scene->runtime != nullptr) {
        auto& runtime = *context.scene->runtime;
        for (const auto& object : *context.object_list) {
            if (!object.is_object() || (object.contains("name") && !object.at("name").is_string()))
                continue;
            const auto name = object.value("name", std::string {});
            const auto count = context.layer_name_counts.find(name);
            if (count == context.layer_name_counts.end() || count->second <= 1u) continue;
            if (object.contains("id") && !object.at("id").is_number()) continue;
            const auto id = object.value("id", 0);
            if (const auto key = context.object_runtime_names.find(id);
                key != context.object_runtime_names.end()) {
                runtime.RegisterLayerAlias(name, key->second);
            } else if (IsLayerObject(object) && id != 0) {
                runtime.RegisterLayerAlias(name, NodeRuntimeName(name, id, count->second));
            }
        }
        // A layer registered under a generated key (its name is shared, or
        // empty) is still called what the scene file calls it. A script
        // compiles as its layer is parsed, and the layer object it builds then
        // (its `thisLayer`, a layer it looks up at module level) keeps the
        // name it was built with, so the names are on record before the first
        // script compiles, under the key each kind of layer will be given.
        const auto record_name = [&runtime](const std::string& name, const std::string& key) {
            if (! key.empty() && key != name) runtime.RegisterLayerAuthoredName(key, name);
        };
        for (const auto& obj : wp_objs) {
            std::visit(visitor::overload {
                           [&](const wpscene::WPTextObject& object) {
                               record_name(object.name, TextRuntimeName(context, object));
                           },
                           [&](const wpscene::WPLightObject& object) {
                               record_name(object.name, LightRuntimeName(context, object));
                           },
                           [&](const auto& object) {
                               record_name(object.name, LayerRuntimeName(context, object));
                           },
                       },
                       obj);
        }
        for (const auto& object : *context.object_list) {
            RawLayerObject layer;
            if (IsLayerObject(object) && ParseLayerObject(object, *context.object_list, layer)) {
                record_name(layer.name, LayerRuntimeName(context, layer));
            }
        }
    }
    g_parse_layer_index = &layer_index;
    context.scene->layer_texture_error = ClassifyLayerTextureReferences(layer_refs, layer_index);
    context.scene->layer_texture_sources = context.referenced_layer_ids;
    ParseLayerNodes(context, json.at("objects"));
    ParseCamera(context, sc);
    if (context.scene->runtime != nullptr && json.at("general").contains("zoom")) {
        auto& runtime = *context.scene->runtime;
        if (auto animation = ResolveScalarAnimation(json.at("general").at("zoom"))) {
            runtime.RegisterSceneZoomAnimation(runtime.RegisterScalarAnimation("", std::move(*animation)));
        } else if (HasDynamicSetting(sc.general.zoom_setting)) {
            runtime.RegisterSceneZoom(ResolveFloatSetting(runtime, sc.general.zoom_setting));
        }
    }

    {
        const auto render_width =
            std::max(1, static_cast<i32>(context.scene->cameras.at("global")->Width()));
        const auto render_height =
            std::max(1, static_cast<i32>(context.scene->cameras.at("global")->Height()));
        // The author's canvas. Latched before any render scale can be applied
        // so that presentation layout and cursor mapping keep resolving against
        // the composition the author designed, whatever the internal raster
        // size becomes.
        context.scene->scene_extent[0] = render_width;
        context.scene->scene_extent[1] = render_height;
        context.scene->renderTargets[SpecTex_Default.data()] = {
            .width           = render_width,
            .height          = render_height,
            .authored_width  = render_width,
            .authored_height = render_height,
            .bind            = { .enable = true, .screen = true },
            .format = context.scene->hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8,
        };
        context.scene->renderTargets[WE_MIP_MAPPED_FRAME_BUFFER.data()] = {
            .width      = render_width,
            .height     = render_height,
            .has_mipmap = true,
            .bind       = { .enable = true, .name = SpecTex_Default.data() },
            .format = context.scene->hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8,
        };
        context.scene->renderTargets["_rt_shadowAtlas"] = {
            .width      = render_width,
            .height     = render_height,
            .allowReuse = true,
        };
        context.scene->renderTargetAliases["_alias_lightCookie"] = "_rt_shadowAtlas";
        context.scene->renderTargets["_rt_4FrameBuffer"]         = {
                    .width      = std::max(1, render_width / 4),
                    .height     = std::max(1, render_height / 4),
                    .allowReuse = true,
                    .format = context.scene->hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8,
        };
        context.scene->renderTargets["_rt_8FrameBuffer"] = {
            .width      = std::max(1, render_width / 8),
            .height     = std::max(1, render_height / 8),
            .allowReuse = true,
            .format = context.scene->hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8,
        };
        context.scene->renderTargets["_rt_Bloom"] = {
            .width      = std::max(1, render_width / 8),
            .height     = std::max(1, render_height / 8),
            .allowReuse = true,
            .format = context.scene->hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8,
        };
    }

    context.scene->scene_id = request.scene_id;

    WPShaderParser::InitGlslang();

    for (WPObjectVar& obj : wp_objs) {
        std::visit(visitor::overload {
                       [&context](wpscene::WPImageObject& obj) {
                           ParseImageObj(context, obj);
                       },
                       [&context](wpscene::WPParticleObject& obj) {
                           ParseParticleObj(context, obj);
                       },
                       [&context, &sm](wpscene::WPSoundObject& obj) {
                           WPSoundParser::Parse(obj,
                                                *context.vfs,
                                                sm,
                                                context.scene->runtime.get(),
                                                LayerRuntimeName(context, obj));
                       },
                       [&context](wpscene::WPLightObject& obj) {
                           ParseLightObj(context, obj);
                       },
                       [&context](wpscene::WPTextObject& obj) {
                           ParseTextObj(context, obj);
                       },
                       [&context](wpscene::WPModelObject& obj) {
                           ParseModelObj(context, obj);
                       },
                       [&context](wpscene::WPShapeObject& obj) {
                           ParseShapeObj(context, obj);
                       },
                       [&context, &sc](wpscene::WPCameraObject& obj) {
                           // Read the authored scene settings, not a shared camera whose FOV
                           // an earlier visible shot may already have replaced.
                           ParseCameraObj(context, obj, ResolvePerspectiveFov(sc.general, obj.fov));
                       },
                   },
                   obj);
    }

    // Model and external material textures are discovered while parsing their
    // consumers. Keep their hidden producers too, including forward references
    // and further dependencies discovered while loading those producers.
    std::unordered_set<int32_t> prepared_sources;
    std::vector<int32_t> pending_sources;
    for (;;) {
        pending_sources.clear();
        for (const auto id : context.scene->layer_texture_sources) {
            if (prepared_sources.insert(id).second) pending_sources.push_back(id);
        }
        if (pending_sources.empty()) break;
        for (const auto id : pending_sources) {
            if (context.scene->HasRenderTarget(LayerCompositeTargetKey(id))) continue;
            context.referenced_layer_ids.insert(id);
            bool already_parsed = false;
            for (const auto& object : wp_objs) {
                const auto* image = std::get_if<wpscene::WPImageObject>(&object);
                const auto* text  = std::get_if<wpscene::WPTextObject>(&object);
                if ((image == nullptr || image->id != id) && (text == nullptr || text->id != id))
                    continue;
                if (const auto node = context.layer_nodes.find(id);
                    node != context.layer_nodes.end() && node->second != nullptr) {
                    if (image != nullptr) {
                        RegisterImageComposite(context, *image, *node->second);
                    } else if (const auto card = context.text_cards.find(id);
                               card != context.text_cards.end()) {
                        RegisterTextComposite(context, *text, *node->second, card->second);
                    }
                }
                already_parsed = true;
                break;
            }
            if (already_parsed) continue;
            for (const auto& object : json.at("objects")) {
                if (object.value("id", 0) != id || ! object.contains("image")) continue;
                wpscene::WPImageObject image;
                if (! image.FromJson(object, vfs)) break;
                const auto names = layer_index.ids_by_name.find(image.name);
                context.object_runtime_names[id] = NodeRuntimeName(
                    image.name, id, names == layer_index.ids_by_name.end() ? 0u
                                                                         : names->second.size());
                ParseImageObj(context, image);
                break;
            }
        }
    }

    ApplyDefaultDepthTarget(context);
    AttachRemainingLayerNodes(context);
    PrewarmParticleSystems(context);
    RegisterLayerAttachments(context);
    LayOutPassthroughCards(context);
    SyncImageEffectFinalTransforms(context);

    BuildBloomPostProcess(context, sc);

    // Last, once the scene graph, the cameras and the textures are all in
    // place: the structural check it consults needs the finished scene.
    FlushPendingMetalTranslations(*context.scene);

    WPShaderParser::FinalGlslang();
    g_parse_layer_index = nullptr;
    if (context.scene->runtime != nullptr) {
        auto& runtime = *context.scene->runtime;
        // Scripts count layers in the order the scene file declares them, look
        // them up by their scene.json id, and read what the file says about one.
        std::vector<std::string> declared_order;
        for (const auto& object : *context.object_list) {
            if (! object.is_object() || ! object.contains("id") || ! object.at("id").is_number()) {
                continue;
            }
            const auto id   = object.at("id").get<int32_t>();
            const auto node = context.layer_nodes.find(id);
            if (node == context.layer_nodes.end() || node->second == nullptr ||
                node->second->Name().empty()) {
                continue;
            }
            declared_order.push_back(node->second->Name());
            runtime.RegisterLayerId(id, node->second->Name());
            // A layer registered under a generated key (its name is shared, or
            // empty) is still called what the scene file calls it.
            const auto authored = object.contains("name") && object.at("name").is_string()
                                      ? object.at("name").get<std::string>()
                                      : std::string {};
            if (authored != node->second->Name()) {
                runtime.RegisterLayerAuthoredName(node->second->Name(), authored);
            }
        }
        runtime.SetLayerOrder(declared_order);
        // The scene scripts below start here, and their `init` may read the
        // object list. Whether they will is known from their source.
        for (const auto& [layer_name, script_source] : context.pending_scene_scripts) {
            (void)layer_name;
            if (script_source.find("getInitialLayerConfig") != std::string::npos) {
                runtime.RequestInitialLayerConfig();
            }
        }
        if (runtime.InitialLayerConfigRequested()) {
            runtime.SetInitialLayerConfigProvider(
                [objects = std::make_shared<const nlohmann::json>(*context.object_list)](
                    int32_t id) -> std::string {
                    for (const auto& object : *objects) {
                        if (object.is_object() && object.contains("id") &&
                            object.at("id").is_number() && object.at("id").get<int32_t>() == id) {
                            return object.dump();
                        }
                    }
                    return {};
                });
        }
        // A script that changes a text layer's `font` names a font the way the
        // scene file does, and it is found the same way.
        runtime.SetTextFontResolver([&vfs](TextLayerState& state, const std::string& font_key) {
            ResolveTextLayerFont(state, vfs, font_key);
        });

        auto inputs = std::make_shared<LazyParseInputs>(LazyParseInputs {
            .globals     = std::move(context.global_base_uniforms),
            .index       = std::move(layer_index),
            .is_ortho    = context.is_ortho,
            .uses_models = context.uses_models,
        });

        // `createLayer({ text })`: the layer is parsed as a text object of the
        // scene would be, from the configuration the script gave.
        runtime.SetTextLayerFactory(
            [weak_scene = std::weak_ptr<Scene>(context.scene), &vfs,
             inputs](const std::string& config_json, int32_t object_id) -> std::shared_ptr<SceneNode> {
                auto scene = weak_scene.lock();
                if (scene == nullptr) return nullptr;
                nlohmann::json config = nlohmann::json::parse(config_json, nullptr, false);
                if (! config.is_object()) return nullptr;
                config["id"] = object_id;
                wpscene::WPTextObject text;
                if (! text.FromJson(config, vfs)) return nullptr;
                ParseContext lazy = MakeLazyParseContext(scene, vfs, *inputs);
                LazyShaderParseScope scope(inputs->index);
                ParseTextObj(lazy, text);
                FlushPendingMetalTranslations(*scene);
                const auto node = lazy.layer_nodes.find(object_id);
                return node != lazy.layer_nodes.end() ? node->second : nullptr;
            });

        runtime.SetLayerTemplateLoader(
            [weak_scene = std::weak_ptr<Scene>(context.scene), &vfs,
             inputs](std::string_view path) {
                auto scene = weak_scene.lock();
                if (scene == nullptr) return false;
                // The runtime asks for more than one spelling of a path, so a
                // miss is an answer, not an error to log.
                if (! vfs.Contains("/assets/" + std::string(path))) return false;
                // Visible, because every layer created from it starts as a copy
                // of it and a new layer shows until its script says otherwise.
                // The template itself never joins the scene graph (below).
                wpscene::WPImageObject image;
                if (! image.FromJson({ { "image", path }, { "visible", true },
                                      { "name", "__template:" + std::string(path) } }, vfs))
                    return false;
                // A scene layer carries the size the editor gave it; a layer
                // made from a bare model has none unless the model states it,
                // and a zero-sized card draws nothing. Such a model is as large
                // as its picture, as when the editor first places it.
                if (! image.fullscreen && (image.size[0] <= 0.0f || image.size[1] <= 0.0f) &&
                    scene->imageParser != nullptr && ! image.material.textures.empty() &&
                    ! image.material.textures.front().empty() &&
                    ! IsSpecTex(image.material.textures.front())) {
                    const ImageHeader header =
                        scene->imageParser->ParseHeader(image.material.textures.front());
                    if (header.mapWidth > 0 && header.mapHeight > 0) {
                        image.size = { static_cast<float>(header.mapWidth),
                                       static_cast<float>(header.mapHeight) };
                    }
                }
                ParseContext lazy = MakeLazyParseContext(scene, vfs, *inputs);
                LazyShaderParseScope scope(inputs->index);
                ParseImageObj(lazy, image);
                FlushPendingMetalTranslations(*scene);
                // RegisterLayerTemplate owns the hidden source. Only its clones
                // enter the scene graph, so unused templates cost no draw.
                return lazy.layer_nodes.contains(image.id) &&
                       lazy.layer_nodes.at(image.id)->Mesh() != nullptr;
            });

        // Scene scripts run `init` as they are registered, so they start last:
        // the layers' order and ids, the object list, the text hooks and the
        // template loader are all in place for it, as they are for every later
        // call, and the scene is built the way a script running in a frame sees it.
        for (const auto& [layer_name, script_source] : context.pending_scene_scripts) {
            runtime.RegisterSceneScript(script_source, layer_name);
        }
    }
    return context.scene;
}

std::shared_ptr<Scene> WPSceneParser::Parse(std::string_view scene_id, const std::string& buf,
                                            fs::VFS& vfs, audio::SoundManager& sm) {
    SceneParseRequest request {
        .scene_id = std::string(scene_id),
    };
    return Parse(request, buf, vfs, sm);
}
