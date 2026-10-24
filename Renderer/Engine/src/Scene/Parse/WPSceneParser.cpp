// Clean-room implementation from the WallpaperMachine spec p1-scene-structure.md; written without access to the original source.
#include "WPSceneParser.hpp"
#include "LayerParallax.hpp"
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
#include "Particle/ParticleModify.h"

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
#include <functional>
#include <iostream>
#include <map>
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
#include "Utils/Linalg.hpp"

using namespace wallpaper;
using namespace wallpaper::linalg;

/// One entry of the object list that became a member of the layer tree.
struct ParsedLayer {
    std::size_t                entry { 0 };      // position in the `objects` array
    int32_t                    id { 0 };
    int32_t                    parent_id { -1 }; // as authored; -1 for none
    std::string                key;              // the name scripts and bindings use
    std::string                authored_name;
    std::string                attachment;
    std::shared_ptr<SceneNode> node;
    // A node that only carries a transform: a group, a shape, or the stand-in of
    // an entry whose typed object is not (or not yet) built.
    bool                       plain { true };
    // The effect chain of an image layer that draws through effects.
    std::shared_ptr<SceneImageEffectLayer> effects;
    // The skeleton and shared playback state of a puppet layer, for attachments.
    std::shared_ptr<WPPuppet> puppet;
    WPPuppetLayer             puppet_layer;
};

