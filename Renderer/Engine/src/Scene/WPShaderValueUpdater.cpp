// Clean-room implementation from the WallpaperMachine spec e1a-scene-host.md; written without access to the original source.
#include "WPShaderValueUpdater.hpp"
#include "Utils/Linalg.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "SpriteAnimation.hpp"
#include "SpecTexs.hpp"
#include "Core/ArrayHelper.hpp"
#include "Utils/Algorism.h"
#include "Utils/TimeOfDay.hpp"

#include <iostream>
#include <chrono>
#include <ctime>
#include <numeric>
#include <vector>
#include <span>
#include <algorithm>
#include <cmath>
#include <cstring>

using namespace wallpaper;
using namespace wallpaper::linalg;

namespace
{

constexpr std::string_view G_NORMALMODEL            = "g_NormalModelMatrix";
constexpr std::string_view G_LAYERMODEL             = "g_LayerModelMatrix";
constexpr std::string_view G_DAYTIME_ALIAS          = "g_Daytime";

constexpr std::string_view G_AUDIO16_LEFT  = "g_AudioSpectrum16Left";
constexpr std::string_view G_AUDIO16_RIGHT = "g_AudioSpectrum16Right";
constexpr std::string_view G_AUDIO32_LEFT  = "g_AudioSpectrum32Left";
constexpr std::string_view G_AUDIO32_RIGHT = "g_AudioSpectrum32Right";
constexpr std::string_view G_AUDIO64_LEFT  = "g_AudioSpectrum64Left";
constexpr std::string_view G_AUDIO64_RIGHT = "g_AudioSpectrum64Right";

constexpr std::string_view G_LPOINT_COLOR         = "g_LPoint_Color";
constexpr std::string_view G_LPOINT_ORIGIN        = "g_LPoint_Origin";
constexpr std::string_view G_LSPOT_COLOR          = "g_LSpot_Color";
constexpr std::string_view G_LSPOT_ORIGIN         = "g_LSpot_Origin";
constexpr std::string_view G_LSPOT_DIRECTION      = "g_LSpot_Direction";
constexpr std::string_view G_LSPOT_EXPONENT       = "g_LSpot_Exponent";
constexpr std::string_view G_LTUBE_COLOR          = "g_LTube_Color";
constexpr std::string_view G_LTUBE_ORIGINA        = "g_LTube_OriginA";
constexpr std::string_view G_LTUBE_ORIGINB        = "g_LTube_OriginB";
constexpr std::string_view G_LDIRECTIONAL_COLOR   = "g_LDirectional_Color";
constexpr std::string_view G_LDIRECTIONAL_DIRECTION = "g_LDirectional_Direction";
constexpr std::array       kLightingV1Uniforms {
    G_LPOINT_COLOR,  G_LPOINT_ORIGIN,  G_LSPOT_COLOR,        G_LSPOT_ORIGIN,
    G_LSPOT_DIRECTION, G_LSPOT_EXPONENT, G_LTUBE_COLOR,      G_LTUBE_ORIGINA,
    G_LTUBE_ORIGINB, G_LDIRECTIONAL_COLOR, G_LDIRECTIONAL_DIRECTION,
};

/// One frame's `LightingV1` uniform arrays, four floats per slot, laid out as
/// Wallpaper Engine fills them: each kind's visible lights in scene order, up
/// to the count the scene's light config compiled its shaders for, with unused
/// slots left zero.
struct LightingV1Arrays {
    std::vector<float> point_color, point_origin;
    std::vector<float> spot_color, spot_origin, spot_direction, spot_exponent;
    std::vector<float> tube_color, tube_origin_a, tube_origin_b;
    std::vector<float> directional_color, directional_direction;
};

/// A material that reads the screen behind a layer through its
/// model-view-projection matrix, which `composelayer.vert` turns into the screen
/// coordinate it samples: the first pass of a compose layer.
bool SamplesScreenBackground(const SceneMaterial& material) {
    return material.name == "composelayer";
}

void PutVec4(std::vector<float>& array, std::size_t slot, const Vector3d& xyz, float w) {
    array[slot * 4 + 0] = static_cast<float>(xyz.x());
    array[slot * 4 + 1] = static_cast<float>(xyz.y());
    array[slot * 4 + 2] = static_cast<float>(xyz.z());
    array[slot * 4 + 3] = w;
}

LightingV1Arrays PackLightingV1(const Scene& scene) {
    const auto&      config = scene.light_config;
    LightingV1Arrays arrays;
    for (auto* array : { &arrays.point_color, &arrays.point_origin }) array->assign(config.point * 4, 0.0f);
    for (auto* array : { &arrays.spot_color, &arrays.spot_origin, &arrays.spot_direction,
                         &arrays.spot_exponent })
        array->assign(config.spot * 4, 0.0f);
    for (auto* array : { &arrays.tube_color, &arrays.tube_origin_a, &arrays.tube_origin_b })
        array->assign(config.tube * 4, 0.0f);
    for (auto* array : { &arrays.directional_color, &arrays.directional_direction })
        array->assign(config.directional * 4, 0.0f);

    std::size_t point = 0, spot = 0, tube = 0, directional = 0;
    constexpr double kDegrees = 3.14159265358979323846 / 180.0;
    for (const auto& light : scene.lights) {
        if (light == nullptr || light->node() == nullptr || ! light->visible()) continue;
        auto* node = light->node();
        node->UpdateTrans();
        const Matrix4d  world  = node->ModelTrans();
        const Vector3d  origin = world.block<3, 1>(0, 3);
        // The light's own x axis, scale included, is the way a spot or
        // directional light points.
        const Vector3d  axis   = world.block<3, 1>(0, 0);
        const Vector3d  color  = (light->color() * light->intensity()).cast<double>();
        switch (light->type()) {
        case SceneLightType::Point:
            if (point >= config.point) break;
            PutVec4(arrays.point_color, point, color, light->radius());
            PutVec4(arrays.point_origin, point, origin, light->exponent());
            ++point;
            break;
        case SceneLightType::Spot:
            if (spot >= config.spot) break;
            PutVec4(arrays.spot_color, spot, color, light->radius());
            PutVec4(arrays.spot_origin, spot, origin,
                    static_cast<float>(std::cos(light->innerCone() * kDegrees)));
            PutVec4(arrays.spot_direction, spot, axis,
                    static_cast<float>(std::cos(light->outerCone() * kDegrees)));
            arrays.spot_exponent[spot * 4] = light->exponent();
            ++spot;
            break;
        case SceneLightType::Tube: {
            if (tube >= config.tube) break;
            const Vector4d far_end =
                world * light->controlPoint().cast<double>().homogeneous();
            PutVec4(arrays.tube_color, tube, color, light->radius());
            PutVec4(arrays.tube_origin_a, tube, origin, light->exponent());
            PutVec4(arrays.tube_origin_b, tube, far_end.head<3>(), 0.0f);
            ++tube;
            break;
        }
        case SceneLightType::Directional:
            if (directional >= config.directional) break;
            PutVec4(arrays.directional_color, directional, color, 1.0f);
            // Towards the light: it shines along its own x axis.
            PutVec4(arrays.directional_direction, directional, -axis, 0.0f);
            ++directional;
            break;
        case SceneLightType::Legacy: break;
        }
    }
    return arrays;
}

/// The legacy four-light packing: positions in `g_LightsPosition`, colours
/// premultiplied by intensity and radius squared in three vec4s, the fourth
/// light's channels in their w lanes.
struct LegacyLightArrays {
    std::array<float, 16> positions { 0 };
    std::array<float, 12> colors { 0 };
};

LegacyLightArrays PackLegacyLights(const Scene& scene) {
    LegacyLightArrays arrays;
    std::size_t       count = 0;
    for (const auto& light : scene.lights) {
        if (light == nullptr || light->type() != SceneLightType::Legacy) continue;
        if (light->node() == nullptr || ! light->visible()) continue;
        // Only the first four shine; the rest are left out.
        if (count >= 4) break;
        auto* node = light->node();
        node->UpdateTrans();
        const Matrix4d world = node->ModelTrans();
        for (int axis = 0; axis < 3; ++axis) {
            arrays.positions[count * 4 + static_cast<std::size_t>(axis)] =
                static_cast<float>(world(axis, 3));
        }
        arrays.positions[count * 4 + 3] = 0.0f;
        const Vector3f color = light->premultipliedColor();
        if (count < 3) {
            for (int axis = 0; axis < 3; ++axis) {
                arrays.colors[count * 4 + static_cast<std::size_t>(axis)] = color[axis];
            }
        } else {
            // The fourth light rides in the w lanes of the three colour vectors.
            arrays.colors[3]  = color[0];
            arrays.colors[7]  = color[1];
            arrays.colors[11] = color[2];
        }
        ++count;
    }
    return arrays;
}

/// A shader value from a short list of floats.
ShaderValue Vec(std::initializer_list<float> values) {
    return ShaderValue(values.begin(), values.size());
}

/// The first four lanes of `slot`'s family in a table of 13 names, or null past it.
bool SlotInRange(uint32_t slot) { return slot < 13; }

uint64_t HashFloats(uint64_t hash, const float* values, std::size_t count) {
    const auto* bytes = reinterpret_cast<const unsigned char*>(values);
    for (std::size_t i = 0; i < count * sizeof(float); ++i) {
        hash = (hash ^ bytes[i]) * 0x100000001b3ULL;
    }
    return hash;
}

} // namespace

