#include "WPShaderValueUpdater.hpp"
#include "Eigen/src/Core/Matrix.h"
#include "Eigen/src/Geometry/Transform.h"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "SpriteAnimation.hpp"
#include "SpecTexs.hpp"
#include "Core/ArrayHelper.hpp"
#include "Utils/Algorism.h"
#include "Utils/TimeOfDay.hpp"

#include <Eigen/Dense>
#include <Eigen/Geometry>
#include <iostream>
#include <chrono>
#include <ctime>
#include <numeric>
#include <vector>
#include <span>
#include <algorithm>
#include <cmath>

using namespace wallpaper;
using namespace Eigen;

namespace
{

constexpr std::string_view G_AUDIO_SPECTRUM16_LEFT  = "g_AudioSpectrum16Left";
constexpr std::string_view G_AUDIO_SPECTRUM16_RIGHT = "g_AudioSpectrum16Right";
constexpr std::string_view G_AUDIO_SPECTRUM32_LEFT  = "g_AudioSpectrum32Left";
constexpr std::string_view G_AUDIO_SPECTRUM32_RIGHT = "g_AudioSpectrum32Right";
constexpr std::string_view G_AUDIO_SPECTRUM64_LEFT  = "g_AudioSpectrum64Left";
constexpr std::string_view G_AUDIO_SPECTRUM64_RIGHT = "g_AudioSpectrum64Right";
constexpr std::string_view G_NORMALMODEL            = "g_NormalModelMatrix";

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
    uint              i = 0;
    for (const auto& l : scene.lights) {
        if (i == 4) break;
        if (l == nullptr || l->type() != SceneLightType::Legacy || l->node() == nullptr) continue;
        if (! l->visible()) continue;
        l->node()->UpdateTrans();
        const Vector3d trans = l->node()->ModelTrans().block<3, 1>(0, 3);
        for (size_t axis = 0; axis < 3; ++axis) {
            arrays.positions[i * 4 + axis] = static_cast<float>(trans[axis]);
        }
        const auto color = l->premultipliedColor();
        if (i < 3) {
            std::copy(color.begin(), color.end(), arrays.colors.begin() + i * 4);
        } else {
            // Three vec4 uniforms hold four RGB lights: the last light's
            // channels occupy the w component of each of the first three.
            for (size_t channel = 0; channel < 3; ++channel) {
                arrays.colors[channel * 4 + 3] = color[channel];
            }
        }
        i++;
    }
    return arrays;
}

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
        step = std::clamp((1.0 - m_parallax.delay / 3.0) * 10.0 * m_scene->frameTime, 0.0, 1.0);
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