namespace
{

/// One material's shader, captured with the Metal program its settled compile
/// produced and everything a later plane variant of it would be compiled from.
///
/// The compile that settles a material's combos, default textures and texture
/// slots is the Metal compile: the stages of its last iteration are the program.
/// Turning them into the scene's program is deferred to the end of the parse,
/// because whether the scene is a candidate for this backend at all (a particle
/// emitter, a puppet, a video texture it cannot play) is only known once the
/// whole scene exists, and the inputs of the optional plane variant are
/// snapshots of what the settled compile was handed, which do not outlive
/// `LoadMaterial`.
struct PendingMetalTranslation {
    std::shared_ptr<SceneShader>      shader;
    std::string                       shader_name;
    std::string                       scene_id;
    /// What the settled compile was handed, before it merged its results in.
    std::vector<WPShaderUnit>         units;
    WPShaderInfo                      shader_info;
    std::vector<WPShaderTexInfo>      texinfos;
    /// The material's texture keys, in slot order, so the flush can ask the
    /// scene which slot is a video without re-deriving the list.
    std::vector<std::string>          texture_keys;
    /// What the settled compile produced.
    std::vector<shader::RustShaderMetalStage> stages;
    std::string                       reflection_json;
    /// Every include that compile read, for translating the same program again.
    WPShaderIncludeMap                includes;
};


/// Parsing is single-threaded per scene but several scenes may parse at once,
/// so the queue is per-thread rather than global.
thread_local std::vector<PendingMetalTranslation> g_pending_metal_translations;
thread_local const LayerObjectIndex* g_parse_layer_index { nullptr };
/// The shaders of this parse that could not be compiled, one sentence each, in
/// the order the parse met them. The layer or effect that wanted one is left out
/// of the scene (its material did not load), so the parse ends by handing these
/// to the scene, whose capability gate refuses it with the first as the reason:
/// a scene is never drawn with a part of it missing.
thread_local std::vector<std::string> g_shader_failures;

/// Records that `shader_name` could not be compiled, with the compiler's own
/// explanation when it has one (its first line, so a long diagnostic does not
/// become the panel's reason).
void NoteShaderFailure(std::string_view shader_name, std::string detail) {
    constexpr std::size_t kMaxDetail = 240;
    if (const auto line = detail.find('\n'); line != std::string::npos) detail.resize(line);
    if (detail.size() > kMaxDetail) detail.resize(kMaxDetail);
    std::string reason = "the shader '" + std::string(shader_name) + "' could not be translated to Metal";
    if (! detail.empty() && detail != "no shader error") reason += " (" + detail + ")";
    g_shader_failures.push_back(std::move(reason));
}

/// What the scene reports when the parse met shaders that did not compile.
std::string ShaderFailureReason() {
    if (g_shader_failures.empty()) return {};
    std::string reason = g_shader_failures.front();
    if (g_shader_failures.size() > 1) {
        reason += "; " + std::to_string(g_shader_failures.size() - 1) + " more shader" +
                  (g_shader_failures.size() == 2 ? "" : "s") + " failed too";
    }
    return reason;
}

/// Compiles one iteration of a material's shader to Metal, merging what the
/// compile learned into `units` and `shader_info`, and queues the program it
/// made (or, for a later iteration of the same shader, replaces the earlier
/// one). The inputs are copied before the compile consumes them, so the record
/// holds exactly what the compile saw rather than the state it left behind; the
/// last iteration to run is the one that settled. A failed compile leaves
/// nothing queued for the shader.
bool CompileAndQueueMetalProgram(const std::shared_ptr<SceneShader>& shader,
                                 std::string_view scene_id, std::string_view shader_name,
                                 std::span<WPShaderUnit> units, fs::VFS& vfs,
                                 WPShaderInfo* shader_info,
                                 std::span<const WPShaderTexInfo> texinfos,
                                 std::vector<std::string> texture_keys,
                                 std::string* reflection_json) {
    PendingMetalTranslation pending;
    pending.shader       = shader;
    pending.shader_name  = std::string(shader_name);
    pending.scene_id     = std::string(scene_id);
    pending.units.assign(units.begin(), units.end());
    pending.shader_info  = *shader_info;
    pending.texinfos.assign(texinfos.begin(), texinfos.end());
    pending.texture_keys = std::move(texture_keys);

    const bool replaces = ! g_pending_metal_translations.empty() &&
                          g_pending_metal_translations.back().shader == shader;
    if (! WPShaderParser::CompileToMslRust(scene_id,
                                           shader_name,
                                           units,
                                           pending.stages,
                                           vfs,
                                           shader_info,
                                           texinfos,
                                           &pending.reflection_json,
                                           std::nullopt,
                                           &pending.includes)) {
        if (replaces) g_pending_metal_translations.pop_back();
        NoteShaderFailure(shader_name, shader::LastRustShaderError());
        return false;
    }
    if (reflection_json != nullptr) *reflection_json = pending.reflection_json;
    if (replaces) {
        g_pending_metal_translations.back() = std::move(pending);
    } else {
        g_pending_metal_translations.push_back(std::move(pending));
    }
    return true;
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

/// Attaches the queued programs to their shaders, if the scene is still a
/// candidate for this backend.
///
/// A program that cannot be used (no stages, no reflection) is recorded with its
/// error, which the capability gate turns into a user-readable reason for
/// holding the scene.
void FlushPendingMetalTranslations(Scene& scene) {
    auto pending = std::move(g_pending_metal_translations);
    g_pending_metal_translations.clear();
    g_parse_layer_index = nullptr;
    if (pending.empty()) return;
    if (! metal::SceneMetalStructuralRejection(scene).empty()) return;

    for (auto& request : pending) {
        if (request.shader == nullptr) continue;
        auto program = std::make_shared<SceneMetalProgram>();

        program->reflection_json = std::move(request.reflection_json);
        for (const auto& stage : request.stages) {
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
            LOG_ERROR("metal translation of '%s' failed: %s",
                      request.shader_name.c_str(),
                      program->error.c_str());
        } else {
            CaptureVideoPlaneInputs(scene, request, *program, std::move(request.includes));
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

/// What the card of a passthrough layer with effects is made from: the layer's rectangle
/// (`half_w` by `half_h` about its origin) and how the draw puts it into the buffer its
/// effects work on. With `clip_space` the pass copies the footprint 1:1 into clip space.
/// Otherwise the pass goes through the camera that frames the card's own rectangle about the
/// origin, so the positions are the card's own corners and only the texture coordinates
/// follow the footprint.
struct PassthroughCardShape {
    float half_w { 0.0f };
    float half_h { 0.0f };
    float canvas_width { 1.0f };
    float canvas_height { 1.0f };
    bool  clip_space { false };
};

struct ParseContext {
    std::shared_ptr<Scene>                                  scene;
    WPShaderValueUpdater*                                   shader_updater;
    i32                                                     ortho_w;
    i32                                                     ortho_h;
    fs::VFS*                                                vfs;
    std::unordered_map<int32_t, std::shared_ptr<SceneNode>> layer_nodes;
    std::unordered_map<std::string, uint32_t>               layer_name_counts;
    ShaderValueMap             global_base_uniforms;
    std::shared_ptr<SceneNode> effect_camera_node;
    std::shared_ptr<SceneNode> global_camera_node;
    std::shared_ptr<SceneNode> global_perspective_camera_node;
    std::unordered_map<int32_t, WPPuppetLayer>              layer_puppet_animations;
    /// Particle systems that have a prewarm to run, a child's before its parent's.
    /// It waits for the finished scene graph: the matrix a system is born by is
    /// its layer's world matrix, parent groups included, and a layer joins its
    /// group only once every object exists.
    std::vector<ParticleSubSystem*>                         pending_prewarms;
    /// Work that waits for the layers to sit in their tree (a child system's place under a
    /// world-space parent depends on the scale it is drawn under).
    std::vector<std::function<void()>>                      after_attach;
    /// The scene file's objects, for questions about a layer's ancestors.
    const nlohmann::json*                                   objects { nullptr };
    /// The cards of pass-through layers, laid out once every layer sits under its parent.
    struct PassthroughCard {
        std::shared_ptr<SceneNode> node;
        std::shared_ptr<SceneMesh> mesh;
        PassthroughCardShape       shape;
    };
    std::vector<PassthroughCard>                            passthrough_cards;
    /// Bindings whose scripts read other layers as they are made: bound once every layer exists.
    std::vector<std::function<void()>>                      deferred_bindings;
    /// A parse after the scene exists (a layer a script makes) binds at once: every layer is there.
    bool                                                    bind_now { false };
    std::unordered_set<int32_t>                             referenced_layer_ids;
    /// The layers of the tree, in the order the scene file declares them.
    std::vector<ParsedLayer>                                layers;
    /// Scene-event scripts waiting for the scene to be complete: source, owning layer key.
    std::vector<std::pair<std::string, std::string>>        scene_scripts;
    /// How many text layers carry each authored name.
    std::unordered_map<std::string, uint32_t>               text_name_counts;
    /// The header of each file texture met so far, read once per name.
    std::unordered_map<std::string, ImageHeader>            texture_headers;
    /// The card each text layer shows, for a composite registered only once
    /// a later consumer turns out to sample the layer.
    std::unordered_map<int32_t, TextLayerRenderFrame>       text_cards;

    bool                       uses_models { false };
    // `orthogonalprojection` present and not null. The scene is then projected
    // by that canvas, which is the space every 2D layer's geometry, origin and
    // alignment is authored in.
    bool                       is_ortho { true };
    // The canvas has a pixel size: particle files then default omitted keys in
    // pixel units.
    bool                       pixel_canvas { true };
    // The scene predates version 5: a re-tinted particle preset is multiplied
    // by its instance colour override as well.
    bool                       tint_after_retint { true };
};

namespace
{
void MarkSceneRequiresAudioResponse(Scene* scene) {
    if (scene != nullptr && scene->runtime != nullptr) scene->runtime->MarkSceneRequiresAudioResponse();
}

/// A setting that a project property or a running script decides.
bool HasDynamicSetting(const nlohmann::json& value) { return wpscene::SettingIsDriven(value); }

/// A visibility only a reload changes: the authored value, or one of the
/// wallpaper's own properties, which reparse the scene when they change.
/// Anything handed to a script can change from one frame to the next.
bool VisibilitySettledBy(const nlohmann::json& setting) {
    return ! setting.is_object() || ! setting.contains("script");
}

// Runs the prewarms the particle layers queued, now that every layer sits under
// its parent.
void PrewarmParticleSystems(ParseContext& context) {
    for (auto& fixup : context.after_attach) fixup();
    context.after_attach.clear();
    for (auto* system : context.pending_prewarms) system->Prewarm();
    context.pending_prewarms.clear();
}

/// The extent of a view of `canvas` units at `zoom`: the canvas divided by the
/// zoom, truncated to whole units, at least 1. A zoom that is not finite and
/// positive counts as 1.
int32_t ZoomedExtent(int32_t canvas, double zoom) {
    const double applied = std::isfinite(zoom) && zoom > 0.0 ? zoom : 1.0;
    const double units   = std::trunc(static_cast<double>(canvas) / applied);
    return static_cast<int32_t>(std::clamp(units, 1.0, 2147483647.0));
}

/// The extent of the offscreen targets an image layer draws into: its size
/// rounded to whole numbers, where an axis of 2 or less (or not finite) takes the
/// canvas's extent on that axis instead, at least 4.
std::array<int32_t, 2> ResolveImageRenderExtent(const wpscene::WPImageObject& object,
                                                const ParseContext&           context) {
    const std::array<int32_t, 2> canvas { context.ortho_w, context.ortho_h };
    std::array<int32_t, 2>       extent {};
    for (std::size_t axis = 0; axis < 2; ++axis) {
        const double size = object.size[axis];
        if (std::isfinite(size) && std::round(size) > 2.0) {
            extent[axis] = static_cast<int32_t>(std::min(std::round(size), 2147483647.0));
        } else {
            extent[axis] = std::max(4, canvas[axis]);
        }
    }
    return extent;
}

/// One axis of an effect buffer: the base divided by the buffer's integer scale
/// (0 reads as 1), rounded to the nearest whole number, at least 4.
int32_t ResolveRenderTargetDimension(float base_dimension, uint32_t scale) {
    const double divisor = scale == 0 ? 1.0 : static_cast<double>(scale);
    const double value   = std::isfinite(base_dimension) ? base_dimension / divisor : 0.0;
    return static_cast<int32_t>(std::clamp(std::round(value), 4.0, 2147483647.0));
}

// The format Wallpaper Engine gives an effect buffer. Float buffers hold signed
// values, such as a fluid simulation's velocity and pressure, which an 8-bit
// target would clamp at zero; the back-buffer formats follow the scene. A
// single- or two-channel float buffer takes the four-channel float target, the
// narrowest float format the renderer allocates.
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

/// A quad of four vertices in the order left-bottom, left-top, right-bottom,
/// right-top, drawn as the triangles (0, 1, 2) and (2, 1, 3).
std::shared_ptr<SceneMesh> MakeQuadMesh(const std::array<float, 12>& positions,
                                        const std::array<float, 8>&  uvs,
                                        MeshUpdate update = MeshUpdate::Fixed) {
    SceneVertexArray vertices({ { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
                                { std::string(WE_IN_TEXCOORD), VertexType::FLOAT2 } },
                              4);
    // Each attribute takes four floats of the vertex, padding included.
    std::array<float, 32> packed {};
    for (std::size_t corner = 0; corner < 4; ++corner) {
        float* vertex = packed.data() + corner * 8;
        for (std::size_t lane = 0; lane < 3; ++lane) vertex[lane] = positions[corner * 3 + lane];
        vertex[4] = uvs[corner * 2];
        vertex[5] = uvs[corner * 2 + 1];
    }
    vertices.SetVertexs(0, packed);
    // Sixteen-bit indices, two to a slot of the index array.
    const std::array<uint16_t, 6> indices { 0, 1, 2, 2, 1, 3 };
    SceneIndexArray index_array(1);
    index_array.AssignHalf(0, indices);
    auto mesh = std::make_shared<SceneMesh>(update);
    mesh->AddVertexArray(std::move(vertices));
    mesh->AddIndexArray(std::move(index_array));
    return mesh;
}

/// A layer's own card: a rectangle centred on the origin, as wide and tall as the
/// size cut down to whole units (kept inside 0..65535). Texture coordinate v is 0
/// at the top; (u, v) is how much of a padded texture holds the picture.
std::shared_ptr<SceneMesh> MakeCardMesh(float width, float height, float u = 1.0f, float v = 1.0f) {
    const auto whole = [](float size) {
        return std::isfinite(size) ? std::clamp(std::trunc(size), 0.0f, 65535.0f) : 0.0f;
    };
    const float half_w = whole(width) * 0.5f;
    const float half_h = whole(height) * 0.5f;
    return MakeQuadMesh({ -half_w, -half_h, 0.0f, -half_w, half_h, 0.0f, half_w, -half_h, 0.0f,
                          half_w, half_h, 0.0f },
                        { 0.0f, v, 0.0f, 0.0f, u, v, u, 0.0f });
}

/// A text layer's card over the box `[left, right] x [bottom, top]`, with the whole
/// texture across it. A text card is rewritten when the text is laid out again, and
/// never otherwise.
std::shared_ptr<SceneMesh> MakeTextCardMesh(float left, float bottom, float right, float top) {
    return MakeQuadMesh({ left, bottom, 0.0f, left, top, 0.0f, right, bottom, 0.0f, right, top,
                          0.0f },
                        { 0.0f, 1.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 0.0f }, MeshUpdate::OnEvent);
}

/// The positions and texture coordinates (in the order of `MakeQuadMesh`) of the card of a
/// passthrough layer with effects drawn where `world` puts the layer: its four corners in
/// canvas positions, y up, each sampling the scene output at that place.
void PassthroughCardVertices(const PassthroughCardShape& shape, const Matrix4d& world,
                             std::array<float, 12>& positions, std::array<float, 8>& uvs) {
    const std::array<std::array<double, 2>, 4> offsets { {
        { -static_cast<double>(shape.half_w), -static_cast<double>(shape.half_h) },
        { -static_cast<double>(shape.half_w), static_cast<double>(shape.half_h) },
        { static_cast<double>(shape.half_w), -static_cast<double>(shape.half_h) },
        { static_cast<double>(shape.half_w), static_cast<double>(shape.half_h) } } };
    for (std::size_t corner = 0; corner < 4; ++corner) {
        const linalg::Vector4d point =
            world * linalg::Vector4d(offsets[corner][0], offsets[corner][1], 0.0, 1.0);
        const float x = static_cast<float>(point.x());
        const float y = static_cast<float>(point.y());
        positions[corner * 3]     = shape.clip_space ? 2.0f * x / shape.canvas_width - 1.0f
                                                     : static_cast<float>(offsets[corner][0]);
        positions[corner * 3 + 1] = shape.clip_space ? 2.0f * y / shape.canvas_height - 1.0f
                                                     : static_cast<float>(offsets[corner][1]);
        positions[corner * 3 + 2] = 0.0f;
        uvs[corner * 2]           = x / shape.canvas_width;
        uvs[corner * 2 + 1]       = 1.0f - y / shape.canvas_height;
    }
}

std::shared_ptr<SceneMesh> MakePassthroughMesh(const PassthroughCardShape& shape, const Matrix4d& world,
                                               MeshUpdate update) {
    std::array<float, 12> positions {};
    std::array<float, 8>  uvs {};
    PassthroughCardVertices(shape, world, positions, uvs);
    return MakeQuadMesh(positions, uvs, update);
}

/// Lays the card out again where `world` puts its layer.
void LayOutPassthroughCard(SceneMesh& mesh, const PassthroughCardShape& shape, const Matrix4d& world) {
    if (mesh.VertexCount() < 1 || mesh.GetVertexArray(0).VertexCount() < 4) return;
    std::array<float, 12> positions {};
    std::array<float, 8>  uvs {};
    PassthroughCardVertices(shape, world, positions, uvs);
    auto& quad = mesh.GetVertexArray(0);
    quad.SetVertex(WE_IN_POSITION, positions);
    quad.SetVertex(WE_IN_TEXCOORD, uvs);
}

void AddParticleIndexArray(SceneMesh& mesh, uint32_t count) {
    const auto layout = PlanParticleIndexLayout(count);
    mesh.AddIndexArray(SceneIndexArray(count, layout.width));
}

/// What the generators of one particle file read besides their own JSON.
ParticleParseContext MakeParticleParseContext(
    ParticleSubSystem& pSys, const wpscene::Particle& wp,
    const std::shared_ptr<const wpscene::ParticleInstanceoverride>& over, Scene* scene,
    bool pixel_canvas, bool tint_after_retint) {
    ParticleParseContext ctx;
    ctx.tint_after_retint = tint_after_retint;
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
/// The blend mode a material's `blending` word names. `disabled` writes the
/// fragment as it is, like `normal`; a word outside the list reads as `normal`.
BlendMode ParseSceneBlendMode(std::string_view word) {
    if (word == "translucent") return BlendMode::Translucent;
    if (word == "additive") return BlendMode::Additive;
    if (word == "alphatocoverage") return BlendMode::AlphaToCoverage;
    if (word != "normal" && word != "disabled") {
        LOG_ERROR("unknown blending '%s', reading it as normal", std::string(word).c_str());
    }
    return BlendMode::Normal;
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

bool AlignmentHasAnchorOffset(std::string_view align) {
    for (const auto edge : { "top", "bottom", "left", "right" }) {
        if (align.find(edge) != std::string_view::npos) return true;
    }
    return false;
}

/// Where an aligned image layer's quad centre lies from its origin: half the
/// scaled size towards the middle from the edge or corner the word names (`bottom`
/// beats `top`, `left` beats `right`), turned by the layer's angles so a rotated
/// layer keeps that edge on the origin.
Vector3f AlignmentAnchorOffset(std::string_view align, const std::array<float, 2>& size,
                               const Vector3f& scale, const Vector3f& angles) {
    const auto names = [align](std::string_view edge) {
        return align.find(edge) != std::string_view::npos;
    };
    const double half_x = static_cast<double>(size[0]) * scale.x() * 0.5;
    const double half_y = static_cast<double>(size[1]) * scale.y() * 0.5;
    double       x      = 0.0;
    double       y      = 0.0;
    if (names("bottom")) y = half_y;
    else if (names("top")) y = -half_y;
    if (names("left")) x = half_x;
    else if (names("right")) x = -half_x;
    if (x == 0.0 && y == 0.0) return Vector3f::Zero();
    const Matrix4d turn = SceneNode::LocalTransOf(Vector3f::Zero(), Vector3f(1.0f, 1.0f, 1.0f), angles);
    const double   rx   = turn(0, 0) * x + turn(0, 1) * y;
    const double   ry   = turn(1, 0) * x + turn(1, 1) * y;
    const double   rz   = turn(2, 0) * x + turn(2, 1) * y;
    return Vector3f(static_cast<float>(rx), static_cast<float>(ry), static_cast<float>(rz));
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

// Whether an effect is part of the chain a layer is built with: one that is
// visible, or one a script may switch on later. Wallpaper Engine keeps every
// effect of a layer and runs the ones its effect object says are visible.
bool EffectIsBuilt(const wpscene::WPImageEffect& effect) {
    return effect.visible || effect.scripted_visible;
}

/// The padding a text object's file gives, on each axis: capped at 512 pixels from above and not
/// floored, since Wallpaper Engine lets a negative padding take the card in around the text.
linalg::Vector2f AuthoredTextCardPadding(const wpscene::WPTextObject& obj) {
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
    // The script that decides the effect's visibility has the effect as its `thisObject`.
    auto reference = runtime.RegisterEffectObject(runtime_name, effect);
    runtime.RegisterEffectVisibility(
        effect, ResolveBoolSetting(runtime, source.visible_setting, runtime_name, -1,
                                   std::move(reference)));
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

/// Gives `node` the local translation, scale and angles that make its local matrix
/// `transform` (translation, then z, y and x rotations, then scale: the order
/// `SceneNode::LocalTransOf` composes). A mirrored matrix carries its mirror on x.
void SetNodeTransformFromMatrix(SceneNode& node, const Matrix4d& transform) {
    const auto at = [&transform](int row, int column) { return transform(row, column); };
    std::array<double, 3> scale {};
    for (int column = 0; column < 3; ++column) {
        scale[column] = std::sqrt(at(0, column) * at(0, column) + at(1, column) * at(1, column) +
                                  at(2, column) * at(2, column));
    }
    // The sign of the 3x3 part's determinant tells a mirror from a turn.
    const double det = at(0, 0) * (at(1, 1) * at(2, 2) - at(1, 2) * at(2, 1)) -
                       at(0, 1) * (at(1, 0) * at(2, 2) - at(1, 2) * at(2, 0)) +
                       at(0, 2) * (at(1, 0) * at(2, 1) - at(1, 1) * at(2, 0));
    if (det < 0.0) scale[0] = -scale[0];
    double rotation[3][3];
    for (int column = 0; column < 3; ++column) {
        for (int row = 0; row < 3; ++row) {
            rotation[row][column] = std::abs(scale[column]) > 1e-12 ? at(row, column) / scale[column]
                                                                    : (row == column ? 1.0 : 0.0);
        }
    }
    // R = Rz * Ry * Rx.
    const double sin_y = std::clamp(-rotation[2][0], -1.0, 1.0);
    double       x     = 0.0;
    double       y     = std::asin(sin_y);
    double       z     = 0.0;
    if (std::abs(sin_y) < 1.0 - 1e-9) {
        x = std::atan2(rotation[2][1], rotation[2][2]);
        z = std::atan2(rotation[1][0], rotation[0][0]);
    } else {
        x = std::atan2(-rotation[1][2], rotation[1][1]);
    }
    node.SetTranslate(Vector3f(static_cast<float>(at(0, 3)), static_cast<float>(at(1, 3)),
                               static_cast<float>(at(2, 3))));
    node.SetScale(Vector3f(static_cast<float>(scale[0]), static_cast<float>(scale[1]),
                           static_cast<float>(scale[2])));
    node.SetRotation(Vector3f(static_cast<float>(x), static_cast<float>(y), static_cast<float>(z)));
}

// ---------------------------------------------------------------------------
// Materials: constants, texture slots and the shader compile (P2 R23 to R48).
// ---------------------------------------------------------------------------

/// A constant as the setting resolvers read it: the authored lanes plus the
/// binding members, in the shape of a scene-object setting.
nlohmann::json MaterialConstantSettingJson(const wpscene::WPConstantShaderValue& source) {
    nlohmann::json setting = nlohmann::json::object();
    if (! source.value.empty()) {
        setting["value"] = source.value.size() == 1 ? nlohmann::json(source.value.front())
                                                    : nlohmann::json(source.value);
    }
    // The binding members, each copied across only when the constant has it.
    // The flag form keeps its condition; a plain name stays a plain name.
    const nlohmann::json user_name =
        source.user_condition.has_value()
            ? nlohmann::json { { "name", source.user }, { "condition", *source.user_condition } }
            : nlohmann::json(source.user);
    const nlohmann::json script_text = source.script;
    const std::pair<const char*, const nlohmann::json*> bindings[] = {
        { "user", source.user.empty() ? nullptr : &user_name },
        { "script", source.script.empty() ? nullptr : &script_text },
        { "scriptproperties", source.scriptproperties.is_object() ? &source.scriptproperties : nullptr },
        { "animation", source.animation.is_object() ? &source.animation : nullptr },
    };
    for (const auto& [key, content] : bindings) {
        if (content != nullptr) setting.emplace(key, *content);
    }
    return setting;
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

/// The uniform a constant's key names: the shader layer's alias list (a material
/// key, or a uniform name without its two-character prefix).
std::optional<std::string> ConstantUniformName(const WPShaderInfo& info, const std::string& key) {
    if (const auto found = info.alias.find(key); found != info.alias.end()) return found->second;
    return std::nullopt;
}

/// A key with no uniform is silent when the shader declares `<key>Start` and
/// `<key>End` and the material supplies both: the pair stands in for the key.
bool ConstantIsSplitInTwo(const WPShaderInfo& info, const wpscene::WPMaterial& wpmat,
                          const std::string& key) {
    const auto supplied = [&](const std::string& part) {
        return info.alias.contains(part) && wpmat.constantshadervalues.contains(part);
    };
    return supplied(key + "Start") && supplied(key + "End");
}

struct ResolvedConstant {
    std::string                           key;
    std::string                           uniform;
    const wpscene::WPConstantShaderValue* constant { nullptr };
};

/// The uniform of every constant that names one, in key order. The keys that
/// resolve to nothing (and are not a Start/End pair) go to `unmatched` when given.
std::vector<ResolvedConstant> ResolveConstantUniforms(const wpscene::WPMaterial& wpmat,
                                                      const WPShaderInfo&        info,
                                                      std::vector<std::string>*  unmatched = nullptr) {
    std::vector<ResolvedConstant> resolved;
    std::vector<std::string> keys;
    keys.reserve(wpmat.constantshadervalues.size());
    for (const auto& entry : wpmat.constantshadervalues) keys.push_back(entry.first);
    std::sort(keys.begin(), keys.end());
    for (const auto& key : keys) {
        const auto& constant = wpmat.constantshadervalues.at(key);
        if (const auto uniform = ConstantUniformName(info, key); uniform.has_value()) {
            resolved.push_back({ key, *uniform, &constant });
        } else if (unmatched != nullptr && ! ConstantIsSplitInTwo(info, wpmat, key)) {
            unmatched->push_back(key);
        }
    }
    return resolved;
}

enum class MaterialConstantWrite { Replace, Overlay };

/// Writes the authored lanes of every constant that has a uniform. Effect
/// restoration overlays the chosen layer defaults without replacing their tails.
void LoadStaticMaterialConstants(SceneMaterial& material, const wpscene::WPMaterial& wpmat,
                                 const WPShaderInfo& info, bool report_unmatched = true,
                                 MaterialConstantWrite write = MaterialConstantWrite::Replace) {
    std::vector<std::string> unmatched;
    const auto resolved = ResolveConstantUniforms(wpmat, info, report_unmatched ? &unmatched : nullptr);
    for (const auto& key : unmatched) LOG_ERROR("ShaderValue: %s not found in glsl", key.c_str());
    for (const auto& entry : resolved) {
        if (entry.constant->value.empty()) continue;
        auto& value = material.customShader.constValues[entry.uniform];
        const auto& authored = entry.constant->value;
        if (write == MaterialConstantWrite::Overlay && authored.size() < value.size()) {
            for (std::size_t lane = 0; lane < authored.size(); ++lane) value[lane] = authored[lane];
        } else {
            value = ShaderValue(authored.data(), authored.size());
        }
    }
}

/// One timeline-driven constant, ready to register: its curves (a follower's
/// already set to play once) and the clock it reads.
using ConstantTimelineTable = std::unordered_map<std::string, std::shared_ptr<MaterialConstantAnimation>>;

/// Which clock a constant's timeline reads. `root` names the constant that owns the
/// clock; for a broken chain it names what broke the chain instead (the parent that is
/// not a timeline of the pass, or the constant where a loop closed), so constants that
/// share the fault share the group.
struct ConstantClockGroup {
    std::string root;
    bool        frozen { false };

    std::string Label() const { return (frozen ? "!" : "=") + root; }
};

/// Resolves the group of `key` by following `options.parent.key`, memoising every
/// member it passes (linear overall).
ConstantClockGroup
GroupOfConstantTimeline(const std::string&                                                  key,
                        const std::unordered_map<std::string, MaterialConstantAnimationSource>& timelines,
                        std::unordered_map<std::string, ConstantClockGroup>&             memo,
                        std::unordered_set<std::string>&                                 on_path) {
    if (const auto known = memo.find(key); known != memo.end()) return known->second;
    if (! on_path.insert(key).second) return { key, true };

    const std::string& parent = timelines.at(key).parent_key;
    ConstantClockGroup group { key, false };
    if (! parent.empty()) {
        group = timelines.contains(parent) ? GroupOfConstantTimeline(parent, timelines, memo, on_path)
                                           : ConstantClockGroup { parent, true };
    }
    on_path.erase(key);
    memo[key] = group;
    return group;
}

/// Builds the playback of every constant of the pass that a timeline drives, one
/// clock per group registered with the runtime (R46).
ConstantTimelineTable BuildConstantTimelines(SceneRuntimeContext& runtime,
                                             const wpscene::WPMaterial& wpmat,
                                             std::string_view layer_name) {
    auto timelines = CollectMaterialConstantAnimations(wpmat);
    // A constant a property or a script drives is not played from its timeline.
    std::erase_if(timelines, [&](const auto& entry) {
        return HasDynamicSetting(MaterialConstantSettingJson(wpmat.constantshadervalues.at(entry.first)));
    });

    std::vector<std::string> keys;
    keys.reserve(timelines.size());
    for (const auto& entry : timelines) keys.push_back(entry.first);
    std::sort(keys.begin(), keys.end());

    // Phase one: the group of every constant, and what each group spans.
    struct GroupSpan {
        ConstantClockGroup group;
        std::string        lead; // the constant whose curve lends the clock
        double             last_frame { 0.0 };
    };
    std::unordered_map<std::string, ConstantClockGroup> memo;
    std::unordered_set<std::string>                     on_path;
    std::map<std::string, GroupSpan>                    spans; // by group label
    for (const auto& key : keys) {
        const auto group = GroupOfConstantTimeline(key, timelines, memo, on_path);
        auto [at, first_member] = spans.try_emplace(group.Label());
        auto& span = at->second;
        if (first_member) {
            span.group = group;
            span.lead  = group.frozen ? key : group.root;
            if (group.frozen) {
                LOG_ERROR("material constant timelines of '%s' cannot follow their parent (%s)",
                          std::string(layer_name).c_str(), group.root.c_str());
            }
        }
        span.last_frame = std::max(span.last_frame, timelines.at(key).last_frame);
    }

    // Phase two: one clock per group, then every member's playback.
    std::map<std::string, std::shared_ptr<ScalarAnimationPlayback>> clock_of;
    for (const auto& [label, span] : spans) {
        const auto&     lead  = timelines.at(span.lead);
        ScalarAnimation clock = lead.components[lead.first_curve];
        if (span.group.frozen || ! (clock.length_frames > 0.0)) {
            clock.length_frames = std::max(clock.length_frames, span.last_frame);
        }
        clock.start_paused = clock.start_paused || span.group.frozen;
        clock_of[label]    = runtime.RegisterScalarAnimation(layer_name, std::move(clock));
    }

    ConstantTimelineTable table;
    for (const auto& key : keys) {
        const auto& group  = memo.at(key);
        const auto& source = timelines.at(key);
        auto        play   = std::make_shared<MaterialConstantAnimation>();
        play->playback        = clock_of.at(group.Label());
        play->component_count = source.component_count;
        play->components      = source.components;
        if (group.frozen || group.root != key) {
            for (auto& curve : play->components) curve.mode = ScalarAnimationMode::Single;
        }
        table.emplace(key, std::move(play));
    }
    return table;
}

/// The constants of one material pass that a property, a script or a timeline
/// drives, registered with the runtime on the material (R45, R46).
void RegisterDrivenMaterialConstants(ParseContext& context, const std::shared_ptr<SceneMaterial>& material,
                                     const wpscene::WPMaterial& wpmat, const WPShaderInfo& info,
                                     std::string_view layer_name) {
    auto* runtime = context.scene->runtime.get();
    if (runtime == nullptr || material == nullptr) return;

    const auto timelines = BuildConstantTimelines(*runtime, wpmat, layer_name);
    // The constants a script drives that are also keyed: the script's `thisObject` finds the
    // setting's own timeline, on a clock of its own.
    const auto keyed = CollectMaterialConstantAnimations(wpmat);
    for (const auto& entry : ResolveConstantUniforms(wpmat, info)) {
        const auto setting = MaterialConstantSettingJson(*entry.constant);
        if (HasDynamicSetting(setting)) {
            const auto lanes = entry.constant->value.size();
            std::shared_ptr<ScalarAnimationPlayback> own_clock;
            if (setting.contains("script")) {
                if (const auto source = keyed.find(entry.key); source != keyed.end()) {
                    ScalarAnimation clock = source->second.components[source->second.first_curve];
                    if (!(clock.length_frames > 0.0)) clock.length_frames = source->second.last_frame;
                    own_clock = runtime->RegisterSettingClock(std::move(clock));
                }
            }
            auto       value = lanes == 0 ? ResolveStringSetting(*runtime, setting, layer_name)
                                          : ResolveVectorSetting(*runtime, setting, lanes, layer_name,
                                                                 std::move(own_clock));
            runtime->RegisterMaterialConstant(material, entry.uniform, std::move(value));
        } else if (const auto timeline = timelines.find(entry.key); timeline != timelines.end()) {
            runtime->RegisterMaterialConstant(material, entry.uniform,
                                              std::make_unique<DynamicValue>(0.0f), timeline->second);
        }
    }
}

/// The header of a file texture, read once per distinct name per parse.
const ImageHeader& TextureHeaderOf(ParseContext& context, const std::string& name) {
    const auto found = context.texture_headers.find(name);
    if (found != context.texture_headers.end()) return found->second;
    ImageHeader header;
    if (context.scene->imageParser != nullptr) header = context.scene->imageParser->ParseHeader(name);
    return context.texture_headers.emplace(name, std::move(header)).first->second;
}

/// Load-time geometry facts of a file texture. The authored first stored level,
/// not the nominal extent or the budget's first kept mip, establishes padding.
/// Cards and shader resolution constants must make the same decision.
struct FileTextureGeometry {
    std::array<float, 4> resolution;
    float u { 1.0f };
    float v { 1.0f };
};

FileTextureGeometry TextureGeometryOf(const ImageHeader& header) {
    const float iw = static_cast<float>(header.mapWidth);
    const float ih = static_cast<float>(header.mapHeight);
    FileTextureGeometry geometry { .resolution = { iw, ih, iw, ih } };
    if (header.mipmap_larger) {
        geometry.resolution[0] = static_cast<float>(header.width);
        geometry.resolution[1] = static_cast<float>(header.height);
        if (header.width > 0 && header.height > 0 && header.mapWidth > 0 && header.mapHeight > 0) {
            geometry.u = iw / geometry.resolution[0];
            geometry.v = ih / geometry.resolution[1];
        }
    }
    return geometry;
}

/// A primary file slot with usable sheet frames, after the caller's texture
/// substitutions/defaults. Header caching keeps this a load-time-only query.
const ImageHeader* SpriteHeaderOf(ParseContext& context, const std::vector<std::string>& slots) {
    if (slots.empty() || slots[0].empty() || IsSpecTex(slots[0])) return nullptr;
    const auto& header = TextureHeaderOf(context, slots[0]);
    return header.isSprite && header.spriteAnim.numFrames() > 0 ? &header : nullptr;
}

bool IsParticleSheetShader(std::string_view shader) {
    return shader == "genericparticle" || shader == "genericropeparticle";
}

bool ParticleSheetUsesWholeCells(const ImageHeader& header) {
    const auto power_of_two = [](int32_t size) { return size > 0 && (size & (size - 1)) == 0; };
    return power_of_two(header.width) && power_of_two(header.height);
}

/// Records a file texture the scene draws with: its sampling, whether it is a
/// video or a sprite sheet. One entry exists per distinct name.
void RegisterFileTexture(ParseContext& context, const std::string& name, const ImageHeader& header) {
    auto& textures = context.scene->textures;
    if (textures.contains(name)) return;
    SceneTexture texture;
    texture.url         = name;
    texture.sample      = header.sample;
    texture.isVideo     = header.isVideo;
    texture.isSprite    = header.isSprite && header.spriteAnim.numFrames() > 0;
    if (header.isSprite && ! texture.isSprite) {
        LOG_ERROR("texture '%s' has no sprite frames; using it as a static texture", name.c_str());
    }
    texture.spriteAnim  = header.spriteAnim;
    textures[name]      = std::move(texture);
}

/// What the texture string of a slot turns into after the classification of R34:
/// the name the draw samples (empty when the slot stays unbound), and whether it is
/// another layer's composite.
struct ClassifiedTexture {
    std::string name;
    bool        is_file { false };
    bool        is_target { false };
};

ClassifiedTexture ClassifyTexture(ParseContext& context, const std::string& authored,
                                  std::string_view shader, bool has_blend_combo) {
    ClassifiedTexture result;
    if (authored.empty()) return result;
    auto& scene = *context.scene;

    // Runtime pictures (a now-playing cover) are neither layers nor targets.
    const auto* runtime_images = dynamic_cast<RuntimeImageSource*>(scene.imageParser.get());
    if (runtime_images != nullptr && runtime_images->IsRuntimeImage(authored)) {
        result.name    = authored;
        result.is_file = true;
        return result;
    }
    static const LayerObjectIndex kNoLayers;
    const auto resolution = ResolveLayerTextureName(
        authored, g_parse_layer_index != nullptr ? *g_parse_layer_index : kNoLayers, context.vfs);
    if (! resolution.error.empty()) {
        LOG_ERROR("texture '%s' cannot be resolved: %s", authored.c_str(), resolution.error.c_str());
        return result;
    }
    if (resolution.is_layer) {
        result.name = resolution.resolved;
        return result;
    }
    if (! IsSpecTex(authored)) {
        result.name    = authored;
        result.is_file = true;
        return result;
    }
    // Special names (R28, R29).
    if (authored == "_rt_FullFrameBuffer") {
        if (shader == "genericimage2" && ! has_blend_combo) return result;
        result.name      = std::string(SpecTex_Default);
        result.is_target = true;
        return result;
    }
    if (! scene.HasRenderTarget(authored)) {
        LOG_ERROR("render target '%s' is not registered, leaving the texture slot unbound",
                  authored.c_str());
        return result;
    }
    result.name      = authored;
    result.is_target = true;
    return result;
}

/// What the shader layer is told about each slot of a pass.
std::vector<WPShaderTexInfo> SlotInfos(ParseContext& context, const std::vector<std::string>& slots,
                                       const std::vector<bool>& author_supplied) {
    std::vector<WPShaderTexInfo> infos(slots.size());
    for (std::size_t slot = 0; slot < slots.size(); ++slot) {
        auto& info   = infos[slot];
        info.present = slot < author_supplied.size() && author_supplied[slot];
        const auto& name = slots[slot];
        if (name.empty()) continue;
        if (IsSpecTex(name)) {
            // Render targets are always known to carry every component.
            info.enabled      = true;
            info.composEnabled = { true, true, true, true };
            continue;
        }
        const auto& header = TextureHeaderOf(context, name);
        info.format        = header.format;
        if (header.extraHeader.contains("compo1")) {
            info.enabled = true;
            for (std::size_t component = 0; component < 4; ++component) {
                const auto found = header.extraHeader.find("compo" + std::to_string(component + 1));
                info.composEnabled[component] = found != header.extraHeader.end() && found->second.val != 0;
            }
        }
    }
    return infos;
}

/// What a loaded material leaves to its caller.
struct MaterialLoadOptions {
    /// The pass is drawn where the scene's fog does not belong (the card of a
    /// layer composited through effects): fog stays out of it and `fog_deferred`
    /// of the shader info says the pass would have taken it.
    bool defer_fog { false };
    /// A synthesized puppet close must consume the processed sheet even if the
    /// copied material or its user texture supplies slot 0. Applied before any
    /// classification/compilation. Empty leaves ordinary pass routing alone.
    std::string_view required_texture0;
    /// Settle particle sheet/layout combos from the same final slot list as the
    /// compiler (including user replacements and sampler-default textures).
    bool particle_material { false };
    /// The two stages of a program made in code; with both empty the shader's
    /// files are read from the asset namespace.
    std::string vertex_source;
    std::string fragment_source;
};

struct LoadedMaterial {
    WPShaderInfo                               info;
    std::vector<std::pair<usize, std::string>> render_targets;
};

constexpr std::size_t kMaxTextureSlots   = 13;
constexpr int         kMaxCompileRounds  = 8;

/// Whether the picture a `scenetexture` property chose can be opened: a texture or loose
/// picture the project holds, a video, or one of the names the renderer itself supplies.
/// (The slot takes the name either way; this decides only whether the layer's colour still
/// shows.)
bool ChosenPictureOpens(ParseContext& context, const std::string& name) {
    if (name.empty()) return false;
    if (IsSpecTex(name)) return true;
    const auto* runtime_images = dynamic_cast<RuntimeImageSource*>(context.scene->imageParser.get());
    if (runtime_images != nullptr && runtime_images->IsRuntimeImage(name)) return true;
    const auto& header = TextureHeaderOf(context, name);
    return header.width > 0 || header.mapWidth > 0 || header.isVideo;
}

/// Whether a chosen picture fills the solid-colour placeholder this material is made of: the
/// texture slot a `scenetexture` property names resolves, now, to a picture that can be opened,
/// and the slot held no picture of its own. The layer then draws that picture as it is.
bool ChosenPictureFillsPlaceholder(ParseContext& context, const wpscene::WPMaterial& wpmat) {
    if (context.scene->runtime == nullptr || wpmat.usertextures.empty()) return false;
    if (UserTexturePropertyName(wpmat.usertextures.front()).empty()) return false;
    const std::string shipped = wpmat.textures.empty() ? std::string() : wpmat.textures.front();
    if (! shipped.empty() && shipped != "util/white") return false;
    std::vector<std::string> slots { shipped };
    ApplySystemUserTextures(slots, { wpmat.usertextures.front() },
                            &context.scene->runtime->projectProperties(), nullptr);
    return slots.front() != shipped && ChosenPictureOpens(context, slots.front());
}

/// Loads a material (R23 to R30, R39, R48): reads the shader, settles its combos
/// and default textures, clears the slots the shader does not sample, and fills the
/// material with its state, textures, shader and base constants. False when the
/// shader cannot be read, does not compile or never settles.
bool LoadMaterial(ParseContext& context, const wpscene::WPMaterial& wpmat, SceneMaterial& material,
                  LoadedMaterial& loaded, const MaterialLoadOptions& options = {}) {
    auto& scene = *context.scene;
    if (wpmat.shader.empty()) return false;
    const std::string base = "/assets/shaders/" + wpmat.shader;
    std::vector<WPShaderUnit> units(2);
    units[0].stage = ShaderType::VERTEX;
    units[1].stage = ShaderType::FRAGMENT;
    if (! options.vertex_source.empty() && ! options.fragment_source.empty()) {
        units[0].src = options.vertex_source;
        units[1].src = options.fragment_source;
    } else {
        units[0].src = fs::GetFileContent(*context.vfs, base + ".vert");
        units[1].src = fs::GetFileContent(*context.vfs, base + ".frag");
    }
    if (units[0].src.empty() || units[1].src.empty()) {
        LOG_ERROR("shader '%s' is missing its source files", wpmat.shader.c_str());
        return false;
    }

    // The textures: the material's, with user textures and cover slots put in.
    std::vector<std::string> slots = wpmat.textures;
    const ProjectProperties* properties =
        scene.runtime != nullptr ? &scene.runtime->projectProperties() : nullptr;
    // A cover slot over another layer's composite keeps that composite as its texture and
    // swaps to the cover in the renderer once one exists; it takes no stand-in image.
    auto                     usertextures = wpmat.usertextures;
    std::vector<std::string> cover_slots(slots.size());
    for (std::size_t slot = 0; slot < usertextures.size() && slot < slots.size(); ++slot) {
        if (! wpscene::IsSystemUserTexture(usertextures[slot]) || slots[slot].empty()) continue;
        static const LayerObjectIndex kNoLayers;
        const auto authored = ResolveLayerTextureName(
            slots[slot], g_parse_layer_index != nullptr ? *g_parse_layer_index : kNoLayers, context.vfs);
        if (! authored.is_layer || ! authored.error.empty()) continue;
        cover_slots[slot] = usertextures[slot].name;
        usertextures[slot] = {};
    }
    ApplySystemUserTextures(slots, usertextures, properties,
                            dynamic_cast<RuntimeImageSource*>(scene.imageParser.get()));
    if (scene.runtime != nullptr) {
        for (const auto& user : wpmat.usertextures) {
            const auto property = UserTexturePropertyName(user);
            if (! property.empty()) scene.runtime->NoteLoadOnlyProperty(property);
        }
    }
    if (! options.required_texture0.empty()) {
        slots.resize(std::max<std::size_t>(slots.size(), 1));
        slots[0] = options.required_texture0;
        if (! cover_slots.empty()) cover_slots[0].clear();
    }
    if (slots.size() > kMaxTextureSlots) slots.resize(kMaxTextureSlots);
    std::vector<bool> author_supplied(slots.size());
    for (std::size_t slot = 0; slot < slots.size(); ++slot) author_supplied[slot] = ! slots[slot].empty();

    // The combos the request starts from: the material's, then the engine's.
    Combos base_combos;
    for (const auto& [name, value] : wpmat.combos) base_combos[name] = std::to_string(value);
    base_combos["HDR"]         = scene.hdr ? "1" : "0";
    base_combos["SCENE_ORTHO"] = context.is_ortho ? "1" : "0";
    if (! scene.light_config.empty()) {
        base_combos["LIGHTS_POINT"]       = std::to_string(scene.light_config.point);
        base_combos["LIGHTS_SPOT"]        = std::to_string(scene.light_config.spot);
        base_combos["LIGHTS_TUBE"]        = std::to_string(scene.light_config.tube);
        base_combos["LIGHTS_DIRECTIONAL"] = std::to_string(scene.light_config.directional);
    }
    const BlendMode blend = ParseSceneBlendMode(wpmat.blending);
    if (blend == BlendMode::AlphaToCoverage) base_combos["ALPHATOCOVERAGE"] = "1";

    const bool has_blend_combo = wpmat.combos.contains("BLENDMODE");
    std::vector<ClassifiedTexture> classified(slots.size());
    const auto classify_all = [&]() {
        for (std::size_t slot = 0; slot < slots.size(); ++slot) {
            classified[slot] = ClassifyTexture(context, slots[slot], wpmat.shader, has_blend_combo);
            slots[slot]      = classified[slot].name;
        }
    };
    // Classification is repeated only for slots that change; first pass handles the authored.
    classify_all();

    const auto texture_keys_of = [&]() { return slots; };
    // A cached header pointer, valid only during this load. The selected program's
    // sheet facts survive resource pruning without retaining an unused GPU texture.
    const ImageHeader* compiled_sheet = nullptr;
    const auto compile = [&](WPShaderInfo& info, Combos combos, std::string* reflection,
                             const std::shared_ptr<SceneShader>& shader) {
        if (options.particle_material) {
            const auto* sheet = SpriteHeaderOf(context, slots);
            const bool sheet_material = sheet != nullptr && IsParticleSheetShader(wpmat.shader);
            compiled_sheet = sheet_material ? sheet : nullptr;
            combos["SPRITESHEET"] = sheet_material ? "1" : "0";
            if (sheet != nullptr) combos["THICKFORMAT"] = "1";
            combos["SPRITESHEETBLENDNPOT"] =
                sheet_material && ParticleSheetUsesWholeCells(*sheet) ? "1" : "0";
        }
        info.combos = std::move(combos);
        for (std::size_t slot = 0; slot < slots.size(); ++slot) {
            if (slots[slot].empty() || IsSpecTex(slots[slot])) continue;
            shader::ApplyTextureFormatCombo(info.combos, slot, TextureHeaderOf(context, slots[slot]).format);
        }
        const auto texinfos = SlotInfos(context, slots, author_supplied);
        return CompileAndQueueMetalProgram(shader, scene.scene_id, wpmat.shader, units, *context.vfs,
                                           &info, texinfos, texture_keys_of(), reflection);
    };

    auto shader = std::make_shared<SceneShader>();
    shader->name = wpmat.shader;
    shader->id   = 0;
    WPShaderInfo info;
    std::string  reflection;
    Combos       combos = base_combos;
    bool         settled = false;
    for (int round = 0; round < kMaxCompileRounds && ! settled; ++round) {
        info = WPShaderInfo {};
        if (! compile(info, combos, &reflection, shader)) return false;
        // Defaults fill only the slots nothing was put in; a slot named twice is filled once.
        bool filled = false;
        for (const auto& [slot, name] : info.defTexs) {
            if (slot < 0 || static_cast<std::size_t>(slot) >= kMaxTextureSlots) continue;
            const auto index = static_cast<std::size_t>(slot);
            if (index >= slots.size()) {
                slots.resize(index + 1);
                classified.resize(index + 1);
                author_supplied.resize(index + 1, false);
            }
            if (! slots[index].empty()) continue;
            const auto result = ClassifyTexture(context, name, wpmat.shader, has_blend_combo);
            if (result.name.empty()) continue;
            slots[index]      = result.name;
            classified[index] = result;
            filled            = true;
        }
        settled = ! filled;
        // The combos the settled compile reported feed the next round only through the
        // slots; the request starts from the same base every time.
    }
    if (! settled) {
        LOG_ERROR("shader '%s' never settled its default textures", wpmat.shader.c_str());
        return false;
    }

    // Fog (R48): a pass whose effective FOG combo is on is compiled once more with the
    // scene's fog, unless the closing pass of its chain takes it.
    const bool scene_fog = scene.fog_distance || scene.fog_height;
    if (scene_fog) {
        const auto fog = info.combos.find("FOG");
        if (fog != info.combos.end() && fog->second != "0") {
            if (options.defer_fog) {
                info.fog_deferred = true;
            } else {
                Combos with_fog = base_combos;
                if (scene.fog_distance) with_fog["FOG_DIST"] = "1";
                if (scene.fog_height) with_fog["FOG_HEIGHT"] = "1";
                with_fog["FOG_COMPUTED"] = "1";
                WPShaderInfo fogged;
                if (! compile(fogged, with_fog, &reflection, shader)) return false;
                fogged.fog_deferred = false;
                info                = std::move(fogged);
            }
        }
    }

    // Slots the shader never samples hold nothing (R27).
    std::unordered_set<uint> sampled;
    for (const auto& unit : units) {
        sampled.insert(unit.preprocess_info.active_tex_slots.begin(),
                       unit.preprocess_info.active_tex_slots.end());
    }
    for (std::size_t slot = 0; slot < slots.size(); ++slot) {
        if (! slots[slot].empty() && ! sampled.contains(static_cast<uint>(slot))) {
            slots[slot].clear();
            classified[slot] = {};
        }
    }

    // A slot the shader samples and nobody bound reads zero in every channel, as a null
    // resource does in Direct3D. Only a slot the author left out, or listed as null, is
    // bound so, and only after the shader's own defaults have had their say; a texture the
    // author named that cannot be found, or a layer that does not resolve, stays unbound
    // and keeps its failure. Whether the slot counts as supplied (the switches that follow
    // "a texture is bound") was settled above and does not change.
    for (const uint slot : sampled) {
        if (slot >= kMaxTextureSlots) continue;
        if (slot >= slots.size()) {
            slots.resize(slot + 1);
            classified.resize(slot + 1);
            author_supplied.resize(slot + 1, false);
        }
        if (! slots[slot].empty() || author_supplied[slot]) continue;
        slots[slot]           = kUnboundTextureName;
        classified[slot].name = kUnboundTextureName;
        classified[slot].is_file = true;
    }

    // The scene's own constants first, then what each slot knows about its texture (R23).
    auto& constants = material.customShader.constValues;
    for (const auto& [name, value] : context.global_base_uniforms) constants[name] = value;
    for (std::size_t slot = 0; slot < slots.size(); ++slot) {
        const auto& name = slots[slot];
        if (name.empty()) continue;
        if (IsSpecLinkTex(name)) {
            // Another layer's composite: its size is the value updater's to supply.
            loaded.render_targets.emplace_back(slot, name);
            continue;
        }
        std::array<float, 4> resolution {};
        if (classified[slot].is_target) {
            const auto* target = scene.FindRenderTarget(name);
            if (target == nullptr) continue;
            const float w = static_cast<float>(target->width);
            const float h = static_cast<float>(target->height);
            resolution    = { w, h, w, h };
            loaded.render_targets.emplace_back(slot, scene.ResolveRenderTargetName(name));
        } else {
            const auto& header = TextureHeaderOf(context, name);
            resolution = TextureGeometryOf(header).resolution;
            RegisterFileTexture(context, name, header);
            if (header.isSprite && header.spriteAnim.numFrames() > 0) material.hasSprite = true;
        }
        constants[std::string(WE_GLTEX_RESOLUTION_NAMES[slot])] = ShaderValue(resolution.data(), 4);
        if (resolution[2] != 0.0f && resolution[3] != 0.0f) {
            const std::array<float, 4> texel { 1.0f / resolution[2], 1.0f / resolution[3],
                                               resolution[2], resolution[3] };
            constants[std::string(WE_GLTEX_TEXEL_NAMES[slot])] = ShaderValue(texel.data(), 4);
        }
    }

    shader->default_uniforms = info.svs;
    shader->rust_reflection_json = reflection;
    material.name                  = wpmat.shader;
    material.textures              = slots;
    material.cover_slots.clear();
    for (std::size_t slot = 0; slot < cover_slots.size() && slot < slots.size(); ++slot) {
        if (cover_slots[slot].empty() || slots[slot].empty()) continue;
        material.cover_slots.resize(slots.size());
        material.cover_slots[slot] = cover_slots[slot];
    }
    material.customShader.shader   = shader;
    material.blenmode              = blend;
    material.cull_mode             = ParseSceneCullMode(wpmat.cullmode);
    ApplyMaterialDepth(material, wpmat);
    material.defines.clear();
    for (const auto& [name, value] : info.combos) {
        if (value != "0") material.defines.push_back(name);
    }
    std::sort(material.defines.begin(), material.defines.end());
    if (const auto audio = info.combos.find("AUDIOPROCESSING");
        audio != info.combos.end() && audio->second != "0") {
        MarkSceneRequiresAudioResponse(&scene);
    }
    LoadStaticMaterialConstants(material, wpmat, info);
    // Intrinsic particle facts finalize after authored constants, just as they did
    // in particle preparation. They describe the compiled program, not its pruned slots.
    if (compiled_sheet != nullptr) {
        const auto& frame = compiled_sheet->spriteAnim.FrameAt(0);
        constants["g_RenderVar1"] = ShaderValue(std::array<float, 4> {
            frame.xAxis[0], frame.yAxis[1],
            static_cast<float>(compiled_sheet->spriteAnim.numFrames()), frame.rate });
        // Whole-cell rounding uses texels; subtexel/non-finite cells cannot divide.
        const float cell_w = std::trunc(frame.width);
        const float cell_h = std::trunc(frame.height);
        const auto resolution = constants.find("g_Texture0Resolution");
        if (ParticleSheetUsesWholeCells(*compiled_sheet) && std::isfinite(cell_w) &&
            std::isfinite(cell_h) && cell_w >= 1.0f && cell_h >= 1.0f &&
            resolution != constants.end() && resolution->second.size() >= 4) {
            const auto& value = resolution->second;
            constants["g_Texture0Resolution"] = ShaderValue(std::array<float, 4> {
                value[0], value[1], value[2] - std::fmod(value[2], cell_w),
                value[3] - std::fmod(value[3], cell_h) });
        }
    }
    loaded.info = std::move(info);
    return true;
}

/// The four corners `point0` to `point3` of the first effect's first pass, in the
/// 0..1 square of the shape, if all four are there.
std::optional<std::array<linalg::Vector2f, 4>>
ShapeCornerPoints(const wpscene::WPShapeObject& obj) {
    if (obj.effects.empty() || obj.effects.front().materials.empty()) return std::nullopt;
    auto material = obj.effects.front().materials.front();
    if (! obj.effects.front().passes.empty()) material.MergePass(obj.effects.front().passes.front());
    std::array<linalg::Vector2f, 4> points;
    for (std::size_t index = 0; index < points.size(); ++index) {
        const auto value = material.constantshadervalues.find("point" + std::to_string(index));
        if (value == material.constantshadervalues.end() || value->second.value.size() < 2) {
            return std::nullopt;
        }
        points[index] = linalg::Vector2f(value->second.value[0], value->second.value[1]);
    }
    return points;
}

bool ScriptHandlesCursor(std::string_view script) {
    return script.find("cursor") != std::string_view::npos;
}

bool SettingHandlesCursor(const nlohmann::json& setting) {
    if (! setting.is_object()) return false;
    const auto script = setting.find("script");
    return script != setting.end() && script->is_string() &&
           ScriptHandlesCursor(script->get_ref<const std::string&>());
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
        const auto is_dynamic = [](const nlohmann::json& value) {
            return value.is_object() && (value.contains("user") || value.contains("script"));
        };
        if (setting.contains("visible") && is_dynamic(setting.at("visible"))) {
            runtime.RegisterDynamicValueListener(
                ResolveBoolSetting(runtime, setting.at("visible"), runtime_name, layer_index),
                [layer, layer_index](const DynamicValue& value) mutable {
                    layer.setVisible(layer_index, value.getBool());
                });
        }
        if (setting.contains("rate") && is_dynamic(setting.at("rate"))) {
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, setting.at("rate"), runtime_name, layer_index),
                [layer, layer_index](const DynamicValue& value) mutable {
                    layer.setRate(layer_index, value.getFloat());
                });
        }
        if (setting.contains("blend") && is_dynamic(setting.at("blend"))) {
            runtime.RegisterDynamicValueListener(
                ResolveFloatSetting(runtime, setting.at("blend"), runtime_name, layer_index),
                [layer, layer_index](const DynamicValue& value) mutable {
                    layer.setBlend(layer_index, value.getFloat());
                });
        }
    }
}

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
    // A render target or a link texture has no header; neither does a file that
    // could not be read, whose default sample is not a request for points -- which
    // is why a texture already registered cannot be asked, its sample is that
    // default as well.
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
    } else {
        value = ResolveFloatSetting(runtime, setting)->getFloat();
    }
    runtime.NoteLoadOnlyProperty(UserPropertyName(setting));
}

/// `ResolveLoadOnlySceneSetting` for a colour.
void ResolveLoadOnlySceneVec3(SceneRuntimeContext& runtime, const nlohmann::json& setting,
                              std::array<float, 3>& value) {
    if (! HasDynamicSetting(setting)) return;
    const linalg::Vector3f resolved = ResolveVec3Setting(runtime, setting)->getVec3();
    value                = { resolved.x(), resolved.y(), resolved.z() };
    runtime.NoteLoadOnlyProperty(UserPropertyName(setting));
}

// The scene's wind and gravity (`windenabled`, `winddirection`, `windstrength`,
// `gravitydirection`, `gravitystrength`) are read into the scene description and
// reach no one: the particle simulation takes only the gravity of its own `movement`
// operator and has no entry for a scene-wide force (P4 asks for none).

/// Wallpaper Engine composes a layer from the flags and shader of its model, not
/// from the model's path. These are the editor's two models of that kind: the
/// composition layer, and the one that also tests depth.
bool IsComposeLayerModel(std::string_view image) {
    return image == "models/util/composelayer.json" ||
           image == "models/util/composelayer_depthtest.json";
}

// ---------------------------------------------------------------------------
// Image layers (P2 R1 to R22, R38 to R92).
// ---------------------------------------------------------------------------

/// Writes a layer's alpha into one material: `g_Color4`'s alpha, `g_Alpha`, and
/// `g_UserAlpha` where the pass has no opacity of its own (R40).
void SetMaterialAlpha(SceneMaterial& material, float alpha) {
    auto& values = material.customShader.constValues;
    if (! material.own_user_alpha) values["g_UserAlpha"] = ShaderValue(alpha);
    values["g_Alpha"] = ShaderValue(alpha);
    std::array<float, 4> tint { 1.0f, 1.0f, 1.0f, alpha };
    if (const auto held = values.find("g_Color4"); held != values.end() && held->second.size() >= 3) {
        tint[0] = held->second[0];
        tint[1] = held->second[1];
        tint[2] = held->second[2];
    }
    values["g_Color4"] = ShaderValue(tint);
}

/// The colour, brightness and alpha a layer's passes start with (R39, R40). A pass
/// that only copies or blends what the chain made takes white.
void SetLayerTint(const ParseContext& context, SceneMaterial& material, const wpscene::WPImageObject& image,
                  bool white) {
    auto& values = material.customShader.constValues;
    if (white) {
        values["g_Color4"] = ShaderValue(std::array<float, 4> { 1.0f, 1.0f, 1.0f, 1.0f });
        values["g_Color"]  = ShaderValue(std::array<float, 3> { 1.0f, 1.0f, 1.0f });
        return;
    }
    const float brightness = context.scene->hdr ? image.brightness : 1.0f;
    material.tint.color      = image.color;
    material.tint.brightness = brightness;
    values["g_Color"]        = ShaderValue(image.color.data(), 3);
    values["g_Color4"]       = ShaderValue(std::array<float, 4> {
        image.color[0] * brightness, image.color[1] * brightness, image.color[2] * brightness,
        image.alpha });
    values["g_Alpha"]        = ShaderValue(image.alpha);
    if (! material.own_user_alpha || ! values.contains("g_UserAlpha")) {
        values["g_UserAlpha"] = ShaderValue(image.alpha);
    }
}

/// Hands a layer's alpha to the runtime on every material it owns (R40, R90): a
/// property, a script that exports `update` or a timeline owns it; with none of
/// them a script may write it.
void RegisterAlphaSetting(ParseContext& context, const std::string& key,
                          const nlohmann::json& setting, float authored,
                          const std::vector<std::shared_ptr<SceneMaterial>>& materials) {
    auto* runtime = context.scene->runtime.get();
    if (runtime == nullptr || materials.empty()) return;
    if (HasDynamicSetting(setting)) {
        auto value = ResolveFloatSetting(*runtime, setting, key);
        runtime->RegisterDynamicValueListener(
            std::move(value), [materials](const DynamicValue& now) {
                for (const auto& material : materials) SetMaterialAlpha(*material, now.getFloat());
            });
        return;
    }
    if (auto animation = ResolveScalarAnimation(setting); animation.has_value()) {
        const auto playback = runtime->RegisterScalarAnimation(key, std::move(*animation));
        for (const auto& material : materials) runtime->RegisterMaterialAlphaAnimation(material, playback);
        return;
    }
    runtime->RegisterNodeAlpha(key, materials, authored);
}

void RegisterLayerAlphaDrivers(ParseContext& context, const std::string& key,
                        const wpscene::WPImageObject&                      image,
                        const std::vector<std::shared_ptr<SceneMaterial>>& materials) {
    RegisterAlphaSetting(context, key, image.alpha_setting, image.alpha, materials);
}

/// A layer's colour and brightness bindings (R38, R39), applied to every material
/// that takes the layer's tint.
void RegisterLayerTint(ParseContext& context, const std::string& key, const nlohmann::json& entry,
                       const std::array<float, 3>&                         authored,
                       const std::vector<std::shared_ptr<SceneMaterial>>& tinted) {
    auto* runtime = context.scene->runtime.get();
    if (runtime == nullptr || tinted.empty()) return;
    if (const auto color = entry.find("color"); color != entry.end() && color->is_object()) {
        if (HasDynamicSetting(*color)) {
            runtime->BindMaterialColor(key, tinted, ResolveVec3Setting(*runtime, *color, key));
        } else if (const auto animation = ResolveVec3Animation(*runtime, key, *color);
                   animation != nullptr) {
            runtime->RegisterMaterialColorAnimation(tinted, animation);
        } else if (color->contains("script") || tinted.size() > 1) {
            // Event-only scripts and multi-material static layers retain their
            // existing mutation recipients, but a static value is not a driver:
            // registration must not replay it over an authored effect constant.
            runtime->BindMaterialColor(
                key, tinted, std::make_unique<DynamicValue>(Vector3f(authored.data())), false);
        }
    } else if (tinted.size() > 1) {
        runtime->BindMaterialColor(key, tinted,
                                   std::make_unique<DynamicValue>(Vector3f(authored.data())), false);
    }
    if (const auto brightness = entry.find("brightness");
        brightness != entry.end() && HasDynamicSetting(*brightness)) {
        runtime->BindMaterialBrightness(
            context.scene->hdr ? tinted : std::vector<std::shared_ptr<SceneMaterial>> {},
            ResolveFloatSetting(*runtime, *brightness, key));
    }
}

/// The video textures of a layer's own material, for playback control (R89).
void RegisterLayerVideos(ParseContext& context, const std::string& key,
                         const std::vector<std::string>& textures) {
    auto* runtime = context.scene->runtime.get();
    if (runtime == nullptr) return;
    std::unordered_set<std::string> seen;
    for (const auto& name : textures) {
        if (name.empty() || IsSpecTex(name) || ! seen.insert(name).second) continue;
        const auto found = context.scene->textures.find(name);
        if (found != context.scene->textures.end() && found->second.isVideo) {
            runtime->RegisterNodeVideoTexture(key, name);
        }
    }
}

/// The reserved names of a layer's working buffers.
std::string PingPongName(std::string_view prefix, std::string_view camera_name) {
    return std::string(prefix) + std::string(camera_name);
}

/// The render target of the buffer `fbo_name` that the effect at `position` in layer `layer_id`'s
/// chain declares: a target the engine made, whatever the effect calls it. A `_rt_` name
/// (`_rt_half`) keeps its spelling; any other (`_coc`, `plain`, `_alias_cookie`) goes under
/// `_rt_` and ends in a word rather than a number, so `plain` and `_rt_plain` stay two buffers.
std::string EffectBufferName(const std::string& fbo_name, int32_t layer_id, std::size_t position) {
    const auto owner = "_" + std::to_string(layer_id) + "_" + std::to_string(position);
    if (StartsWithText(fbo_name, WE_SPEC_PREFIX)) return fbo_name + owner;
    return std::string(WE_SPEC_PREFIX) + fbo_name + owner + "_named";
}

/// Registers the render target of one effect buffer (R55).
void RegisterEffectBuffer(ParseContext& context, const std::string& name,
                          const wpscene::WPEffectFbo& fbo, std::array<int32_t, 2> extent,
                          bool follows_screen, bool carries_previous_frame) {
    auto&      scene  = *context.scene;
    const auto fixed  = follows_screen ? std::nullopt
                                       : FixedEffectFboExtent(fbo, static_cast<float>(extent[0]),
                                                              static_cast<float>(extent[1]));
    const std::array<int32_t, 2> size =
        fixed.has_value() ? *fixed
                          : std::array<int32_t, 2> { ResolveRenderTargetDimension(extent[0], fbo.scale),
                                                     ResolveRenderTargetDimension(extent[1], fbo.scale) };
    SceneRenderTarget target;
    target.width                = size[0];
    target.height               = size[1];
    target.allowReuse           = ! carries_previous_frame;
    target.carriesPreviousFrame = carries_previous_frame;
    target.sample               = { TextureWrap::CLAMP_TO_EDGE, TextureWrap::CLAMP_TO_EDGE,
                                    TextureFilter::LINEAR, TextureFilter::LINEAR };
    target.format               = EffectFboFormat(fbo.format, scene.hdr);
    if (follows_screen) {
        target.bind.enable = true;
        target.bind.screen = true;
        target.bind.scale  = 1.0 / std::max<double>(1.0, fbo.scale);
    }
    scene.renderTargets[name] = target;
}

/// The mesh a layer's own pass draws and the mesh of its final card, sized by the layer.
struct LayerGeometry {
    std::array<float, 2>   size { 2.0f, 2.0f };
    std::array<int32_t, 2> extent { 1, 1 };
    float                  u { 1.0f };
    float                  v { 1.0f };
};

/// A pass of an effect chain: its node, mesh and material, and the effect it belongs to.
std::shared_ptr<SceneNode> MakeEffectPassNode(SceneMaterial&& material) {
    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(std::move(material));
    node->AddMesh(std::move(mesh));
    return node;
}

/// A pass of an effect after its file entry and its instance entry are settled: the
/// assembled material (slots included) and the buffer it writes.
struct EffectPassPlan {
    wpscene::WPMaterial material;
    std::string         output;
};

/// Settles every pass of `source` before any of them is compiled (R42, R55, R79):
/// the instance's entry overlays the file's, the chain's input stands in for the
/// layer's own composite, binds fill their slots, slot 0 defaults to the chain's
/// input and `target` picks the buffer written (the chain's output when it names
/// nothing known).
std::vector<EffectPassPlan> PlanEffectPasses(const wpscene::WPImageEffect& source, int32_t layer_id,
                                             const std::unordered_map<std::string, std::string>& buffers,
                                             const std::string& chain_input,
                                             const std::string& chain_output) {
    const auto buffer_named = [&buffers](const std::string& name) -> const std::string* {
        const auto found = buffers.find(name);
        return found == buffers.end() ? nullptr : &found->second;
    };

    std::vector<EffectPassPlan> plans(source.materials.size());
    for (std::size_t pass = 0; pass < plans.size(); ++pass) {
        auto&                          plan     = plans[pass];
        const wpscene::WPMaterialPass* instance = pass < source.passes.size() ? &source.passes[pass] : nullptr;
        plan.material = source.materials[pass];
        plan.output   = chain_output;
        if (instance != nullptr) {
            plan.material.MergePass(*instance);
            if (! instance->target.empty()) {
                if (const auto* written = buffer_named(instance->target)) plan.output = *written;
            }
        }
        BindOwnEffectChainInput(plan.material, layer_id, chain_input);

        auto& slots = plan.material.textures;
        if (instance != nullptr) {
            for (const auto& bind : instance->bind) {
                if (bind.index < 0 || bind.index >= static_cast<int32_t>(kMaxTextureSlots)) continue;
                const auto* buffer = buffer_named(bind.name);
                if (buffer == nullptr) {
                    LOG_INFO("effect pass binds the unknown buffer '%s'", bind.name.c_str());
                    continue;
                }
                const auto slot = static_cast<std::size_t>(bind.index);
                slots.resize(std::max(slots.size(), slot + 1));
                slots[slot] = *buffer;
            }
        }
        slots.resize(std::max<std::size_t>(slots.size(), 1));
        if (slots.front().empty()) slots.front() = chain_input;
    }
    return plans;
}

/// One effect of a layer's chain (R53 to R57, R79 to R82). Returns false when a pass
/// of it cannot be built; the effect is then left out and the layer kept.
bool BuildEffect(ParseContext& context, const wpscene::WPImageObject& image,
                 const wpscene::WPImageEffect& source, std::size_t index,
                 const std::shared_ptr<SceneNode>& layer_node, SceneImageEffectLayer& chain,
                 const std::array<int32_t, 2>& extent, bool fullscreen, bool white_tint,
                 bool defer_fog, bool is_closing_pass, const std::string& key,
                 const std::string& camera_name,
                 std::vector<std::shared_ptr<SceneMaterial>>& tinted,
                 std::vector<std::shared_ptr<SceneMaterial>>& all_materials,
                 std::shared_ptr<SceneImageEffect>*           built_out,
                 const WPPuppetLayer*                         puppet = nullptr,
                 bool mandatory_previous_slot0 = false) {
    auto&      scene = *context.scene;
    const auto previous_name = PingPongName(WE_EFFECT_PPONG_PREFIX_A, camera_name);
    const auto output_name   = PingPongName(WE_EFFECT_PPONG_PREFIX_B, camera_name);

    std::unordered_map<std::string, std::string> fbo_map;
    fbo_map["previous"] = previous_name;
    for (const auto& fbo : source.fbos) {
        const auto name = EffectBufferName(fbo.name, image.id, index);
        fbo_map[fbo.name] = name;
        RegisterEffectBuffer(context, name, fbo, extent, fullscreen,
                             EffectReadsBeforeWriting(source, fbo.name, 0));
    }

    auto effect = std::make_shared<SceneImageEffect>();
    struct Built {
        std::shared_ptr<SceneNode> node;
        std::string                output;
        std::shared_ptr<SceneMaterial> material;
        WPShaderInfo                   info;
        wpscene::WPMaterial            authored;
    };
    std::vector<Built> built;
    auto plans = PlanEffectPasses(source, image.id, fbo_map, previous_name, output_name);
    for (auto& plan : plans) {
        auto&               material = plan.material;
        auto&               output   = plan.output;
        SceneMaterial  scene_material;
        LoadedMaterial loaded;
        MaterialLoadOptions options;
        options.defer_fog = defer_fog;
        if (mandatory_previous_slot0) options.required_texture0 = previous_name;
        if (! LoadMaterial(context, material, scene_material, loaded, options)) return false;
        // The closing pass of a puppet is the layer's own material, with the layer's alpha
        // as its own; every other pass keeps an alpha of its own.
        scene_material.own_user_alpha = puppet == nullptr;
        const bool white = white_tint || is_closing_pass;
        SetLayerTint(context, scene_material, image, white);
        // Layer values are load-time defaults. Authored aliases override them;
        // unmatched keys were already reported by LoadMaterial, only once.
        LoadStaticMaterialConstants(scene_material, material, loaded.info, false,
                                    MaterialConstantWrite::Overlay);
        scene_material.blenmode = BlendMode::Normal;
        Built entry;
        entry.node     = MakeEffectPassNode(std::move(scene_material));
        entry.output   = std::move(output);
        entry.material = entry.node->Mesh()->MaterialSlotPtr(0);
        entry.info     = std::move(loaded.info);
        entry.authored = std::move(material);
        if (context.shader_updater != nullptr) {
            WPShaderValueData data;
            data.effect_owner   = layer_node.get();
            data.effect_extent  = linalg::Vector2f(static_cast<float>(extent[0]),
                                                   static_cast<float>(extent[1]));
            data.parallaxDepth  = image.parallaxDepth;
            data.parallax_layer = layer_node.get();
            data.renderTargets  = std::move(loaded.render_targets);
            if (puppet != nullptr) data.puppet_layer = *puppet;
            context.shader_updater->SetNodeData(entry.node.get(), 0, data);
        }
        built.push_back(std::move(entry));
    }
    if (built.empty()) return false;

    for (auto& entry : built) {
        effect->nodes.push_back(SceneImageEffectNode { .output = entry.output, .sceneNode = entry.node });
        RegisterDrivenMaterialConstants(context, entry.material, entry.authored, entry.info, key);
        // A pass that takes white takes no alpha of the layer's either, driven or not: what
        // reaches it has the alpha in it already.
        if (! white_tint && ! is_closing_pass) {
            all_materials.push_back(entry.material);
            tinted.push_back(entry.material);
        }
    }
    LowerEffectCommands(source, fbo_map, scene, effect->commands);
    RegisterScriptedEffectVisibility(context, source, effect, key);
    chain.AddEffect(effect);
    if (built_out != nullptr) *built_out = effect;
    return true;
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
            point.base_offset = linalg::Vector3d(over.controlpoint[i][0],
                                                over.controlpoint[i][1],
                                                over.controlpoint[i][2]);
            // A pinned control point is carried into the layer's space each
            // step; any other is where the scene put it.
            if (! point.worldspace || i == 0) point.offset = point.base_offset;
        }
        if (over.controlpointangleSet[i]) {
            const auto& a = over.controlpointangle[i];
            point.rotation =
                (linalg::AngleAxisd(a[2], linalg::Vector3d::UnitZ()) *
                 linalg::AngleAxisd(a[1], linalg::Vector3d::UnitY()) *
                 linalg::AngleAxisd(a[0], linalg::Vector3d::UnitX()))
                    .toRotationMatrix();
            point.has_rotation = true;
        }
    }
}

std::shared_ptr<SceneNode> ReuseOrCreateLayerNode(ParseContext& context, int32_t id) {
    auto node_iterator = context.layer_nodes.find(id);
    if (node_iterator != context.layer_nodes.end() && node_iterator->second != nullptr) {
        return node_iterator->second;
    }
    return std::make_shared<SceneNode>();
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

} // namespace

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
                                        RuntimeImageSource*                        covers) {
    for (std::size_t slot = 0; slot < usertextures.size(); ++slot) {
        const auto& user = usertextures[slot];
        if (user.name.empty() && user.type.empty()) continue;
        // The texture the slot already has: what an unreadable choice falls back to,
        // and what a cover slot shows until a cover arrives.
        const std::string authored = slot < textures.size() ? textures[slot] : std::string();

        if (wpscene::IsSystemUserTexture(user)) {
            if (textures.size() <= slot) textures.resize(slot + 1);
            textures[slot] = covers != nullptr ? covers->BindCoverSlot(user.name, authored) : user.name;
            continue;
        }
        // Any other typed entry names something this renderer does not supply.
        if (! user.type.empty()) continue;

        // A bare name is a project property of kind scene texture; without a table
        // to read it from, the authored texture stays.
        if (properties == nullptr) continue;
        const auto found = properties->find(user.name);
        if (found == properties->end() ||
            found->second.kind != RuntimeScalarValue::Kind::String) {
            continue;
        }
        const auto& value = found->second.asString();
        if (value.empty()) continue;
        if (auto name = TexturePropertyTextureName(value); name.has_value()) {
            if (textures.size() <= slot) textures.resize(slot + 1);
            textures[slot] = std::move(*name);
        }
    }
}

void wallpaper::LoadMaterialConstantShaderValues(SceneMaterial& material,
                                                 const wpscene::WPMaterial& wpmat,
                                                 const WPShaderInfo& info) {
    LoadStaticMaterialConstants(material, wpmat, info);
}

namespace
{
// What a layer made while the scene runs needs of the parse that built the scene.
struct LazyParseInputs {
    ShaderValueMap   globals;
    LayerObjectIndex index;
    bool             is_ortho { true };
    bool             uses_models { false };
    wpscene::WPSceneGeneral general;
};

ParseContext MakeLazyParseContext(const std::shared_ptr<Scene>& scene, fs::VFS& vfs,
                                  const LazyParseInputs& inputs) {
    ParseContext lazy {};
    lazy.scene                    = scene;
    lazy.vfs                      = &vfs;
    lazy.shader_updater           = static_cast<WPShaderValueUpdater*>(scene->shaderValueUpdater.get());
    lazy.ortho_w                  = scene->ortho[0];
    lazy.ortho_h                  = scene->ortho[1];
    lazy.bind_now                 = true;
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
        WPShaderParser::BeginShaderSession();
    }
    ~LazyShaderParseScope() {
        g_pending_metal_translations.clear();
        // A layer a script creates after the scene is drawing: its failure is the
        // script's (the layer is not made), never a reason to refuse the scene.
        g_shader_failures.clear();
        g_parse_layer_index = previous;
        WPShaderParser::EndShaderSession();
    }
};
} // namespace

namespace
{
// ---------------------------------------------------------------------------
// Entries of the object list: what each is, whether it is built, what it is
// called (R31 to R35, R75, R87, R112).
// ---------------------------------------------------------------------------

enum class EntryKind
{
    Ignored,
    Group,
    Image,
    Particle,
    Sound,
    Light,
    Text,
    Model,
    Camera,
    Shape,
};

/// What becomes of an entry: nothing, a transform-only node, or a typed object
/// (which owns a node of its own, or none for a sound).
enum class Admission
{
    Skip,
    Node,
    Object,
};

struct EntryPlan {
    EntryKind   kind { EntryKind::Ignored };
    Admission   admission { Admission::Skip };
    int32_t     id { 0 };
    bool        has_children { false }; // another entry names this one as its parent
    bool        placeholder { false }; // a node standing in for a typed object that has children
    std::string key;
};

/// A script that only registers scene events: it exports no `update` and calls
/// `engine.on(`, `scene.on(` or `thisScene.on(`. It is run once, as a scene script
/// of its layer, rather than attached to the value it was written on.
bool IsSceneEventScript(std::string_view source) {
    if (ExportsFunction(source, "update")) return false;
    for (const std::string_view call : { "engine.on(", "scene.on(", "thisScene.on(" }) {
        if (source.find(call) != std::string_view::npos) return true;
    }
    return false;
}

/// Queues the scene-event scripts among the bindings of a layer.
void QueueSceneScripts(ParseContext& context, const nlohmann::json& bindings,
                       const std::string& key) {
    if (! bindings.is_object()) return;
    for (const auto& [name, binding] : bindings.items()) {
        const auto script = binding.find("script");
        if (script == binding.end() || ! script->is_string()) continue;
        const auto& source = script->get_ref<const std::string&>();
        if (IsSceneEventScript(source)) context.scene_scripts.emplace_back(source, key);
    }
}

/// The member `key` of an entry when it is there and not `null`.
const nlohmann::json* NonNullMember(const nlohmann::json& entry, const char* key) {
    const auto found = entry.find(key);
    return found == entry.end() || found->is_null() ? nullptr : &*found;
}

EntryKind ClassifyEntry(const nlohmann::json& entry) {
    if (! entry.is_object()) return EntryKind::Ignored;
    if (const auto* image = NonNullMember(entry, "image"); image != nullptr && image->is_string()) {
        return EntryKind::Image;
    }
    if (NonNullMember(entry, "particle") != nullptr) return EntryKind::Particle;
    if (NonNullMember(entry, "sound") != nullptr) return EntryKind::Sound;
    if (NonNullMember(entry, "light") != nullptr) return EntryKind::Light;
    if (NonNullMember(entry, "text") != nullptr) return EntryKind::Text;
    if (NonNullMember(entry, "model") != nullptr) return EntryKind::Model;
    if (NonNullMember(entry, "camera") != nullptr) return EntryKind::Camera;
    // A kind key that holds nothing usable makes the entry neither a group nor a
    // typed object.
    for (const char* key : { "image", "particle", "sound", "light", "text", "model", "camera" }) {
        if (entry.contains(key)) return EntryKind::Ignored;
    }
    const auto shape = entry.find("shape");
    return shape != entry.end() && shape->is_string() ? EntryKind::Shape : EntryKind::Group;
}

/// `visible` is plainly false: the boolean, or a wrapper whose `value` is false
/// with neither a property nor a script to change it.
bool StaticallyHidden(const nlohmann::json& entry) {
    const auto found = entry.find("visible");
    if (found == entry.end()) return false;
    if (found->is_boolean()) return ! found->get<bool>();
    if (! found->is_object() || wpscene::VisibilityIsBound(*found)) return false;
    const auto value = found->find("value");
    return value != found->end() && value->is_boolean() && ! value->get<bool>();
}

int32_t EntryId(const nlohmann::json& entry) {
    int32_t id = 0;
    if (const auto found = entry.find("id"); found != entry.end()) wpscene::ReadInt32(*found, id);
    return id;
}

/// The object list with the files of each image object read into it: under
/// `__external`, the model the object names and the material that model names. The
/// layers those files sample are sources like the ones the object names itself (P2 R60),
/// and the scans of the object list look at the whole of each object.
nlohmann::json WithExternalMaterials(const nlohmann::json& objects, fs::VFS& vfs) {
    if (! objects.is_array()) return objects;
    nlohmann::json scanned = objects;
    const auto     read    = [&vfs](const std::string& path, nlohmann::json& into) {
        if (path.empty()) return false;
        nlohmann::json json;
        if (! vfs.Contains("/assets/" + path) ||
            ! wpscene::ParseBoundedJson(fs::GetFileContent(vfs, "/assets/" + path), json) ||
            ! json.is_object()) {
            return false;
        }
        into = std::move(json);
        return true;
    };
    for (auto& object : scanned) {
        if (! object.is_object()) continue;
        const auto image = object.find("image");
        if (image == object.end() || ! image->is_string()) continue;
        nlohmann::json model;
        if (! read(image->get<std::string>(), model)) continue;
        nlohmann::json external = nlohmann::json::array();
        if (const auto material = model.find("material");
            material != model.end() && material->is_string()) {
            nlohmann::json file;
            if (read(material->get<std::string>(), file)) external.push_back(std::move(file));
        }
        external.push_back(std::move(model));
        object["__external"] = std::move(external);
    }
    return scanned;
}

/// What the scripts of the object list could reach: the quoted strings of every
/// script anywhere in it.
std::unordered_set<std::string> ScriptLiterals(const nlohmann::json& objects) {
    std::unordered_set<std::string> literals;
    std::vector<const std::string*> sources;
    CollectScriptSources(objects, sources);
    for (const auto* source : sources) CollectScriptStringLiterals(*source, literals);
    return literals;
}

/// Whether a statically hidden entry is built anyway: a script sits inside it, a
/// script names it by a quoted literal, or (for an image) another built image
/// reads its picture.
bool RetainedWhileHidden(EntryKind kind, const nlohmann::json& entry, int32_t id,
                         const std::unordered_set<int32_t>&     reachable,
                         const std::unordered_set<std::string>& literals) {
    if (kind == EntryKind::Image && id != 0 && reachable.contains(id)) return true;
    std::vector<const std::string*> sources;
    CollectScriptSources(entry, sources);
    if (! sources.empty()) return true;
    if (const auto name = entry.find("name");
        name != entry.end() && name->is_string() && ! name->get_ref<const std::string&>().empty()) {
        return literals.contains(name->get<std::string>());
    }
    return false;
}

/// Decides, for every entry, what is built and what is called.
std::vector<EntryPlan> PlanEntries(ParseContext& context, const nlohmann::json& objects,
                                   const nlohmann::json& scanned, const LayerObjectIndex& index) {
    std::vector<EntryPlan> plans(objects.size());
    std::unordered_set<int32_t> parent_ids;
    for (const auto& entry : objects) {
        int32_t parent = 0;
        if (entry.is_object()) {
            if (const auto found = entry.find("parent");
                found != entry.end() && wpscene::ReadInt32(*found, parent)) {
                parent_ids.insert(parent);
            }
        }
    }
    const auto reachable = CollectReachableLayerIds(scanned, index, context.vfs);
    const auto literals  = ScriptLiterals(objects);

    for (std::size_t at = 0; at < objects.size(); ++at) {
        const auto& entry = objects[at];
        auto&       plan  = plans[at];
        plan.kind         = ClassifyEntry(entry);
        if (plan.kind == EntryKind::Ignored) continue;
        plan.id            = EntryId(entry);
        const bool has_id  = plan.id != 0;
        const bool has_kids = has_id && parent_ids.contains(plan.id);
        plan.has_children   = has_kids;
        const bool hidden  = StaticallyHidden(entry);
        switch (plan.kind) {
        case EntryKind::Group:
        case EntryKind::Shape: plan.admission = has_id ? Admission::Node : Admission::Skip; break;
        case EntryKind::Sound: plan.admission = hidden ? Admission::Skip : Admission::Object; break;
        case EntryKind::Light:
            // A light that is statically hidden is dropped whatever binds its
            // visibility; its children still keep their parent.
            if (hidden) plan.admission = has_kids ? Admission::Node : Admission::Skip;
            else plan.admission = Admission::Object;
            break;
        case EntryKind::Text: plan.admission = has_id ? Admission::Object : Admission::Skip; break;
        default:
            if (! has_id) {
                plan.admission = Admission::Skip;
            } else if (! hidden || RetainedWhileHidden(plan.kind, entry, plan.id, reachable, literals)) {
                plan.admission = Admission::Object;
            } else {
                plan.admission = has_kids ? Admission::Node : Admission::Skip;
            }
            break;
        }
        plan.placeholder = has_kids && plan.admission == Admission::Object &&
                           (plan.kind == EntryKind::Text || plan.kind == EntryKind::Model ||
                            plan.kind == EntryKind::Camera);
        if (plan.admission == Admission::Node && plan.kind != EntryKind::Group &&
            plan.kind != EntryKind::Shape) {
            plan.placeholder = true;
        }
    }

    // Names. Entries of every kind but text and light are counted together; a
    // text layer is counted apart.
    std::unordered_map<std::string, uint32_t> counted;
    for (std::size_t at = 0; at < objects.size(); ++at) {
        const auto& plan = plans[at];
        if (plan.admission == Admission::Skip || plan.kind == EntryKind::Light) continue;
        const auto name = objects[at].find("name");
        if (name == objects[at].end() || ! name->is_string()) continue;
        const auto& text = name->get_ref<const std::string&>();
        if (text.empty()) continue;
        if (plan.kind == EntryKind::Text) {
            ++context.text_name_counts[text];
        } else if (plan.admission == Admission::Object || plan.kind == EntryKind::Group ||
                   plan.kind == EntryKind::Shape) {
            ++counted[text];
        }
    }
    context.layer_name_counts = counted;

    for (std::size_t at = 0; at < objects.size(); ++at) {
        auto& plan = plans[at];
        if (plan.admission == Admission::Skip) continue;
        std::string authored;
        if (const auto name = objects[at].find("name"); name != objects[at].end() && name->is_string()) {
            authored = name->get<std::string>();
        }
        const auto count_of = [&](const std::unordered_map<std::string, uint32_t>& table) {
            const auto found = table.find(authored);
            return found == table.end() ? 0u : found->second;
        };
        const std::string id_text = std::to_string(plan.id);
        switch (plan.kind) {
        case EntryKind::Text:
            plan.key = ! authored.empty() && count_of(counted) == 0 &&
                               count_of(context.text_name_counts) <= 1
                           ? authored
                           : "__we_text_" + id_text;
            break;
        case EntryKind::Light:
            plan.key = ! authored.empty() && count_of(counted) == 0 ? authored
                                                                    : "__we_light_" + id_text;
            break;
        case EntryKind::Sound:
            // A sound is a layer like any other: counted by name, and a shared name gives it a
            // key of its own.
            plan.key = ! authored.empty() && count_of(counted) <= 1
                           ? authored
                           : "__we_layer_" + (plan.id != 0 ? id_text : "s" + std::to_string(at));
            break;
        default:
            plan.key = ! authored.empty() && count_of(counted) <= 1 ? authored
                                                                    : "__we_layer_" + id_text;
            break;
        }
    }
    return plans;
}

// ---------------------------------------------------------------------------
// The layer tree (R38 to R43, R75 to R78, R87).
// ---------------------------------------------------------------------------

/// The node of an entry that only carries a transform, registered under its key
/// with its bindings. `animate` is false for the stand-in of a typed object, whose
/// own loader registers the timelines.
std::shared_ptr<SceneNode> MakePlainLayerNode(ParseContext& context, const nlohmann::json& entry,
                                              const EntryPlan& plan, bool animate) {
    wpscene::WPMiscObjectBase base;
    base.FromCommonJson(entry);
    auto node = std::make_shared<SceneNode>(Vector3f(base.origin.data()),
                                            Vector3f(base.scale.data()),
                                            Vector3f(base.angles.data()), plan.key);
    node->ID() = plan.id;
    // A parse with no property table has no runtime: nothing is bound, and every
    // value keeps what the file says.
    bool visible = base.visible;
    if (auto* runtime_ptr = context.scene->runtime.get(); runtime_ptr != nullptr) {
        auto& runtime = *runtime_ptr;
        runtime.RegisterNode(plan.key, node.get());
        runtime.RegisterLayerId(plan.id, plan.key);
        {
            // The name the file gives the layer (possibly none), which `layer.name` reads
            // when the layer is registered under a generated key.
            std::string authored;
            if (const auto name = entry.find("name"); name != entry.end() && name->is_string()) {
                authored = name->get<std::string>();
            }
            if (authored != plan.key) {
                runtime.RegisterLayerAuthoredName(plan.key, authored);
                // Name lookup answers with the first declaration of a shared name.
                if (! authored.empty()) runtime.RegisterLayerAlias(authored, plan.key);
            }
        }
        const auto has_script = [](const nlohmann::json& setting) {
            return setting.is_object() && setting.contains("script");
        };
        if (! context.bind_now && (has_script(base.origin_setting) || has_script(base.scale_setting) ||
                                   has_script(base.angles_setting))) {
            // A script may look up other layers when it is made, so it is made once they all exist.
            context.deferred_bindings.push_back(
                [&context, weak = std::weak_ptr<SceneNode>(node), key = plan.key, base, animate]() {
                    const auto held = weak.lock();
                    auto* const live = context.scene->runtime.get();
                    if (held == nullptr || live == nullptr) return;
                    RegisterNodeTransformSettings(*live, held.get(), key, base.origin_setting,
                                                  base.scale_setting, base.angles_setting, animate);
                });
        } else {
            RegisterNodeTransformSettings(runtime, node.get(), plan.key, base.origin_setting,
                                          base.scale_setting, base.angles_setting, animate);
        }
        QueueSceneScripts(context, base.field_bindings, plan.key);

        // Visibility: the authored flag, or the value a property or script gives it,
        // which the runtime then keeps following. A hidden node that only a reload can
        // change costs the render graph nothing.
        if (base.dynamic_visible) {
            auto value = ResolveBoolSetting(runtime, base.visible_setting, plan.key);
            visible    = value->getBool();
            runtime.RegisterNodeVisibility(plan.key, node.get(), std::move(value));
        }
    }
    node->SetVisible(visible);
    node->SetVisibilitySettled(VisibilitySettledBy(base.visible_setting));
    return node;
}

/// The authored setting, or a literal standing in for a key the file leaves out.
nlohmann::json SettingOrValue(const nlohmann::json& setting, const nlohmann::json& literal) {
    return setting.is_null() ? literal : setting;
}

bool LoadSoundEntry(ParseContext& context, const nlohmann::json& entry, const EntryPlan& plan,
                    audio::SoundManager& sm);

/// Makes the node of an entry and puts it in the tree record. A light without an
/// id hangs from the scene's root and answers to no id.
ParsedLayer& AddLayer(ParseContext& context, std::size_t at, const nlohmann::json& entry,
                      const EntryPlan& plan, bool animate, bool plain) {
    ParsedLayer layer;
    layer.entry = at;
    layer.id    = plan.id;
    layer.key   = plan.key;
    if (const auto name = entry.find("name"); name != entry.end() && name->is_string()) {
        layer.authored_name = name->get<std::string>();
    }
    if (plan.id != 0) {
        if (const auto parent = entry.find("parent"); parent != entry.end()) {
            wpscene::ReadInt32(*parent, layer.parent_id);
        }
    }
    if (const auto attachment = entry.find("attachment");
        attachment != entry.end() && attachment->is_string()) {
        layer.attachment = attachment->get<std::string>();
    }
    layer.node  = MakePlainLayerNode(context, entry, plan, animate);
    layer.plain = plain;
    if (plan.id != 0) context.layer_nodes[plan.id] = layer.node;
    context.layers.push_back(std::move(layer));
    return context.layers.back();
}

/// How the cursor treats a layer the pointer can never hit: groups, lights and
/// the stand-ins of typed objects.
void SetUnhittable(ParseContext& context, const std::string& key, bool solid = false,
                   bool disable_propagation = false) {
    if (context.scene->runtime != nullptr) {
        context.scene->runtime->SetNodeCursorTarget(key, false, solid, disable_propagation);
    }
}

// ---------------------------------------------------------------------------
// Puppets drawn directly: one material per mesh, clipping masks (P2 R75, P5 R68, R69).
// ---------------------------------------------------------------------------

/// The render target the clipping masks are drawn into: the screen scaled by one half (R25).
constexpr std::string_view kPuppetMaskTarget = "_rt_puppet_mask";

struct PuppetSlot {
    wpscene::WPMaterial authored;
    LoadedMaterial      loaded;
};

/// Reads a material file for a puppet slot; the puppet's skinning combos are put in first.
std::optional<wpscene::WPMaterial> ReadPuppetMaterial(fs::VFS& vfs, const std::string& path,
                                                      const WPMdl& mdl, bool has_bones) {
    nlohmann::json json;
    if (path.empty() ||
        ! wpscene::ParseBoundedJson(fs::GetFileContent(vfs, "/assets/" + path), json)) {
        return std::nullopt;
    }
    wpscene::WPMaterial material;
    if (! material.FromJson(json)) return std::nullopt;
    material.use_puppet = true;
    if (has_bones) WPMdlParser::AddPuppetMatInfo(material, mdl);
    return material;
}

/// The clipping-mask material of one mask (R69): the shipped `clippingmaskimage4`
/// shader, translucent, never depth tested, written or culled, drawing the piece's
/// picture with the mask's picture. Skinning combos apply to it as to any slot.
wpscene::WPMaterial MakeClippingMaskMaterial(const std::string& piece_texture,
                                             const std::string& mask_texture, const WPMdl& mdl,
                                             bool has_bones) {
    wpscene::WPMaterial material {
        .blending   = "translucent",
        .cullmode   = "nocull",
        .shader     = "clippingmaskimage4",
        .depthtest  = "disabled",
        .depthwrite = "disabled",
        .textures   = { piece_texture, mask_texture },
        .use_puppet = true,
    };
    if (has_bones) WPMdlParser::AddPuppetMatInfo(material, mdl);
    return material;
}

/// The mesh's own material drawn through a mask (R69, R25): both clipping combos on and
/// texture slot 8 holding the mask target.
wpscene::WPMaterial MakeClippedCopy(wpscene::WPMaterial material) {
    constexpr std::size_t kMaskSlot = 8;
    for (const char* combo : { "CLIPPINGTARGET", "CLIPPINGUVS" }) material.combos[combo] = 1;
    material.textures.resize(std::max(material.textures.size(), kMaskSlot + 1));
    material.textures[kMaskSlot] = std::string(kPuppetMaskTarget);
    return material;
}

/// Loads every slot of a puppet drawn directly, in submesh order: the mesh's own material,
/// then for each mask its mask material and its clipped copy. False abandons the whole set.
bool LoadPuppetSlots(ParseContext& context, const wpscene::WPImageObject& image, const WPMdl& mdl,
                     bool has_bones, bool additive, SceneMesh& mesh, std::vector<PuppetSlot>& slots) {
    const auto load = [&](wpscene::WPMaterial authored, bool tint) -> bool {
        SceneMaterial scene_material;
        PuppetSlot    slot;
        if (! LoadMaterial(context, authored, scene_material, slot.loaded)) return false;
        if (tint) SetLayerTint(context, scene_material, image, false);
        if (additive) scene_material.blenmode = BlendMode::Additive;
        slot.authored = std::move(authored);
        mesh.AddMaterial(std::move(scene_material));
        slots.push_back(std::move(slot));
        return true;
    };
    bool mask_target_added = false;
    for (const auto& source : mdl.meshes) {
        if (source.positions.empty()) continue;
        auto base = ReadPuppetMaterial(*context.vfs, source.mat_json_file, mdl, has_bones);
        if (! base.has_value()) {
            LOG_ERROR("puppet mesh names no usable material ('%s')", source.mat_json_file.c_str());
            return false;
        }
        if (! source.masks.empty() && ! mask_target_added) {
            const auto* frame = context.scene->FindRenderTarget(std::string(SpecTex_Default));
            SceneRenderTarget target;
            target.width      = std::max(1, (frame != nullptr ? frame->width : context.ortho_w) / 2);
            target.height     = std::max(1, (frame != nullptr ? frame->height : context.ortho_h) / 2);
            target.allowReuse = true;
            target.format     = context.scene->hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8;
            target.bind       = { .enable = true, .screen = true, .scale = 0.5 };
            context.scene->renderTargets[std::string(kPuppetMaskTarget)] = target;
            mask_target_added = true;
        }
        const std::string first_texture =
            ! base->textures.empty() && ! base->textures[0].empty()
                ? base->textures[0]
                : (! image.material.textures.empty() ? image.material.textures[0] : std::string());
        if (! load(*base, true)) return false;
        for (const auto& mask : source.masks) {
            if (! load(MakeClippingMaskMaterial(first_texture, mask.mat_json_file, mdl, has_bones), true)) {
                return false;
            }
            if (! load(MakeClippedCopy(*base), true)) return false;
        }
    }
    return ! slots.empty();
}

/// Whether something the scene file says can move an object while the scene runs: an origin,
/// scale or angles that a property, a script or a timeline drives (those are objects in the
/// file, not plain values), on the object or on any of its ancestors.
bool WorldTransformMayChange(const ParseContext& context, const nlohmann::json& entry) {
    if (context.objects == nullptr || ! context.objects->is_array()) return true;
    const nlohmann::json* current = &entry;
    for (std::size_t depth = 0; depth <= context.objects->size(); ++depth) {
        if (! current->is_object()) return false;
        for (const char* key : { "origin", "scale", "angles" }) {
            const auto setting = current->find(key);
            if (setting != current->end() && setting->is_object()) return true;
        }
        int32_t parent = 0;
        const auto link = current->find("parent");
        if (link == current->end() || ! wpscene::ReadInt32(*link, parent)) return false;
        const nlohmann::json* next = nullptr;
        for (const auto& candidate : *context.objects) {
            if (candidate.is_object() && EntryId(candidate) == parent) {
                next = &candidate;
                break;
            }
        }
        if (next == nullptr) return false;
        current = next;
    }
    return true; // a loop of parents has no end to look at
}

/// The model flags and the numbers that decide how an image layer is built.
struct ImageKind {
    bool fullscreen { false };
    bool passthrough { false };
    bool compose_model { false };
    bool children { false };
};

/// Loads one image layer (R1 to R22, R38 to R92).
bool LoadImageEntry(ParseContext& context, std::size_t at, const nlohmann::json& entry,
                    const EntryPlan& plan, const wpscene::WPSceneGeneral& general) {
    auto& scene = *context.scene;
    wpscene::WPImageObject image;
    if (! image.FromJson(entry, *context.vfs)) return false;
    if (image.id == 0) image.id = plan.id;
    // A picture the user (or the preset) chose for the placeholder is drawn as it is.
    if (! image.colorIgnored && ChosenPictureFillsPlaceholder(context, image.material)) {
        image.color        = { 1.0f, 1.0f, 1.0f };
        image.colorIgnored = true;
    }

    ImageKind kind;
    kind.fullscreen    = image.fullscreen;
    kind.passthrough   = image.config.passthrough;
    kind.compose_model = IsComposeLayerModel(image.image);
    kind.children      = plan.has_children;
    const bool referenced = image.id != 0 && context.referenced_layer_ids.contains(image.id);

    // Size and placement (R11 to R14, R20).
    std::array<float, 3> origin = image.origin;
    std::array<float, 3> scale  = image.scale;
    std::array<float, 3> angles = image.angles;
    if (kind.fullscreen || (image.autosize && image.projectlayer)) {
        image.size = { static_cast<float>(context.ortho_w), static_cast<float>(context.ortho_h) };
    }
    LayerGeometry geometry;
    geometry.size   = image.size;
    geometry.extent = kind.fullscreen
                          ? std::array<int32_t, 2> { std::max(1, context.ortho_w), std::max(1, context.ortho_h) }
                          : ResolveImageRenderExtent(image, context);

    ResolveUserEffectVisibility(context, image.effects, plan.key);
    std::vector<const wpscene::WPImageEffect*> chain_sources;
    std::vector<wpscene::WPImageEffect>        extras;
    extras.reserve(2);
    for (const auto& effect : image.effects) {
        if (! EffectIsBuilt(effect) || effect.materials.empty()) continue;
        chain_sources.push_back(&effect);
    }
    // The colour blend (R52): mode 31 is additive blending, any other mode one more pass.
    const bool additive_blend = image.colorBlendMode == kAdditiveColorBlendMode;
    bool       blend_pass     = false;
    if (image.colorBlendMode != 0 && ! additive_blend) {
        auto effect = MakeColorBlendEffect(*context.vfs, image.colorBlendMode);
        if (! effect.has_value()) return false;
        extras.push_back(std::move(*effect));
        chain_sources.push_back(&extras.back());
        blend_pass = true;
    }
    const std::size_t built_effects = chain_sources.size();
    const bool composition =
        (kind.compose_model && kind.children && (! image.copybackground || built_effects > 0)) ||
        (kind.fullscreen && kind.passthrough && kind.children && built_effects > 0);
    // A sampled layer whose effects all failed to load still renders into its own base buffer.
    const bool failed_effects = built_effects == 0 && referenced && entry.contains("effects") &&
                                entry.at("effects").is_array() && ! entry.at("effects").empty();
    bool has_effects = built_effects > 0 || composition || failed_effects ||
                       (kind.compose_model && ! image.copybackground);
    // A puppet (R66, R75): one that cannot be read leaves the layer an ordinary card.
    WPMdl mdl;
    bool  puppet_ok = false;
    if (! image.puppet.empty()) {
        puppet_ok = WPMdlParser::Parse(image.puppet, *context.vfs, mdl) &&
                    ((mdl.puppet != nullptr && ! mdl.puppet->bones.empty()) ||
                     std::any_of(mdl.meshes.begin(), mdl.meshes.end(),
                                 [](const WPMdl::Mesh& mesh) { return ! mesh.positions.empty(); }));
        if (! puppet_ok) LOG_ERROR("layer %d: the puppet '%s' cannot be used", image.id, image.puppet.c_str());
    }
    const bool puppet_bones  = puppet_ok && mdl.puppet != nullptr && ! mdl.puppet->bones.empty();
    const bool puppet_direct = puppet_ok && built_effects == 0 && ! composition &&
                               (image.colorBlendMode == 0 || additive_blend);
    // Under effects the chain works on the flat sheet and closes with one pass that draws
    // the assembled model (R72); a model with bones takes the colour blend into that pass.
    const bool puppet_closing = puppet_ok && ! puppet_direct;
    const bool blend_closing  = puppet_closing && puppet_bones && blend_pass;
    const bool blend_separate = blend_pass && ! blend_closing;
    if (blend_closing) chain_sources.pop_back();
    if (puppet_closing) has_effects = true;

    // A card with the `perspective` flag in a 2D scene is seen through the scene's perspective
    // camera, as a particle system or a model with the flag is: bare, or by the pass that puts
    // its effects' result onto the scene. A fullscreen layer fills the canvas whatever it says
    // and a composition copies the screen behind it where the flat view puts it.
    const bool perspective_card =
        image.perspective && context.is_ortho && ! kind.fullscreen && ! kind.compose_model && ! composition;

    // A card with no area, saved with a size of 0 on one axis, shows nothing. When it draws
    // into targets of its own (it has effects, or another layer reads it) the card takes the
    // size of those targets on that axis, so what its effects make fills them, and it is
    // drawn into its own composite alone. A card only a unit or two thin keeps its size.
    std::array<float, 2> card_size = geometry.size;
    bool                 arealess  = false;
    if ((geometry.size[0] == 0.0f) != (geometry.size[1] == 0.0f) && (has_effects || referenced) &&
        ! kind.fullscreen && ! kind.compose_model && ! composition && ! puppet_ok) {
        arealess = true;
        for (std::size_t axis = 0; axis < 2; ++axis) {
            if (geometry.size[axis] == 0.0f) card_size[axis] = static_cast<float>(geometry.extent[axis]);
        }
    }
    wpscene::WPMaterial closing_material;
    if (puppet_closing) {
        closing_material = image.material;
        if (puppet_bones) {
            WPMdlParser::AddPuppetMatInfo(closing_material, mdl);
            if (blend_closing) closing_material.combos["BLENDMODE"] = image.colorBlendMode;
            // Nothing before the closing pass lights anything.
            image.material.combos["LIGHTING"] = 0;
        }
    }
    if (puppet_direct && puppet_bones) WPMdlParser::AddPuppetMatInfo(image.material, mdl);

    // Fog on a chain (R54).
    std::optional<wpscene::WPImageEffect> fog_pass;
    const bool scene_fog = scene.fog_distance || scene.fog_height;
    if (scene_fog && built_effects > 0 && ! composition && ! kind.fullscreen && ! blend_pass &&
        ! puppet_closing) {
        fog_pass = MakeFogCompositeEffect(*context.vfs);
    }

    // The layer's own material.
    SceneMaterial  own;
    LoadedMaterial own_loaded;
    MaterialLoadOptions own_options;
    own_options.defer_fog = fog_pass.has_value();
    const bool bare_compose  = kind.compose_model && ! has_effects;
    const bool draws_nothing = ! has_effects && ((bare_compose && ! referenced) ||
                                                 (kind.passthrough && ! kind.compose_model));
    if (! LoadMaterial(context, image.material, own, own_loaded, own_options)) {
        LOG_ERROR("layer %d: the material cannot be loaded", image.id);
        return false;
    }
    if (fog_pass.has_value() && ! own_loaded.info.fog_deferred) fog_pass.reset();
    const BlendMode authored_blend = own.blenmode;

    // The mesh of the own pass: a card, with the padding of the picture left out (R21, R22).
    if (! own.textures.empty() && ! own.textures[0].empty() && ! IsSpecTex(own.textures[0]) &&
        ! image.nopadding) {
        const auto texture_geometry = TextureGeometryOf(TextureHeaderOf(context, own.textures[0]));
        geometry.u = texture_geometry.u;
        geometry.v = texture_geometry.v;
    }

    auto& layer = AddLayer(context, at, entry, plan, true, false);
    const auto node = layer.node;
    auto* runtime   = scene.runtime.get();

    // Placement: a fullscreen layer sits on the canvas centre and keeps its authored
    // transform for what hangs from it; an anchored layer is moved by its alignment.
    if (kind.fullscreen) {
        node->SetChildFrame(Vector3f(origin.data()), Vector3f(scale.data()), Vector3f(angles.data()));
        node->SetIgnoreParentTransform(true);
        node->SetTranslate(Vector3f(static_cast<float>(context.ortho_w) * 0.5f,
                                    static_cast<float>(context.ortho_h) * 0.5f, 0.0f));
        node->SetScale(Vector3f(1.0f, 1.0f, 1.0f));
        node->SetRotation(Vector3f::Zero());
    } else if (AlignmentHasAnchorOffset(image.alignment)) {
        if (runtime == nullptr) {
            node->SetTranslate(Vector3f(origin.data()) +
                               AlignmentAnchorOffset(image.alignment, geometry.size,
                                                     Vector3f(scale.data()), Vector3f(angles.data())));
        }
    }
    if (runtime != nullptr) {
        runtime->RegisterNodeSize(plan.key, linalg::Vector2f(geometry.size[0], geometry.size[1]));
        if (kind.fullscreen) {
            runtime->SetNodeAnchorAlignment(
                plan.key, "center",
                Vector3f(static_cast<float>(context.ortho_w) * 0.5f,
                         static_cast<float>(context.ortho_h) * 0.5f, 0.0f));
        } else if (AlignmentHasAnchorOffset(image.alignment)) {
            runtime->SetNodeAnchorAlignment(plan.key, image.alignment, node->Translate());
        }
        runtime->SetNodeCursorTarget(plan.key, true, image.solid, image.disablepropagation);
    }
    node->SetSkipRenderPass(false);

    std::vector<std::shared_ptr<SceneMaterial>> tinted;
    std::vector<std::shared_ptr<SceneMaterial>> all_materials;

    // The own pass and its mesh.
    const bool passthrough_card = kind.passthrough && ! kind.compose_model && has_effects;
    std::shared_ptr<SceneMesh> mesh;
    std::optional<PassthroughCardShape> passthrough_shape;
    std::vector<PuppetSlot>    puppet_slots;
    if (puppet_direct) {
        mesh = std::make_shared<SceneMesh>();
        WPMdlParser::GenPuppetMesh(*mesh, mdl, true);
        if (! LoadPuppetSlots(context, image, mdl, puppet_bones, additive_blend, *mesh, puppet_slots)) {
            // The whole slot set is abandoned: every submesh draws with the layer's material.
            puppet_slots.clear();
            mesh = std::make_shared<SceneMesh>();
            WPMdlParser::GenPuppetMesh(*mesh, mdl, false);
            for (auto& submesh : mesh->Submeshes()) submesh.material_slot = 0;
        }
    } else if (passthrough_card) {
        // The card copies the screen where the layer is drawn. Its parents are not attached
        // yet, so it starts from the layer's own transform and is laid out from its world
        // transform once every layer is under its parent (R78), and again whenever that moves.
        const Matrix4d local = SceneNode::LocalTransOf(Vector3f(origin.data()), Vector3f(scale.data()),
                                                       Vector3f(angles.data()));
        PassthroughCardShape shape;
        shape.half_w        = static_cast<float>(static_cast<double>(geometry.size[0]) * 0.5);
        shape.half_h        = static_cast<float>(static_cast<double>(geometry.size[1]) * 0.5);
        shape.canvas_width  = static_cast<float>(std::max(1, context.ortho_w));
        shape.canvas_height = static_cast<float>(std::max(1, context.ortho_h));
        shape.clip_space    = image.material.shader == "passthrough";
        // A card that something in the scene can move is rewritten in place by an event; any
        // other is fixed, and rewritten (with the graph built again) only if it moves anyway.
        mesh = MakePassthroughMesh(shape, local,
                                   WorldTransformMayChange(context, entry) ? MeshUpdate::OnEvent
                                                                           : MeshUpdate::Fixed);
        passthrough_shape = shape;
    } else {
        mesh = MakeCardMesh(card_size[0], card_size[1], geometry.u, geometry.v);
    }
    if (has_effects) own.blenmode = BlendMode::Normal;
    else if (additive_blend) own.blenmode = BlendMode::Additive;
    SetLayerTint(context, own, image, false);
    if (puppet_slots.empty()) mesh->AddMaterial(std::move(own));
    node->AddMesh(mesh);
    if (passthrough_shape.has_value()) {
        context.passthrough_cards.push_back({ node, mesh, *passthrough_shape });
    }
    auto own_material = mesh->MaterialSlotPtr(0);
    WPPuppetLayer puppet_layer;
    if (puppet_ok && mdl.puppet != nullptr) {
        puppet_layer = WPPuppetLayer(mdl.puppet);
        puppet_layer.prepared(image.puppet_layers);
        layer.puppet       = mdl.puppet;
        layer.puppet_layer = puppet_layer;
        if (runtime != nullptr) {
            runtime->RegisterPuppetLayer(plan.key, puppet_layer);
            BindPuppetAnimationLayerSettings(context, plan.key, image, puppet_layer);
        }
    }
    if (puppet_slots.empty()) {
        RegisterDrivenMaterialConstants(context, own_material, image.material, own_loaded.info, plan.key);
        tinted.push_back(own_material);
        all_materials.push_back(own_material);
        if (context.shader_updater != nullptr) {
            WPShaderValueData data;
            data.parallaxDepth = image.parallaxDepth;
            data.renderTargets = own_loaded.render_targets;
            data.puppet_layer  = puppet_layer;
            context.shader_updater->SetNodeData(node.get(), 0, data);
        }
        RegisterLayerVideos(context, plan.key, own_material->textures);
    } else {
        std::vector<std::string> textures;
        for (std::size_t slot = 0; slot < puppet_slots.size(); ++slot) {
            auto material = mesh->MaterialSlotPtr(slot);
            RegisterDrivenMaterialConstants(context, material, puppet_slots[slot].authored,
                                      puppet_slots[slot].loaded.info, plan.key);
            tinted.push_back(material);
            all_materials.push_back(material);
            textures.insert(textures.end(), material->textures.begin(), material->textures.end());
            if (context.shader_updater != nullptr) {
                WPShaderValueData data;
                data.parallaxDepth = image.parallaxDepth;
                data.renderTargets = puppet_slots[slot].loaded.render_targets;
                data.puppet_layer  = puppet_layer;
                context.shader_updater->SetNodeData(node.get(), static_cast<uint32_t>(slot), data);
            }
        }
        RegisterLayerVideos(context, plan.key, textures);
    }

    if (draws_nothing) {
        node->SetSkipRenderPass(true);
    } else if (bare_compose) {
        // Only its composite is drawn: its card covers the whole target.
        node->SetCompositeOnly(true);
    } else if (composition && built_effects == 0) {
        // A composition with no effect of its own draws nothing, or only its composite.
        if (referenced) node->SetCompositeOnly(true);
        else node->SetSkipRenderPass(true);
    }
    if (arealess && ! draws_nothing) node->SetCompositeOnly(true);

    // The effect chain (R53 to R57, R79 to R84).
    if (has_effects) {
        const std::string camera_name = "__effect_layer_" + std::to_string(image.id);
        const auto first = PingPongName(WE_EFFECT_PPONG_PREFIX_A, camera_name);
        const auto other = PingPongName(WE_EFFECT_PPONG_PREFIX_B, camera_name);
        const auto sample = LayerRenderTargetSample(scene, image);
        for (const auto& name : { first, other }) {
            SceneRenderTarget target;
            target.width      = geometry.extent[0];
            target.height     = geometry.extent[1];
            target.allowReuse = true;
            target.sample     = sample;
            target.format     = scene.hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8;
            if (kind.fullscreen) {
                target.authored_width  = target.width;
                target.authored_height = target.height;
                target.bind.enable     = true;
                target.bind.screen     = true;
            }
            scene.renderTargets[name] = target;
        }
        auto chain = std::make_shared<SceneImageEffectLayer>(
            node.get(), static_cast<float>(geometry.extent[0]), static_cast<float>(geometry.extent[1]),
            first, other);
        // The final pass draws the layer's card, or for a puppet the assembled model: every
        // mesh, with the layer's one material.
        std::shared_ptr<SceneMesh> final_card;
        if (puppet_closing) {
            final_card = std::make_shared<SceneMesh>();
            WPMdlParser::GenPuppetMesh(*final_card, mdl, false);
            for (auto& submesh : final_card->Submeshes()) submesh.material_slot = 0;
        } else {
            final_card = MakeCardMesh(card_size[0], card_size[1], 1.0f, 1.0f);
        }
        chain->FinalMesh().ChangeMeshDataFrom(*final_card);
        chain->SetFinalBlend(blend_pass ? BlendMode::Normal
                                        : (additive_blend ? BlendMode::Additive : authored_blend));
        const bool sorted = ! context.is_ortho && general.transparentsorting && ImageLayerIsSorted(authored_blend);
        chain->SetFinalDepth(own_material->depth_test, own_material->depth_write && ! sorted);
        if (kind.fullscreen) chain->SetFinalCamera(std::string(FullscreenLayerCamera));
        else if (perspective_card) chain->SetFinalCamera("global_perspective");

        const bool defer = fog_pass.has_value();
        std::size_t index = 0;
        bool        any_fixed = false;
        for (const auto* source : chain_sources) {
            const bool is_blend_pass = blend_separate && source == chain_sources.back();
            if (BuildEffect(context, image, *source, index, node, *chain, geometry.extent, kind.fullscreen,
                            is_blend_pass, defer, false, plan.key, camera_name, tinted, all_materials, nullptr)) {
                if (! source->scripted_visible) any_fixed = true;
            }
            ++index;
        }
        if (fog_pass.has_value()) {
            BuildEffect(context, image, *fog_pass, index++, node, *chain, geometry.extent,
                        kind.fullscreen, true, false, true, plan.key, camera_name, tinted, all_materials, nullptr);
        }
        // A composition with nothing to run still has its picture to put on the scene.
        const bool bare_composition = chain_sources.empty() && (composition || kind.compose_model);
        if (! any_fixed && (! chain_sources.empty() || bare_composition)) {
            if (auto idle = MakeColorBlendEffect(*context.vfs, 0); idle.has_value()) {
                for (auto& material : idle->materials) material.combos.erase("BLENDMODE");
                std::shared_ptr<SceneImageEffect> fallback;
                // On a composition layer the idle pass carries the layer's colour and alpha.
                const bool carries_tint = composition || kind.compose_model;
                if (BuildEffect(context, image, *idle, index++, node, *chain, geometry.extent,
                                kind.fullscreen, ! carries_tint, false, ! carries_tint, plan.key, camera_name,
                                tinted, all_materials, &fallback) && fallback != nullptr) {
                    fallback->fallback = true;
                }
            }
        }

        if (puppet_closing) {
            // The last pass: the layer's own material over what the chain made, skinned.
            wpscene::WPImageEffect closing;
            closing.materials.push_back(closing_material);
            if (BuildEffect(context, image, closing, index++, node, *chain, geometry.extent, false, false,
                            false, false, plan.key, camera_name, tinted, all_materials, nullptr,
                            mdl.puppet != nullptr ? &puppet_layer : nullptr, true)) {
                any_fixed = true;
            }
        }

        auto camera = std::make_shared<SceneCamera>(geometry.extent[0], geometry.extent[1], -1.0f, 1.0f);
        // The first pass of a composition model reads the screen where the layer is drawn, so
        // its camera is not local to the layer's own picture, children or none.
        camera->SetLayerLocal(! composition && ! kind.compose_model);
        camera->SetComposeLayer(composition);
        camera->SetChildrenUseSceneCamera(composition && kind.fullscreen);
        camera->AttatchNode(composition ? node : context.effect_camera_node);
        camera->AttatchImgEffect(chain);
        scene.cameras[camera_name] = camera;
        node->SetCamera(camera_name);
        if (! image.copybackground) node->SetSkipRenderPass(true);
        // The own pass fills its buffer untransformed; the final card carries the placement.
        node->SetRenderTransformOverride(Matrix4d::Identity());
        layer.effects = chain;
        if (runtime != nullptr) runtime->RegisterNodeEffectFinal(plan.key, node.get(), chain.get());
    } else if (kind.fullscreen) {
        node->SetCamera(std::string(FullscreenLayerCamera));
    } else if (perspective_card) {
        node->SetCamera("global_perspective");
    }
    if (referenced) RegisterImageComposite(context, image, *node);

    RegisterLayerAlphaDrivers(context, plan.key, image, all_materials);
    if (image.colorIgnored && entry.contains("color")) {
        // The colour (and what drives it) no longer tints anything: the picture is drawn as it is.
        nlohmann::json without_color = entry;
        without_color.erase("color");
        RegisterLayerTint(context, plan.key, without_color, image.color, tinted);
    } else {
        RegisterLayerTint(context, plan.key, entry, image.color, tinted);
    }
    if (runtime != nullptr && ImageObjectHandlesCursorEvents(image)) {
        if (auto mask = BuildImageHitMask(context, image); mask.has_value()) {
            runtime->RegisterNodeHitMask(plan.key, std::move(*mask));
        }
    }
    return true;
}

/// The final card of every layer that draws through effects sits where its layer is
/// drawn, once the tree exists (R83).
void SyncEffectFinals(ParseContext& context) {
    for (auto& layer : context.layers) {
        if (layer.effects == nullptr || layer.node == nullptr) continue;
        layer.node->UpdateTrans();
        SetNodeTransformFromMatrix(layer.effects->FinalNode(), layer.node->ModelTrans());
    }
}

/// The card of every pass-through layer with effects copies the screen where its layer is
/// drawn: its world transform, under all its parents, which is known once the tree exists.
/// The runtime then keeps the card in step with that transform while the scene runs.
void LayOutPassthroughCards(ParseContext& context) {
    auto* runtime = context.scene->runtime.get();
    for (auto& card : context.passthrough_cards) {
        card.node->UpdateTrans();
        const Matrix4d world = card.node->ModelTrans();
        LayOutPassthroughCard(*card.mesh, card.shape, world);
        if (runtime == nullptr) continue;
        runtime->RegisterPassthroughCard(
            card.node, card.mesh,
            [shape = card.shape](SceneMesh& mesh, const Matrix4d& moved) {
                LayOutPassthroughCard(mesh, shape, moved);
            },
            world);
    }
    context.passthrough_cards.clear();
}

/// The layer record of a typed entry: the stand-in node its children already hang from,
/// or a new one. Typed objects register their own timelines.
ParsedLayer& TypedLayer(ParseContext& context, std::size_t at, const nlohmann::json& entry,
                        const EntryPlan& plan) {
    if (plan.placeholder && ! context.layers.empty() && context.layers.back().entry == at) {
        auto& layer = context.layers.back();
        layer.plain = false;
        if (auto* runtime = context.scene->runtime.get(); runtime != nullptr) {
            wpscene::WPMiscObjectBase base;
            base.FromCommonJson(entry);
            RegisterNodeTransformSettings(*runtime, layer.node.get(), plan.key, base.origin_setting,
                                          base.scale_setting, base.angles_setting, true);
        }
        return layer;
    }
    return AddLayer(context, at, entry, plan, true, false);
}

/// A model material: read as a material file, with the defaults of a solid model where
/// the pass leaves a word out (normal blending, back faces culled, depth tested and written).
std::optional<wpscene::WPMaterial> ReadModelMaterial(fs::VFS& vfs, const std::string& path) {
    nlohmann::json json;
    if (path.empty() ||
        ! wpscene::ParseBoundedJson(fs::GetFileContent(vfs, "/assets/" + path), json)) {
        return std::nullopt;
    }
    wpscene::WPMaterial material;
    if (! material.FromJson(json)) return std::nullopt;
    const nlohmann::json* pass = nullptr;
    if (const auto passes = json.find("passes"); passes != json.end() && passes->is_array() && ! passes->empty()) {
        pass = &passes->front();
    }
    const auto says = [pass](const char* key) { return pass != nullptr && pass->is_object() && pass->contains(key); };
    if (! says("blending")) material.blending = "normal";
    if (! says("cullmode")) material.cullmode = "normal";
    if (! says("depthtest")) material.depthtest = "enabled";
    if (! says("depthwrite")) material.depthwrite = "enabled";
    return material;
}

/// Loads one 3D model object (P5 R74 to R78).
bool LoadModelEntry(ParseContext& context, std::size_t at, const nlohmann::json& entry,
                    const EntryPlan& plan, const wpscene::WPSceneGeneral&) {
    auto& scene = *context.scene;
    wpscene::WPModelObject model;
    if (! model.FromJson(entry, *context.vfs)) {
        LOG_ERROR("model object %d names no model", plan.id);
        return false;
    }
    WPMdl mdl;
    if (! WPMdlParser::Parse(model.model, *context.vfs, mdl) ||
        std::none_of(mdl.meshes.begin(), mdl.meshes.end(),
                     [](const WPMdl::Mesh& mesh) { return ! mesh.positions.empty(); })) {
        LOG_ERROR("model '%s' cannot be read or has no vertices", model.model.c_str());
        return false;
    }
    const bool has_bones = mdl.puppet != nullptr && ! mdl.puppet->bones.empty();

    auto mesh = std::make_shared<SceneMesh>();
    WPMdlParser::GenPuppetMesh(*mesh, mdl, false);
    struct Slot {
        wpscene::WPMaterial authored;
        WPShaderInfo        info;
        LoadedMaterial      loaded;
        bool                ok { false };
    };
    std::vector<Slot> slots;
    for (const auto& source : mdl.meshes) {
        if (source.positions.empty()) continue;
        Slot slot;
        if (auto material = ReadModelMaterial(*context.vfs, source.mat_json_file); material.has_value()) {
            slot.authored = std::move(*material);
            if (has_bones) WPMdlParser::AddPuppetMatInfo(slot.authored, mdl);
            SceneMaterial scene_material;
            if (LoadMaterial(context, slot.authored, scene_material, slot.loaded)) {
                slot.ok = true;
                mesh->AddMaterial(std::move(scene_material));
            }
        }
        if (! slot.ok) {
            LOG_ERROR("model '%s': the material '%s' cannot be loaded", model.model.c_str(),
                      source.mat_json_file.c_str());
            mesh->AddMaterial(SceneMaterial {});
            const std::size_t index = slots.size();
            if (index < mesh->Submeshes().size()) {
                mesh->Submeshes()[index].SetDrawRanges(
                    std::array<SceneMesh::DrawRange, 1> { SceneMesh::DrawRange { 0, 0 } });
            }
        }
        slots.push_back(std::move(slot));
    }
    context.uses_models = true;

    auto& layer = TypedLayer(context, at, entry, plan);
    const auto node = layer.node;
    node->AddMesh(mesh);
    if (model.perspective || (scene.activeCamera != nullptr && scene.activeCamera->IsPerspective())) {
        node->SetCamera("global_perspective");
    }

    WPPuppetLayer puppet_layer;
    auto*         runtime = scene.runtime.get();
    if (mdl.puppet != nullptr) {
        puppet_layer = WPPuppetLayer(mdl.puppet);
        puppet_layer.prepared(model.puppet_layers);
        layer.puppet       = mdl.puppet;
        layer.puppet_layer = puppet_layer;
        if (runtime != nullptr) {
            runtime->RegisterPuppetLayer(plan.key, puppet_layer);
            BindPuppetAnimationLayerSettings(context, plan.key, model, puppet_layer);
        }
    }
    for (std::size_t slot = 0; slot < slots.size(); ++slot) {
        if (context.shader_updater != nullptr) {
            WPShaderValueData data;
            data.parallaxDepth = model.parallaxDepth;
            data.renderTargets = slots[slot].loaded.render_targets;
            data.puppet_layer  = puppet_layer;
            context.shader_updater->SetNodeData(node.get(), static_cast<uint32_t>(slot), data);
        }
        if (slots[slot].ok) {
            RegisterDrivenMaterialConstants(context, mesh->MaterialSlotPtr(slot), slots[slot].authored,
                                      slots[slot].loaded.info, plan.key);
        }
    }
    if (runtime != nullptr) {
        runtime->SetNodeCursorTarget(plan.key, true, model.solid, model.disablepropagation);
    }
    return true;
}

// ---------------------------------------------------------------------------
// Text objects (P3 R1 to R55, R65, R67 to R75, R79, R85; R112).
// ---------------------------------------------------------------------------

/// The text a setting holds: the string itself, or the `value` (else the `text`)
/// string of a wrapper; anything else is the empty string (P3 R7).
std::string SettingText(const nlohmann::json& setting) {
    if (setting.is_string()) return setting.get<std::string>();
    if (setting.is_object()) {
        for (const char* member : { "value", "text" }) {
            const auto found = setting.find(member);
            if (found != setting.end() && found->is_string()) return found->get<std::string>();
        }
    }
    return {};
}

/// Names the font of a text layer and finds what draws it (P3 R35): one of the eight
/// scene keys is an installed face of the system; any other string is first tried as
/// a file of the asset namespace (a leading `assets/` or `/` is tolerated), then,
/// when it starts with `/`, as a path of its own; whatever cannot be found is Arial.
/// The font the scene named stays in `font_key` for scripts to read back.
void ResolveTextFont(fs::VFS& vfs, TextLayerState& state, const std::string& key) {
    constexpr std::string_view kKeyPrefix = "systemfont_";
    state.font_key = key;
    state.resolved_font_data = SharedFontData();
    state.resolved_font_path.clear();
    state.resolved_font_face.clear();
    state.resolved_font_fit = {};
    if (! key.empty() && ! IsSceneFontKey(key)) {
        std::string relative = key;
        if (relative.front() == '/') relative.erase(0, 1);
        if (relative.rfind("assets/", 0) == 0) relative.erase(0, 7);
        std::vector<std::string> candidates { "/assets/" + relative };
        if (key.front() == '/') candidates.push_back(key);
        for (const auto& path : candidates) {
            const std::string bytes = fs::GetFileContent(vfs, path);
            if (bytes.empty()) continue;
            state.resolved_font_kind     = "asset";
            state.resolved_font_identity = key;
            state.resolved_font_path     = path;
            state.resolved_font_data     = std::vector<uint8_t>(bytes.begin(), bytes.end());
            return;
        }
    }
    const auto face = ResolveSceneFont(key);
    state.resolved_font_kind     = "system";
    state.resolved_font_identity = IsSceneFontKey(key) ? key.substr(kKeyPrefix.size()) : "arial";
    state.resolved_font_path     = face.path;
    state.resolved_font_face     = face.postscript_name;
    state.resolved_font_fit      = face.fit;
}

/// How a text card is drawn; each combination is one generated program (P3 R85).
struct TextCardKind {
    bool composite { false }; // seeds its picture from the scene behind it
    bool styled { false };    // the picture holds three coverage masks
    bool outline { false };
    bool filled { false };    // an opaque background lies under the glyphs
    int  neutral { 0 };       // 1: over white, 2: over black (colour blend modes 5 and 10)
};

std::string TextProgramName(const TextCardKind& kind) {
    std::string name = kind.composite ? "text_composite" : "text";
    if (kind.styled) name += kind.outline ? "_styled_outline" : "_styled";
    if (kind.filled) name += "_filled";
    if (kind.neutral == 1) name += "_over_white";
    if (kind.neutral == 2) name += "_over_black";
    return name;
}

std::string TextVertexSource(const TextCardKind& kind) {
    std::string source = "uniform mat4 g_ModelViewProjectionMatrix;\n";
    if (kind.composite) source += "uniform mat4 g_EffectModelViewProjectionMatrix;\n";
    source += "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n";
    if (kind.composite) source += "varying vec3 v_ScreenPos;\n";
    source += "void main() {\n"
              "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
              "  v_TexCoord = a_TexCoord;\n";
    if (kind.composite) {
        // Where the vertex lies on the screen, for the picture behind it: the layer's own
        // matrix, since the pass itself draws into the chain's buffer.
        source += "  vec4 s = g_EffectModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
                  "  v_ScreenPos = vec3(s.x * 0.5 + s.w * 0.5, s.w * 0.5 - s.y * 0.5, s.w);\n";
    }
    source += "}\n";
    return source;
}

std::string TextFragmentSource(const TextCardKind& kind) {
    std::string source = "uniform sampler2D g_Texture0;\n";
    if (kind.composite) source += "uniform sampler2D g_Texture1;\nuniform float g_Composite;\n";
    source += "uniform vec3 g_Color;\nuniform float g_Alpha;\nuniform float g_Brightness;\n";
    if (kind.outline) source += "uniform vec3 g_OutlineColor;\n";
    if (kind.styled) source += "uniform vec3 g_ShadowColor;\n";
    if (kind.filled) {
        source += "uniform vec3 g_Background;\nuniform float g_BackgroundBrightness;\n"
                  "uniform vec2 g_CardInset;\n";
    }
    source += "varying vec2 v_TexCoord;\n";
    if (kind.composite) source += "varying vec3 v_ScreenPos;\n";
    source += "void main() {\n"
              "  vec4 texel = texture(g_Texture0, v_TexCoord);\n"
              "  vec3 tint = g_Color * g_Brightness;\n"
              "  vec3 color;\n"
              "  float cover;\n";
    if (kind.styled) {
        source += "  float glyph_a = texel.g * g_Alpha;\n"
                  "  float shadow_a = texel.b * g_Alpha;\n";
        source += kind.outline ? "  vec3 glyph = mix(g_OutlineColor, tint, texel.r);\n"
                               : "  vec3 glyph = tint;\n";
        source += "  cover = glyph_a + shadow_a * (1.0 - glyph_a);\n"
                  "  color = cover > 0.0 ? (glyph * glyph_a + g_ShadowColor * shadow_a * "
                  "(1.0 - glyph_a)) / cover : glyph;\n";
    } else {
        source += "  color = texel.rgb * tint;\n"
                  "  cover = texel.a * g_Alpha;\n";
    }
    if (kind.filled) {
        source += "  vec3 fill_color = g_Background * g_BackgroundBrightness;\n"
                  "  bool inside = v_TexCoord.x >= g_CardInset.x && v_TexCoord.x <= 1.0 - g_CardInset.x "
                  "&& v_TexCoord.y >= g_CardInset.y && v_TexCoord.y <= 1.0 - g_CardInset.y;\n"
                  "  float fill = inside ? g_Alpha : 0.0;\n";
    } else {
        source += "  vec3 fill_color = vec3(0.0);\n  float fill = 0.0;\n";
    }
    if (kind.composite) {
        source += "  if (g_Composite > 0.5) {\n"
                  "    vec2 screen = v_ScreenPos.xy / v_ScreenPos.z;\n"
                  "    vec3 behind = texture(g_Texture1, screen).rgb;\n"
                  "    vec3 base = fill > 0.0 ? fill_color : behind;\n"
                  "    float held = pow(cover, " + std::to_string(kTextCompositeAlphaExponent) + ") + fill * (1.0 - cover);\n"
                  "    gl_FragColor = vec4(mix(base, color, cover), clamp(held, 0.0, 1.0));\n"
                  "    return;\n"
                  "  }\n";
    }
    if (kind.neutral != 0) {
        source += kind.neutral == 1 ? "  vec3 neutral = vec3(1.0);\n" : "  vec3 neutral = vec3(0.0);\n";
        source += "  vec3 base = fill > 0.0 ? fill_color : neutral;\n"
                  "  gl_FragColor = vec4(mix(base, color, cover), 1.0);\n";
    } else {
        source += "  float total = cover + fill * (1.0 - cover);\n"
                  "  vec3 mixed = total > 0.0 ? (color * cover + fill_color * fill * (1.0 - cover)) / total : color;\n"
                  "  gl_FragColor = vec4(mixed, total);\n";
    }
    source += "}\n";
    return source;
}

/// The card's material: the generated program of `kind`, over the layer's own raster
/// (slot 0) and, for a composite, the scene colour buffer (slot 1).
bool LoadTextMaterial(ParseContext& context, const TextCardKind& kind, const std::string& raster,
                      SceneMaterial& material, LoadedMaterial& loaded) {
    wpscene::WPMaterial authored;
    authored.shader     = TextProgramName(kind);
    authored.blending   = "translucent";
    authored.cullmode   = "nocull";
    authored.depthtest  = "disabled";
    authored.depthwrite = "disabled";
    authored.textures   = { raster };
    if (kind.composite) authored.textures.push_back("_rt_FullFrameBuffer");
    MaterialLoadOptions options;
    options.vertex_source   = TextVertexSource(kind);
    options.fragment_source = TextFragmentSource(kind);
    if (! LoadMaterial(context, authored, material, loaded, options)) return false;
    material.name = "text";
    return true;
}

/// A raster side in whole texels, 1 to 4096.
uint32_t TextRasterSide(float extent) {
    if (! (extent > 1.0f)) return 1;
    if (extent >= 4096.0f) return 4096;
    return static_cast<uint32_t>(std::ceil(extent));
}

/// Draws the text once and hands the picture to the scene's image source, under the
/// name the card's material reads it by.
void PublishInitialTextRaster(Scene& scene, const TextLayerState& state, const TextLayerLayout& layout) {
    auto* images = dynamic_cast<RuntimeImageSource*>(scene.imageParser.get());
    if (images == nullptr) return;
    const auto     wanted = TextLayerRasterSizeForLayout(state, layout);
    const uint32_t width  = TextRasterSide(wanted.x());
    const uint32_t height = TextRasterSide(wanted.y());
    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);
    images->SetRgbaImage(TextTextureName(state.layer_key), width, height, rgba.data(), rgba.size());
}

/// The brightness a text value takes: only an HDR scene applies it.
float EffectiveTextBrightness(const Scene& scene, float authored) {
    return scene.hdr && std::isfinite(authored) ? authored : 1.0f;
}

/// Hands a text layer's live constant to its material: `convert` turns the value into the
/// uniform's lanes.
void FollowTextConstant(ParseContext& context, const std::shared_ptr<SceneMaterial>& material,
                        const nlohmann::json& entry, const char* key, const char* uniform,
                        const std::string& layer_key,
                        std::function<ShaderValue(const DynamicValue&)> convert,
                        bool vec3) {
    auto* runtime = context.scene->runtime.get();
    if (runtime == nullptr) return;
    const auto setting = entry.find(key);
    if (setting == entry.end() || ! HasDynamicSetting(*setting)) return;
    auto value = vec3 ? ResolveVec3Setting(*runtime, *setting, layer_key)
                      : ResolveFloatSetting(*runtime, *setting, layer_key);
    std::weak_ptr<SceneMaterial> weak = material;
    const std::string            name = uniform;
    runtime->RegisterDynamicValueListener(
        std::move(value), [weak, name, convert = std::move(convert)](const DynamicValue& now) {
            if (const auto held = weak.lock()) held->customShader.constValues[name] = convert(now);
        });
}

/// Loads one text object (P3 R2 to R11, R17 to R26, R29 to R33, R39 to R55).
bool LoadTextEntry(ParseContext& context, std::size_t at, const nlohmann::json& entry,
                   const EntryPlan& plan) {
    auto& scene = *context.scene;
    wpscene::WPTextObject obj;
    if (! obj.FromJson(entry, *context.vfs)) return false;
    auto* runtime = scene.runtime.get();
    const bool scene_fog = scene.fog_distance || scene.fog_height;

    // Keys that are baked as the layer is laid out are read once, with the user's value.
    ResolveLoadTimeTextStyle(context, obj, plan.key);
    if (runtime != nullptr) {
        for (const auto& [key, field] : { std::pair<const char*, float*> { "pointsize", &obj.pointsize },
                                          { "maxwidth", &obj.maxwidth } }) {
            const auto found = entry.find(key);
            if (found != entry.end() && found->is_object() && found->contains("user") &&
                ! found->contains("script")) {
                ResolveLoadOnlySceneSetting(*runtime, *found, *field);
            }
        }
    }

    // The effect chain: the effects that are built (visible, or switchable by a script)
    // and have a pass, then the colour blend's passthrough. A buffer of an effect is the
    // card's size whatever its declared scale.
    ResolveUserEffectVisibility(context, obj.effects, plan.key);
    std::vector<wpscene::WPImageEffect> chain_sources;
    chain_sources.reserve(obj.effects.size() + 1);
    for (const auto& effect : obj.effects) {
        if (! EffectIsBuilt(effect) || effect.materials.empty()) continue;
        chain_sources.push_back(effect);
        for (auto& fbo : chain_sources.back().fbos) fbo.scale = 1;
    }
    const std::size_t real_effects = chain_sources.size();
    const bool        additive     = obj.colorBlendMode == kAdditiveColorBlendMode;
    const bool        blend_pass   = obj.colorBlendMode != 0 && ! additive;
    if (blend_pass) {
        auto effect = MakeColorBlendEffect(*context.vfs, obj.colorBlendMode);
        if (! effect.has_value()) return false;
        chain_sources.push_back(std::move(*effect));
    }
    const bool has_chain = ! chain_sources.empty();

    // What the layer says.
    std::unique_ptr<DynamicValue> text_value;
    std::string                   initial = SettingText(obj.text);
    if (runtime != nullptr && wpscene::SettingIsDriven(obj.text)) {
        nlohmann::json setting = obj.text;
        setting["value"]       = initial;
        text_value             = ResolveStringSetting(*runtime, setting, plan.key);
        initial                = text_value->toString();
    } else if (runtime != nullptr && obj.text.is_object() && obj.text.contains("script") &&
               obj.text["script"].is_string() &&
               ! IsSceneEventScript(obj.text["script"].get_ref<const std::string&>())) {
        // Handlers only: the script is attached and drives nothing.
        nlohmann::json setting = obj.text;
        setting["value"]       = initial;
        runtime->RegisterDynamicValueListener(ResolveStringSetting(*runtime, setting, plan.key),
                                              [](const DynamicValue&) {});
    }

    const bool            padded = TextCardIsPadded(obj, scene_fog);
    const auto            authored_padding = AuthoredTextCardPadding(obj);
    const float           brightness = EffectiveTextBrightness(scene, obj.brightness);
    TextLayerState state;
    state.text                = initial;
    state.layer_key           = plan.key;
    state.point_size          = obj.pointsize;
    state.padding             = padded ? authored_padding : linalg::Vector2f::Zero();
    state.authored_padding    = authored_padding;
    state.padding_applies     = padded;
    state.spacing             = linalg::Vector2f(obj.spacing[0], obj.spacing[1]);
    // The raster is neutral: colour, alpha and brightness reach the card through its
    // uniforms, so the state keeps its white, full-alpha defaults.
    state.horizontal_align    = std::string(TextHorizontalAlignWord(ParseTextHorizontalAlign(obj.horizontalalign)));
    state.vertical_align      = std::string(TextVerticalAlignWord(ParseTextVerticalAlign(obj.verticalalign)));
    state.max_width           = obj.maxwidth;
    state.max_rows            = obj.maxrows;
    state.limit_width         = obj.limitwidth;
    state.limit_rows          = obj.limitrows;
    state.use_ellipsis        = obj.limituseellipsis;
    state.block_align         = obj.blockalign;
    state.style.outline           = obj.outline;
    state.style.outline_thickness = obj.outlinethickness;
    state.style.outline_color     = Vector3f(obj.outlinecolor.data());
    state.style.blur              = obj.blur;
    state.style.blur_size         = obj.blursize;
    state.style.drop_shadow       = obj.dropshadow;
    state.style.shadow_size       = obj.dropshadowsize;
    state.style.shadow_opacity    = obj.dropshadowopacity;
    state.style.shadow_offset     = linalg::Vector2f(obj.dropshadowoffset[0], obj.dropshadowoffset[1]);
    state.style.shadow_color      = Vector3f(obj.dropshadowcolor.data());
    ResolveTextFont(*context.vfs, state, SettingText(obj.font).empty() ? std::string(kDefaultSceneFontKey)
                                                                       : SettingText(obj.font));

    // Laid out and drawn once, here.
    const TextLayerLayout layout = MeasureTextLayerLayout(state);
    const auto            frame  = TextLayerRenderFrameForLayout(state, layout);
    PublishInitialTextRaster(scene, state, layout);

    // The card's material.
    TextCardKind kind;
    kind.composite = real_effects > 0 && ! blend_pass;
    kind.styled    = TextStyleActive(state.style);
    kind.outline   = kind.styled && state.style.outline;
    kind.filled    = obj.opaquebackground;
    if (blend_pass && obj.colorBlendMode == 5) kind.neutral = 1;
    if (blend_pass && obj.colorBlendMode == 10) kind.neutral = 2;
    SceneMaterial  card;
    LoadedMaterial card_loaded;
    if (! LoadTextMaterial(context, kind, TextTextureName(plan.key), card, card_loaded)) {
        LOG_ERROR("text object %d: the card's program cannot be loaded", plan.id);
        return false;
    }
    card.blenmode    = has_chain ? BlendMode::Normal : (additive ? BlendMode::Additive : BlendMode::Translucent);
    card.depth_test  = false;
    card.depth_write = false;
    {
        auto& values = card.customShader.constValues;
        card.tint.color      = obj.color;
        card.tint.brightness = 1.0f;
        values["g_Color"]      = ShaderValue(obj.color.data(), 3);
        values["g_Brightness"] = ShaderValue(brightness);
        SetMaterialAlpha(card, obj.alpha);
        if (kind.outline) values["g_OutlineColor"] = ShaderValue(obj.outlinecolor.data(), 3);
        if (kind.styled) values["g_ShadowColor"] = ShaderValue(obj.dropshadowcolor.data(), 3);
        if (kind.filled) {
            values["g_Background"] = ShaderValue(obj.backgroundcolor.data(), 3);
            values["g_BackgroundBrightness"] =
                ShaderValue(EffectiveTextBrightness(scene, obj.backgroundbrightness));
        }
    }

    // The node, the card and what the runtime keeps of the layer.
    auto& layer = TypedLayer(context, at, entry, plan);
    const auto node = layer.node;
    auto mesh = MakeTextCardMesh(frame.bounds.left, frame.bounds.bottom, frame.bounds.right,
                                 frame.bounds.top);
    mesh->AddMaterial(std::move(card));
    node->AddMesh(mesh);
    node->SetSkipRenderPass(false);
    const auto card_material = mesh->MaterialSlotPtr(0);
    context.text_cards[plan.id] = frame;
    if (context.shader_updater != nullptr) {
        WPShaderValueData data;
        data.parallaxDepth = obj.parallaxDepth;
        data.renderTargets = card_loaded.render_targets;
        context.shader_updater->SetNodeData(node.get(), 0, data);
    }

    DynamicValue* composite_value = nullptr;
    DynamicValue* inset_value     = nullptr;
    if (runtime != nullptr) {
        runtime->RegisterTextLayer(plan.key, state, layout);
        if (text_value != nullptr) runtime->RegisterTextValue(plan.key, std::move(text_value), false);
        runtime->SetNodeCursorTarget(plan.key, true, obj.solid, obj.disablepropagation);
        if (const auto anchor = ParseTextScreenAnchor(obj.anchor); anchor != TextScreenAnchor::None) {
            runtime->SetNodeScreenAnchor(plan.key, anchor);
        }
        if (kind.filled) {
            auto inset = std::make_unique<DynamicValue>(TextCardInsetInRaster(state, layout));
            inset_value = inset.get();
            runtime->RegisterMaterialConstant(card_material, "g_CardInset", std::move(inset));
        }
    } else if (kind.filled) {
        const auto inset = TextCardInsetInRaster(state, layout);
        card_material->customShader.constValues["g_CardInset"] =
            ShaderValue(std::array<float, 2> { inset.x(), inset.y() });
    }

    // The effect chain, drawn in the card's own plane.
    std::vector<std::shared_ptr<SceneMaterial>> all_materials { card_material };
    std::vector<std::shared_ptr<SceneImageEffect>> counted_effects;
    TextLayerRenderFrame effect_frame = TextLayerEffectFrame(frame);
    const bool referenced = plan.id != 0 && context.referenced_layer_ids.contains(plan.id);
    if (has_chain) {
        // The passes read the card's alpha and nothing else of the layer: its colour is
        // already in the picture.
        wpscene::WPImageObject proxy;
        proxy.id            = plan.id;
        proxy.parallaxDepth = obj.parallaxDepth;
        proxy.clampuvs      = obj.clampuvs;
        proxy.color         = { 1.0f, 1.0f, 1.0f };
        proxy.alpha         = 1.0f; // the card holds the layer's alpha; an opacity effect adds none
        proxy.brightness    = 1.0f;
        const std::array<int32_t, 2> extent { static_cast<int32_t>(std::lround(effect_frame.size.x())),
                                              static_cast<int32_t>(std::lround(effect_frame.size.y())) };
        const std::string camera_name = "__effect_layer_" + std::to_string(plan.id);
        const auto first = PingPongName(WE_EFFECT_PPONG_PREFIX_A, camera_name);
        const auto other = PingPongName(WE_EFFECT_PPONG_PREFIX_B, camera_name);
        const auto sample = LayerRenderTargetSample(scene, proxy);
        for (const auto& name : { first, other }) {
            SceneRenderTarget target;
            target.width      = extent[0];
            target.height     = extent[1];
            target.allowReuse = true;
            target.sample     = sample;
            target.format     = scene.hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8;
            scene.renderTargets[name] = target;
        }
        auto chain = std::make_shared<SceneImageEffectLayer>(
            node.get(), static_cast<float>(extent[0]), static_cast<float>(extent[1]), first, other);
        const auto final_card = MakeTextCardMesh(effect_frame.bounds.left, effect_frame.bounds.bottom,
                                                 effect_frame.bounds.right, effect_frame.bounds.top);
        chain->SetFinalMeshDynamic(MeshUpdate::OnEvent);
        chain->FinalMesh().ChangeMeshDataFrom(*final_card);
        // The last pass is drawn translucent by the alpha it holds, whatever the blend.
        chain->SetFinalBlend(BlendMode::Translucent);
        // With every effect off the layer is plain text again, added when it says so.
        if (additive) chain->SetIdleFinalBlend(BlendMode::Additive);
        chain->SetFinalDepth(false, false);

        std::vector<std::shared_ptr<SceneMaterial>> unused_tint;
        std::size_t index     = 0;
        bool        any_fixed = false;
        for (const auto& source : chain_sources) {
            const bool is_blend_pass = blend_pass && index + 1 == chain_sources.size();
            std::shared_ptr<SceneImageEffect> built;
            if (BuildEffect(context, proxy, source, index, node, *chain, extent, false, is_blend_pass,
                            false, false, plan.key, camera_name, unused_tint, all_materials, &built)) {
                if (! source.scripted_visible) any_fixed = true;
                if (index < real_effects && built != nullptr) counted_effects.push_back(built);
            }
            ++index;
        }
        if (! any_fixed) {
            if (auto idle = MakeColorBlendEffect(*context.vfs, 0); idle.has_value()) {
                for (auto& material : idle->materials) material.combos.erase("BLENDMODE");
                std::shared_ptr<SceneImageEffect> fallback;
                if (BuildEffect(context, proxy, *idle, index++, node, *chain, extent, false, true, false,
                                true, plan.key, camera_name, unused_tint, all_materials, &fallback) &&
                    fallback != nullptr) {
                    fallback->fallback = true;
                }
            }
        }
        // The buffers an effect declares without a size of its own follow the first one,
        // which is the card: they are resized with it as the text changes.
        {
            std::size_t position = 0;
            for (const auto& source : chain_sources) {
                for (const auto& fbo : source.fbos) {
                    const auto found = scene.renderTargets.find(EffectBufferName(fbo.name, plan.id, position));
                    if (found == scene.renderTargets.end()) continue;
                    if (FixedEffectFboExtent(fbo, static_cast<float>(extent[0]),
                                             static_cast<float>(extent[1])).has_value()) {
                        continue;
                    }
                    found->second.bind.enable = true;
                    found->second.bind.screen = false;
                    found->second.bind.name   = first;
                    found->second.bind.scale  = 1.0;
                }
                ++position;
            }
        }
        auto camera_node = std::make_shared<SceneNode>(
            Vector3f(effect_frame.center.x(), effect_frame.center.y(), 0.0f), Vector3f(1.0f, 1.0f, 1.0f),
            Vector3f::Zero());
        scene.sceneGraph->AppendChild(camera_node);
        auto camera = std::make_shared<SceneCamera>(extent[0], extent[1], -1.0f, 1.0f);
        camera->SetLayerLocal(true);
        camera->AttatchNode(camera_node);
        camera->AttatchImgEffect(chain);
        camera->Update();
        scene.cameras[camera_name] = camera;
        node->SetCamera(camera_name);
        // The own pass fills its buffer untransformed; the final card carries the placement.
        node->SetRenderTransformOverride(Matrix4d::Identity());
        layer.effects = chain;
        if (runtime != nullptr) {
            runtime->RegisterNodeEffectFinal(plan.key, node.get(), chain.get(), effect_frame);
        }
    }

    // Another layer samples this one: its composite is the card in its own texture space.
    if (referenced) {
        const auto sampled = has_chain ? effect_frame : frame;
        const std::array<int32_t, 2> extent = TextCardTexelExtent(sampled.size);
        auto camera_node = std::make_shared<SceneNode>(
            Vector3f(sampled.center.x(), sampled.center.y(), 0.0f), Vector3f(1.0f, 1.0f, 1.0f),
            Vector3f::Zero());
        scene.sceneGraph->AppendChild(camera_node);
        wpscene::WPImageObject proxy;
        proxy.id = plan.id;
        auto& composite_camera = RegisterLayerComposite(
            context, plan.id, *node,
            { std::min(extent[0], kTextEffectExtentLimit), std::min(extent[1], kTextEffectExtentLimit) },
            obj.clampuvs, camera_node, LayerRenderTargetFilter(scene, proxy));
        // The camera frames the card itself, fraction and all, as it does after a relayout;
        // only the target holds whole texels.
        composite_camera.SetWidth(sampled.size.x());
        composite_camera.SetHeight(sampled.size.y());
        composite_camera.Update();
    }

    // What follows the layer's effects as they are switched (P3 R26, R44).
    const bool any_counted_visible = std::any_of(counted_effects.begin(), counted_effects.end(),
                                                 [](const auto& effect) { return effect->visible; });
    if (kind.composite) {
        auto composite = std::make_unique<DynamicValue>(any_counted_visible ? 1.0f : 0.0f);
        composite_value = composite.get();
        if (runtime != nullptr) {
            runtime->RegisterMaterialConstant(card_material, "g_Composite", std::move(composite));
        } else {
            card_material->customShader.constValues["g_Composite"] =
                ShaderValue(any_counted_visible ? 1.0f : 0.0f);
            composite_value = nullptr;
        }
    }
    if (runtime != nullptr && (! counted_effects.empty() || kind.filled || kind.composite)) {
        SceneRuntimeContext::TextEffectGate gate;
        gate.padded_regardless = TextCardIsPaddedRegardless(obj, scene_fog);
        gate.effects           = counted_effects;
        gate.composite         = composite_value;
        gate.card_inset        = inset_value;
        runtime->RegisterTextEffectGate(plan.key, std::move(gate));
    }

    // Alpha, colour and brightness: live, and never part of the picture (P3 R39 to R41).
    RegisterAlphaSetting(context, plan.key,
                         entry.contains("alpha") ? entry.at("alpha") : nlohmann::json(), obj.alpha,
                         all_materials);
    if (runtime != nullptr) {
        const std::vector<std::shared_ptr<SceneMaterial>> tinted { card_material };
        if (const auto color = entry.find("color"); color != entry.end() && color->is_object()) {
            nlohmann::json only_color = nlohmann::json::object();
            only_color["color"]       = *color;
            RegisterLayerTint(context, plan.key, only_color, obj.color, tinted);
        } else {
            runtime->BindMaterialColor(plan.key, tinted,
                                       std::make_unique<DynamicValue>(Vector3f(obj.color.data())));
        }
    }
    const bool hdr = scene.hdr;
    FollowTextConstant(context, card_material, entry, "brightness", "g_Brightness", plan.key,
                       [hdr](const DynamicValue& now) {
                           const float value = now.getFloat();
                           return ShaderValue(hdr && std::isfinite(value) ? value : 1.0f);
                       }, false);
    const auto vec3_of = [](const DynamicValue& now) {
        const auto lanes = now.getVec3();
        return ShaderValue(std::array<float, 3> { lanes.x(), lanes.y(), lanes.z() });
    };
    if (kind.filled) {
        FollowTextConstant(context, card_material, entry, "backgroundcolor", "g_Background", plan.key,
                           vec3_of, true);
        FollowTextConstant(context, card_material, entry, "backgroundbrightness",
                           "g_BackgroundBrightness", plan.key,
                           [hdr](const DynamicValue& now) {
                               const float value = now.getFloat();
                               return ShaderValue(hdr && std::isfinite(value) ? value : 1.0f);
                           }, false);
    }
    if (kind.outline) {
        FollowTextConstant(context, card_material, entry, "outlinecolor", "g_OutlineColor", plan.key,
                           vec3_of, true);
    }
    if (kind.styled) {
        FollowTextConstant(context, card_material, entry, "dropshadowcolor", "g_ShadowColor", plan.key,
                           vec3_of, true);
    }
    return true;
}

/// The layer a script's `createLayer({ text, ... })` makes (P3 R55, R73): the keys go
/// through the path of a scene object, with the id the runtime gives it. The layer is
/// not attached; the runtime joins it to the scene graph.
std::shared_ptr<SceneNode> MakeScriptTextLayer(const std::shared_ptr<Scene>& scene, fs::VFS* vfs,
                                               const LazyParseInputs& inputs,
                                               const std::string& config, int32_t object_id) {
    if (scene == nullptr || scene->runtime == nullptr || vfs == nullptr) return nullptr;
    auto entry = nlohmann::json::parse(config, nullptr, false);
    if (! entry.is_object()) return nullptr;
    entry["id"] = object_id;
    // The name is the script's to give (`NameLayer`); the key is always generated.
    entry.erase("name");
    entry.erase("parent");
    if (! entry.contains("text") || entry["text"].is_null()) entry["text"] = "";
    EntryPlan plan;
    plan.kind      = EntryKind::Text;
    plan.admission = Admission::Object;
    plan.id        = object_id;
    plan.key       = "__we_text_" + std::to_string(object_id);

    ParseContext lazy = MakeLazyParseContext(scene, *vfs, inputs);
    LazyShaderParseScope scope(inputs.index);
    if (! LoadTextEntry(lazy, 0, entry, plan) || lazy.layers.empty()) {
        LOG_ERROR("createLayer: the text layer could not be built");
        return nullptr;
    }
    FlushPendingMetalTranslations(*scene);
    for (auto& [source, key] : lazy.scene_scripts) {
        scene->runtime->RegisterSceneScript(std::move(source), std::move(key));
    }
    return lazy.layers.back().node;
}

/// Reads an asset as a JSON object. A file that is missing (the virtual file system has
/// already said so) or empty is no document, and is not parsed to log a second error.
bool ReadAssetObject(fs::VFS& vfs, const std::string& asset_path, nlohmann::json& out) {
    const auto text = fs::GetFileContent(vfs, "/assets/" + asset_path);
    return ! text.empty() && wpscene::ParseBoundedJson(text, out) && out.is_object();
}

/// Builds the template a script's `createLayer(<model path>)` copies (P2 R8): the layer
/// of an object that holds the model, visible and placed nowhere, built once and never
/// attached to the scene. A model that gives no size takes the picture size of its first
/// texture. False when there is no such model or it is a shape that cannot be copied.
bool LoadLayerTemplate(const std::shared_ptr<Scene>& scene, fs::VFS* vfs,
                       const LazyParseInputs& inputs, std::string_view requested) {
    if (scene == nullptr || scene->runtime == nullptr || vfs == nullptr) return false;
    const std::string path(requested);
    nlohmann::json    model;
    if (path.empty() || ! ReadAssetObject(*vfs, path, model)) return false;
    const auto flag = [&model](const char* key) {
        const auto found = model.find(key);
        return found != model.end() && found->is_boolean() && found->get<bool>();
    };
    if (IsComposeLayerModel(path) || flag("passthrough") || flag("fullscreen")) {
        scene->runtime->ReportUnsupportedLayerTemplate(path);
        return false;
    }

    nlohmann::json entry = { { "image", path },
                             { "name", "__we_template_" + path },
                             { "visible", true },
                             { "origin", { 0, 0, 0 } },
                             { "scale", { 1, 1, 1 } },
                             { "angles", { 0, 0, 0 } } };
    EntryPlan plan;
    plan.kind      = EntryKind::Image;
    plan.admission = Admission::Object;
    plan.key       = "__we_template_" + path;

    ParseContext lazy = MakeLazyParseContext(scene, *vfs, inputs);
    LazyShaderParseScope scope(inputs.index);
    if (! model.contains("width")) {
        // The picture of the first texture of the model's material, when it can be read.
        nlohmann::json material;
        const auto     named = model.find("material");
        if (named != model.end() && named->is_string() &&
            ReadAssetObject(*vfs, named->get<std::string>(), material)) {
            const auto passes = material.find("passes");
            if (passes != material.end() && passes->is_array() && ! passes->empty() &&
                passes->front().is_object()) {
                const auto textures = passes->front().find("textures");
                if (textures != passes->front().end() && textures->is_array() && ! textures->empty() &&
                    textures->front().is_string()) {
                    const auto& header = TextureHeaderOf(lazy, textures->front().get<std::string>());
                    const int32_t width  = header.mapWidth > 0 ? header.mapWidth : header.width;
                    const int32_t height = header.mapHeight > 0 ? header.mapHeight : header.height;
                    if (width > 0 && height > 0) entry["size"] = { width, height };
                }
            }
        }
    }
    if (! LoadImageEntry(lazy, 0, entry, plan, inputs.general) || lazy.layers.empty()) {
        LOG_ERROR("createLayer: the template of '%s' could not be built", path.c_str());
        return false;
    }
    FlushPendingMetalTranslations(*scene);
    auto node = lazy.layers.back().node;
    scene->runtime->RegisterLayerTemplate(path, node, scene->runtime->NodeSize(plan.key));
    return true;
}

// ---------------------------------------------------------------------------
// Particle layers (P4 R1 to R10, R31 to R34, R50, R51 to R58, R75 to R78, R82 to R90,
// R92 to R97, R99 to R113, R121, R124; R37, R49, R87).
// ---------------------------------------------------------------------------

constexpr uint32_t kMaxParticleCapacity = 20000;
constexpr uint64_t kMaxParticleMeshBytes = 1ull << 30;

enum class ParticleRendererKind
{
    Sprite,
    SpriteTrail,
    Rope,
    RopeTrail,
};

/// A name starting with `rope` is a rope; one ending in `trail` a trail; any other draws a sprite.
ParticleRendererKind ClassifyParticleRenderer(const std::string& name) {
    const bool rope  = name.rfind("rope", 0) == 0;
    const bool trail = name.size() >= 5 && name.compare(name.size() - 5, 5, "trail") == 0;
    if (rope) return trail ? ParticleRendererKind::RopeTrail : ParticleRendererKind::Rope;
    return trail ? ParticleRendererKind::SpriteTrail : ParticleRendererKind::Sprite;
}

bool IsRopeKind(ParticleRendererKind kind) {
    return kind == ParticleRendererKind::Rope || kind == ParticleRendererKind::RopeTrail;
}

/// The mesh a renderer fills every frame, with room for `quads` quads: the billboard layout
/// of a sprite (position, the corner and size record, colour, the thick record for sheets and
/// trails, the two other angles) or the seven four-float groups of a rope piece.
std::shared_ptr<SceneMesh> MakeParticleMesh(ParticleRendererKind kind, bool thick, uint32_t quads) {
    using Attribute = SceneVertexArray::SceneVertexAttribute;
    std::vector<Attribute> attributes;
    if (IsRopeKind(kind)) {
        attributes = { { std::string(WE_IN_POSITIONVEC4), VertexType::FLOAT4 },
                       { std::string(WE_IN_TEXCOORDVEC4), VertexType::FLOAT4 },
                       { std::string(WE_IN_TEXCOORDVEC4C1), VertexType::FLOAT4 },
                       { std::string(WE_IN_TEXCOORDVEC4C2), VertexType::FLOAT4 },
                       { std::string(WE_IN_TEXCOORDVEC4C3), VertexType::FLOAT4 },
                       { std::string(WE_IN_TEXCOORDC4), VertexType::FLOAT4 },
                       { std::string(WE_IN_COLOR), VertexType::FLOAT4 } };
    } else {
        attributes = { { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
                       { std::string(WE_IN_TEXCOORDVEC4), VertexType::FLOAT4 },
                       { std::string(WE_IN_COLOR), VertexType::FLOAT4 } };
        if (thick) attributes.push_back({ std::string(WE_IN_TEXCOORDVEC4C1), VertexType::FLOAT4 });
        attributes.push_back({ std::string(WE_IN_TEXCOORDC2), VertexType::FLOAT2 });
    }
    auto mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    mesh->AddVertexArray(SceneVertexArray(attributes, static_cast<std::size_t>(quads) * 4));
    AddParticleIndexArray(*mesh, quads);
    auto& vertices = mesh->GetVertexArray(0);
    vertices.SetOption(WE_CB_THICK_FORMAT, thick);
    if (IsRopeKind(kind)) vertices.SetOption(WE_PRENDER_ROPE, true);
    else vertices.SetOption(WE_PRENDER_SPRITE, true);
    if (kind == ParticleRendererKind::SpriteTrail || kind == ParticleRendererKind::RopeTrail) {
        vertices.SetOption(WE_PRENDER_TRAIL, true);
    }
    if (kind == ParticleRendererKind::RopeTrail) vertices.SetOption(WE_PRENDER_ROPETRAIL, true);
    return mesh;
}

/// One renderer entry of a particle file, prepared: its material, mesh and what the
/// material needs to know about it.
struct ParticleRendererBuild {
    ParticleRendererKind       kind { ParticleRendererKind::Sprite };
    wpscene::ParticleRender    render;
    SceneMaterial              material;
    LoadedMaterial             loaded;
    wpscene::WPMaterial        authored;
    std::shared_ptr<SceneMesh> mesh;
    uint32_t                   pieces_per_pair { 1 }; // rope: pieces between two particles
    uint32_t                   segments { 0 };        // rope trail: recorded points
};

/// One system of a layer, prepared: nothing of it is registered anywhere yet.
struct ParticleSystemBuild {
    const wpscene::Particle*          file { nullptr };
    const wpscene::ParticleChild*     entry { nullptr };
    std::vector<ParticleRendererBuild> renderers;
    std::vector<ParticleSystemBuild>  children;
    uint32_t                          capacity { 0 };
    bool                              has_plain_rope { false };
};

/// Prepares one system and, under it, the children that can be built: the materials load and
/// the meshes are sized. `instances` is the product of the `maxcount` of the child entries on
/// the way from the layer (R83). False when the system cannot be built (a material that does
/// not load, a mesh too large); `skipped` is set for a capacity of zero, which is no error.
bool PrepareParticleSystem(ParseContext& context, const wpscene::Particle& file,
                           const wpscene::ParticleChild* entry, uint64_t instances,
                           ParticleSystemBuild& build, bool& skipped) {
    skipped            = false;
    build.file         = &file;
    build.entry        = entry;
    build.capacity     = std::min(file.maxcount, kMaxParticleCapacity);
    if (build.capacity == 0) {
        LOG_INFO("particle file with a capacity of zero is skipped");
        skipped = true;
        return false;
    }
    for (const auto& render : file.renderers) {
        ParticleRendererBuild item;
        item.render = render;
        item.kind   = ClassifyParticleRenderer(render.name);
        item.authored = file.material;
        if (IsRopeKind(item.kind)) {
            item.authored.shader = "genericropeparticle";
            build.has_plain_rope = build.has_plain_rope || item.kind == ParticleRendererKind::Rope;
        }
        const bool trail = item.kind == ParticleRendererKind::SpriteTrail ||
                           item.kind == ParticleRendererKind::RopeTrail;
        item.authored.combos["THICKFORMAT"]      = trail || IsRopeKind(item.kind) ? 1 : 0;
        item.authored.combos["SPRITESHEETBLEND"] = file.BlendsSpriteFrames() ? 1 : 0;
        item.authored.combos["TRAILRENDERER"]    = trail ? 1 : 0;
        MaterialLoadOptions options;
        options.particle_material = true;
        if (! LoadMaterial(context, item.authored, item.material, item.loaded, options)) {
            LOG_ERROR("particle material '%s' cannot be loaded", item.authored.shader.c_str());
            return false;
        }
        const auto thick_combo = item.loaded.info.combos.find("THICKFORMAT");
        const bool thick = thick_combo != item.loaded.info.combos.end() && thick_combo->second != "0";
        auto& constants = item.material.customShader.constValues;
        if (context.is_ortho) {
            // A 2D scene's eye: the centre of the canvas view, 2000 units in front of it, and
            // screen-facing axes (R114).
            constants["g_EyePosition"] = ShaderValue(std::array<float, 3> {
                static_cast<float>(context.ortho_w) * 0.5f, static_cast<float>(context.ortho_h) * 0.5f, 2000.0f });
            constants["g_OrientationUp"]      = ShaderValue(std::array<float, 3> { 0.0f, 1.0f, 0.0f });
            constants["g_OrientationRight"]   = ShaderValue(std::array<float, 3> { 1.0f, 0.0f, 0.0f });
            constants["g_OrientationForward"] = ShaderValue(std::array<float, 3> { 0.0f, 0.0f, 1.0f });
            constants["g_ViewUp"]             = ShaderValue(std::array<float, 3> { 0.0f, 1.0f, 0.0f });
            constants["g_ViewRight"]          = ShaderValue(std::array<float, 3> { 1.0f, 0.0f, 0.0f });
        }
        // How many straight pieces join two particles (rope), or two recorded points (trail).
        const uint32_t added = static_cast<uint32_t>(std::clamp(render.subdivision, 0.0f, 32.0f));
        item.pieces_per_pair = added + 1;
        uint64_t quads = static_cast<uint64_t>(build.capacity) * instances;
        if (item.kind == ParticleRendererKind::Rope) quads *= item.pieces_per_pair;
        if (item.kind == ParticleRendererKind::RopeTrail) {
            item.segments = static_cast<uint32_t>(std::clamp(render.segments, 2.0f, 32.0f));
            quads *= static_cast<uint64_t>(item.segments) * item.pieces_per_pair;
        }
        const uint64_t floats_per_vertex = IsRopeKind(item.kind) ? 28 : (thick ? 20 : 16);
        const uint64_t bytes             = quads * 4 * floats_per_vertex * 4 + quads * 6 * 4;
        if (quads > std::numeric_limits<uint32_t>::max() || bytes > kMaxParticleMeshBytes) {
            LOG_ERROR("particle mesh of %llu quads is too large", static_cast<unsigned long long>(quads));
            return false;
        }
        item.mesh = MakeParticleMesh(item.kind, thick, static_cast<uint32_t>(std::max<uint64_t>(quads, 1)));
        if (item.kind == ParticleRendererKind::SpriteTrail) {
            constants["g_RenderVar0"] = ShaderValue(std::array<float, 4> {
                render.length, render.maxlength, render.minlength,
                static_cast<float>(build.capacity) - 1.0f });
        }
        if (item.kind == ParticleRendererKind::RopeTrail) {
            const float length = static_cast<float>(item.segments * item.pieces_per_pair);
            constants["g_RenderVar0"] = ShaderValue(std::array<float, 4> {
                static_cast<float>(item.segments), 0.0f, 0.0f,
                EncodeRopeTrailLength(length, render.uvscale) });
        }
        build.renderers.push_back(std::move(item));
    }
    for (const auto& child : file.children) {
        ParticleSystemBuild prepared;
        bool                child_skipped = false;
        // Saturating: a chain of children with huge counts must not wrap round to a small product.
        constexpr uint64_t  kMostInstances = uint64_t { 1 } << 32;
        const uint64_t      share = std::min(kMostInstances, instances * static_cast<uint64_t>(std::max(1, child.maxcount)));
        if (PrepareParticleSystem(context, child.obj, &child, share, prepared, child_skipped)) {
            build.children.push_back(std::move(prepared));
        }
    }
    return true;
}

/// Follows the scene object's bound override fields (R57): each value that a property, a
/// script or a timeline drives is written into the shared override record as it changes.
void FollowParticleOverride(ParseContext& context, const nlohmann::json& entry,
                            const std::shared_ptr<wpscene::ParticleInstanceoverride>& over,
                            const std::string& key) {
    auto* runtime = context.scene->runtime.get();
    if (runtime == nullptr || ! over->enabled) return;
    const auto block = entry.find("instanceoverride");
    if (block == entry.end() || ! block->is_object()) return;
    using Override = wpscene::ParticleInstanceoverride;
    static constexpr std::array<std::pair<const char*, float Override::*>, 7> kNumbers { {
        { "alpha", &Override::alpha }, { "size", &Override::size }, { "lifetime", &Override::lifetime },
        { "speed", &Override::speed }, { "count", &Override::count }, { "rate", &Override::rate },
        { "brightness", &Override::brightness } } };
    for (const auto& [name, field] : kNumbers) {
        const auto setting = block->find(name);
        if (setting == block->end() || ! HasDynamicSetting(*setting)) continue;
        auto value = ResolveFloatSetting(*runtime, *setting, key);
        runtime->RegisterDynamicValueListener(std::move(value), [over, field = field](const DynamicValue& now) {
            const float next = now.getFloat();
            if (std::isfinite(next)) (*over).*field = next;
        });
    }
    const auto lanes_into = [](std::array<float, 3>& out, const DynamicValue& now) {
        const auto lanes = now.getVec3();
        if (lanes.allFinite()) out = { lanes.x(), lanes.y(), lanes.z() };
    };
    if (const auto setting = block->find("color"); setting != block->end() && HasDynamicSetting(*setting)) {
        runtime->RegisterDynamicValueListener(
            ResolveVec3Setting(*runtime, *setting, key),
            [over, lanes_into](const DynamicValue& now) { lanes_into(over->color, now); });
    }
    if (const auto setting = block->find("colorn"); setting != block->end() && HasDynamicSetting(*setting)) {
        runtime->RegisterDynamicValueListener(
            ResolveVec3Setting(*runtime, *setting, key),
            [over, lanes_into](const DynamicValue& now) { lanes_into(over->colorn, now); });
    }
    for (std::size_t index = 0; index < 8; ++index) {
        if (const auto setting = block->find("controlpoint" + std::to_string(index));
            setting != block->end() && HasDynamicSetting(*setting)) {
            runtime->RegisterDynamicValueListener(
                ResolveVec3Setting(*runtime, *setting, key),
                [over, lanes_into, index](const DynamicValue& now) {
                    lanes_into(over->controlpoint[index], now);
                    over->controlpointSet[index] = true;
                });
        }
        if (const auto setting = block->find("controlpointangle" + std::to_string(index));
            setting != block->end() && HasDynamicSetting(*setting)) {
            runtime->RegisterDynamicValueListener(
                ResolveVec3Setting(*runtime, *setting, key),
                [over, lanes_into, index](const DynamicValue& now) {
                    lanes_into(over->controlpointangle[index], now);
                    over->controlpointangleSet[index] = true;
                });
        }
    }
}

/// What the commit of every system of one layer shares.
struct ParticleCommit {
    ParseContext*                                     context { nullptr };
    std::string                                       key;
    std::shared_ptr<wpscene::ParticleInstanceoverride> over;
    std::shared_ptr<SceneNode>                        layer_node;
    std::array<float, 2>                              parallax_depth { 1.0f, 1.0f };
    nlohmann::json                                    entry;
    std::unordered_set<int>                           logged_audio_modes;
};

/// The node that draws one renderer's mesh, with its constants and value data registered.
void AttachParticleMesh(ParticleCommit& commit, const std::shared_ptr<SceneNode>& node,
                        ParticleRendererBuild& renderer, bool perspective, bool is_layer_node) {
    auto& context = *commit.context;
    auto  mesh    = renderer.mesh;
    mesh->AddMaterial(std::move(renderer.material));
    node->AddMesh(mesh);
    if (perspective && context.is_ortho) node->SetCamera("global_perspective");
    const auto material = mesh->MaterialSlotPtr(0);
    RegisterDrivenMaterialConstants(context, material, renderer.authored, renderer.loaded.info, commit.key);
    RegisterLayerVideos(context, commit.key, material->textures);
    if (context.shader_updater != nullptr) {
        WPShaderValueData data;
        data.parallaxDepth  = commit.parallax_depth;
        data.renderTargets  = renderer.loaded.render_targets;
        if (! is_layer_node) data.parallax_layer = commit.layer_node.get();
        context.shader_updater->SetNodeData(node.get(), 0, data);
    }
}

/// The animation value a sprite shows (R102), written for every particle of a renderer.
ParticleRawGenSpecOp MakeParticleSpecOp(const wpscene::Particle& file) {
    const float multiplier = std::isfinite(file.sequencemultiplier) ? file.sequencemultiplier : 1.0f;
    if (file.animationmode == "randomframe") {
        return [](const Particle& particle, const ParticleRawGenSpec& spec) { *spec.lifetime = particle.seed; };
    }
    return [multiplier](const Particle& particle, const ParticleRawGenSpec& spec) {
        *spec.lifetime = static_cast<float>(ParticleModify::LifetimePos(particle)) * multiplier;
    };
}

/// Builds the subsystem of one prepared system, its mirrors and its children, hung from `node`.
std::unique_ptr<ParticleSubSystem> CommitParticleSystem(
    ParticleCommit& commit, ParticleSystemBuild& build, const std::shared_ptr<SceneNode>& node,
    bool world_space, ParticleSubSystem::SpawnType type, std::vector<ParticleSubSystem*>& statics) {
    auto&       context = *commit.context;
    auto&       scene   = *context.scene;
    const auto& file    = *build.file;
    const bool  perspective = file.flags[wpscene::Particle::FlagEnum::perspective];
    const uint32_t entry_instances = build.entry != nullptr ? static_cast<uint32_t>(std::max(1, build.entry->maxcount)) : 1u;
    const double probability = build.entry != nullptr ? std::clamp<double>(build.entry->probability, 0.0, 1.0) : 1.0;

    std::shared_ptr<SceneMesh> first_mesh = build.renderers.empty() ? nullptr : build.renderers.front().mesh;
    auto sub = std::make_unique<ParticleSubSystem>(*scene.paritileSys, first_mesh, build.capacity, 1.0,
                                                   entry_instances, probability, type,
                                                   MakeParticleSpecOp(file));
    sub->SetOwnerNode(node);
    sub->SetWorldSpace(world_space);
    sub->SetDrawn(! build.renderers.empty());
    sub->SetStartTime(file.starttime);
    const auto over = commit.over;
    sub->SetRateMultiplier([over]() { return over->enabled ? static_cast<double>(over->rate) : 1.0; });
    sub->SetControlpointSource([over](std::span<ParticleControlpoint> points) {
        ApplyParticleOverrideControlpoints(*over, points);
    });

    // Control points: the file's entries by id (or by position), zero for the rest (R75).
    auto points = sub->Controlpoints();
    for (std::size_t at = 0; at < file.controlpoints.size() && at < 8; ++at) {
        const auto& entry = file.controlpoints[at];
        const std::size_t index = entry.id >= 0 && entry.id < 8 ? static_cast<std::size_t>(entry.id) : at;
        auto& point = points[index];
        point.link_mouse  = entry.flags[wpscene::ParticleControlpoint::FlagEnum::link_mouse];
        point.worldspace  = entry.flags[wpscene::ParticleControlpoint::FlagEnum::worldspace];
        point.base_offset = linalg::Vector3d(entry.offset[0], entry.offset[1], entry.offset[2]);
        point.offset      = point.base_offset;
        point.prev_offset = point.base_offset;
    }
    ApplyParticleOverrideControlpoints(*over, points);

    // Emitters, initializers and operators (R3, R31, R32, R50).
    const std::function<audio::AudioSpectrumSnapshot()> spectrum = [scene_pointer = &scene]() {
        return scene_pointer->runtime != nullptr ? scene_pointer->runtime->CurrentAudioSpectrumSnapshot()
                                                 : audio::AudioSpectrumSnapshot {};
    };
    const int start = build.entry != nullptr ? build.entry->controlpointstartindex : 0;
    for (auto emitter : file.emitters) {
        if (build.entry != nullptr) {
            const int shifted = emitter.controlpoint + start;
            emitter.controlpoint = shifted > 7 ? -1 : shifted;
        }
        if (emitter.audioprocessingmode >= 1 && emitter.audioprocessingmode <= 3) {
            MarkSceneRequiresAudioResponse(&scene);
        } else if (emitter.audioprocessingmode != 0 &&
                   commit.logged_audio_modes.insert(static_cast<int>(emitter.audioprocessingmode)).second) {
            LOG_INFO("emitter audio processing mode %u is not supported and is ignored",
                     emitter.audioprocessingmode);
        }
        sub->AddEmitter(WPParticleParser::genParticleEmittOp(emitter, build.has_plain_rope, over, spectrum,
                                                             sub->SpawnContext()));
    }
    const auto parse_context =
        MakeParticleParseContext(*sub, file, over, &scene, context.pixel_canvas, context.tint_after_retint);
    for (const auto& initializer : file.initializers) {
        if (initializer.is_object()) sub->AddInitializer(WPParticleParser::genParticleInitOp(initializer, parse_context));
    }
    sub->AddInitializer(WPParticleParser::genOverrideInitOp(over, parse_context.color,
                                                            parse_context.speed_override,
                                                            parse_context.size_override,
                                                            parse_context.tint_after_retint));
    for (const auto& op : file.operators) {
        if (! op.is_object()) continue;
        sub->AddOperator(WPParticleParser::genParticleOperatorOp(op, parse_context));
        const auto name = op.find("name");
        if (name != op.end() && name->is_string()) {
            if (name->get_ref<const std::string&>() == "movement") sub->SetNeedsWorldAxes(true);
            if (name->get_ref<const std::string&>() == "controlpointattract") {
                sub->SetTracksPreviousPosition(true);
            }
        }
    }

    // Renderers: the first draws the simulated system, the others mirror it (R112).
    for (std::size_t index = 0; index < build.renderers.size(); ++index) {
        auto& renderer = build.renderers[index];
        const auto& render = renderer.render;
        ParticleSubSystem* target = sub.get();
        std::unique_ptr<ParticleSubSystem> mirror;
        std::shared_ptr<SceneNode> drawn = node;
        if (index > 0) {
            drawn = std::make_shared<SceneNode>();
            node->AppendChild(drawn);
            mirror = std::make_unique<ParticleSubSystem>(*scene.paritileSys, renderer.mesh, build.capacity, 1.0,
                                                         1, 1.0, ParticleSubSystem::SpawnType::STATIC,
                                                         MakeParticleSpecOp(file));
            mirror->SetOwnerNode(drawn);
            mirror->SetWorldSpace(world_space);
            target = mirror.get();
        }
        if (IsRopeKind(renderer.kind)) {
            target->SetRopeSubdivision(renderer.pieces_per_pair);
            target->SetRopeUv(render.uvscale, render.uvscrolling, render.uvsmoothing && ! render.uvscrolling);
        }
        if (index == 0 && renderer.kind == ParticleRendererKind::RopeTrail && render.length > 0.0f) {
            ParticleTrailConfig trail;
            trail.samples = renderer.segments;
            trail.period  = std::max(0.001, static_cast<double>(render.length)) / renderer.segments;
            sub->SetTrail(trail);
        }
        // A bound `uvscale`, `uvscrolling` or `uvsmoothing` follows its value (R57).
        if (auto* runtime = scene.runtime.get(); runtime != nullptr && IsRopeKind(renderer.kind)) {
            auto uv = std::make_shared<std::array<float, 3>>(std::array<float, 3> {
                render.uvscale, render.uvscrolling ? 1.0f : 0.0f, render.uvsmoothing ? 1.0f : 0.0f });
            const auto apply = [target, uv]() {
                target->SetRopeUv((*uv)[0], (*uv)[1] != 0.0f, (*uv)[2] != 0.0f && (*uv)[1] == 0.0f);
            };
            const std::array<std::pair<const nlohmann::json*, std::size_t>, 3> settings { {
                { &render.uvscale_setting, 0 }, { &render.uvscrolling_setting, 1 },
                { &render.uvsmoothing_setting, 2 } } };
            for (const auto& [setting, lane] : settings) {
                if (! HasDynamicSetting(*setting)) continue;
                runtime->RegisterDynamicValueListener(
                    ResolveFloatSetting(*runtime, *setting, commit.key),
                    [uv, lane = lane, apply](const DynamicValue& now) {
                        (*uv)[lane] = now.getFloat();
                        apply();
                    });
            }
        }
        AttachParticleMesh(commit, drawn, renderer, perspective, drawn == commit.layer_node);
        if (mirror != nullptr) sub->AddMirror(std::move(mirror));
    }

    // Children hang under this system's node with the entry's own transform (R82, R97).
    for (auto& child : build.children) {
        const auto& entry = *child.entry;
        const auto  child_type = entry.type == "eventfollow" ? ParticleSubSystem::SpawnType::EVENT_FOLLOW
                                 : entry.type == "eventspawn" ? ParticleSubSystem::SpawnType::EVENT_SPAWN
                                 : entry.type == "eventdeath" ? ParticleSubSystem::SpawnType::EVENT_DEATH
                                                              : ParticleSubSystem::SpawnType::STATIC;
        const bool is_static = child_type == ParticleSubSystem::SpawnType::STATIC;
        const bool own_world = child.file->flags[wpscene::Particle::FlagEnum::wordspace];
        const bool child_world = is_static ? own_world : world_space;
        const bool keeps_units = world_space || (is_static && own_world);
        auto child_node = std::make_shared<SceneNode>(Vector3f(entry.origin.data()), Vector3f(entry.scale.data()),
                                                      Vector3f(entry.angles.data()));
        node->AppendChild(child_node);
        if (keeps_units) {
            // The authored offset stays in scene units under a scaled layer: the node takes it
            // divided by the scale it will be drawn under, once the layer sits in its tree.
            const Vector3f authored(entry.origin.data());
            std::weak_ptr<SceneNode> weak_parent = node;
            std::weak_ptr<SceneNode> weak_child  = child_node;
            context.after_attach.push_back([authored, weak_parent, weak_child]() {
                const auto parent = weak_parent.lock();
                const auto child  = weak_child.lock();
                if (parent == nullptr || child == nullptr) return;
                parent->UpdateTrans();
                const Matrix4d model = parent->ModelTrans();
                Vector3f       translate = authored;
                for (int axis = 0; axis < 3; ++axis) {
                    const double length = model.block<3, 1>(0, axis).norm();
                    if (length > 1e-12) translate[axis] = static_cast<float>(authored[axis] / length);
                }
                child->SetTranslate(translate);
            });
        }
        auto child_sub = CommitParticleSystem(commit, child, child_node, child_world, child_type, statics);
        if (is_static) statics.push_back(child_sub.get());
        sub->AddChild(std::move(child_sub));
    }
    return sub;
}

/// Loads one particle layer (P4 R1 to R10, R31 to R34, R57, R75 to R78, R121; R37, R49, R87).
bool LoadParticleEntry(ParseContext& context, std::size_t at, const nlohmann::json& entry,
                       const EntryPlan& plan) {
    auto& scene = *context.scene;
    wpscene::WPParticleObject object;
    if (! object.FromJson(entry, *context.vfs)) return false;

    ParticleSystemBuild build;
    bool                skipped = false;
    if (! PrepareParticleSystem(context, object.particleObj, nullptr, 1, build, skipped)) {
        return skipped;
    }

    // Everything that can fail has: from here the layer is registered.
    auto over = std::make_shared<wpscene::ParticleInstanceoverride>(object.instanceoverride);
    over->hdr = scene.hdr;
    auto& layer = TypedLayer(context, at, entry, plan);
    SetUnhittable(context, plan.key);
    ParticleCommit commit;
    commit.context        = &context;
    commit.key            = plan.key;
    commit.over           = over;
    commit.layer_node     = layer.node;
    commit.parallax_depth = object.parallaxDepth;
    FollowParticleOverride(context, entry, over, plan.key);

    std::vector<ParticleSubSystem*> statics;
    const bool world = object.particleObj.flags[wpscene::Particle::FlagEnum::wordspace];
    auto sub = CommitParticleSystem(commit, build, layer.node, world,
                                    ParticleSubSystem::SpawnType::STATIC, statics);
    // Pre-simulation waits for the finished tree, children before their parent (R91).
    for (auto* child : statics) context.pending_prewarms.push_back(child);
    context.pending_prewarms.push_back(sub.get());
    scene.paritileSys->subsystems.push_back(std::move(sub));
    return true;
}

// ---------------------------------------------------------------------------
// Shapes (P2 R87) and the bloom post-process (R105 to R109, R114).
// ---------------------------------------------------------------------------

/// A shape object: a quad drawn through its last effect straight onto the scene,
/// additively, with that effect's `DIRECTDRAW` combo forced on.
void LoadShapeEntry(ParseContext& context, ParsedLayer& layer, const nlohmann::json& entry,
                    const EntryPlan& plan) {
    if (StaticallyHidden(entry)) return;
    wpscene::WPShapeObject shape;
    if (! shape.FromJson(entry, *context.vfs)) return;
    ResolveUserEffectVisibility(context, shape.effects, plan.key);
    const wpscene::WPImageEffect* last = nullptr;
    for (const auto& effect : shape.effects) {
        if (EffectIsBuilt(effect) && ! effect.materials.empty()) last = &effect;
    }
    if (last == nullptr || last->materials.size() != 1) return;

    auto material = last->materials.front();
    if (! last->passes.empty()) material.MergePass(last->passes.front());
    material.combos["DIRECTDRAW"] = 1;
    SceneMaterial  scene_material;
    LoadedMaterial loaded;
    if (! LoadMaterial(context, material, scene_material, loaded)) return;
    scene_material.blenmode = BlendMode::Additive;

    const float side = static_cast<float>(std::max(1, context.ortho_h));
    std::array<float, 12> positions {};
    std::array<float, 8>  uvs {};
    // Zigzag order: left-bottom, left-top, right-bottom, right-top.
    std::array<std::array<float, 2>, 4> corners { { { 0.0f, 1.0f }, { 0.0f, 0.0f }, { 1.0f, 1.0f }, { 1.0f, 0.0f } } };
    if (const auto points = ShapeCornerPoints(shape); points.has_value()) {
        const std::array<std::size_t, 4> order { 0, 3, 1, 2 };
        for (std::size_t corner = 0; corner < 4; ++corner) {
            const auto& point = (*points)[order[corner]];
            corners[corner]   = { point.x(), point.y() };
        }
    }
    for (std::size_t corner = 0; corner < 4; ++corner) {
        positions[corner * 3]     = side * corners[corner][0] - side * 0.5f;
        positions[corner * 3 + 1] = side * (1.0f - corners[corner][1]) - side * 0.5f;
        uvs[corner * 2]           = corners[corner][0];
        uvs[corner * 2 + 1]       = corners[corner][1];
    }
    auto mesh = MakeQuadMesh(positions, uvs);
    mesh->AddMaterial(std::move(scene_material));
    layer.node->AddMesh(mesh);
    RegisterDrivenMaterialConstants(context, mesh->MaterialSlotPtr(0), material, loaded.info, plan.key);
    if (context.shader_updater != nullptr) {
        WPShaderValueData data;
        data.renderTargets = loaded.render_targets;
        context.shader_updater->SetNodeData(layer.node.get(), 0, data);
    }
}

/// Steps that take back what a build has done so far; run newest first.
using UndoList = std::vector<std::function<void()>>;

void RunUndo(UndoList& undo) {
    while (! undo.empty()) {
        auto step = std::move(undo.back());
        undo.pop_back();
        step();
    }
}

/// Adds (or replaces) a scene render target and notes in `undo` how to give it back:
/// the target that held the name before returns, or the name goes away (R105).
void PutSceneRenderTarget(Scene& scene, UndoList& undo, const std::string& name,
                          SceneRenderTarget target) {
    auto& table = scene.renderTargets;
    if (const auto held = table.find(name); held != table.end()) {
        undo.push_back([&table, name, previous = held->second]() { table[name] = previous; });
    } else {
        undo.push_back([&table, name]() { table.erase(name); });
    }
    table[name] = std::move(target);
}

/// A screen-following bloom target of `fraction` of the colour buffer.
SceneRenderTarget BloomTarget(const Scene& scene, double fraction) {
    const auto* frame = scene.FindRenderTarget(std::string(SpecTex_Default));
    const i32   w     = frame != nullptr ? frame->width : 1;
    const i32   h     = frame != nullptr ? frame->height : 1;
    SceneRenderTarget target;
    target.width      = std::max(1, static_cast<i32>(std::floor(w * fraction)));
    target.height     = std::max(1, static_cast<i32>(std::floor(h * fraction)));
    target.allowReuse = true;
    target.format     = scene.hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8;
    target.bind       = { .enable = true, .screen = true, .scale = fraction };
    return target;
}

/// One pass of the chain: a shipped utility material read from the asset tree, its
/// first textures set by the chain, drawn through the effect camera on the 2 by 2 card.
std::optional<ScenePostProcessPass> BuildBloomPass(
    ParseContext& context, const std::string& material_name, std::vector<std::string> textures,
    std::string output, float source_texel_radius,
    const std::vector<std::pair<std::string, ShaderValue>>& constants,
    std::shared_ptr<SceneMaterial>*                          out_material = nullptr) {
    nlohmann::json json;
    wpscene::WPMaterial material;
    if (! PARSE_JSON(fs::GetFileContent(*context.vfs, "/assets/materials/util/" + material_name + ".json"),
                     json) ||
        ! material.FromJson(json)) {
        LOG_ERROR("cannot load bloom material %s", material_name.c_str());
        return std::nullopt;
    }
    material.textures = std::move(textures);
    SceneMaterial  scene_material;
    LoadedMaterial loaded;
    if (! LoadMaterial(context, material, scene_material, loaded)) {
        LOG_ERROR("cannot load bloom material %s", material_name.c_str());
        return std::nullopt;
    }
    for (const auto& [name, value] : constants) scene_material.customShader.constValues[name] = value;
    auto mesh = MakeCardMesh(2.0f, 2.0f, 1.0f, 1.0f);
    const auto shader_name = material.shader;
    mesh->AddMaterial(std::move(scene_material));
    auto node = std::make_shared<SceneNode>();
    node->SetName("__bloom_" + shader_name);
    node->AddMesh(mesh);
    node->SetCamera("effect");
    if (context.shader_updater != nullptr) {
        WPShaderValueData data;
        data.renderTargets = loaded.render_targets;
        context.shader_updater->SetNodeData(node.get(), 0, data);
    }
    if (out_material != nullptr) *out_material = mesh->MaterialSlotPtr(0);
    return ScenePostProcessPass { .node = node, .output = std::move(output),
                                  .source_texel_radius = source_texel_radius };
}

ShaderValue Vec4Value(const std::array<float, 4>& lanes) { return ShaderValue(lanes.data(), 4); }

/// The LDR chain (R107): extract, vertical down-sample, horizontal blur, combine.
bool BuildLdrBloom(ParseContext& context, const wpscene::WPSceneGeneral& general,
                   ScenePostProcess& post, UndoList& undo) {
    auto& scene = *context.scene;
    PutSceneRenderTarget(scene, undo, "_rt_bloom_mip1", BloomTarget(scene, 0.25));
    PutSceneRenderTarget(scene, undo, "_rt_bloom_mip2", BloomTarget(scene, 0.125));
    PutSceneRenderTarget(scene, undo, "_rt_bloom_blur", BloomTarget(scene, 0.125));
    PutSceneRenderTarget(scene, undo, "_rt_bloom_combine", BloomTarget(scene, 1.0));
    const std::string frame(SpecTex_Default);

    float strength = general.bloomstrength;
    float threshold = general.bloomthreshold;
    std::array<float, 3> tint = general.bloomtint;
    std::shared_ptr<SceneMaterial> extract_material;
    auto extract = BuildBloomPass(
        context, "downsample_quarter_bloom", { frame }, "_rt_bloom_mip1", 0.0f,
        { { "g_BloomStrength", ShaderValue(strength) }, { "g_BloomThreshold", ShaderValue(threshold) },
          { "g_BloomTint", ShaderValue(tint.data(), 3) } },
        &extract_material);
    auto down = BuildBloomPass(context, "downsample_eighth_blur_v", { "_rt_bloom_mip1" },
                               "_rt_bloom_mip2", 0.0f, {});
    auto blur = BuildBloomPass(context, "blur_h_bloom", { "_rt_bloom_mip2" }, "_rt_bloom_blur", 0.0f, {});
    auto combine = BuildBloomPass(context, "combine_ldr", { frame, "_rt_bloom_blur" },
                                  "_rt_bloom_combine", 0.0f, {});
    if (! extract || ! down || ! blur || ! combine) return false;
    post.name = "__bloom";
    post.steps.push_back(std::move(*extract));
    post.steps.push_back(std::move(*down));
    post.steps.push_back(std::move(*blur));
    post.steps.push_back(std::move(*combine));
    post.steps.push_back(ScenePostProcessCopy { .src = "_rt_bloom_combine", .dst = frame });

    if (auto* runtime = scene.runtime.get(); runtime != nullptr && extract_material != nullptr) {
        // Followed through listeners, so a changed property reaches the pass at once.
        const auto follow_float = [&](const nlohmann::json& setting, const char* uniform) {
            if (! HasDynamicSetting(setting)) return;
            runtime->RegisterDynamicValueListener(
                ResolveFloatSetting(*runtime, setting),
                [extract_material, uniform](const DynamicValue& now) {
                    extract_material->customShader.constValues[uniform] = ShaderValue(now.getFloat());
                });
        };
        follow_float(general.bloomstrength_setting, "g_BloomStrength");
        follow_float(general.bloomthreshold_setting, "g_BloomThreshold");
        if (general.dynamic_bloomtint) {
            runtime->RegisterDynamicValueListener(
                ResolveVec3Setting(*runtime, general.bloomtint_setting),
                [extract_material](const DynamicValue& now) {
                    const auto tint = now.getVec3();
                    extract_material->customShader.constValues["g_BloomTint"] =
                        ShaderValue(std::array<float, 3> { tint.x(), tint.y(), tint.z() });
                });
        }
    }
    return true;
}

/// The values the HDR chain's live bindings recompute from (R109).
struct HdrBloomState {
    float strength { 2.0f };
    float scatter { 1.619f };
    float threshold { 1.0f };
    float feather { 0.1f };
    int   levels { 1 };
};

/// The HDR chain (R108). A missing required material is a failure of the whole scene.
bool BuildHdrBloom(ParseContext& context, const wpscene::WPSceneGeneral& general,
                   ScenePostProcess& post, UndoList& undo) {
    auto&       scene = *context.scene;
    const auto  exists = [&](const char* name) {
        return ! fs::GetFileContent(*context.vfs, std::string("/assets/materials/util/") + name + ".json").empty();
    };
    for (const char* required : { "hdr_downsample_bloom", "hdr_downsample", "hdr_upsample",
                                  "combine_hdr_upsample_linear" }) {
        if (! exists(required)) {
            throw std::runtime_error(std::string("HDR bloom needs the material ") + required);
        }
    }
    const std::string cubic = exists("hdr_upsample_cubic") ? "hdr_upsample_cubic" : "hdr_upsample";

    auto state       = std::make_shared<HdrBloomState>();
    state->strength  = general.bloomhdrstrength;
    state->scatter   = general.bloomhdrscatter;
    state->threshold = general.bloomhdrthreshold;
    state->feather   = general.bloomhdrfeather;
    state->levels    = HDRBloomLevels(general.bloomhdriterations, context.ortho_w, context.ortho_h);
    const int levels = state->levels;

    for (int level = 0; level < levels; ++level) {
        PutSceneRenderTarget(scene, undo, "_rt_hdr_bloom_" + std::to_string(level),
                             BloomTarget(scene, 1.0 / static_cast<double>(1 << (level + 1))));
    }
    PutSceneRenderTarget(scene, undo, "_rt_bloom_combine", BloomTarget(scene, 1.0));
    const std::string frame(SpecTex_Default);
    const auto        level_name = [](int level) { return "_rt_hdr_bloom_" + std::to_string(level); };
    const std::pair<std::string, ShaderValue> zero_var { "g_RenderVar0", Vec4Value({ 0, 0, 0, 0 }) };

    std::shared_ptr<SceneMaterial>              extract_material;
    std::vector<std::shared_ptr<SceneMaterial>> up_materials;
    const auto blend = HDRBloomBlend(state->threshold, state->feather);
    auto extract = BuildBloomPass(
        context, "hdr_downsample_bloom", { frame }, level_name(0), 1.0f,
        { zero_var,
          { "g_BloomStrength", ShaderValue(HDRBloomExtractionStrength(state->strength, state->scatter, levels)) },
          { "g_BloomBlendParams", Vec4Value(blend) },
          { "g_BloomTint", ShaderValue(general.bloomtint.data(), 3) } },
        &extract_material);
    if (! extract) return false;
    post.name = "__hdr_bloom";
    post.steps.push_back(std::move(*extract));
    for (int level = 1; level < levels; ++level) {
        auto pass = BuildBloomPass(context, "hdr_downsample", { level_name(level - 1) }, level_name(level),
                                   1.0f, { zero_var });
        if (! pass) return false;
        post.steps.push_back(std::move(*pass));
    }
    for (int level = levels - 1; level >= 1; --level) {
        std::shared_ptr<SceneMaterial> material;
        auto pass = BuildBloomPass(context, level >= levels - 2 ? cubic : "hdr_upsample",
                                   { level_name(level) }, level_name(level - 1), 0.5f,
                                   { zero_var, { "g_BloomScatter", ShaderValue(state->scatter) } }, &material);
        if (! pass) return false;
        up_materials.push_back(material);
        post.steps.push_back(std::move(*pass));
    }
    auto combine = BuildBloomPass(context, "combine_hdr_upsample_linear", { frame, level_name(0) },
                                  "_rt_bloom_combine", 0.0f, {});
    if (! combine) return false;
    post.steps.push_back(std::move(*combine));
    post.steps.push_back(ScenePostProcessCopy { .src = "_rt_bloom_combine", .dst = frame });

    if (auto* runtime = scene.runtime.get(); runtime != nullptr) {
        const auto follow = [&](const nlohmann::json& setting, float HdrBloomState::* field,
                                std::function<void()> apply) {
            if (! HasDynamicSetting(setting)) return;
            auto value = ResolveFloatSetting(*runtime, setting);
            (*state).*field = value->getFloat();
            runtime->RegisterDynamicValueListener(
                std::move(value), [state, field, apply](const DynamicValue& now) {
                    (*state).*field = now.getFloat();
                    apply();
                });
        };
        const auto apply_strength = [state, extract_material]() {
            if (extract_material == nullptr) return;
            extract_material->customShader.constValues["g_BloomStrength"] = ShaderValue(
                HDRBloomExtractionStrength(state->strength, state->scatter, state->levels));
        };
        const auto apply_scatter = [state, up_materials, apply_strength]() {
            for (const auto& material : up_materials) {
                if (material != nullptr) {
                    material->customShader.constValues["g_BloomScatter"] = ShaderValue(state->scatter);
                }
            }
            apply_strength();
        };
        const auto apply_blend = [state, extract_material]() {
            if (extract_material == nullptr) return;
            extract_material->customShader.constValues["g_BloomBlendParams"] =
                Vec4Value(HDRBloomBlend(state->threshold, state->feather));
        };
        follow(general.bloomhdrstrength_setting, &HdrBloomState::strength, apply_strength);
        follow(general.bloomhdrscatter_setting, &HdrBloomState::scatter, apply_scatter);
        follow(general.bloomhdrthreshold_setting, &HdrBloomState::threshold, apply_blend);
        follow(general.bloomhdrfeather_setting, &HdrBloomState::feather, apply_blend);
        if (general.dynamic_bloomtint && extract_material != nullptr) {
            runtime->RegisterDynamicValueListener(
                ResolveVec3Setting(*runtime, general.bloomtint_setting),
                [extract_material](const DynamicValue& now) {
                    const auto tint = now.getVec3();
                    extract_material->customShader.constValues["g_BloomTint"] =
                        ShaderValue(std::array<float, 3> { tint.x(), tint.y(), tint.z() });
                });
        }
        apply_scatter();
        apply_blend();
    }
    return true;
}

/// Installs the bloom chain the scene's settings ask for (R105).
void BuildBloom(ParseContext& context, const wpscene::WPSceneGeneral& general, bool bloom) {
    if (! bloom) return;
    auto post = std::make_shared<ScenePostProcess>();
    UndoList undo;
    bool     built = false;
    try {
        built = context.scene->hdr ? BuildHdrBloom(context, general, *post, undo)
                                   : BuildLdrBloom(context, general, *post, undo);
    } catch (...) {
        RunUndo(undo);
        throw;
    }
    if (built) context.scene->post_processes.push_back(std::move(post));
    else RunUndo(undo);
}

/// A light: a member of the tree with no picture of its own. Its colour, radius,
/// exponent and intensity follow their bindings; its cones and control point are
/// fixed at load (R100 to R102).
bool LoadLightEntry(ParseContext& context, std::size_t at, const nlohmann::json& entry,
                    const EntryPlan& plan) {
    wpscene::WPLightObject light;
    if (! light.FromJson(entry, *context.vfs)) return false;
    auto* runtime_ptr = context.scene->runtime.get();
    auto& layer       = AddLayer(context, at, entry, plan, true, true);
    SetUnhittable(context, plan.key);

    auto source = std::make_unique<SceneLight>(ParseSceneLightType(light.light),
                                               Vector3f(light.color.data()), light.radius,
                                               light.intensity);
    source->setExponent(light.exponent);
    source->setCones(light.innercone, light.outercone);
    source->setControlPoint(Vector3f(light.controlpoint.data()));
    source->setNode(layer.node);
    SceneLight* raw = source.get();
    if (runtime_ptr == nullptr) {
        context.scene->lights.push_back(std::move(source));
        return true;
    }
    auto& runtime = *runtime_ptr;

    const auto follow_float = [&](const nlohmann::json& setting, auto apply) {
        if (! HasDynamicSetting(setting)) return;
        auto value = ResolveFloatSetting(runtime, setting, plan.key);
        apply(value->getFloat());
        runtime.RegisterDynamicValueListener(std::move(value), [apply](const DynamicValue& now) {
            apply(now.getFloat());
        });
    };
    follow_float(light.radius_setting, [raw](float value) { raw->setRadius(value); });
    follow_float(light.exponent_setting, [raw](float value) { raw->setExponent(value); });
    if (HasDynamicSetting(light.color_setting)) {
        auto value = ResolveVec3Setting(runtime, light.color_setting, plan.key);
        raw->setColor(value->getVec3());
        runtime.RegisterDynamicValueListener(std::move(value), [raw](const DynamicValue& now) {
            raw->setColor(now.getVec3());
        });
    }
    // An intensity that a property or script drives is live; a timeline on it
    // plays on the clock of its own, when nothing else writes the value.
    if (HasDynamicSetting(light.intensity_setting)) {
        follow_float(light.intensity_setting, [raw](float value) { raw->setIntensity(value); });
    } else if (auto animation = ResolveScalarAnimation(light.intensity_setting);
               animation.has_value()) {
        raw->setIntensityAnimation(runtime.RegisterScalarAnimation(plan.key, std::move(*animation)));
    }
    context.scene->lights.push_back(std::move(source));
    return true;
}

/// A camera object. In a scene projected by its canvas it only frames the canvas
/// (R27, R93); in a perspective scene it is a shot of the camera it names, which
/// the last visible one poses (R26, R89 to R98).
bool LoadCameraEntry(ParseContext& context, std::size_t at, const nlohmann::json& entry,
                     const EntryPlan& plan, const wpscene::WPSceneGeneral& general) {
    wpscene::WPCameraObject camera;
    if (! camera.FromJson(entry, *context.vfs)) return false;
    auto& scene       = *context.scene;
    auto* runtime_ptr = scene.runtime.get();
    const bool canvas = context.is_ortho;
    auto& layer       = AddLayer(context, at, entry, plan, ! canvas, true);
    SetUnhittable(context, plan.key, camera.solid, camera.disablepropagation);

    if (canvas && runtime_ptr == nullptr) {
        // No runtime to re-decide it each tick: the shot frames the canvas as it is
        // authored, when it is visible.
        if (layer.node->EffectiveVisible() && std::isfinite(camera.zoom) && camera.zoom > 0.0f) {
            scene.FrameCanvas(camera.zoom, Vector2f(camera.origin[0], camera.origin[1]));
        }
        return true;
    }
    if (canvas) {
        auto& runtime = *runtime_ptr;
        auto zoom = ResolveFloatSetting(runtime, SettingOrValue(camera.zoom_setting, camera.zoom),
                                        plan.key);
        runtime.RegisterCameraShot(layer.node.get(), std::move(zoom),
                                   ResolveCameraShotTimeline(runtime, camera, plan.key),
                                   camera.dynamic_origin);
        return true;
    }

    // The camera the shot addresses: the scene's own for an empty name or
    // `default`, else one of that name made on first sight.
    auto own = scene.cameras.at("global_perspective");
    std::shared_ptr<SceneCamera> target = own;
    if (! camera.camera.empty() && camera.camera != "default") {
        auto found = scene.cameras.find(camera.camera);
        if (found == scene.cameras.end()) {
            auto named = std::make_shared<SceneCamera>(*own);
            named->AttatchNode(own->GetAttachedNode());
            // Born with the field of view its first shot resolves to.
            named->SetFov(ResolvePerspectiveFov(general, camera.fov));
            found = scene.cameras.emplace(camera.camera, std::move(named)).first;
        }
        target = found->second;
    }
    target->LockFov(true);

    if (runtime_ptr == nullptr) {
        // The last visible shot poses its camera, and that camera projects the scene.
        if (layer.node->EffectiveVisible()) {
            target->AttatchNode(layer.node);
            target->SetFov(ResolvePerspectiveFov(general, camera.fov));
            target->Update();
            scene.activeCamera = target.get();
        }
        return true;
    }
    auto& runtime = *runtime_ptr;
    CameraPathPlayback path;
    if (! camera.path.empty()) {
        nlohmann::json document;
        if (wpscene::ParseBoundedJson(fs::GetFileContent(*context.vfs, "/assets/" + camera.path),
                                      document)) {
            path = CameraPathPlayback(ParseCameraPaths(document), camera.queuemode);
        }
    }
    runtime.RegisterPerspectiveCameraShot(layer.node, target.get(),
                                          ResolvePerspectiveFov(general, camera.fov),
                                          std::move(path));
    return true;
}

/// Builds the entries in the order the file declares them: the plain node of a
/// group, a shape or a stand-in, and the typed object an entry carries. Layers are
/// registered with the runtime in this order, which is the order scripts count
/// them in.
void BuildLayers(ParseContext& context, const wpscene::WPSceneGeneral& general,
                 const nlohmann::json& objects, const std::vector<EntryPlan>& plans,
                 audio::SoundManager& sm) {
    // Every layer's authored name is on record before the first script compiles.
    if (auto* runtime = context.scene->runtime.get(); runtime != nullptr) {
        for (std::size_t at = 0; at < objects.size(); ++at) {
            if (plans[at].admission == Admission::Skip) continue;
            std::string authored;
            if (const auto name = objects[at].find("name"); name != objects[at].end() && name->is_string()) {
                authored = name->get<std::string>();
            }
            runtime->DeclareLayerName(plans[at].key, std::move(authored));
        }
    }
    for (std::size_t at = 0; at < objects.size(); ++at) {
        const auto& plan  = plans[at];
        const auto& entry = objects[at];
        if (plan.admission == Admission::Skip) continue;
        const bool plain = plan.admission == Admission::Node;
        const bool typed_node = plan.kind == EntryKind::Light || plan.kind == EntryKind::Camera;
        if (plain || (plan.placeholder && ! typed_node)) {
            auto& layer = AddLayer(context, at, entry, plan, plain, true);
            SetUnhittable(context, plan.key);
            if (plan.kind == EntryKind::Shape) LoadShapeEntry(context, layer, entry, plan);
        }
        if (plain) continue;
        bool built = true;
        switch (plan.kind) {
        case EntryKind::Sound: {
            // The sound's layer: a node of the scene like any other, found by name and id.
            AddLayer(context, at, entry, plan, false, true);
            SetUnhittable(context, plan.key);
            built = LoadSoundEntry(context, entry, plan, sm);
            break;
        }
        case EntryKind::Light: built = LoadLightEntry(context, at, entry, plan); break;
        case EntryKind::Image: built = LoadImageEntry(context, at, entry, plan, general); break;
        case EntryKind::Model: built = LoadModelEntry(context, at, entry, plan, general); break;
        case EntryKind::Text: built = LoadTextEntry(context, at, entry, plan); break;
        case EntryKind::Particle: built = LoadParticleEntry(context, at, entry, plan); break;
        case EntryKind::Camera: built = LoadCameraEntry(context, at, entry, plan, general); break;
        default:
            LOG_ERROR("object %d (%s) is not built: its kind is not loaded by this parser yet",
                      plan.id, plan.key.c_str());
            break;
        }
        if (! built) {
            LOG_ERROR("object %d (%s) could not be built", plan.id, plan.key.c_str());
        }
    }
}

/// Layers that name an attachment of their parent puppet hang from that anchor instead of
/// the parent's origin (P5 R60, R61): the first attachment of that name, when its bone exists.
void RegisterPuppetAttachments(ParseContext& context, const std::vector<std::size_t>& parent) {
    constexpr std::size_t kNone = static_cast<std::size_t>(-1);
    if (context.shader_updater == nullptr) return;
    auto& layers = context.layers;
    std::unordered_map<std::size_t, std::vector<WPShaderValueUpdater::PuppetAttachment>> by_parent;
    for (std::size_t at = 0; at < layers.size(); ++at) {
        if (parent[at] == kNone || layers[at].attachment.empty()) continue;
        const auto& holder = layers[parent[at]];
        if (holder.puppet == nullptr) continue;
        const auto& puppet = *holder.puppet;
        const auto  anchor = std::find_if(puppet.attachments.begin(), puppet.attachments.end(),
                                          [&](const WPPuppet::Attachment& candidate) {
                                              return candidate.name == layers[at].attachment;
                                          });
        if (anchor == puppet.attachments.end() || anchor->bone_index >= puppet.bones.size()) continue;
        by_parent[parent[at]].push_back(WPShaderValueUpdater::PuppetAttachment {
            .node           = layers[at].node.get(),
            .bone_index     = anchor->bone_index,
            .bind_transform = puppet.bones[anchor->bone_index].world_bind * anchor->local_xform });
    }
    for (auto& [holder, attachments] : by_parent) {
        context.shader_updater->RegisterPuppetAttachments(layers[holder].puppet_layer,
                                                          std::move(attachments));
    }
}

/// Hangs every layer under its parent, once all of them exist: roots under the
/// scene's root, children under theirs, both in file order. A parent that is
/// absent, is no member of the tree, appears under more than one entry, is the
/// layer itself or is part of a cycle makes the layer a root.
void AttachLayers(ParseContext& context) {
    auto&             layers = context.layers;
    const std::size_t count  = layers.size();
    std::unordered_map<int32_t, std::size_t> slot_of;
    std::unordered_set<int32_t>              ambiguous;
    for (std::size_t at = 0; at < count; ++at) {
        if (layers[at].id == 0) continue;
        if (! slot_of.emplace(layers[at].id, at).second) ambiguous.insert(layers[at].id);
    }
    constexpr std::size_t    kNone = static_cast<std::size_t>(-1);
    std::vector<std::size_t> parent(count, kNone);
    for (std::size_t at = 0; at < count; ++at) {
        const int32_t wanted = layers[at].parent_id;
        if (wanted == 0 || wanted == layers[at].id || ambiguous.contains(wanted)) continue;
        const auto found = slot_of.find(wanted);
        if (found != slot_of.end()) parent[at] = found->second;
    }
    // Cycles, found without recursion: walk each unvisited chain, and when it runs
    // into a link of its own walk, every member of that loop becomes a root.
    std::vector<uint8_t> state(count, 0); // 0 new, 1 on the current walk, 2 settled
    for (std::size_t start = 0; start < count; ++start) {
        if (state[start] != 0) continue;
        std::vector<std::size_t> walk;
        std::size_t              at = start;
        while (at != kNone && state[at] == 0) {
            state[at] = 1;
            walk.push_back(at);
            at = parent[at];
        }
        if (at != kNone && state[at] == 1) {
            const auto loop = std::find(walk.begin(), walk.end(), at);
            for (auto member = loop; member != walk.end(); ++member) parent[*member] = kNone;
        }
        for (const auto member : walk) state[member] = 2;
    }
    for (std::size_t at = 0; at < count; ++at) {
        auto& holder = parent[at] == kNone ? context.scene->sceneGraph : layers[parent[at]].node;
        holder->AppendChild(layers[at].node);
    }
    RegisterPuppetAttachments(context, parent);
}

// ---------------------------------------------------------------------------
// Typed objects: sounds are the only kind this stage builds.
// ---------------------------------------------------------------------------

bool LoadSoundEntry(ParseContext& context, const nlohmann::json& entry, const EntryPlan& plan,
                    audio::SoundManager& sm) {
    wpscene::WPSoundObject sound;
    if (! sound.FromJson(entry, *context.vfs)) {
        LOG_ERROR("sound object has no list of sounds");
        return false;
    }
    WPSoundParser::Parse(sound, *context.vfs, sm, context.scene->runtime.get(), plan.key);
    return true;
}

// ---------------------------------------------------------------------------
// Scene settings and cameras (R12 to R30, R79 to R88, R111, R113).
// ---------------------------------------------------------------------------

void SetGlobalUniform(ParseContext& context, const char* name, std::initializer_list<float> lanes) {
    const std::vector<float> values(lanes);
    context.global_base_uniforms[name] = ShaderValue(values.data(), values.size());
}

/// floor(extent / divisor), at least 1.
int32_t FractionOf(int32_t extent, int32_t divisor) { return std::max(1, extent / divisor); }

/// A camera at `translate` under the scene's root, with its own node.
std::shared_ptr<SceneNode> AddCameraNode(ParseContext& context, SceneCamera& camera,
                                         const Vector3f& translate) {
    auto node = std::make_shared<SceneNode>(translate, Vector3f(1.0f, 1.0f, 1.0f),
                                            Vector3f(0.0f, 0.0f, 0.0f));
    context.scene->sceneGraph->AppendChild(node);
    camera.AttatchNode(node);
    return node;
}

/// The cameras of the scene and the targets every scene has (R111, R113).
void BuildCamerasAndTargets(ParseContext& context, const wpscene::WPScene& wp, double zoom) {
    auto&       scene   = *context.scene;
    const auto& general = wp.general;
    const i32   width   = context.ortho_w;
    const i32   height  = context.ortho_h;
    const Vector3f centre(static_cast<float>(width) * 0.5f, static_cast<float>(height) * 0.5f, 0.0f);

    // Targets first: every parse registers them before any object is built.
    // The colour buffer is the view the scene starts with: the canvas over the starting zoom.
    const i32  frame_w = ZoomedExtent(width, zoom);
    const i32  frame_h = ZoomedExtent(height, zoom);
    const auto format  = scene.hdr ? TextureFormat::RGBA16F : TextureFormat::RGBA8;
    auto&      targets = scene.renderTargets;
    targets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width           = frame_w,
        .height          = frame_h,
        .authored_width  = frame_w,
        .authored_height = frame_h,
        .bind            = { .enable = true, .screen = true },
        .format          = format,
    };
    uint32_t mip_levels = 1;
    for (i32 side = std::max(frame_w, frame_h); side > 1; side /= 2) ++mip_levels;
    targets[std::string(WE_MIP_MAPPED_FRAME_BUFFER)] = SceneRenderTarget {
        .width        = frame_w,
        .height       = frame_h,
        .has_mipmap   = true,
        .mipmap_level = mip_levels,
        .bind         = { .enable = true, .name = std::string(SpecTex_Default) },
        .format       = format,
    };
    targets["_rt_shadowAtlas"] =
        SceneRenderTarget { .width = frame_w, .height = frame_h, .allowReuse = true };
    scene.renderTargetAliases["_alias_lightCookie"] = "_rt_shadowAtlas";
    for (const auto& [name, divisor] :
         { std::pair<const char*, i32> { "_rt_4FrameBuffer", 4 }, { "_rt_8FrameBuffer", 8 },
           { "_rt_Bloom", 8 } }) {
        targets[name] = SceneRenderTarget { .width      = FractionOf(frame_w, divisor),
                                            .height     = FractionOf(frame_h, divisor),
                                            .allowReuse = true,
                                            .format     = format };
    }

    // The screen space of effect passes: 2 by 2 units, depth -1 to 1.
    auto effect = std::make_shared<SceneCamera>(2, 2, -1.0f, 1.0f);
    context.effect_camera_node = AddCameraNode(context, *effect, Vector3f::Zero());
    effect->Update();
    scene.cameras["effect"] = effect;

    // The framed canvas view: the canvas over the starting zoom.
    auto global = std::make_shared<SceneCamera>(ZoomedExtent(width, zoom),
                                                ZoomedExtent(height, zoom), -5000.0f, 5000.0f);
    context.global_camera_node = AddCameraNode(context, *global, centre);
    global->Update();
    scene.cameras["global"] = global;

    // The camera of fullscreen layers: the authored canvas, never the zoomed view.
    auto fullscreen = std::make_shared<SceneCamera>(std::max(1, width), std::max(1, height),
                                                    -5000.0f, 5000.0f);
    AddCameraNode(context, *fullscreen, centre);
    fullscreen->Update();
    scene.cameras[std::string(FullscreenLayerCamera)] = fullscreen;

    std::shared_ptr<SceneCamera> perspective;
    if (context.is_ortho) {
        // The lens perspective layers of a canvas scene look through.
        perspective = std::make_shared<SceneCamera>(static_cast<float>(global->Aspect()), 5.0f,
                                                    15000.0f, ResolveCanvasPerspectiveFov(general));
        context.global_perspective_camera_node = AddCameraNode(context, *perspective, centre);
        FitCanvasPerspective(*perspective, *global);
        perspective->Update();
        scene.activeCamera = global.get();
    } else {
        // The scene's own camera, placed by the `camera` block.
        const float far_plane = general.farz + std::max(1.0f, std::abs(general.farz) * 0.001f);
        perspective           = std::make_shared<SceneCamera>(
            static_cast<float>(width) / static_cast<float>(std::max(1, height)), general.nearz,
            far_plane, ResolvePerspectiveFov(general));
        perspective->LockFov(true);
        context.global_perspective_camera_node =
            AddCameraNode(context, *perspective, Vector3f::Zero());
        PlacePerspectiveCameraNode(*context.global_perspective_camera_node, wp.camera);
        perspective->Update();
        scene.activeCamera = perspective.get();
    }
    scene.cameras["global_perspective"] = perspective;
}

/// Every setting of the `general` block that reaches the scene or its runtime
/// (R12 to R19, R59, R64): colours, light budget, fog, camera shake and parallax.
void ApplySceneSettings(ParseContext& context, const wpscene::WPScene& wp) {
    auto&       scene   = *context.scene;
    auto* const runtime_ptr = scene.runtime.get();
    // The scene file's values, with the ambient and skylight colours and the height fog that a
    // user property is bound to replaced by what the property holds as the scene loads. They
    // are uniforms every material shares and nothing in the frame rewrites them: a change to
    // such a property takes a reload (`NoteLoadOnlyProperty`).
    auto general = wp.general;
    if (runtime_ptr != nullptr) {
        auto& runtime = *runtime_ptr;
        ResolveLoadOnlySceneVec3(runtime, general.ambientcolor_setting, general.ambientcolor);
        ResolveLoadOnlySceneVec3(runtime, general.skylightcolor_setting, general.skylightcolor);
        ResolveLoadOnlySceneVec3(runtime, general.fogheightcolor_setting, general.fogheightcolor);
        ResolveLoadOnlySceneSetting(runtime, general.fogheightstart_setting, general.fogheightstart);
        ResolveLoadOnlySceneSetting(runtime, general.fogheightend_setting, general.fogheightend);
        ResolveLoadOnlySceneSetting(runtime, general.fogheightstartdensity_setting,
                                    general.fogheightstartdensity);
        ResolveLoadOnlySceneSetting(runtime, general.fogheightenddensity_setting,
                                    general.fogheightenddensity);
    }

    scene.clearEnabled = general.clearenabled;
    scene.clearColor   = general.clearcolor;
    if (runtime_ptr != nullptr && general.dynamic_clearcolor) {
        runtime_ptr->RegisterSceneClearColor(
            ResolveVec3Setting(*runtime_ptr, general.clearcolor_setting));
    }
    scene.light_config = ParseSceneLightConfig(general.lightconfig);
    scene.fog_distance = general.fogdistance;
    scene.fog_height   = general.fogheight;
    scene.opaque_first = general.transparentsorting && ! context.is_ortho;

    SetGlobalUniform(context, "g_LightAmbientColor",
                     { general.ambientcolor[0], general.ambientcolor[1], general.ambientcolor[2] });
    SetGlobalUniform(context, "g_LightSkylightColor",
                     { general.skylightcolor[0], general.skylightcolor[1], general.skylightcolor[2] });
    SetGlobalUniform(context, "g_FogDistanceColor",
                     { general.fogdistancecolor[0], general.fogdistancecolor[1],
                       general.fogdistancecolor[2] });
    SetGlobalUniform(context, "g_FogDistanceParams",
                     { general.fogdistancestart, general.fogdistanceend - general.fogdistancestart,
                       general.fogdistancestartdensity,
                       general.fogdistanceenddensity - general.fogdistancestartdensity });
    SetGlobalUniform(context, "g_FogHeightColor",
                     { general.fogheightcolor[0], general.fogheightcolor[1],
                       general.fogheightcolor[2] });
    SetGlobalUniform(context, "g_FogHeightParams",
                     { general.fogheightstart, general.fogheightend - general.fogheightstart,
                       general.fogheightstartdensity,
                       general.fogheightenddensity - general.fogheightstartdensity });

    // The shake of the camera: static, or following its properties.
    if (runtime_ptr != nullptr &&
        (general.camerashake || HasDynamicSetting(general.camerashake_setting))) {
        auto& runtime = *runtime_ptr;
        runtime.RegisterCameraShake(
            ResolveBoolSetting(runtime,
                               SettingOrValue(general.camerashake_setting, general.camerashake)),
            ResolveFloatSetting(runtime, SettingOrValue(general.camerashakeamplitude_setting,
                                                        general.camerashakeamplitude)),
            ResolveFloatSetting(runtime, SettingOrValue(general.camerashakespeed_setting,
                                                        general.camerashakespeed)),
            ResolveFloatSetting(runtime, SettingOrValue(general.camerashakeroughness_setting,
                                                        general.camerashakeroughness)));
    }

    // Parallax: the switch, amount and mouse influence are read once; the delay follows.
    WPCameraParallax parallax;
    parallax.enable         = general.cameraparallax;
    parallax.amount         = general.cameraparallaxamount;
    parallax.delay          = general.cameraparallaxdelay;
    parallax.mouseinfluence = general.cameraparallaxmouseinfluence;
    parallax.canvas_scene   = context.is_ortho;
    if (runtime_ptr != nullptr) {
        auto& runtime = *runtime_ptr;
        ResolveLoadOnlySceneSetting(runtime, general.cameraparallax_setting, parallax.enable);
        ResolveLoadOnlySceneSetting(runtime, general.cameraparallaxamount_setting, parallax.amount);
        ResolveLoadOnlySceneSetting(runtime, general.cameraparallaxmouseinfluence_setting,
                                    parallax.mouseinfluence);
        if (HasDynamicSetting(general.cameraparallaxdelay_setting)) {
            auto value     = ResolveFloatSetting(runtime, general.cameraparallaxdelay_setting);
            parallax.delay = value->getFloat();
            auto* updater  = context.shader_updater;
            runtime.RegisterDynamicValueListener(std::move(value), [updater](const DynamicValue& now) {
                auto current  = updater->CameraParallax();
                current.delay = now.getFloat();
                updater->SetCameraParallax(current);
            });
        }
    }
    context.shader_updater->SetCameraParallax(parallax);
}

/// The scene's zoom: where it starts, and what keeps it going. A playable timeline
/// on the zoom plays even when a property is named too, and the property then
/// only supplies the start; otherwise a bound zoom follows its property.
struct SceneZoomPlan {
    double                         start { 1.0 };
    std::unique_ptr<DynamicValue>  bound;
    std::optional<ScalarAnimation> animation;
};

SceneZoomPlan PlanSceneZoom(ParseContext& context, const wpscene::WPSceneGeneral& general) {
    SceneZoomPlan plan;
    plan.start = general.zoom;
    auto* runtime = context.scene->runtime.get();
    if (runtime == nullptr) return plan;
    plan.animation = ResolveScalarAnimation(general.zoom_setting);
    if (HasDynamicSetting(general.zoom_setting)) {
        plan.bound = ResolveFloatSetting(*runtime, general.zoom_setting);
        plan.start = plan.bound->getFloat();
    }
    return plan;
}

/// Hands the zoom to the runtime; the cameras it frames exist by now.
void InstallSceneZoom(ParseContext& context, SceneZoomPlan plan) {
    auto* runtime = context.scene->runtime.get();
    if (runtime == nullptr) return;
    if (plan.animation.has_value()) {
        runtime->RegisterSceneZoomAnimation(
            runtime->RegisterScalarAnimation("", std::move(*plan.animation)));
    } else if (plan.bound != nullptr) {
        runtime->RegisterSceneZoom(std::move(plan.bound));
    }
}

/// The canvas of the scene (R21, R88): the authored size, the largest image layer
/// for an `auto` projection, and the fallback of 1920 by 1080 for the rest.
std::array<int32_t, 2> ResolveCanvas(ParseContext& context, const wpscene::WPSceneGeneral& general,
                                     const nlohmann::json&         objects,
                                     const std::vector<EntryPlan>& plans) {
    if (! general.isOrtho || ! general.orthogonalprojection.auto_) {
        return { general.orthogonalprojection.width, general.orthogonalprojection.height };
    }
    std::array<int32_t, 2> largest { 0, 0 };
    int64_t                best = -1;
    for (std::size_t at = 0; at < objects.size(); ++at) {
        if (plans[at].kind != EntryKind::Image || plans[at].admission != Admission::Object) continue;
        wpscene::WPImageObject image;
        if (! image.FromJson(objects[at], *context.vfs)) continue;
        const auto side = [](float value) {
            return std::isfinite(value) ? static_cast<int32_t>(std::clamp(value, 0.0f, 2.0e9f)) : 0;
        };
        const std::array<int32_t, 2> size { side(image.size[0]), side(image.size[1]) };
        const int64_t                area = static_cast<int64_t>(size[0]) * size[1];
        if (area > best) {
            best    = area;
            largest = size;
        }
    }
    return largest;
}

/// The thread-local state of one parse: nothing from an earlier parse is left in
/// it, and nothing of this one remains once it ends, however it ends.
struct ParseSession {
    ParseSession() {
        g_pending_metal_translations.clear();
        g_shader_failures.clear();
        g_parse_layer_index = nullptr;
        WPShaderParser::BeginShaderSession();
    }
    ~ParseSession() {
        g_pending_metal_translations.clear();
        g_shader_failures.clear();
        g_parse_layer_index = nullptr;
        WPShaderParser::EndShaderSession();
    }
};

std::shared_ptr<Scene> ParseSceneDocument(const SceneParseRequest& request, const std::string& buf,
                                          fs::VFS& vfs, audio::SoundManager& sm) {
    nlohmann::json json;
    if (! wpscene::ParseBoundedJson(buf, json) || ! json.is_object()) {
        LOG_ERROR("the scene file is not a JSON document with an object at its top");
        return nullptr;
    }
    const auto objects_found = json.find("objects");
    if (objects_found == json.end() || ! objects_found->is_array()) {
        LOG_ERROR("the scene file has no list of objects");
        return nullptr;
    }
    auto& objects = *objects_found;
    ParseSession session;

    wpscene::WPScene wp;
    wp.FromJson(json, request.pkg_version);
    const auto& general = wp.general;
    // Parented layers ride the outermost parent's parallax depth.
    ResolveLayerParallax(objects);

    auto scene           = std::make_shared<Scene>();
    scene->scene_id      = request.scene_id;
    scene->project_path  = request.project_path;
    scene->sceneGraph    = std::make_shared<SceneNode>();
    scene->imageParser   = std::make_unique<RuntimeImageSource>(std::make_unique<WPTexImageParser>(&vfs));
    scene->shaderValueUpdater = std::make_unique<WPShaderValueUpdater>(scene.get());
    scene->paritileSys   = std::make_unique<ParticleSystem>(*scene);
    scene->paritileSys->gener = std::make_unique<WPParticleRawGener>();
    scene->resolution    = CurrentSceneResolution();
    // The card every chain pass is drawn on: 2 by 2 units, texture coordinates 0 to 1.
    scene->default_effect_mesh.ChangeMeshDataFrom(*MakeCardMesh(2.0f, 2.0f, 1.0f, 1.0f));
    scene->display_sized = ! general.isOrtho;

    ParseContext context {};
    context.objects        = &objects;
    context.scene          = scene;
    context.vfs            = &vfs;
    context.shader_updater = static_cast<WPShaderValueUpdater*>(scene->shaderValueUpdater.get());
    context.is_ortho       = general.isOrtho;
    context.pixel_canvas   = general.pixelCanvas;
    context.tint_after_retint = wp.version < wpscene::WPScene::kRetintOnlyVersion;

    const LayerObjectIndex index = BuildLayerObjectIndex(objects);
    g_parse_layer_index          = &index;
    // What the files of the image objects sample counts as much as what the objects name.
    const nlohmann::json scanned = WithExternalMaterials(objects, vfs);
    const auto plans             = PlanEntries(context, objects, scanned, index);

    const auto canvas = ResolveCanvas(context, general, objects, plans);
    context.ortho_w   = canvas[0];
    context.ortho_h   = canvas[1];
    scene->ortho[0]   = canvas[0];
    scene->ortho[1]   = canvas[1];
    // The extent layout and the cursor map against: the unzoomed canvas, latched.
    scene->scene_extent[0] = std::max(1, canvas[0]);
    scene->scene_extent[1] = std::max(1, canvas[1]);

    SceneRuntimeBootstrap bootstrap;
    bootstrap.canvas_width  = canvas[0];
    bootstrap.canvas_height = canvas[1];
    if (request.project_properties != nullptr) bootstrap.project_properties = *request.project_properties;
    if (request.authored_project_properties != nullptr) {
        bootstrap.authored_project_properties = *request.authored_project_properties;
    }
    // Without a property table there is nothing to bind to, and no runtime.
    if (request.project_properties != nullptr) {
        scene->runtime = std::make_unique<SceneRuntimeContext>(std::move(bootstrap));
        scene->runtime->AttachScene(scene.get());
    }

    // What decides how the scene is built is read once, as it loads.
    bool bloom = general.bloom;
    if (scene->runtime != nullptr) {
        ResolveLoadOnlySceneSetting(*scene->runtime, general.bloom_setting, bloom);
    }
    scene->hdr = general.hdr && bloom;

    ApplySceneSettings(context, wp);
    auto zoom = PlanSceneZoom(context, general);
    BuildCamerasAndTargets(context, wp, zoom.start);
    InstallSceneZoom(context, std::move(zoom));

    // The layers other layers sample are known before any is built.
    const auto early_refs = CollectLayerTextureRefs(scanned, index, &vfs);
    for (const auto& ref : early_refs) {
        if (ref.source_id != 0) context.referenced_layer_ids.insert(ref.source_id);
    }

    BuildLayers(context, general, objects, plans, sm);
    AttachLayers(context);
    LayOutPassthroughCards(context);
    SyncEffectFinals(context);

    ApplyDefaultDepthTarget(context);
    PrewarmParticleSystems(context);
    BuildBloom(context, general, bloom);

    // Layers that read other layers' pictures, and whether that is legal: the references
    // found before any layer was built (the files they came from do not change).
    for (const auto& ref : early_refs) scene->layer_texture_sources.insert(ref.source_id);
    scene->layer_texture_error = ClassifyLayerTextureReferences(early_refs, index);

    FlushPendingMetalTranslations(*scene);
    scene->shader_compile_error = ShaderFailureReason();

    // The registries a script may query (P3 R72): the declared order of the layers, and the
    // scene file's objects when some script says it reads them.
    if (scene->runtime != nullptr) {
        std::vector<std::string> order;
        order.reserve(context.layers.size());
        for (const auto& layer : context.layers) order.push_back(layer.key);
        scene->runtime->SetLayerOrder(order);
        std::vector<const std::string*> sources;
        CollectScriptSources(objects, sources);
        const bool wanted = std::any_of(sources.begin(), sources.end(), [](const std::string* source) {
            return source->find("getInitialLayerConfig") != std::string::npos;
        });
        if (wanted) {
            scene->runtime->RequestInitialLayerConfig();
            auto kept = std::make_shared<nlohmann::json>(objects);
            scene->runtime->SetInitialLayerConfigProvider([kept](int32_t id) -> std::string {
                for (const auto& entry : *kept) {
                    if (entry.is_object() && EntryId(entry) == id) return entry.dump();
                }
                return {};
            });
        }
    }

    // The hooks scripts build and restyle text with (P3 R73), before any script starts.
    if (scene->runtime != nullptr) {
        fs::VFS* const vfs_pointer = &vfs;
        scene->runtime->SetTextFontResolver(
            [vfs_pointer](TextLayerState& state, const std::string& font_key) {
                ResolveTextFont(*vfs_pointer, state, font_key);
            });
        LazyParseInputs inputs;
        inputs.globals     = context.global_base_uniforms;
        inputs.index       = index;
        inputs.is_ortho    = context.is_ortho;
        inputs.uses_models = context.uses_models;
        inputs.general     = general;
        const std::weak_ptr<Scene> weak = scene;
        scene->runtime->SetLayerTemplateLoader(
            [weak, vfs_pointer, inputs](std::string_view template_path) {
                return LoadLayerTemplate(weak.lock(), vfs_pointer, inputs, template_path);
            });
        scene->runtime->SetTextLayerFactory(
            [weak, vfs_pointer, inputs](const std::string& config, int32_t object_id) {
                return MakeScriptTextLayer(weak.lock(), vfs_pointer, inputs, config, object_id);
            });
    }

    // The scripts bound to transforms are made now that every layer, id and hook exists.
    {
        auto bindings = std::move(context.deferred_bindings);
        for (auto& bind : bindings) bind();
    }

    // Scene scripts start last, once every layer, id and hook they may use exists,
    // in the order the file declares their layers.
    auto scripts = std::move(context.scene_scripts);
    if (scene->runtime != nullptr) {
        for (auto& [source, key] : scripts) {
            scene->runtime->RegisterSceneScript(std::move(source), std::move(key));
        }
    }
    return scene;
}

} // namespace

std::shared_ptr<Scene> WPSceneParser::Parse(const SceneParseRequest& request,
                                            const std::string& buf, fs::VFS& vfs,
                                            audio::SoundManager& sm) {
    return ParseSceneDocument(request, buf, vfs, sm);
}

std::shared_ptr<Scene> WPSceneParser::Parse(std::string_view scene_id, const std::string& buf,
                                            fs::VFS& vfs, audio::SoundManager& sm) {
    SceneParseRequest request;
    request.scene_id = std::string(scene_id);
    return ParseSceneDocument(request, buf, vfs, sm);
}