void WPShaderValueUpdater::FrameBegin() {
    for (auto& group : m_puppetAttachments) UpdatePuppetAttachments(group);
    if (const auto day_time = LocalTimeOfDay(m_wall_clock())) m_dayTime = *day_time;
    // Shaders see the cursor itself; only parallax eases towards it, as in
    // Wallpaper Engine: each frame it closes (1 - delay / 3) * 10 * frametime of
    // the remaining way, clamped to [0, 1], so a delay of zero (authored as
    // `cameraparallaxdelay: 0`) follows the cursor at once.
    m_mousePosLast = m_mousePos;
    m_mousePos     = m_mousePosInput;
    const std::array<float, 2> target { std::clamp(m_mousePosInput[0], 0.0f, 1.0f),
                                        std::clamp(m_mousePosInput[1], 0.0f, 1.0f) };
    double step = 1.0;
    if (m_parallax.delay > 0.0f) {
        const double frame_time = m_scene != nullptr ? m_scene->frameTime : 0.0;
        step = std::clamp((1.0 - m_parallax.delay / 3.0) * 10.0 * frame_time, 0.0, 1.0);
    }
    for (std::size_t axis = 0; axis < 2; ++axis) {
        m_parallaxPos[axis] = static_cast<float>(
            algorism::lerp(step, m_parallaxPos[axis], target[axis]));
    }
}

void WPShaderValueUpdater::FrameEnd() {}