uint32_t WPShaderValueUpdater::FrameVaryingUniforms(SceneNode*          node,
                                                    uint32_t            material_slot,
                                                    const std::string& camera_override) const {
    // Reflection captured at InitUniforms is the authority. A node the updater
    // never saw is reported as varying in every way, because absence of a
    // record is not evidence that nothing advances.
    if (node == nullptr || ! exists(m_nodeUniformInfoMap, node)) return frame_varying_uniform::kAll;
    const auto& slot_infos = m_nodeUniformInfoMap.at(node);
    auto        it         = slot_infos.find(material_slot);
    if (it == slot_infos.end()) it = slot_infos.find(0);
    if (it == slot_infos.end()) return frame_varying_uniform::kAll;

    const auto& info  = it->second;
    uint32_t    flags = frame_varying_uniform::kNone;
    if (info.has_TIME || info.has_FRAMETIME) flags |= frame_varying_uniform::kTime;
    if (info.has_DAYTIME || info.has_DAYTIME_ALIAS) flags |= frame_varying_uniform::kDayTime;
    if (info.has_POINTERPOSITION || info.has_POINTERPOSITIONLAST || info.has_POINTERSTATE)
        flags |= frame_varying_uniform::kPointer;
    if (info.has_PARALLAXPOSITION) flags |= frame_varying_uniform::kParallax;
    if (info.has_BONES) flags |= frame_varying_uniform::kBones;
    if (info.has_AudioSpectrum16Left || info.has_AudioSpectrum16Right ||
        info.has_AudioSpectrum32Left || info.has_AudioSpectrum32Right ||
        info.has_AudioSpectrum64Left || info.has_AudioSpectrum64Right)
        flags |= frame_varying_uniform::kAudio;
    // Camera parallax moves a layer with the cursor through its model matrix.
    // No uniform the shader declares reveals that, and the static cache hashes
    // the node's transform without it: unreported, the pass is reused while the
    // cursor moves, and a still scene never wakes for the pointer. Decided for
    // the camera the pass draws through, as UpdateUniforms decides it: the
    // effect camera and a layer-local one never move a layer, so a composite
    // another layer samples stays reusable.
    if (m_parallax.enable && m_parallax.amount != 0.0f && m_parallax.mouseinfluence != 0.0f &&
        (info.has_M || info.has_MVP || info.has_MI || info.has_MVPI)) {
        const std::string& cam_name = camera_override.empty() ? node->Camera() : camera_override;
        const SceneCamera* camera   = m_scene->activeCamera;
        if (! cam_name.empty()) {
            const auto found = m_scene->cameras.find(cam_name);
            camera = found != m_scene->cameras.end() ? found->second.get() : nullptr;
        }
        const auto data_slots = m_nodeDataMap.find(node);
        if (camera != nullptr && cam_name != "effect" && ! camera->IsLayerLocal() &&
            data_slots != m_nodeDataMap.end()) {
            auto data = data_slots->second.find(material_slot);
            if (data == data_slots->second.end()) data = data_slots->second.find(0);
            if (data != data_slots->second.end()) {
                // The depth UpdateUniforms moves the pass by.
                const auto* material = node->Mesh() != nullptr
                                           ? node->Mesh()->MaterialForSlot(material_slot)
                                           : nullptr;
                const auto depth = material != nullptr && SamplesScreenBackground(*material)
                                       ? NodeParallaxDepth(node)
                                       : data->second.parallaxDepth;
                if (depth[0] != 0.0f || depth[1] != 0.0f) flags |= frame_varying_uniform::kParallax;
            }
        }
    }
    return flags;
}

void WPShaderValueUpdater::RegisterPuppetAttachments(
    WPPuppetLayer layer, std::vector<PuppetAttachment> attachments) {
    auto& group = m_puppetAttachments.emplace_back(
        PuppetAttachmentGroup { std::move(layer), std::move(attachments) });
    UpdatePuppetAttachments(group);
}

void WPShaderValueUpdater::UpdatePuppetAttachments(PuppetAttachmentGroup& group) {
    const auto bones = group.layer.genFrame(m_scene->elapsingTime);
    for (const auto& attachment : group.attachments) {
        if (attachment.node == nullptr || attachment.bone_index >= bones.size()) continue;
        attachment.node->SetAttachmentTransform(
            (bones[attachment.bone_index] * attachment.bind_transform).matrix().cast<double>());
    }
}

void WPShaderValueUpdater::MouseInput(double x, double y) {
    m_mousePosInput[0] = (float)x;
    m_mousePosInput[1] = (float)y;
}

void WPShaderValueUpdater::InitUniforms(SceneNode* pNode, const ExistsUniformOp& existsOp) {
    InitUniforms(pNode, 0, existsOp);
}