uint64_t WPShaderValueUpdater::LightStateHash(SceneNode* node, uint32_t material_slot) const {
    if (node == nullptr || m_scene == nullptr) return 0;
    const auto slots = m_nodeUniformInfoMap.find(node);
    if (slots == m_nodeUniformInfoMap.end()) return 0;
    auto it = slots->second.find(material_slot);
    if (it == slots->second.end()) it = slots->second.find(0);
    if (it == slots->second.end()) return 0;
    const auto& info = it->second;
    if (! info.has_LP && ! info.has_LCP && ! info.has_LIGHTS_V1) return 0;

    uint64_t hash = 0xcbf29ce484222325ULL;
    if (info.has_LP || info.has_LCP) {
        const auto legacy = PackLegacyLights(*m_scene);
        hash = HashFloats(hash, legacy.positions.data(), legacy.positions.size());
        hash = HashFloats(hash, legacy.colors.data(), legacy.colors.size());
    }
    if (info.has_LIGHTS_V1) {
        const auto lights = PackLightingV1(*m_scene);
        for (const auto* values : {
                 &lights.point_color, &lights.point_origin, &lights.spot_color, &lights.spot_origin,
                 &lights.spot_direction, &lights.spot_exponent, &lights.tube_color,
                 &lights.tube_origin_a, &lights.tube_origin_b, &lights.directional_color,
                 &lights.directional_direction }) {
            hash = HashFloats(hash, values->data(), values->size());
        }
    }
    // Zero is "reads no lights"; a material that does never hashes to it.
    return hash == 0 ? 1 : hash;
}

const WPUniformInfo* WPShaderValueUpdater::FindUniformInfo(const SceneNode* node,
                                                           uint32_t slot) const {
    const auto slots = m_nodeUniformInfoMap.find(const_cast<SceneNode*>(node));
    if (slots == m_nodeUniformInfoMap.end()) return nullptr;
    auto found = slots->second.find(slot);
    if (found == slots->second.end()) found = slots->second.find(0);
    return found == slots->second.end() ? nullptr : &found->second;
}

const WPShaderValueData* WPShaderValueUpdater::FindNodeData(const SceneNode* node,
                                                            uint32_t slot) const {
    const auto slots = m_nodeDataMap.find(const_cast<SceneNode*>(node));
    if (slots == m_nodeDataMap.end()) return nullptr;
    auto found = slots->second.find(slot);
    if (found == slots->second.end()) found = slots->second.find(0);
    return found == slots->second.end() ? nullptr : &found->second;
}

const SceneCamera* WPShaderValueUpdater::CameraNamed(const std::string& name) const {
    if (m_scene == nullptr) return nullptr;
    if (name.empty()) return m_scene->activeCamera;
    const auto found = m_scene->cameras.find(name);
    return found == m_scene->cameras.end() ? nullptr : found->second.get();
}

bool WPShaderValueUpdater::ParallaxMovesDraw(const WPUniformInfo& info, const SceneNode* node,
                                             const std::string& camera_name,
                                             const WPShaderValueData* data, bool compose_first,
                                             std::array<float, 2>* depth) const {
    if (! m_parallax.enable || m_parallax.amount == 0.0f || m_parallax.mouseinfluence == 0.0f) {
        return false;
    }
    if (! (info.has_M || info.has_MVP || info.has_MI || info.has_MVPI)) return false;
    const SceneCamera* camera = CameraNamed(camera_name);
    if (camera == nullptr || camera_name == "effect" || camera->IsLayerLocal()) return false;
    // Without node data nothing says how deep the draw is.
    if (data == nullptr) return false;
    // A compose layer's first pass asks for the depth of the layer, which sits on its effect
    // passes; every other draw moves by the depth of its own record.
    const std::array<float, 2> found = compose_first ? NodeParallaxDepth(node) : data->parallaxDepth;
    if (depth != nullptr) *depth = found;
    return found[0] != 0.0f || found[1] != 0.0f;
}

uint32_t WPShaderValueUpdater::FrameVaryingUniforms(SceneNode* node, uint32_t material_slot,
                                                    const std::string& camera_override) const {
    if (m_scene == nullptr || node == nullptr) return frame_varying_uniform::kAll;
    const WPUniformInfo* info = FindUniformInfo(node, material_slot);
    // No record is no evidence that nothing advances.
    if (info == nullptr) return frame_varying_uniform::kAll;

    uint32_t bits = frame_varying_uniform::kNone;
    if (info->has_TIME || info->has_FRAMETIME) bits |= frame_varying_uniform::kTime;
    if (info->has_DAYTIME || info->has_DAYTIME_ALIAS) bits |= frame_varying_uniform::kDayTime;
    if (info->has_POINTERPOSITION || info->has_POINTERPOSITIONLAST || info->has_POINTERSTATE) {
        bits |= frame_varying_uniform::kPointer;
    }
    if (info->has_PARALLAXPOSITION) bits |= frame_varying_uniform::kParallax;
    if (info->has_BONES) bits |= frame_varying_uniform::kBones;
    if (info->has_AudioSpectrum16Left || info->has_AudioSpectrum16Right ||
        info->has_AudioSpectrum32Left || info->has_AudioSpectrum32Right ||
        info->has_AudioSpectrum64Left || info->has_AudioSpectrum64Right) {
        bits |= frame_varying_uniform::kAudio;
    }
    // Parallax that moves the draw through its model matrix, which no uniform reveals.
    const std::string& camera_name = camera_override.empty() ? node->Camera() : camera_override;
    const SceneMaterial* material =
        node->Mesh() != nullptr ? node->Mesh()->MaterialForSlot(material_slot) : nullptr;
    const bool compose = material != nullptr && SamplesScreenBackground(*material);
    if (ParallaxMovesDraw(*info, node, camera_name, FindNodeData(node, material_slot), compose,
                          nullptr)) {
        bits |= frame_varying_uniform::kParallax;
    }
    return bits;
}

void WPShaderValueUpdater::RegisterPuppetAttachments(
    WPPuppetLayer layer, std::vector<PuppetAttachment> attachments) {
    auto& group = m_puppetAttachments.emplace_back(
        PuppetAttachmentGroup { std::move(layer), std::move(attachments) });
    UpdatePuppetAttachments(group);
}

void WPShaderValueUpdater::UpdatePuppetAttachments(PuppetAttachmentGroup& group) {
    const auto bones = group.layer.genFrame(m_scene != nullptr ? m_scene->elapsingTime : 0.0);
    for (const auto& attachment : group.attachments) {
        if (attachment.node == nullptr || attachment.bone_index >= bones.size()) continue;
        attachment.node->SetAttachmentTransform(
            (bones[attachment.bone_index] * attachment.bind_transform).matrix().cast<double>());
    }
}

void WPShaderValueUpdater::MouseInput(double x, double y) {
    // As given: the clamped copy parallax follows is made when the frame begins.
    m_mousePosInput = { static_cast<float>(x), static_cast<float>(y) };
}

void WPShaderValueUpdater::InitUniforms(SceneNode* pNode, const ExistsUniformOp& existsOp) {
    InitUniforms(pNode, 0, existsOp);
}

void WPShaderValueUpdater::InitUniforms(SceneNode* node, uint32_t material_slot,
                                        const ExistsUniformOp& exists) {
    if (node == nullptr || ! exists) return;
    WPUniformInfo info;
    info.has_M                = exists(G_M);
    info.has_AM               = exists(G_AM);
    info.has_MI               = exists(G_MI);
    info.has_MVP              = exists(G_MVP);
    info.has_MVPI             = exists(G_MVPI);
    info.has_VP               = exists(G_VP);
    info.has_NORMALMODEL      = exists(G_NORMALMODEL);
    info.has_ETVP             = exists(G_ETVP);
    info.has_ETVPI            = exists(G_ETVPI);
    info.has_layer_model      = exists(G_LAYERMODEL);
    info.has_effect_model     = exists(G_EFFECTMODEL);
    info.has_effect_mvp       = exists(G_EFFECTMVP);
    info.has_effect_mvpi      = exists(G_EFFECTMVPI);
    info.has_BONES            = exists(G_BONES);
    info.has_TIME             = exists(G_TIME);
    info.has_FRAMETIME        = exists(G_FRAMETIME);
    info.has_DAYTIME          = exists(G_DAYTIME);
    info.has_DAYTIME_ALIAS    = exists(G_DAYTIME_ALIAS);
    info.has_POINTERPOSITION     = exists(G_POINTERPOSITION);
    info.has_POINTERPOSITIONLAST = exists(G_POINTERPOSITIONLAST);
    info.has_POINTERSTATE        = exists(G_POINTERSTATE);
    info.has_TEXTUREREDUCTIONSCALE = exists(G_TEXTUREREDUCTIONSCALE);
    info.has_PARALLAXPOSITION = exists(G_PARALLAXPOSITION);
    info.has_TEXELSIZE        = exists(G_TEXELSIZE);
    info.has_TEXELSIZEHALF    = exists(G_TEXELSIZEHALF);
    info.has_SCREEN           = exists(G_SCREEN);
    info.has_LP               = exists(G_LP);
    info.has_LCP              = exists(G_LCP);
    for (const auto name : kLightingV1Uniforms) {
        if (exists(name)) info.has_LIGHTS_V1 = true;
    }
    info.has_ORIENTATIONUP      = exists(G_ORIENTATIONUP);
    info.has_ORIENTATIONRIGHT   = exists(G_ORIENTATIONRIGHT);
    info.has_ORIENTATIONFORWARD = exists(G_ORIENTATIONFORWARD);
    info.has_EYE                = exists(G_EYEPOSITION);
    info.has_VIEWFORWARD        = exists(G_VIEWFORWARD);
    info.has_VIEWUP             = exists(G_VIEWUP);
    info.has_VIEWRIGHT          = exists(G_VIEWRIGHT);
    info.has_AudioSpectrum16Left  = exists(G_AUDIO16_LEFT);
    info.has_AudioSpectrum16Right = exists(G_AUDIO16_RIGHT);
    info.has_AudioSpectrum32Left  = exists(G_AUDIO32_LEFT);
    info.has_AudioSpectrum32Right = exists(G_AUDIO32_RIGHT);
    info.has_AudioSpectrum64Left  = exists(G_AUDIO64_LEFT);
    info.has_AudioSpectrum64Right = exists(G_AUDIO64_RIGHT);
    for (std::size_t slot = 0; slot < info.texs.size(); ++slot) {
        info.texs[slot].has_resolution = exists(WE_GLTEX_RESOLUTION_NAMES[slot]);
        info.texs[slot].has_mipmap     = exists(WE_GLTEX_MIPMAPINFO_NAMES[slot]);
        info.texs[slot].has_texel      = exists(WE_GLTEX_TEXEL_NAMES[slot]);
    }
    const bool reads_audio = info.has_AudioSpectrum16Left || info.has_AudioSpectrum16Right ||
                             info.has_AudioSpectrum32Left || info.has_AudioSpectrum32Right ||
                             info.has_AudioSpectrum64Left || info.has_AudioSpectrum64Right;
    if (reads_audio && m_scene != nullptr && m_scene->runtime != nullptr) {
        m_scene->runtime->MarkSceneRequiresAudioResponse();
    }
    m_nodeUniformInfoMap[node][material_slot] = info;
}

void WPShaderValueUpdater::UpdateUniforms(SceneNode* pNode, sprite_map_t& sprites,
                                          const UpdateUniformOp& updateOp) {
    UpdateUniforms(pNode, 0, sprites, updateOp);
}