void WPShaderValueUpdater::InitUniforms(SceneNode* pNode, uint32_t material_slot,
                                        const ExistsUniformOp& existsOp) {
    m_nodeUniformInfoMap[pNode][material_slot] = WPUniformInfo();
    auto& info                                = m_nodeUniformInfoMap[pNode][material_slot];
    info.has_MI                 = existsOp(G_MI);
    info.has_M                  = existsOp(G_M);
    info.has_AM                 = existsOp(G_AM);
    info.has_MVP                = existsOp(G_MVP);
    info.has_MVPI               = existsOp(G_MVPI);
    info.has_ETVP               = existsOp(G_ETVP);
    info.has_ETVPI              = existsOp(G_ETVPI);

    info.has_VP = existsOp(G_VP);
    info.has_layer_model  = existsOp("g_LayerModelMatrix");
    info.has_effect_mvp   = existsOp(G_EFFECTMVP);
    info.has_effect_model = existsOp(G_EFFECTMODEL);
    info.has_effect_mvpi  = existsOp(G_EFFECTMVPI);

    info.has_BONES            = existsOp(G_BONES);
    info.has_TIME             = existsOp(G_TIME);
    info.has_DAYTIME          = existsOp(G_DAYTIME);
    info.has_DAYTIME_ALIAS    = existsOp("g_Daytime");
    info.has_POINTERPOSITION  = existsOp(G_POINTERPOSITION);
    info.has_POINTERPOSITIONLAST   = existsOp(G_POINTERPOSITIONLAST);
    info.has_POINTERSTATE          = existsOp(G_POINTERSTATE);
    info.has_FRAMETIME             = existsOp(G_FRAMETIME);
    info.has_TEXTUREREDUCTIONSCALE = existsOp(G_TEXTUREREDUCTIONSCALE);
    info.has_PARALLAXPOSITION = existsOp(G_PARALLAXPOSITION);
    info.has_TEXELSIZE        = existsOp(G_TEXELSIZE);
    info.has_TEXELSIZEHALF    = existsOp(G_TEXELSIZEHALF);
    info.has_SCREEN           = existsOp(G_SCREEN);
    info.has_LP               = existsOp(G_LP);
    info.has_LCP              = existsOp(G_LCP);
    info.has_LIGHTS_V1        = std::any_of(kLightingV1Uniforms.begin(), kLightingV1Uniforms.end(),
                                     [&existsOp](std::string_view name) { return existsOp(name); });
    info.has_NORMALMODEL      = existsOp(G_NORMALMODEL);
    info.has_ORIENTATIONUP      = existsOp(G_ORIENTATIONUP);
    info.has_ORIENTATIONRIGHT   = existsOp(G_ORIENTATIONRIGHT);
    info.has_ORIENTATIONFORWARD = existsOp(G_ORIENTATIONFORWARD);
    info.has_EYE              = existsOp(G_EYEPOSITION);
    info.has_VIEWFORWARD      = existsOp(G_VIEWFORWARD);
    info.has_VIEWUP           = existsOp(G_VIEWUP);
    info.has_VIEWRIGHT        = existsOp(G_VIEWRIGHT);
    info.has_AudioSpectrum16Left = existsOp(G_AUDIO_SPECTRUM16_LEFT);
    info.has_AudioSpectrum16Right = existsOp(G_AUDIO_SPECTRUM16_RIGHT);
    info.has_AudioSpectrum32Left = existsOp(G_AUDIO_SPECTRUM32_LEFT);
    info.has_AudioSpectrum32Right = existsOp(G_AUDIO_SPECTRUM32_RIGHT);
    info.has_AudioSpectrum64Left = existsOp(G_AUDIO_SPECTRUM64_LEFT);
    info.has_AudioSpectrum64Right = existsOp(G_AUDIO_SPECTRUM64_RIGHT);

    if (info.has_AudioSpectrum16Left || info.has_AudioSpectrum16Right ||
        info.has_AudioSpectrum32Left || info.has_AudioSpectrum32Right ||
        info.has_AudioSpectrum64Left || info.has_AudioSpectrum64Right) {
        if (! m_audioSpectrumPacked) {
            m_audioSpectrumPacked.emplace(std::array<float, 64 * 4> {});
        }
        if (m_scene != nullptr && m_scene->runtime != nullptr) {
            m_scene->runtime->MarkSceneRequiresAudioResponse();
        }
    }

    std::accumulate(begin(info.texs), end(info.texs), 0, [&existsOp](uint index, auto& value) {
        value.has_resolution = existsOp(WE_GLTEX_RESOLUTION_NAMES[index]);
        value.has_mipmap     = existsOp(WE_GLTEX_MIPMAPINFO_NAMES[index]);
        value.has_texel      = existsOp(WE_GLTEX_TEXEL_NAMES[index]);
        return index + 1;
    });
}

void WPShaderValueUpdater::UpdateUniforms(SceneNode* pNode, sprite_map_t& sprites,
                                          const UpdateUniformOp& updateOp) {
    UpdateUniforms(pNode, 0, sprites, updateOp);
}