void WPShaderValueUpdater::UpdateUniforms(SceneNode* node, uint32_t material_slot,
                                          sprite_map_t& sprites, const UpdateUniformOp& write) {
    if (node == nullptr || m_scene == nullptr || ! write) return;
    SceneMesh* mesh = node->Mesh();
    if (mesh == nullptr) return;
    const SceneMaterial* material = mesh->MaterialForSlot(material_slot);
    if (material == nullptr) return;
    const std::string& camera_name = node->Camera();
    const SceneCamera* draw_camera = CameraNamed(camera_name);
    if (draw_camera == nullptr) return;

    node->UpdateTrans();
    const WPShaderValueData* data = FindNodeData(node, material_slot);
    const WPUniformInfo* info = FindUniformInfo(node, material_slot);

    UpdateSprites(node, sprites, write);
    if (info == nullptr) return;

    // ---- bones
    if (info->has_BONES && data != nullptr && data->puppet_layer.hasPuppet()) {
        // Copies of a puppet layer share their playback state, so the pose is the layer's own.
        const auto pose = const_cast<WPShaderValueData*>(data)->puppet_layer.genFrame(m_scene->elapsingTime);
        if (! pose.empty()) {
            std::vector<float> packed(pose.size() * 16);
            for (std::size_t bone = 0; bone < pose.size(); ++bone) {
                const Matrix4f matrix = pose[bone].matrix();
                std::memcpy(packed.data() + bone * 16, matrix.data(), 16 * sizeof(float));
            }
            write(G_BONES, ShaderValue(packed.data(), packed.size()));
        }
    }

    // ---- time, pointer and screen
    const float frame_time = static_cast<float>(m_scene->frameTime);
    if (info->has_TIME) write(G_TIME, ShaderValue(static_cast<float>(m_scene->elapsingTime)));
    if (info->has_FRAMETIME) write(G_FRAMETIME, ShaderValue(frame_time));
    if (info->has_DAYTIME) write(G_DAYTIME, ShaderValue(static_cast<float>(m_dayTime)));
    if (info->has_DAYTIME_ALIAS) write(G_DAYTIME_ALIAS, ShaderValue(static_cast<float>(m_dayTime)));
    if (info->has_TEXTUREREDUCTIONSCALE) write(G_TEXTUREREDUCTIONSCALE, ShaderValue(1.0f));
    if (info->has_POINTERPOSITION) write(G_POINTERPOSITION, Vec({ m_mousePos[0], m_mousePos[1] }));
    if (info->has_POINTERPOSITIONLAST) {
        write(G_POINTERPOSITIONLAST, Vec({ m_mousePosLast[0], m_mousePosLast[1] }));
    }
    if (info->has_POINTERSTATE) {
        const bool  down    = (m_mouseButtonsDown & 1u) != 0;
        const bool  before  = (m_mouseButtonsDownLast & 1u) != 0;
        const float held    = down ? 1.0f : 0.0f;
        const float pressed = down && ! before ? 1.0f : 0.0f;
        write(G_POINTERSTATE, Vec({ held, held, pressed, 0.0f }));
    }
    if (info->has_PARALLAXPOSITION) {
        if (! m_parallax.enable) {
            write(G_PARALLAXPOSITION, Vec({ 0.5f, 0.5f }));
        } else {
            const float influence = m_parallax.mouseinfluence;
            write(G_PARALLAXPOSITION,
                  Vec({ 0.5f + (m_parallaxPos[0] - 0.5f) * influence,
                        0.5f - (m_parallaxPos[1] - 0.5f) * influence }));
        }
    }
    if (info->has_SCREEN) {
        const float w = static_cast<float>(m_screenWidth);
        const float h = static_cast<float>(m_screenHeight);
        write(G_SCREEN, Vec({ w, h, w / h }));
    }
    if (info->has_TEXELSIZE) write(G_TEXELSIZE, Vec({ m_texelSize[0], m_texelSize[1] }));
    if (info->has_TEXELSIZEHALF) {
        write(G_TEXELSIZEHALF, Vec({ m_texelSize[0] * 0.5f, m_texelSize[1] * 0.5f }));
    }

    // ---- matrices
    const bool compose_first = SamplesScreenBackground(*material);
    const SceneCamera* view_camera =
        compose_first && m_scene->activeCamera != nullptr ? m_scene->activeCamera : draw_camera;
    if (info->has_VP) write(G_VP, ShaderValue::fromMatrix(view_camera->GetViewProjectionMatrix()));

    const bool wants_model = info->has_M || info->has_AM || info->has_MI || info->has_MVP ||
                             info->has_MVPI || info->has_NORMALMODEL;
    if (wants_model) {
        Matrix4d model;
        if (compose_first) {
            model = node->ModelTrans();
        } else if (draw_camera->IsLayerLocal()) {
            model = Matrix4d::Identity();
        } else {
            model = node->RenderTrans();
        }
        std::array<float, 2> depth { 0.0f, 0.0f };
        if (ParallaxMovesDraw(*info, node, camera_name, data, compose_first, &depth)) {
            const Vector3d camera_at = view_camera->GetPosition();
            const double   influence = m_parallax.mouseinfluence;
            const double   amount    = m_parallax.amount;
            const double   mouse_x   = (0.5 - m_parallaxPos[0]) * m_scene->ortho[0] * influence;
            const double   mouse_y   = -(0.5 - m_parallaxPos[1]) * m_scene->ortho[1] * influence;
            double         root_x    = model(0, 3);
            double         root_y    = model(1, 3);
            if (m_parallax.canvas_scene) {
                const Vector3d origin = ParallaxRootOrigin(node, data);
                root_x                = origin.x();
                root_y                = origin.y();
            }
            const double shift_x = (mouse_x + root_x - camera_at.x()) * depth[0] * amount;
            const double shift_y = (mouse_y + root_y - camera_at.y()) * depth[1] * amount;
            model(0, 3) += shift_x;
            model(1, 3) += shift_y;
        }
        if (info->has_M) write(G_M, ShaderValue::fromMatrix(model));
        if (info->has_AM) write(G_AM, ShaderValue::fromMatrix(model));
        if (info->has_MI) write(G_MI, ShaderValue::fromMatrix(Matrix4d(model.inverse())));
        const Matrix4d mvp = view_camera->GetViewProjectionMatrix() * model;
        if (info->has_MVP) write(G_MVP, ShaderValue::fromMatrix(mvp));
        if (info->has_MVPI) write(G_MVPI, ShaderValue::fromMatrix(Matrix4d(mvp.inverse())));
        if (info->has_NORMALMODEL) {
            std::array<float, 12> normal {};
            for (int column = 0; column < 3; ++column) {
                Vector3d axis = model.col(column).head<3>();
                const double length = axis.norm();
                if (length > 0.0) axis /= length;
                for (int row = 0; row < 3; ++row) {
                    normal[static_cast<std::size_t>(column * 4 + row)] = static_cast<float>(axis[row]);
                }
            }
            write(G_NORMALMODEL, ShaderValue(normal));
        }
    }

    // ---- effect chain matrices
    if (info->has_layer_model || info->has_effect_model || info->has_effect_mvp ||
        info->has_effect_mvpi || info->has_ETVP || info->has_ETVPI) {
        SceneNode* owner = data != nullptr && data->effect_owner != nullptr ? data->effect_owner : node;
        owner->UpdateTrans();
        const Matrix4d layer = owner->ModelTrans();
        Matrix4d       drawn = layer;
        drawn.block<3, 1>(0, 3) += owner->DrawOffset().cast<double>();
        const Vector2f extent = data != nullptr ? data->effect_extent : Vector2f(2.0f, 2.0f);
        Matrix4d       scale  = Matrix4d::Identity();
        scale(0, 0)           = extent.x() / 2.0;
        scale(1, 1)           = extent.y() / 2.0;
        const bool has_owner  = data != nullptr && data->effect_owner != nullptr;
        Matrix4d   effect_model = drawn;
        if (has_owner && camera_name == "effect") effect_model = drawn * scale;
        if (info->has_layer_model) write(G_LAYERMODEL, ShaderValue::fromMatrix(layer));
        if (info->has_effect_model) write(G_EFFECTMODEL, ShaderValue::fromMatrix(effect_model));
        if (m_scene->activeCamera != nullptr) {
            const Matrix4d view_projection = m_scene->activeCamera->GetViewProjectionMatrix();
            if (info->has_effect_mvp || info->has_effect_mvpi) {
                const Matrix4d effect_mvp = view_projection * effect_model;
                if (info->has_effect_mvp) write(G_EFFECTMVP, ShaderValue::fromMatrix(effect_mvp));
                if (info->has_effect_mvpi) {
                    write(G_EFFECTMVPI, ShaderValue::fromMatrix(Matrix4d(effect_mvp.inverse())));
                }
            }
            if (has_owner && (info->has_ETVP || info->has_ETVPI)) {
                const Matrix4d projection = view_projection * drawn * scale;
                if (info->has_ETVP) write(G_ETVP, ShaderValue::fromMatrix(projection));
                if (info->has_ETVPI) {
                    write(G_ETVPI, ShaderValue::fromMatrix(Matrix4d(projection.inverse())));
                }
            }
        }
    }

    // ---- render-target slots
    if (data != nullptr) {
        for (const auto& [slot, target_name] : data->renderTargets) {
            if (! SlotInRange(static_cast<uint32_t>(slot)) || slot >= info->texs.size()) continue;
            const auto target = m_scene->renderTargets.find(target_name);
            if (target == m_scene->renderTargets.end()) continue;
            const float width  = static_cast<float>(target->second.width);
            const float height = static_cast<float>(target->second.height);
            const auto& flags  = info->texs[slot];
            if (flags.has_resolution) {
                write(WE_GLTEX_RESOLUTION_NAMES[slot], Vec({ width, height, width, height }));
            }
            if (flags.has_mipmap) {
                write(WE_GLTEX_MIPMAPINFO_NAMES[slot],
                      ShaderValue(static_cast<float>(target->second.mipmap_level)));
            }
            if (flags.has_texel && target->second.width > 0 && target->second.height > 0) {
                write(WE_GLTEX_TEXEL_NAMES[slot], Vec({ 1.0f / width, 1.0f / height, width, height }));
            }
        }
    }

    // ---- camera-derived values
    if (info->has_ORIENTATIONRIGHT || info->has_ORIENTATIONUP || info->has_ORIENTATIONFORWARD) {
        const auto axes = draw_camera->GetAxes();
        const auto put  = [&](std::string_view name, const Vector3d& v) {
            write(name, Vec({ static_cast<float>(v.x()), static_cast<float>(v.y()),
                              static_cast<float>(v.z()) }));
        };
        if (info->has_ORIENTATIONRIGHT) put(G_ORIENTATIONRIGHT, axes.right);
        if (info->has_ORIENTATIONUP) put(G_ORIENTATIONUP, axes.up);
        if (info->has_ORIENTATIONFORWARD) put(G_ORIENTATIONFORWARD, axes.forward);
    }
    if (info->has_EYE || info->has_VIEWFORWARD || info->has_VIEWUP || info->has_VIEWRIGHT) {
        // A perspective camera supplies them; an orthographic one would collapse billboards.
        const SceneCamera* eye_camera = draw_camera->IsPerspective() ? draw_camera
                                         : (m_scene->activeCamera != nullptr &&
                                            m_scene->activeCamera->IsPerspective())
                                             ? m_scene->activeCamera
                                             : nullptr;
        if (eye_camera != nullptr) {
            const auto put = [&](std::string_view name, const Vector3d& v) {
                write(name, Vec({ static_cast<float>(v.x()), static_cast<float>(v.y()),
                                  static_cast<float>(v.z()) }));
            };
            if (info->has_EYE) {
                Vector3d eye = eye_camera->GetPosition();
                if (! eye_camera->FovLocked()) eye.z() = kCanvasShaderEyeDepth;
                put(G_EYEPOSITION, eye);
            }
            if (info->has_VIEWFORWARD) put(G_VIEWFORWARD, eye_camera->GetDirection());
            if (info->has_VIEWUP) put(G_VIEWUP, eye_camera->GetUp());
            if (info->has_VIEWRIGHT) put(G_VIEWRIGHT, eye_camera->GetRight());
        }
    }

    // ---- lights
    if (info->has_LP || info->has_LCP) {
        const auto legacy = PackLegacyLights(*m_scene);
        write(G_LP, ShaderValue(legacy.positions.data(), legacy.positions.size()));
        write(G_LCP, ShaderValue(legacy.colors.data(), legacy.colors.size()));
    }
    if (info->has_LIGHTS_V1) {
        const auto lights = PackLightingV1(*m_scene);
        const std::array<std::pair<std::string_view, const std::vector<float>*>, 11> arrays { {
            { G_LPOINT_COLOR, &lights.point_color },
            { G_LPOINT_ORIGIN, &lights.point_origin },
            { G_LSPOT_COLOR, &lights.spot_color },
            { G_LSPOT_ORIGIN, &lights.spot_origin },
            { G_LSPOT_DIRECTION, &lights.spot_direction },
            { G_LSPOT_EXPONENT, &lights.spot_exponent },
            { G_LTUBE_COLOR, &lights.tube_color },
            { G_LTUBE_ORIGINA, &lights.tube_origin_a },
            { G_LTUBE_ORIGINB, &lights.tube_origin_b },
            { G_LDIRECTIONAL_COLOR, &lights.directional_color },
            { G_LDIRECTIONAL_DIRECTION, &lights.directional_direction },
        } };
        for (const auto& [name, values] : arrays) {
            if (values->empty()) continue;
            write(name, ShaderValue(values->data(), values->size()));
        }
    }

    // ---- audio spectrum, one value per vec4 element
    if (info->has_AudioSpectrum16Left || info->has_AudioSpectrum16Right ||
        info->has_AudioSpectrum32Left || info->has_AudioSpectrum32Right ||
        info->has_AudioSpectrum64Left || info->has_AudioSpectrum64Right) {
        audio::AudioSpectrumSnapshot snapshot;
        if (m_scene->runtime != nullptr) snapshot = m_scene->runtime->CurrentAudioSpectrumSnapshot();
        const auto put = [&](std::string_view name, const auto& bands) {
            m_audioPack.assign(bands.size() * 4, 0.0f);
            for (std::size_t i = 0; i < bands.size(); ++i) m_audioPack[i * 4] = bands[i];
            write(name, ShaderValue(m_audioPack.data(), m_audioPack.size()));
        };
        if (info->has_AudioSpectrum16Left) put(G_AUDIO16_LEFT, snapshot.left16);
        if (info->has_AudioSpectrum16Right) put(G_AUDIO16_RIGHT, snapshot.right16);
        if (info->has_AudioSpectrum32Left) put(G_AUDIO32_LEFT, snapshot.left32);
        if (info->has_AudioSpectrum32Right) put(G_AUDIO32_RIGHT, snapshot.right32);
        if (info->has_AudioSpectrum64Left) put(G_AUDIO64_LEFT, snapshot.left64);
        if (info->has_AudioSpectrum64Right) put(G_AUDIO64_RIGHT, snapshot.right64);
    }
}

void WPShaderValueUpdater::UpdateSprites(SceneNode* node, sprite_map_t& sprites,
                                         const UpdateUniformOp& write) {
    bool reported = false;
    for (auto& [slot, animation] : sprites) {
        if (animation.FrameCount() == 0 || ! SlotInRange(static_cast<uint32_t>(slot))) continue;
        const SpriteFrame* frame = nullptr;
        if (node->TextureFrame().has_value()) {
            frame = &animation.SetFrame(*node->TextureFrame());
        } else {
            frame = &animation.GetAnimateFrame(node->TextureAnimationStep(m_scene->frameTime));
        }
        if (! reported) {
            reported = true;
            node->SetTextureAnimationFrame(static_cast<double>(animation.CurFrameIndex()));
        }
        write(WE_GLTEX_ROTATION_NAMES[slot],
              Vec({ frame->xAxis[0], frame->xAxis[1], frame->yAxis[0], frame->yAxis[1] }));
        write(WE_GLTEX_TRANSLATION_NAMES[slot], Vec({ frame->x, frame->y }));
    }
}

Vector3d WPShaderValueUpdater::ParallaxRootOrigin(const SceneNode* node,
                                                  const WPShaderValueData* data) const {
    SceneNode* start = data != nullptr && data->parallax_layer != nullptr
                           ? data->parallax_layer
                           : const_cast<SceneNode*>(node);
    SceneNode* root  = start;
    if (! start->IgnoresParentTransform()) {
        const SceneNode* scene_root = m_scene->sceneGraph.get();
        while (root->Parent() != nullptr && root->Parent() != scene_root) root = root->Parent();
    }
    root->UpdateTrans();
    // A fullscreen root places its layers from the frame the scene saved for it.
    const Matrix4d from = root != start && root->HasChildFrame() ? root->ChildTrans() : root->ModelTrans();
    return Vector3d(from(0, 3), from(1, 3), from(2, 3));
}