void WPShaderValueUpdater::UpdateUniforms(SceneNode* pNode, uint32_t material_slot,
                                          sprite_map_t& sprites,
                                          const UpdateUniformOp& updateOp) {
    if (! pNode->Mesh()) return;

    pNode->UpdateTrans();

    SceneCamera*      camera;
    std::string_view   cam_name = pNode->Camera();
    if (! pNode->Camera().empty()) {
        camera = m_scene->cameras.at(cam_name.data()).get();
    } else
        camera = m_scene->activeCamera;

    if (! camera) return;

    auto* material = pNode->Mesh()->MaterialForSlot(material_slot);
    if (! material) return;
    // auto& shadervs = material->customShader.updateValueList;
    // const auto& valueSet = material->customShader.valueSet;

    assert(exists(m_nodeUniformInfoMap, pNode));
    const auto& slot_infos = m_nodeUniformInfoMap.at(pNode);
    assert(exists(slot_infos, material_slot));
    const auto& info = slot_infos.at(material_slot);

    WPShaderValueData* nodeData = nullptr;
    if (const auto node_it = m_nodeDataMap.find(pNode); node_it != m_nodeDataMap.end()) {
        auto& slot_data = node_it->second;
        auto        data_it   = slot_data.find(material_slot);
        if (data_it == slot_data.end()) data_it = slot_data.find(0);
        if (data_it != slot_data.end()) nodeData = &data_it->second;
    }
    bool hasNodeData = nodeData != nullptr;
    if (info.has_layer_model || info.has_effect_mvp || info.has_effect_model ||
        info.has_effect_mvpi || info.has_ETVP || info.has_ETVPI) {
        auto* owner = hasNodeData && nodeData->effect_owner != nullptr
            ? nodeData->effect_owner : pNode;
        owner->UpdateTrans();
        const Matrix4d layer_model = owner->ModelTrans();
        if (info.has_layer_model) {
            updateOp("g_LayerModelMatrix", ShaderValue::fromMatrix(layer_model));
        }
        // The card the chain ends in is drawn where the layer is drawn, which a screen anchor
        // moves without moving the layer (`SceneNode::DrawOffset`), so the matrices that say
        // where the effect lands on the screen follow the draw, as the final card does.
        Matrix4d drawn_model = layer_model;
        drawn_model.block<3, 1>(0, 3) += owner->DrawOffset().cast<double>();
        Matrix4d effect_model = drawn_model;
        // Intermediate passes use a unit quad; final passes use the layer card.
        if (hasNodeData && nodeData->effect_owner != nullptr && cam_name == "effect") {
            effect_model = drawn_model * Affine3d(Scaling(
                double(nodeData->effect_extent.x()) * 0.5,
                double(nodeData->effect_extent.y()) * 0.5, 1.0)).matrix();
        }
        // Where the effect quad lands in the scene, for lit effects that
        // shade by world position.
        if (info.has_effect_model) updateOp(G_EFFECTMODEL, ShaderValue::fromMatrix(effect_model));
        // An effect pass maps the layer's own texture space onto the screen
        // with the layer card's projection: its view-projection, its model and
        // half its card size, intermediate and final passes alike. A pointer or
        // direction effect undoes it to land in the layer's texture wherever the
        // layer sits, turned, scaled or flipped. Outside an effect chain the
        // parser's identity stays.
        if ((info.has_ETVP || info.has_ETVPI) && hasNodeData && nodeData->effect_owner != nullptr &&
            m_scene->activeCamera != nullptr) {
            const Matrix4d texture_projection =
                m_scene->activeCamera->GetViewProjectionMatrix() * drawn_model *
                Affine3d(Scaling(double(nodeData->effect_extent.x()) * 0.5,
                                 double(nodeData->effect_extent.y()) * 0.5, 1.0))
                    .matrix();
            if (info.has_ETVP) updateOp(G_ETVP, ShaderValue::fromMatrix(texture_projection));
            if (info.has_ETVPI) {
                updateOp(G_ETVPI, ShaderValue::fromMatrix(Matrix4d(texture_projection.inverse())));
            }
        }
        if ((info.has_effect_mvp || info.has_effect_mvpi) && m_scene->activeCamera != nullptr) {
            const Matrix4d effect_mvp =
                m_scene->activeCamera->GetViewProjectionMatrix() * effect_model;
            if (info.has_effect_mvp) updateOp(G_EFFECTMVP, ShaderValue::fromMatrix(effect_mvp));
            if (info.has_effect_mvpi)
                updateOp(G_EFFECTMVPI, ShaderValue::fromMatrix(Matrix4d(effect_mvp.inverse())));
        }
    }
    if (hasNodeData) {
        for (const auto& el : nodeData->renderTargets) {
            const auto rt_it = m_scene->renderTargets.find(el.second);
            if (rt_it == m_scene->renderTargets.end()) continue;
            const auto& rt = rt_it->second;

            const auto& unifrom_tex = info.texs[el.first];

            if (unifrom_tex.has_resolution) {
                std::array<i32, 4> resolution_uint({ rt.width, rt.height, rt.width, rt.height });
                updateOp(WE_GLTEX_RESOLUTION_NAMES[el.first],
                         ShaderValue(array_cast<float>(resolution_uint)));
            }
            if (unifrom_tex.has_mipmap) {
                updateOp(WE_GLTEX_MIPMAPINFO_NAMES[el.first], (float)rt.mipmap_level);
            }
            if (unifrom_tex.has_texel && rt.width > 0 && rt.height > 0) {
                const float width  = static_cast<float>(rt.width);
                const float height = static_cast<float>(rt.height);
                updateOp(WE_GLTEX_TEXEL_NAMES[el.first],
                         std::array { 1.0f / width, 1.0f / height, width, height });
            }
        }
        if (nodeData->puppet_layer.hasPuppet() && info.has_BONES) {
            const auto data = nodeData->puppet_layer.genFrame(m_scene->elapsingTime);
            if (! data.empty()) {
                updateOp(G_BONES, std::span<const float> { data.front().data(), data.size() * 16 });
            }
        }
    }

    bool reqMI    = info.has_MI;
    bool reqM     = info.has_M;
    bool reqAM    = info.has_AM;
    bool reqMVP   = info.has_MVP;
    bool reqMVPI  = info.has_MVPI;

    // composelayer.vert draws a full local target using UVs, but its MVP is
    // used to sample the *screen* behind the layer. The effect camera and
    // identity render override lose the parent's translation/scale here. That
    // holds wherever the layer is drawn to, its own composite included: the
    // screen behind it is what its card holds.
    // A layer-local camera frames the card in the layer's own texture space,
    // so where the layer sits in the scene -- transform, scene camera and
    // parallax alike -- must not reach the image another layer samples.
    const bool layer_local = camera->IsLayerLocal();
    const bool samples_screen_background = SamplesScreenBackground(*material);
    SceneCamera* matrix_camera =
        samples_screen_background && m_scene->activeCamera != nullptr ? m_scene->activeCamera : camera;
    Matrix4d viewProTrans = matrix_camera->GetViewProjectionMatrix();

    if (info.has_VP) {
        updateOp(G_VP, ShaderValue::fromMatrix(viewProTrans));
    }
    if (info.has_ORIENTATIONUP || info.has_ORIENTATIONRIGHT || info.has_ORIENTATIONFORWARD) {
        // Screen-facing particles read the camera node's world axes. The parser
        // writes a constant screen-XY basis; that is only right for an unrotated
        // camera looking down -Z, so the live camera replaces it here.
        const auto axes = camera->GetAxes();
        if (info.has_ORIENTATIONRIGHT) {
            updateOp(G_ORIENTATIONRIGHT,
                     std::array { (float)axes.right.x(), (float)axes.right.y(),
                                  (float)axes.right.z() });
        }
        if (info.has_ORIENTATIONUP) {
            updateOp(G_ORIENTATIONUP,
                     std::array { (float)axes.up.x(), (float)axes.up.y(), (float)axes.up.z() });
        }
        if (info.has_ORIENTATIONFORWARD) {
            updateOp(G_ORIENTATIONFORWARD,
                     std::array { (float)axes.forward.x(), (float)axes.forward.y(),
                                  (float)axes.forward.z() });
        }
    }
    if (reqM || reqMVP || reqMI || reqMVPI || info.has_NORMALMODEL) {
        Matrix4d modelTrans = samples_screen_background ? pNode->ModelTrans()
                              : layer_local             ? Matrix4d::Identity()
                                                        : pNode->RenderTrans();
        if (hasNodeData && cam_name != "effect" && ! layer_local) {
            if (m_parallax.enable) {
                // The screen a compose layer's first pass reads is the place its
                // card is drawn, where the layer's last pass puts it: through the
                // scene camera, moved by the layer's depth. A layer drawn through
                // effects holds that depth on those passes, not on its own node,
                // so it is asked there; read at the unshifted place, the layer
                // would hold what is behind that place instead.
                const auto layer_depth = samples_screen_background ? NodeParallaxDepth(pNode)
                                                                   : nodeData->parallaxDepth;
                Vector2f depth(layer_depth[0], layer_depth[1]);
                Vector2f ortho { (float)m_scene->ortho[0], (float)m_scene->ortho[1] };
                // flip mouse y axis
                Vector2f mouseVec =
                    Scaling(1.0f, -1.0f) * (Vector2f { 0.5f, 0.5f } - Vector2f(&m_parallaxPos[0]));
                mouseVec = mouseVec.cwiseProduct(ortho) * m_parallax.mouseinfluence;
                // Parallax moves a layer by the cursor's offset from the
                // centre of the view and by where the layer sits, scaled by
                // its depth and the scene's amount. The centre of the view is
                // that of the camera the matrix is built with: a compose layer
                // without children frames its effects with a camera at the
                // origin, but its first pass reads the screen through the scene
                // camera.
                Vector2f offset = mouseVec;
                if (m_parallax.canvas_scene) {
                    // Wallpaper Engine moves the whole tree under an outermost
                    // layer by that layer's distance from the eased cursor
                    // point, which rests at the centre of the view: with the
                    // cursor centred a layer off the centre is pushed further
                    // out by its depth. The outermost layer's current origin,
                    // so a scripted or animated one carries its children.
                    const SceneNode* root = nodeData->parallax_layer != nullptr
                                                ? nodeData->parallax_layer
                                                : pNode;
                    // A layer placed by its own transform alone (a fullscreen
                    // layer) is the outermost of its own tree; the layers below
                    // it belong to the tree it sits in, and are placed from the
                    // transform the scene saved for it.
                    const SceneNode* const start = root;
                    if (! root->IgnoresParentTransform()) {
                        while (root->Parent() != nullptr &&
                               root->Parent() != m_scene->sceneGraph.get())
                            root = root->Parent();
                    }
                    const Matrix4d root_model = root != start && root->HasChildFrame()
                                                    ? root->ChildTrans()
                                                    : root->ModelTrans();
                    offset += root_model.block<2, 1>(0, 3).cast<float>() -
                              matrix_camera->GetPosition().cast<float>().head<2>();
                }
                if (! m_parallax.canvas_scene) {
                    // Where the layer sits in the scene, not its parent-relative
                    // origin, which is near zero for the child of a centred group.
                    const Vector2f nodePos = modelTrans.block<2, 1>(0, 3).cast<float>();
                    offset += nodePos - matrix_camera->GetPosition().cast<float>().head<2>();
                }
                const Vector2f paraVec = offset.cwiseProduct(depth) * m_parallax.amount;
                modelTrans =
                    Affine3d(Translation3d(Vector3d(paraVec.x(), paraVec.y(), 0.0f))).matrix() *
                    modelTrans;
            }
        }

        if (reqM) updateOp(G_M, ShaderValue::fromMatrix(modelTrans));
        if (info.has_NORMALMODEL) {
            // The draw's rotation without its scale: each axis of the model
            // matrix normalised, as a std140 mat3 (three padded columns).
            std::array<float, 12> normal_model { 0 };
            for (int column = 0; column < 3; ++column) {
                Vector3d axis = modelTrans.block<3, 1>(0, column);
                if (axis.squaredNorm() > 0.0) axis.normalize();
                for (int row = 0; row < 3; ++row) {
                    normal_model[column * 4 + row] = static_cast<float>(axis[row]);
                }
            }
            updateOp(G_NORMALMODEL, normal_model);
        }
        if (reqAM) updateOp(G_AM, ShaderValue::fromMatrix(modelTrans));
        if (reqMI) updateOp(G_MI, ShaderValue::fromMatrix(modelTrans.inverse()));
        if (reqMVP) {
            Matrix4d mvpTrans = viewProTrans * modelTrans;
            updateOp(G_MVP, ShaderValue::fromMatrix(mvpTrans));
            if (reqMVPI) updateOp(G_MVPI, ShaderValue::fromMatrix(mvpTrans.inverse()));
        }
    }

    //	g_EffectTextureProjectionMatrix
    // shadervs.push_back({"g_EffectTextureProjectionMatrixInverse",
    // ShaderValue::ValueOf(Eigen::Matrix4f::Identity())});
    if (info.has_TIME) updateOp(G_TIME, (float)m_scene->elapsingTime);

    if (info.has_DAYTIME) updateOp(G_DAYTIME, (float)m_dayTime);
    if (info.has_DAYTIME_ALIAS) updateOp("g_Daytime", (float)m_dayTime);

    if (info.has_AudioSpectrum16Left || info.has_AudioSpectrum16Right ||
        info.has_AudioSpectrum32Left || info.has_AudioSpectrum32Right ||
        info.has_AudioSpectrum64Left || info.has_AudioSpectrum64Right) {
        const auto snapshot = m_scene != nullptr && m_scene->runtime != nullptr
            ? m_scene->runtime->CurrentAudioSpectrumSnapshot()
            : wallpaper::audio::AudioSpectrumSnapshot {};

        const auto pushAudioSpectrum = [this, &updateOp](std::string_view name, const auto& values) {
            auto& packed = *m_audioSpectrumPacked;
            packed.setSize(values.size() * 4u);
            for (std::size_t index = 0; index < values.size(); ++index) {
                packed[index * 4u] = values[index];
            }
            updateOp(name, packed);
        };

        if (info.has_AudioSpectrum16Left) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM16_LEFT, snapshot.left16);
        }
        if (info.has_AudioSpectrum16Right) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM16_RIGHT, snapshot.right16);
        }
        if (info.has_AudioSpectrum32Left) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM32_LEFT, snapshot.left32);
        }
        if (info.has_AudioSpectrum32Right) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM32_RIGHT, snapshot.right32);
        }
        if (info.has_AudioSpectrum64Left) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM64_LEFT, snapshot.left64);
        }
        if (info.has_AudioSpectrum64Right) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM64_RIGHT, snapshot.right64);
        }
    }

    if (info.has_POINTERPOSITION) updateOp(G_POINTERPOSITION, m_mousePos);
    // Simulation effects (cursor ripple, fluid) move by the cursor's travel
    // since the last frame and push harder while the primary button is held.
    if (info.has_POINTERPOSITIONLAST) updateOp(G_POINTERPOSITIONLAST, m_mousePosLast);
    if (info.has_POINTERSTATE) {
        // Held in x and y; z only on the frame the button went down, the
        // one-frame push a ripple or fluid gets per click.
        const bool  held    = (m_mouseButtonsDown & 1u) != 0;
        const float down    = held ? 1.0f : 0.0f;
        const float pressed = held && (m_mouseButtonsDownLast & 1u) == 0 ? 1.0f : 0.0f;
        updateOp(G_POINTERSTATE, std::array { down, down, pressed, 0.0f });
    }
    // The seconds this frame advances the scene, which simulation steps scale by.
    if (info.has_FRAMETIME) updateOp(G_FRAMETIME, (float)m_scene->frameTime);
    // Textures are always loaded at their authored size, never reduced.
    if (info.has_TEXTUREREDUCTIONSCALE) updateOp(G_TEXTUREREDUCTIONSCALE, 1.0f);

    if (info.has_TEXELSIZE) updateOp(G_TEXELSIZE, m_texelSize);

    if (info.has_TEXELSIZEHALF)
        updateOp(G_TEXELSIZEHALF, std::array { m_texelSize[0] / 2.0f, m_texelSize[1] / 2.0f });

    if (info.has_SCREEN)
        updateOp(G_SCREEN,
                 std::array<float, 3> {
                     m_screen_size[0], m_screen_size[1], m_screen_size[0] / m_screen_size[1] });

    if (info.has_PARALLAXPOSITION) {
        Vector2f para { 0.5f, 0.5f };
        if (m_parallax.enable) {
            const Vector2f mouseCentered = Vector2f(&m_parallaxPos[0]) - Vector2f { 0.5f, 0.5f };
            para = Vector2f { 0.5f, 0.5f } +
                   (Scaling(1.0f, -1.0f) * mouseCentered) * m_parallax.mouseinfluence;
        }
        updateOp(G_PARALLAXPOSITION, std::array { para[0], para[1] });
    }

    bool reported_texture_frame = false;
    for (auto& [i, sp] : sprites) {
        if (sp.numFrames() == 0) continue;
        // A pinned frame holds; otherwise the sheet advances by the frame time
        // the layer's script lets it have (none while paused, scaled by `rate`).
        const auto& f = pNode->TextureFrame().has_value()
                            ? sp.SetFrame(*pNode->TextureFrame())
                            : sp.GetAnimateFrame(pNode->TextureAnimationStep(m_scene->frameTime));
        if (! reported_texture_frame) {
            pNode->SetTextureAnimationFrame(static_cast<double>(sp.CurFrameIndex()));
            reported_texture_frame = true;
        }
        auto        grot   = WE_GLTEX_ROTATION_NAMES[i];
        auto        gtrans = WE_GLTEX_TRANSLATION_NAMES[i];
        updateOp(grot, std::array { f.xAxis[0], f.xAxis[1], f.yAxis[0], f.yAxis[1] });
        updateOp(gtrans, std::array { f.x, f.y });
    }

    if (info.has_LP || info.has_LCP) {
        const auto legacy = PackLegacyLights(*m_scene);
        updateOp(G_LP, legacy.positions);
        updateOp(G_LCP, legacy.colors);
    }
    if (info.has_LIGHTS_V1) {
        const auto lights = PackLightingV1(*m_scene);
        for (const auto& [name, values] : {
                 std::pair { G_LPOINT_COLOR, &lights.point_color },
                 std::pair { G_LPOINT_ORIGIN, &lights.point_origin },
                 std::pair { G_LSPOT_COLOR, &lights.spot_color },
                 std::pair { G_LSPOT_ORIGIN, &lights.spot_origin },
                 std::pair { G_LSPOT_DIRECTION, &lights.spot_direction },
                 std::pair { G_LSPOT_EXPONENT, &lights.spot_exponent },
                 std::pair { G_LTUBE_COLOR, &lights.tube_color },
                 std::pair { G_LTUBE_ORIGINA, &lights.tube_origin_a },
                 std::pair { G_LTUBE_ORIGINB, &lights.tube_origin_b },
                 std::pair { G_LDIRECTIONAL_COLOR, &lights.directional_color },
                 std::pair { G_LDIRECTIONAL_DIRECTION, &lights.directional_direction },
             }) {
            if (! values->empty()) updateOp(name, std::span<const float> { *values });
        }
    }

    if (info.has_EYE || info.has_VIEWFORWARD || info.has_VIEWUP || info.has_VIEWRIGHT) {
        // 2D scenes keep the authored axis-aligned constants. Overwriting them
        // from the ortho camera node (canvas centre, z = 0) collapses particle
        // billboards that subtract g_EyePosition from a layer on the same plane.
        SceneCamera* view_camera = nullptr;
        if (camera != nullptr && camera->IsPerspective()) {
            view_camera = camera;
        } else if (m_scene->activeCamera != nullptr && m_scene->activeCamera->IsPerspective()) {
            view_camera = m_scene->activeCamera;
        }
        if (view_camera != nullptr) {
            const auto to_array = [](const Eigen::Vector3d& value) {
                return std::array<float, 3> { static_cast<float>(value.x()),
                                              static_cast<float>(value.y()),
                                              static_cast<float>(value.z()) };
            };
            if (info.has_EYE) {
                auto eye = to_array(view_camera->GetPosition());
                // A 2D scene's perspective camera sits where its field of view
                // puts it, which is not where Wallpaper Engine keeps the eye its
                // shaders read: over the view's centre at a fixed depth.
                if (! view_camera->FovLocked()) eye[2] = kCanvasShaderEyeDepth;
                updateOp(G_EYEPOSITION, eye);
            }
            if (info.has_VIEWFORWARD)
                updateOp(G_VIEWFORWARD, to_array(view_camera->GetDirection()));
            if (info.has_VIEWUP) updateOp(G_VIEWUP, to_array(view_camera->GetUp()));
            if (info.has_VIEWRIGHT) updateOp(G_VIEWRIGHT, to_array(view_camera->GetRight()));
        }
    }
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
    m_nodeDataMap.erase(node);
    m_nodeUniformInfoMap.erase(node);
    m_parallaxPasses.erase(node);
}

void WPShaderValueUpdater::SetTexelSize(float x, float y) { m_texelSize = { x, y }; }