void WPShaderValueUpdater::SetNodeData(void* nodeAddr, const WPShaderValueData& data) {
    SetNodeData(nodeAddr, 0, data);
}

void WPShaderValueUpdater::SetNodeData(void* nodeAddr, uint32_t material_slot,
                                       const WPShaderValueData& data) {
    m_nodeDataMap[nodeAddr][material_slot] = data;
    if (data.parallax_layer != nullptr) {
        auto& passes = m_parallaxPasses[data.parallax_layer];
        if (std::find(passes.begin(), passes.end(), nodeAddr) == passes.end()) {
            passes.push_back(nodeAddr);
        }
    }
}

// A layer a script made has no record here until it asks for a depth; then it
// gets the default one, which differs from a layer with no record only in
// following the cursor by the depth it was given. The layers below it that
// already have a record take the same depth, and a layer drawn through effects
// takes it on its effect passes alone; a layer with none is not given one. The
// answer says whether any record went from standing still to following the
// cursor or the reverse.
bool WPShaderValueUpdater::SetNodeParallaxDepth(SceneNode* node, float x, float y) {
    if (node == nullptr || ! std::isfinite(x) || ! std::isfinite(y)) return false;
    const bool follows = x != 0.0f || y != 0.0f;
    bool       changed = false;
    const auto write   = [&](WPShaderValueData& data) {
        const bool followed = data.parallaxDepth[0] != 0.0f || data.parallaxDepth[1] != 0.0f;
        changed             = changed || followed != follows;
        data.parallaxDepth  = { x, y };
    };
    const auto write_all = [&](void* key, bool create) {
        auto found = m_nodeDataMap.find(key);
        if (found == m_nodeDataMap.end()) {
            if (! create) return;
            found = m_nodeDataMap.emplace(key, Map<uint32_t, WPShaderValueData> {}).first;
        }
        if (found->second.empty()) found->second[0] = WPShaderValueData {};
        for (auto& [slot, data] : found->second) write(data);
    };
    std::vector<SceneNode*> pending { node };
    while (! pending.empty()) {
        SceneNode* layer = pending.back();
        pending.pop_back();
        // A layer drawn through effect passes has its depth on them, and only
        // there: its own node draws the first pass into the layer's target, which
        // stays where it is, so the record it holds (the parser leaves its depth
        // at zero) is neither given nor written one.
        const auto passes     = m_parallaxPasses.find(layer);
        const bool has_passes = passes != m_parallaxPasses.end() && ! passes->second.empty();
        if (has_passes) {
            for (void* pass : passes->second) write_all(pass, false);
        } else {
            write_all(layer, layer == node);
        }
        for (const auto& child : layer->GetChildren()) pending.push_back(child.get());
    }
    return changed;
}

// A layer drawn through effects holds its depth on the passes, not on its own
// node, so those are asked first.
std::array<float, 2> WPShaderValueUpdater::NodeParallaxDepth(const SceneNode* node) const {
    const auto depth_of = [this](void* key) -> std::optional<std::array<float, 2>> {
        const auto slots = m_nodeDataMap.find(key);
        if (slots == m_nodeDataMap.end() || slots->second.empty()) return std::nullopt;
        const auto first = slots->second.find(0);
        return (first != slots->second.end() ? first->second : slots->second.begin()->second)
            .parallaxDepth;
    };
    if (const auto passes = m_parallaxPasses.find(node); passes != m_parallaxPasses.end()) {
        for (void* pass : passes->second) {
            if (const auto depth = depth_of(pass)) return *depth;
        }
    }
    return depth_of(const_cast<SceneNode*>(node)).value_or(std::array<float, 2> { 0.0f, 0.0f });
}

void WPShaderValueUpdater::ForgetNode(SceneNode* node) {
    if (node == nullptr) return;
    m_nodeDataMap.erase(node);
    m_nodeUniformInfoMap.erase(node);
    m_parallaxPasses.erase(node);
    // A pass that is freed must not stay in the list of the layer it belonged to.
    for (auto it = m_parallaxPasses.begin(); it != m_parallaxPasses.end();) {
        auto& passes = it->second;
        passes.erase(std::remove(passes.begin(), passes.end(), static_cast<void*>(node)),
                     passes.end());
        it = passes.empty() ? m_parallaxPasses.erase(it) : std::next(it);
    }
    // Nor may a puppet attachment keep writing to a node that is gone.
    for (auto& group : m_puppetAttachments) {
        auto& attachments = group.attachments;
        attachments.erase(std::remove_if(attachments.begin(), attachments.end(),
                                         [node](const PuppetAttachment& a) { return a.node == node; }),
                          attachments.end());
    }
    m_puppetAttachments.erase(
        std::remove_if(m_puppetAttachments.begin(), m_puppetAttachments.end(),
                       [](const PuppetAttachmentGroup& g) { return g.attachments.empty(); }),
        m_puppetAttachments.end());
}

void WPShaderValueUpdater::SetTexelSize(float x, float y) {
    // A texel that is not a positive number would put infinities in every neighbour tap.
    if (! std::isfinite(x) || ! std::isfinite(y) || x <= 0.0f || y <= 0.0f) return;
    m_texelSize = { x, y };
}
