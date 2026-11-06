// Clean-room implementation from the WallpaperMachine spec e1a-scene-host.md; written without access to the original source.
#include "WPShaderValueUpdater.hpp"
#include "Particle/ParticleOrientation.h"
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
constexpr std::array<std::string_view,5> kRenderVariables {
    "g_RenderVar0", "g_RenderVar1", "g_RenderVar2", "g_RenderVar3", "g_RenderVar4"
};

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
// The shadow feature arrays the generated `PerformLighting_V1` reads (C-6.md, sub_140169140)
// and the shadow caster's view-projections (shadowcaster.vert).
constexpr std::string_view G_LFEATURE_SHADOWPROJECTION          = "g_LFeature_ShadowProjection";
constexpr std::string_view G_LFEATURE_SHADOWPROJECTIONTRANSFORM = "g_LFeature_ShadowProjectionTransform";
constexpr std::string_view G_LFEATURE_SHADOWPOINTPROJECTION     = "g_LFeature_ShadowPointProjection";
constexpr std::string_view G_LFEATURE_SHADOWPOINTTRANSFORM      = "g_LFeature_ShadowPointProjectionTransform";
constexpr std::string_view G_VIEWPORTVIEWPROJECTIONS            = "g_ViewportViewProjectionMatrices";
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

void PackLightingV1(const Scene& scene, LightingV1Arrays& arrays) {
    const auto&      config = scene.light_config;
    for (auto* array : { &arrays.point_color, &arrays.point_origin }) array->assign(config.point * 4, 0.0f);
    for (auto* array : { &arrays.spot_color, &arrays.spot_origin, &arrays.spot_direction,
                         &arrays.spot_exponent })
        array->assign(config.spot * 4, 0.0f);
    for (auto* array : { &arrays.tube_color, &arrays.tube_origin_a, &arrays.tube_origin_b })
        array->assign(config.tube * 4, 0.0f);
    for (auto* array : { &arrays.directional_color, &arrays.directional_direction })
        array->assign(config.directional * 4, 0.0f);

    // Wallpaper Engine sorts its lights every time it packs them (`we_SortSceneLights`
    // 0x140186990, called by 0x140190C80 from the frame draw): kind, then flags & 3
    // descending, then the light's own origin (+296, parent space) along the camera's
    // forward axis ascending, nearest first (comparator 0x14019F360). Each kind's array
    // holds its subsets first, each filled through its own cursor: spot
    // [shadow cookie][cookie][shadow][plain] (partition ((shadows ? 1 : 0) + 2) & flags),
    // point and directional [shadow][plain] (partition shadows ? flags & 1 : 0); a kind
    // takes at most its count of lights whatever their partition. A cursor that runs past
    // the array (a config whose subsets exceed its count) writes nothing here; Wallpaper
    // Engine writes into the next array.
    const Vector3d forward = scene.activeCamera != nullptr ? scene.activeCamera->GetDirection()
                                                           : Vector3d(0.0, 0.0, -1.0);
    const bool     shadows = scene.quality.shadows != 0;
    struct Keyed {
        const SceneLight* light;
        double            depth;
    };
    thread_local std::vector<Keyed> sorted;
    sorted.clear();
    for (const auto& light : scene.lights) {
        if (light == nullptr || light->node() == nullptr || ! light->visible()) continue;
        if (light->type() == SceneLightType::Legacy) continue;
        sorted.push_back({ light.get(), light->node()->Translate().cast<double>().dot(forward) });
    }
    std::stable_sort(sorted.begin(), sorted.end(), [](const Keyed& a, const Keyed& b) {
        if (a.light->type() != b.light->type()) return a.light->type() < b.light->type();
        const uint32_t fa = a.light->flags() & 3u, fb = b.light->flags() & 3u;
        if (fa != fb) return fa > fb;
        return a.depth < b.depth;
    });

    // Each partition's cursor starts where the subsets before it end.
    std::array<std::size_t, 4> spot_at;
    spot_at[3] = 0;
    spot_at[2] = config.spot_shadow_cookie;
    spot_at[1] = spot_at[2] + config.spot_cookie;
    spot_at[0] = spot_at[1] + config.spot_shadow;
    std::array<std::size_t, 2> point_at { config.point_shadow, 0 };
    std::array<std::size_t, 2> dir_at { config.directional_shadow, 0 };
    uint32_t    points_left = config.point, spots_left = config.spot, dirs_left = config.directional;
    std::size_t tube        = 0;
    constexpr double kDegrees = 3.14159265358979323846 / 180.0;
    for (const auto& entry : sorted) {
        const SceneLight* light = entry.light;
        auto*             node  = light->node();
        node->UpdateTrans();
        const Matrix4d  world  = node->ModelTrans();
        const Vector3d  origin = world.block<3, 1>(0, 3);
        // The light's own x axis, scale included, is the way a spot or
        // directional light points.
        const Vector3d  axis   = world.block<3, 1>(0, 0);
        const Vector3d  color  = (light->color() * light->intensity()).cast<double>();
        const uint32_t  flags  = light->flags();
        switch (light->type()) {
        case SceneLightType::Point: {
            if (points_left == 0) break;
            --points_left;
            const std::size_t point = point_at[shadows ? (flags & 1u) : 0u]++;
            if (point >= config.point) break;
            PutVec4(arrays.point_color, point, color, light->radius());
            PutVec4(arrays.point_origin, point, origin, light->exponent());
            break;
        }
        case SceneLightType::Spot: {
            if (spots_left == 0) break;
            --spots_left;
            const std::size_t spot = spot_at[((shadows ? 1u : 0u) + 2u) & flags]++;
            if (spot >= config.spot) break;
            PutVec4(arrays.spot_color, spot, color, light->radius());
            PutVec4(arrays.spot_origin, spot, origin,
                    static_cast<float>(std::cos(light->innerCone() * kDegrees)));
            PutVec4(arrays.spot_direction, spot, axis,
                    static_cast<float>(std::cos(light->outerCone() * kDegrees)));
            arrays.spot_exponent[spot * 4] = light->exponent();
            break;
        }
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
        case SceneLightType::Directional: {
            if (dirs_left == 0) break;
            --dirs_left;
            const std::size_t directional = dir_at[shadows ? (flags & 1u) : 0u]++;
            if (directional >= config.directional) break;
            PutVec4(arrays.directional_color, directional, color, 1.0f);
            // Towards the light: it shines along its own x axis.
            PutVec4(arrays.directional_direction, directional, -axis, 0.0f);
            break;
        }
        case SceneLightType::Legacy: break;
        }
    }
}

/// The legacy four-light packing: positions in `g_LightsPosition`, colours
/// premultiplied by intensity and radius squared in three vec4s, the fourth
/// light's channels in their w lanes, and `g_LightsColorRadius` as
/// (colour × intensity, radius) per slot. Each light writes its own slot
/// (`SceneLight::legacySlot`), last writer wins. Wallpaper Engine's
/// `sub_14025D1F0` writes a hidden light's slot as (0, 0, 0, 1) and still
/// writes its position.
struct LegacyLightArrays {
    std::array<float, 16> positions { 0 };
    std::array<float, 12> colors { 0 };
    std::array<float, 16> color_radius { 0 };
};

LegacyLightArrays PackLegacyLights(const Scene& scene) {
    LegacyLightArrays arrays;
    for (const auto& light : scene.lights) {
        if (light == nullptr || light->type() != SceneLightType::Legacy) continue;
        if (light->node() == nullptr) continue;
        const std::size_t slot = light->legacySlot();
        auto* node = light->node();
        node->UpdateTrans();
        const Matrix4d world = node->ModelTrans();
        for (int axis = 0; axis < 3; ++axis) {
            arrays.positions[slot * 4 + static_cast<std::size_t>(axis)] =
                static_cast<float>(world(axis, 3));
        }
        arrays.positions[slot * 4 + 3] = 0.0f;
        const bool     shines = light->visible();
        const Vector3f color  = shines ? light->premultipliedColor() : Vector3f::Zero();
        if (slot < 3) {
            for (int axis = 0; axis < 3; ++axis) {
                arrays.colors[slot * 4 + static_cast<std::size_t>(axis)] = color[axis];
            }
        } else {
            // The fourth light rides in the w lanes of the three colour vectors.
            arrays.colors[3]  = color[0];
            arrays.colors[7]  = color[1];
            arrays.colors[11] = color[2];
        }
        const Vector3f scaled = shines ? Vector3f(light->color() * light->intensity())
                                       : Vector3f::Zero();
        for (int axis = 0; axis < 3; ++axis) {
            arrays.color_radius[slot * 4 + static_cast<std::size_t>(axis)] = scaled[axis];
        }
        arrays.color_radius[slot * 4 + 3] = shines ? light->radius() : 1.0f;
    }
    return arrays;
}

/// The 12 lanes of a draw's normal matrix: each of the model's three axes,
/// normalised, one per vec4 column.
std::array<float, 12> NormalMatrixLanes(const Matrix4d& model) {
    std::array<float, 12> normal {};
    for (int column = 0; column < 3; ++column) {
        Vector3d axis = model.col(column).head<3>();
        const double length = axis.norm();
        if (length > 0.0) axis /= length;
        for (int row = 0; row < 3; ++row) {
            normal[static_cast<std::size_t>(column * 4 + row)] = static_cast<float>(axis[row]);
        }
    }
    return normal;
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

bool ReadsAudioSpectrum(const WPUniformInfo& info) {
    return info.has_AudioSpectrum16Left || info.has_AudioSpectrum16Right ||
           info.has_AudioSpectrum32Left || info.has_AudioSpectrum32Right ||
           info.has_AudioSpectrum64Left || info.has_AudioSpectrum64Right;
}

/// Each spectrum array the material binds, with the bands of `snapshot` it carries, in one
/// fixed order. The uniform write and the reuse hash both go through here, so what a pass is
/// redrawn for is exactly what its uniforms hold.
template <typename Op>
void ForEachBoundSpectrum(const WPUniformInfo& info, const audio::AudioSpectrumSnapshot& snapshot,
                          Op&& op) {
    if (info.has_AudioSpectrum16Left) op(G_AUDIO16_LEFT, std::span<const float>(snapshot.left16));
    if (info.has_AudioSpectrum16Right) op(G_AUDIO16_RIGHT, std::span<const float>(snapshot.right16));
    if (info.has_AudioSpectrum32Left) op(G_AUDIO32_LEFT, std::span<const float>(snapshot.left32));
    if (info.has_AudioSpectrum32Right) op(G_AUDIO32_RIGHT, std::span<const float>(snapshot.right32));
    if (info.has_AudioSpectrum64Left) op(G_AUDIO64_LEFT, std::span<const float>(snapshot.left64));
    if (info.has_AudioSpectrum64Right) op(G_AUDIO64_RIGHT, std::span<const float>(snapshot.right64));
}

/// Folds the bands two at a time: each 64-bit word goes into the state through the SplitMix64
/// finalizer, a bijection, so two runs that differ in one word always end differently. 64 bands
/// cost 32 steps, where `HashFloats` takes 256.
uint64_t HashBands(uint64_t hash, std::span<const float> bands) {
    for (std::size_t at = 0; at < bands.size(); at += 2) {
        uint64_t word = 0;
        std::memcpy(&word, bands.data() + at, std::min<std::size_t>(2, bands.size() - at) * sizeof(float));
        uint64_t x = hash ^ word;
        x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
        x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
        hash = x ^ (x >> 31);
    }
    return hash;
}

} // namespace

struct WPShaderValueUpdater::LightPacking {
    LightingV1Arrays modern;
    LegacyLightArrays legacy;
    Vector3d direction { 0.0, 0.0, -1.0 };
    bool modern_valid { false };
    bool legacy_valid { false };
#ifdef WESCENE_BUILD_TESTS
    std::array<uint64_t, 2> packs { 0, 0 };
#endif
};

WPShaderValueUpdater::WPShaderValueUpdater(Scene* scene, WallClock clock)
    : m_scene(scene), m_wall_clock(std::move(clock)) {}

WPShaderValueUpdater::~WPShaderValueUpdater() = default;

void WPShaderValueUpdater::BeginDraw() {
    m_drawing = true;
    if (m_lightPacking != nullptr) {
        m_lightPacking->modern_valid = false;
        m_lightPacking->legacy_valid = false;
    }
}

void WPShaderValueUpdater::EndDraw() { m_drawing = false; }

WPShaderValueUpdater::LightPacking& WPShaderValueUpdater::PackedLights(bool modern) const {
    if (m_lightPacking == nullptr) m_lightPacking = std::make_unique<LightPacking>();
    auto& packed = *m_lightPacking;
    if (modern) {
        // Reflection draws temporarily replace the active camera. Its forward axis is the
        // only camera input to light packing; a different axis must retain its own ordering.
        const Vector3d direction = m_scene->activeCamera != nullptr
            ? m_scene->activeCamera->GetDirection() : Vector3d(0.0, 0.0, -1.0);
        if (!m_drawing || !packed.modern_valid || packed.direction != direction) {
            PackLightingV1(*m_scene, packed.modern);
            packed.direction = direction;
            packed.modern_valid = true;
#ifdef WESCENE_BUILD_TESTS
            ++packed.packs[1];
#endif
        }
    } else if (!m_drawing || !packed.legacy_valid) {
        packed.legacy = PackLegacyLights(*m_scene);
        packed.legacy_valid = true;
#ifdef WESCENE_BUILD_TESTS
        ++packed.packs[0];
#endif
    }
    return packed;
}

#ifdef WESCENE_BUILD_TESTS
std::array<uint64_t, 2> WPShaderValueUpdater::LightPackingCountsForTests() const {
    return m_lightPacking != nullptr ? m_lightPacking->packs : std::array<uint64_t, 2>{0, 0};
}
#endif

void WPShaderValueUpdater::FrameBegin() {
    // Every audio read of this frame (passes, particle operators, scripts) sees one spectrum.
    if (m_scene != nullptr && m_scene->runtime != nullptr) m_scene->runtime->BeginAudioFrame();
    // The runtime supplies the layer world before stepping its puppet. Advancing
    // it here would consume this frame with the previous world and make merely
    // adding a visual child change its parent's simulation. Texture channels are
    // weighed by the same pose, so they follow the same schedule.
    if (m_scene == nullptr || m_scene->runtime == nullptr) {
        for (auto& group : m_puppetAttachments) UpdatePuppetAttachments(group);
        for (auto& channels : m_textureChannels) UpdatePuppetTextureChannels(channels);
    }
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
    const auto* data=m_scene->volumetric_lights.empty() ? nullptr : FindNodeData(node,material_slot);
    if(data && data->volumetric_light) return data->volumetric_light->generation;
    if (! info.has_LP && ! info.has_LCP && ! info.has_LCR && ! info.has_LIGHTS_V1 &&
        ! info.has_SHADOW_FEATURES)
        return 0;

    uint64_t hash = 0xcbf29ce484222325ULL;
    if (info.has_LP || info.has_LCP || info.has_LCR) {
        const auto& legacy = PackedLights(false).legacy;
        hash = HashFloats(hash, legacy.positions.data(), legacy.positions.size());
        hash = HashFloats(hash, legacy.colors.data(), legacy.colors.size());
        hash = HashFloats(hash, legacy.color_radius.data(), legacy.color_radius.size());
    }
    if (info.has_LIGHTS_V1) {
        const auto& lights = PackedLights(true).modern;
        for (const auto* values : {
                 &lights.point_color, &lights.point_origin, &lights.spot_color, &lights.spot_origin,
                 &lights.spot_direction, &lights.spot_exponent, &lights.tube_color,
                 &lights.tube_origin_a, &lights.tube_origin_b, &lights.directional_color,
                 &lights.directional_direction }) {
            hash = HashFloats(hash, values->data(), values->size());
        }
    }
    if (info.has_SHADOW_FEATURES) {
        const auto& shadows = m_scene->shadows;
        for (const auto* values : { &shadows.projection, &shadows.projection_transform,
                                    &shadows.point_projection, &shadows.point_transform }) {
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
    if (! m_parallax.enable || ! m_user_parallax || m_parallax.amount == 0.0f ||
        m_parallax.mouseinfluence == 0.0f) {
        return false;
    }
    if (! (info.has_M || info.has_MVP || info.has_MI || info.has_MVPI)) return false;
    const SceneCamera* camera = CameraNamed(camera_name);
    if (camera == nullptr || camera_name == "effect" || camera->IsLayerLocal()) return false;
    // Without node data nothing says how deep the draw is.
    if (data == nullptr) return false;
    // A compose layer's first pass asks for the depth of the layer, which sits on its effect
    // passes; every other draw moves by the depth of its own record.
    const std::array<float, 2> found = EffectiveParallaxDepth(node, data, compose_first);
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
    // A puppet's animation moves its bones and weighs its texture channels alike.
    if (info->has_BONES || info->has_BONESALPHA || info->has_MORPH || info->has_BLENDMAP)
        bits |= frame_varying_uniform::kBones;
    if (ReadsAudioSpectrum(*info)) bits |= frame_varying_uniform::kAudio;
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


uint64_t WPShaderValueUpdater::PointerStateHash(SceneNode* node, uint32_t material_slot,
                                                const std::string& camera_override) const {
    if (m_scene == nullptr || node == nullptr) return 0;
    const auto* info = FindUniformInfo(node, material_slot);
    if (info == nullptr) return 0;
    uint64_t hash = 0xcbf29ce484222325ULL;
    bool sampled = false;
    const auto fold = [&](const float* values, std::size_t count) {
        hash = HashFloats(hash, values, count);
        sampled = true;
    };
    if (info->has_POINTERPOSITION) fold(m_mousePos.data(), m_mousePos.size());
    if (info->has_POINTERPOSITIONLAST) {
        fold(m_mousePosLast.data(), m_mousePosLast.size());
        // Last-position shaders change one frame after the event. Include the
        // pending position so a delayed consumer keeps the clock alive until
        // both the uniform and its retained picture have caught up.
        fold(m_mousePos.data(), m_mousePos.size());
    }
    if (info->has_POINTERSTATE) {
        const bool down = (m_mouseButtonsDown & 1u) != 0;
        const bool before = (m_mouseButtonsDownLast & 1u) != 0;
        const std::array<float, 2> state { down ? 1.0f : 0.0f,
                                         down && !before ? 1.0f : 0.0f };
        fold(state.data(), state.size());
    }
    if (info->has_PARALLAXPOSITION) {
        std::array<float, 2> position { 0.5f, 0.5f };
        if (m_parallax.enable && m_user_parallax) {
            position = { 0.5f + (m_parallaxPos[0] - 0.5f) * m_parallax.mouseinfluence,
                         0.5f - (m_parallaxPos[1] - 0.5f) * m_parallax.mouseinfluence };
        }
        fold(position.data(), position.size());
    }
    const auto& camera_name = camera_override.empty() ? node->Camera() : camera_override;
    const auto* material = node->Mesh() != nullptr ? node->Mesh()->MaterialForSlot(material_slot)
                                                  : nullptr;
    const bool compose = material != nullptr && SamplesScreenBackground(*material);
    std::array<float, 2> depth {};
    if (ParallaxMovesDraw(*info, node, camera_name, FindNodeData(node, material_slot), compose,
                         &depth)) {
        fold(m_parallaxPos.data(), m_parallaxPos.size());
        const std::array<float, 4> state { depth[0], depth[1], m_parallax.amount,
                                         m_parallax.mouseinfluence };
        fold(state.data(), state.size());
    }
    return sampled ? (hash == 0 ? 1 : hash) : 0;
}

void WPShaderValueUpdater::RegisterPuppetAttachments(
    WPPuppetLayer layer, std::vector<PuppetAttachment> attachments) {
    for (const auto& attachment : attachments) {
        ForgetPuppetAttachment(attachment.node);
        if (attachment.node) attachment.node->SetAttachmentIndex(attachment.attachment_index);
    }
    PuppetAttachmentGroup added{std::move(layer),std::move(attachments)};
    UpdatePuppetAttachments(added);
    for (auto& group : m_puppetAttachments) {
        if (!group.layer.sharesPoseWith(added.layer)) continue;
        group.attachments.insert(group.attachments.end(),added.attachments.begin(),added.attachments.end());
        return;
    }
    m_puppetAttachments.push_back(std::move(added));
}

void WPShaderValueUpdater::ForgetPuppetAttachment(SceneNode* node) {
    for (auto& group : m_puppetAttachments)
        std::erase_if(group.attachments,[node](const auto& binding){return binding.node==node;});
    std::erase_if(m_puppetAttachments,[](const auto& group){return group.attachments.empty();});
}

void WPShaderValueUpdater::RefreshPuppetAttachments(const WPPuppetLayer& layer) {
    for (auto& group : m_puppetAttachments)
        if (group.layer.sharesPoseWith(layer)) UpdatePuppetAttachments(group);
}

void WPShaderValueUpdater::UpdatePuppetAttachments(PuppetAttachmentGroup& group) {
    auto bones = group.layer.lastFrame();
    if (m_scene == nullptr || m_scene->runtime == nullptr) {
        // Standalone rendering has no runtime to supply this transform. All
        // bindings in a group belong to the same puppet instance and parent.
        if (group.layer.simulates()) {
            for (const auto& attachment : group.attachments) {
                auto* parent = attachment.node != nullptr ? attachment.node->Parent() : nullptr;
                if (parent == nullptr) continue;
                parent->UpdateTrans();
                group.layer.setLayerWorld(parent->ModelTrans());
                break;
            }
        }
        bones = group.layer.genFrame(m_scene != nullptr ? m_scene->elapsingTime : 0.0);
    }
    for (const auto& attachment : group.attachments) {
        if (attachment.node == nullptr || attachment.bone_index >= bones.size()) continue;
        attachment.node->SetAttachmentTransform(
            (bones[attachment.bone_index] * attachment.bind_transform).matrix().cast<double>());
    }
}

void WPShaderValueUpdater::UpdateAttachmentsAfterPose() {
    for (auto& group : m_puppetAttachments) UpdatePuppetAttachments(group);
    for (auto& channels : m_textureChannels) UpdatePuppetTextureChannels(channels);
}

void WPShaderValueUpdater::RegisterPuppetTextureChannels(WPPuppetLayer layer, SceneNode* owner,
                                                         SceneNode* painter, std::size_t channels) {
    if (owner == nullptr || painter == nullptr) return;
    const std::size_t rows = std::max<std::size_t>(1, (channels + 3) / 4);
    auto& entry = m_textureChannels.emplace_back(
        PuppetTextureChannels { std::move(layer), owner, painter, std::vector<float>(rows * 4, 0.0f) });
    UpdatePuppetTextureChannels(entry);
}

void WPShaderValueUpdater::UpdatePuppetTextureChannels(PuppetTextureChannels& channels) {
    channels.layer.textureChannelWeights(m_scene != nullptr ? m_scene->elapsingTime : 0.0, channels.weights);
    // The shader discards every fragment at or below this weight: nothing would be painted.
    constexpr float kNoWeight = 0.001f;
    const bool weighs_in = std::any_of(channels.weights.begin(), channels.weights.end(),
                                       [](float weight) { return weight > kNoWeight; });
    channels.painter->SetVisible(weighs_in && channels.owner->EffectiveVisible());
}

std::span<const float> WPShaderValueUpdater::TextureChannelWeights(const SceneNode* painter) const {
    for (const auto& channels : m_textureChannels) {
        if (channels.painter == painter) return channels.weights;
    }
    return {};
}

void WPShaderValueUpdater::MouseInput(double x, double y) {
    // As given: the clamped copy parallax follows is made when the frame begins.
    m_mousePosInput = { static_cast<float>(x), static_cast<float>(y) };
}

void WPShaderValueUpdater::InitUniforms(SceneNode* pNode, const ExistsUniformOp& existsOp) {
    InitUniforms(pNode, 0, existsOp);
}

/// Which of the uniforms this updater writes a program has, as `exists` answers for each name.
/// One table for the declared members (`InitUniforms`) and the read ones (`TransformInputs`), so
/// the two cannot name a uniform differently.
static WPUniformInfo UniformInfoOf(const ExistsUniformOp& exists) {
    WPUniformInfo info;
    for (std::size_t i=0;i<info.has_render_var.size();++i)
        info.has_render_var[i]=exists(kRenderVariables[i]);
    info.has_M                = exists(G_M);
    info.has_AM               = exists(G_AM);
    info.has_ANM              = exists(G_ANM);
    info.has_AVP              = exists(G_AVP);
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
    info.has_BONESALPHA       = exists(G_BONESALPHA);
    info.has_MORPH = exists("g_MorphOffsets") || exists("g_MorphWeights") ||
                     exists("g_MorphBoneTransform") || exists("g_MorphBoneRules");
    info.has_BLENDMAP         = exists(G_BLENDMAP);
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
    info.has_LCR              = exists(G_LCR);
    info.has_VVPM = exists(G_VIEWPORTVIEWPROJECTIONS);
    info.has_SHADOW_FEATURES = false;
    for (const auto name : { G_LFEATURE_SHADOWPROJECTION, G_LFEATURE_SHADOWPROJECTIONTRANSFORM,
                             G_LFEATURE_SHADOWPOINTPROJECTION, G_LFEATURE_SHADOWPOINTTRANSFORM }) {
        if (exists(name)) info.has_SHADOW_FEATURES = true;
    }
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
    return info;
}

void WPShaderValueUpdater::InitUniforms(SceneNode* node, uint32_t material_slot,
                                        const ExistsUniformOp& exists) {
    if (node == nullptr || ! exists) return;
    const WPUniformInfo info = UniformInfoOf(exists);
    if (ReadsAudioSpectrum(info) && m_scene != nullptr && m_scene->runtime != nullptr) {
        m_scene->runtime->MarkSceneRequiresAudioResponse();
    }
    m_nodeUniformInfoMap[node][material_slot] = info;
}

// Every uniform `UpdateUniforms` derives from a node's world transform, another node's or the
// scene's active camera, for a draw that is neither a compose layer's first pass nor drawn
// through a scene-space camera (those keep everything):
//
// - the model matrices (`g_ModelMatrix`, its inverse, `g_ModelViewProjectionMatrix`, its inverse,
//   the normal and Alt matrices): the identity through a layer-local camera, the node's own
//   transform through the effect camera;
// - the effect matrices (`g_LayerModelMatrix`, `g_EffectModelMatrix`,
//   `g_EffectModelViewProjectionMatrix` and `g_EffectTextureProjectionMatrix` with their
//   inverses): the effect's layer (or the node) and the active camera;
// - the eye and view axes, which fall back to the active camera; particle orientation, which
//   carries the node; the lights, whose packing sorts along the active camera; a volumetric
//   light's matrices; bones, morphs and texture channels, which a puppet poses in its layer's
//   world; and the cursor and parallax values: none of these is proven, so they keep everything.
//
// The view-projection matrices are the draw camera's, which a sample always folds. Parallax moves
// no draw through a layer-local or effect camera (`ParallaxMovesDraw`).
//
// A uniform `UpdateUniforms` comes to derive from a transform or a camera must be added here, to
// what a sample folds or to the unproven list, in the same change: the drift test
// (`ShaderUpdaterSignatures.EveryWrittenUniformThatMovesIsOneTheSampleFolds`) moves only parents,
// nodes and the camera, not lights, puppets, particles or volumetrics.
DrawTransformInputs WPShaderValueUpdater::TransformInputs(SceneNode* node, uint32_t material_slot,
                                                          const std::string& camera_override,
                                                          const ExistsUniformOp& reads) const {
    const DrawTransformInputs all {};
    if (m_scene == nullptr || node == nullptr || ! reads) return all;
    const SceneMaterial* material =
        node->Mesh() != nullptr ? node->Mesh()->MaterialForSlot(material_slot) : nullptr;
    if (material == nullptr || SamplesScreenBackground(*material)) return all;
    const std::string& camera_name = camera_override.empty() ? node->Camera() : camera_override;
    const SceneCamera* camera      = CameraNamed(camera_name);
    if (camera == nullptr) return all;
    const bool layer_local = camera->IsLayerLocal();
    if (! layer_local && camera_name != "effect") return all;
    const WPShaderValueData* data = FindNodeData(node, material_slot);
    if (data != nullptr && data->volumetric_light != nullptr) return all;

    const WPUniformInfo info = UniformInfoOf(reads);
    const bool unproven =
        info.has_EYE || info.has_VIEWFORWARD || info.has_VIEWUP || info.has_VIEWRIGHT ||
        info.has_ORIENTATIONUP || info.has_ORIENTATIONRIGHT || info.has_ORIENTATIONFORWARD ||
        info.has_LP || info.has_LCP || info.has_LCR || info.has_LIGHTS_V1 ||
        info.has_SHADOW_FEATURES || info.has_BONES || info.has_BONESALPHA || info.has_MORPH ||
        info.has_BLENDMAP || info.has_POINTERPOSITION || info.has_POINTERPOSITIONLAST ||
        info.has_POINTERSTATE || info.has_PARALLAXPOSITION;
    if (unproven) return all;

    DrawTransformInputs inputs { .node_transform = false, .active_camera = false, .owner = nullptr };
    const bool model = info.has_M || info.has_AM || info.has_ANM || info.has_MI || info.has_MVP ||
                       info.has_MVPI || info.has_NORMALMODEL;
    if (model && ! layer_local) inputs.node_transform = true;
    const bool effect = info.has_layer_model || info.has_effect_model || info.has_effect_mvp ||
                        info.has_effect_mvpi || info.has_ETVP || info.has_ETVPI;
    if (effect) {
        SceneNode* owner = data != nullptr && data->effect_owner != nullptr ? data->effect_owner : node;
        if (owner == node) inputs.node_transform = true;
        else inputs.owner = owner;
        inputs.active_camera = true;
    }
    return inputs;
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
    // A SKINNING_ALPHA puppet's per-bone alpha from the same evaluation (0x140206430 points
    // the uniform at the skeleton's +616 array, one float a bone).
    if (info->has_BONESALPHA && data != nullptr && data->puppet_layer.hasPuppet()) {
        auto& layer = const_cast<WPShaderValueData*>(data)->puppet_layer;
        layer.genFrame(m_scene->elapsingTime);
        const auto alpha = layer.boneAlpha();
        if (! alpha.empty()) write(G_BONESALPHA, ShaderValue(alpha.data(), alpha.size()));
    }
    if (info->has_MORPH && data != nullptr && data->puppet_layer.hasPuppet()) {
        auto& layer = const_cast<WPShaderValueData*>(data)->puppet_layer;
        layer.genFrame(m_scene->elapsingTime);
        if (const auto* morph = layer.morphUniforms(data->morph_mesh)) {
            write("g_MorphOffsets", morph->offsets);
            write("g_MorphWeights", morph->weights);
            if (morph->transforms.size() != 0) {
                write("g_MorphBoneTransform", morph->transforms);
                write("g_MorphBoneRules", morph->rules);
            }
        }
    }
    if (info->has_BLENDMAP) {
        if (const auto weights = TextureChannelWeights(node); ! weights.empty()) {
            write(G_BLENDMAP, ShaderValue(weights.data(), weights.size()));
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
        if (! m_parallax.enable || ! m_user_parallax) {
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
    const auto projection = [&](const SceneCamera* camera, bool scene_space) {
        return m_scene->display_framed && scene_space
            ? camera->GetRasterViewProjectionMatrix(m_scene->display_clip,
                                                    m_scene->display_clip_generation)
            : camera->GetViewProjectionMatrix();
    };
    const bool view_scene_space = compose_first ||
        (camera_name != "effect" && !draw_camera->IsLayerLocal());
    if (info->has_VP) write(G_VP, ShaderValue::fromMatrix(projection(view_camera, view_scene_space)));
    if (info->has_VVPM) {
        // A caster draws one viewport per pass (instance 0): its view first, the rest identity.
        std::array<float, 96> matrices {};
        const Matrix4d        vp = projection(view_camera, view_scene_space);
        for (std::size_t m = 0; m < 6; ++m) {
            for (int column = 0; column < 4; ++column) {
                for (int row = 0; row < 4; ++row) {
                    matrices[m * 16 + static_cast<std::size_t>(column * 4 + row)] =
                        m == 0 ? static_cast<float>(vp(row, column)) : (row == column ? 1.0f : 0.0f);
                }
            }
        }
        write(G_VIEWPORTVIEWPROJECTIONS, ShaderValue(matrices.data(), matrices.size()));
    }

    // The native draw loop publishes the offset before drawing the object.
    // Queries use that last value, never a fresh calculation. Keep zero-depth
    // draws here too: they replace a previous nonzero offset with zero.
    std::optional<Vector2d> draw_parallax;
    if (data != nullptr && m_parallax.enable && m_user_parallax &&
        m_parallax.mouseinfluence != 0.0f && camera_name != "effect" && !draw_camera->IsLayerLocal()) {
        draw_parallax = DrawParallaxOffset(node, *view_camera, data, compose_first);
        const bool local_base = !compose_first && data->parallax_layer == nullptr &&
            data->parallaxDepth[0] == 0 && data->parallaxDepth[1] == 0 && m_parallaxPasses.contains(node);
        if (!local_base && IsSceneParallaxDraw(node, material_slot, *draw_camera, data)) {
            auto* owner = data->parallax_layer != nullptr ? data->parallax_layer : node;
            owner->SetLastDrawParallaxOffset(static_cast<float>(draw_parallax->x()),
                                             static_cast<float>(draw_parallax->y()));
        }
    }
    const bool wants_model = info->has_M || info->has_AM || info->has_MI || info->has_MVP ||
                             info->has_MVPI || info->has_NORMALMODEL || info->has_ANM || info->has_AVP;
    if (wants_model) {
        Matrix4d model;
        if (compose_first) {
            model = node->ModelTrans();
        } else if (draw_camera->IsLayerLocal()) {
            model = Matrix4d::Identity();
        } else {
            model = node->RenderTrans();
        }
        if (draw_parallax) {
            model(0,3) += draw_parallax->x();
            model(1,3) += draw_parallax->y();
        }
        if (info->has_M) write(G_M, ShaderValue::fromMatrix(model));
        if (info->has_AM) {
            Matrix4d alt = model;
            if (data != nullptr) {
                alt.col(0) *= data->alt_model_scale[0];
                alt.col(1) *= data->alt_model_scale[1];
            }
            write(G_AM, ShaderValue::fromMatrix(alt));
        }
        // `PRELIGHTING` passes light with the Alt matrices: the draw's own world
        // model, its normal matrix and its view projection (the closing pass of
        // a lit layer under effects is drawn at the layer's world transform).
        if (info->has_ANM) write(G_ANM, ShaderValue(NormalMatrixLanes(model)));
        if (info->has_AVP) write(G_AVP, ShaderValue::fromMatrix(projection(view_camera, view_scene_space)));
        if (info->has_MI) write(G_MI, ShaderValue::fromMatrix(Matrix4d(model.inverse())));
        const Matrix4d mvp = projection(view_camera, view_scene_space) * model;
        if (info->has_MVP) write(G_MVP, ShaderValue::fromMatrix(mvp));
        if (info->has_MVPI) write(G_MVPI, ShaderValue::fromMatrix(Matrix4d(mvp.inverse())));
        if (info->has_NORMALMODEL) write(G_NORMALMODEL, ShaderValue(NormalMatrixLanes(model)));
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
            const Matrix4d view_projection = projection(m_scene->activeCamera, true);
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

    if (data != nullptr && data->volumetric_light != nullptr) {
        const auto& volume = *data->volumetric_light;
        if (info->has_AVP) write(G_AVP, ShaderValue::fromMatrix(volume.volume));
        if (info->has_AM) write(G_AM, ShaderValue::fromMatrix(volume.projection));
        if (info->has_effect_model) write(G_EFFECTMODEL, ShaderValue::fromMatrix(volume.camera_inverse));
        for (std::size_t i=0;i<info->has_render_var.size();++i)
            if (info->has_render_var[i]) write(kRenderVariables[i], ShaderValue(volume.parameters[i]));
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
        Vector3f right, up, forward;
        const auto orientation = data != nullptr
            ? static_cast<ParticleOrientation>(data->particle_orientation & 3u) : ParticleOrientation::Camera;
        if (orientation == ParticleOrientation::Camera) {
            const auto axes = draw_camera->GetAxes();
            right = axes.right.cast<float>(); up = axes.up.cast<float>(); forward = axes.forward.cast<float>();
        } else {
            const bool worldspace = (data->particle_orientation & kParticleOrientationWorldspace) != 0;
            const Matrix3f model = node->RenderTrans().topLeftCorner<3,3>().cast<float>();
            const auto stored = [&](std::string_view name, const Vector3f& fallback) {
                const auto found = material->customShader.constValues.find(name);
                if (found == material->customShader.constValues.end() || found->second.size() != 3) return fallback;
                return Vector3f(found->second[0],found->second[1],found->second[2]);
            };
            if (orientation == ParticleOrientation::Fixed) {
                forward = stored(G_ORIENTATIONFORWARD,Vector3f(0,1,0));
                up = stored(G_ORIENTATIONUP,Vector3f(0,0,-1));
                if (!worldspace) { forward = model*forward; up = model*up; }
            } else {
                const auto axes = draw_camera->GetAxes();
                const Vector3f camera_forward = axes.forward.cast<float>();
                if (orientation == ParticleOrientation::Upright) {
                    // Native worldspace upright uses world Y, regardless of the
                    // authored axis; local upright carries that axis by the model.
                    up = worldspace ? Vector3f(0,1,0) : Vector3f(model*stored(G_ORIENTATIONUP,Vector3f(0,1,0)));
                    right = up.cross(camera_forward);
                    forward = right.cross(up);
                } else {
                    forward = camera_forward;
                    up = worldspace ? Vector3f(axes.up.cast<float>()) : Vector3f(model.col(1));
                    up -= forward*forward.dot(up);
                }
            }
            // 0x1402298B0 transforms with the model transpose, not its inverse.
            // Normalize the three outputs independently; re-orthogonalizing up
            // would change WE's nonuniform-scale result. A degenerate upright
            // axis produces non-finite right/forward in WE, not a fixed fallback.
            forward = model.transpose()*forward;
            up = model.transpose()*up;
            right = up.cross(forward);
            const auto normalize = [](const Vector3f& value) {
                const float inverse = 1.0f/std::sqrt(value.squaredNorm());
                return Vector3f(value.x()*inverse,value.y()*inverse,value.z()*inverse);
            };
            forward = normalize(forward); right = normalize(right); up = normalize(up);
        }
        const auto put = [&](std::string_view name, const Vector3f& value) {
            write(name, Vec({value.x(),value.y(),value.z()}));
        };
        if (info->has_ORIENTATIONRIGHT) put(G_ORIENTATIONRIGHT,right);
        if (info->has_ORIENTATIONUP) put(G_ORIENTATIONUP,up);
        if (info->has_ORIENTATIONFORWARD) put(G_ORIENTATIONFORWARD,forward);
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
            if (info->has_VIEWFORWARD) {
                // The native reflected scene updates eye/right/up and matrices,
                // while this shader binding retains the ordinary camera forward.
                const auto* forward_camera = eye_camera == m_scene->reflection.camera.get()
                    && m_scene->reflection.source_camera
                    ? m_scene->reflection.source_camera : eye_camera;
                put(G_VIEWFORWARD, forward_camera->GetDirection());
            }
            if (info->has_VIEWUP) put(G_VIEWUP, eye_camera->GetUp());
            if (info->has_VIEWRIGHT) put(G_VIEWRIGHT, eye_camera->GetRight());
        }
    }

    // ---- lights
    if (info->has_LP || info->has_LCP || info->has_LCR) {
        const auto& legacy = PackedLights(false).legacy;
        write(G_LP, ShaderValue(legacy.positions.data(), legacy.positions.size()));
        write(G_LCP, ShaderValue(legacy.colors.data(), legacy.colors.size()));
        if (info->has_LCR) {
            write(G_LCR, ShaderValue(legacy.color_radius.data(), legacy.color_radius.size()));
        }
    }
    if (info->has_LIGHTS_V1) {
        const auto& lights = PackedLights(true).modern;
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

    if (info->has_SHADOW_FEATURES && (m_scene->shadows.active() || m_scene->shadows.cookie_features)) {
        const auto& shadows = m_scene->shadows;
        const std::array<std::pair<std::string_view, const std::vector<float>*>, 4> arrays { {
            { G_LFEATURE_SHADOWPROJECTION, &shadows.projection },
            { G_LFEATURE_SHADOWPROJECTIONTRANSFORM, &shadows.projection_transform },
            { G_LFEATURE_SHADOWPOINTPROJECTION, &shadows.point_projection },
            { G_LFEATURE_SHADOWPOINTTRANSFORM, &shadows.point_transform },
        } };
        for (const auto& [name, values] : arrays) {
            if (values->empty()) continue;
            write(name, ShaderValue(values->data(), values->size()));
        }
    }

    // ---- audio spectrum, one value per vec4 element
    if (ReadsAudioSpectrum(*info)) {
        static const audio::AudioSpectrumSnapshot silence {};
        const audio::AudioSpectrumSnapshot& snapshot =
            m_scene->runtime != nullptr ? m_scene->runtime->CurrentAudioSpectrumSnapshot() : silence;
        ForEachBoundSpectrum(*info, snapshot, [&](std::string_view name, std::span<const float> bands) {
            m_audioPack.assign(bands.size() * 4, 0.0f);
            for (std::size_t i = 0; i < bands.size(); ++i) m_audioPack[i * 4] = bands[i];
            write(name, ShaderValue(m_audioPack.data(), m_audioPack.size()));
        });
    }
}

std::optional<uint64_t> WPShaderValueUpdater::AudioStateHash(SceneNode* node,
                                                             uint32_t material_slot) const {
    if (m_scene == nullptr || node == nullptr) return std::nullopt;
    const WPUniformInfo* info = FindUniformInfo(node, material_slot);
    // No record is no evidence that it reads no audio.
    if (info == nullptr) return std::nullopt;
    if (! ReadsAudioSpectrum(*info)) return 0;
    const auto* runtime = m_scene->runtime.get();
    // Before the host's first frame every read takes the newest analysis, so this one need
    // not be the one the uniforms were given.
    if (runtime != nullptr && ! runtime->AudioSpectrumHeldPerFrame()) return std::nullopt;
    static const audio::AudioSpectrumSnapshot silence {};
    const audio::AudioSpectrumSnapshot& snapshot =
        runtime != nullptr ? runtime->CurrentAudioSpectrumSnapshot() : silence;
    uint64_t hash = 0xcbf29ce484222325ULL;
    ForEachBoundSpectrum(*info, snapshot, [&hash](std::string_view, std::span<const float> bands) {
        hash = HashBands(hash, bands);
    });
    return hash;
}

void WPShaderValueUpdater::UpdateSprites(SceneNode* node, sprite_map_t& sprites,
                                         const UpdateUniformOp& write) {
    bool        reported = false;
    const auto& command  = node->PendingSheetCommand();
    const bool  detached = node->SheetDetached();
    const double step    = node->TextureAnimationStep(m_scene->frameTime);
    for (auto& [slot, animation] : sprites) {
        if (animation.FrameCount() == 0 || ! SlotInRange(static_cast<uint32_t>(slot))) continue;
        // A script command lands on the frame last drawn, before this frame's time.
        animation.Command(command.serial, command.copy_clock, command.frame);
        const SpriteFrame* frame = &animation.Present(m_scene->frameTime, detached, step);
        if (! reported) {
            reported = true;
            node->SetTextureAnimationFrame(static_cast<double>(animation.CurFrameIndex()));
            node->SetSheetCommandDrawn(command.serial);
        }
        write(WE_GLTEX_ROTATION_NAMES[slot],
              Vec({ frame->xAxis[0], frame->xAxis[1], frame->yAxis[0], frame->yAxis[1] }));
        write(WE_GLTEX_TRANSLATION_NAMES[slot], Vec({ frame->x, frame->y }));
    }
}


SceneNode* WPShaderValueUpdater::ParallaxRoot(const SceneNode* node,
                                                 const WPShaderValueData* data) const {
    SceneNode* start = data != nullptr && data->parallax_layer != nullptr
        ? data->parallax_layer : const_cast<SceneNode*>(node);
    SceneNode* root = start;
    if (m_scene != nullptr && !start->IgnoresParentTransform()) {
        const auto* scene_root = m_scene->sceneGraph.get();
        while (root->Parent() != nullptr && root->Parent() != scene_root) root = root->Parent();
    }
    return root;
}

std::array<float,2> WPShaderValueUpdater::EffectiveParallaxDepth(
        const SceneNode* node, const WPShaderValueData* data, bool compose_first) const {
    const SceneNode* owner = data != nullptr && data->parallax_layer != nullptr
        ? data->parallax_layer : node;
    const SceneNode* root = m_parallax.canvas_scene ? ParallaxRoot(node,data) : owner;
    // A fullscreen layer keeps its raw transform/depth for children but its own
    // screen-filling draw stays fixed. Its material records already carry zero.
    if (owner->HasChildFrame() && owner->IgnoresParentTransform() && data != nullptr)
        return data->parallaxDepth;
    // An ordinary effect layer's first pass is explicitly still; a compose
    // first pass instead reads the screen at the closing card's shifted place.
    if (!compose_first && data != nullptr && data->parallax_layer == nullptr &&
        data->parallaxDepth[0] == 0 && data->parallaxDepth[1] == 0 && m_parallaxPasses.contains(owner))
        return data->parallaxDepth;
    if (root->HasParallaxDepth()) return root->ParallaxDepth();
    if (root != owner && (FindNodeData(root,0) != nullptr || m_parallaxPasses.contains(root)))
        return NodeParallaxDepth(root);
    // Only compose placeholders borrow the effect records. A real own record
    // written to zero must not be revived by an older effect-pass depth.
    if (compose_first && (data == nullptr || data->parallax_layer == nullptr))
        return NodeParallaxDepth(owner);
    if (owner->HasParallaxDepth()) return owner->ParallaxDepth();
    return data != nullptr ? data->parallaxDepth : std::array<float,2>{0,0};
}

Vector2d WPShaderValueUpdater::DrawParallaxOffset(SceneNode* node, const SceneCamera& camera,
                                                  const WPShaderValueData* data, bool compose_first) const {
    const auto* owner = data != nullptr && data->parallax_layer != nullptr ? data->parallax_layer : node;
    SceneNode* root = m_parallax.canvas_scene ? ParallaxRoot(node,data) : node;
    root->UpdateTrans();
    const Matrix4d frame = m_parallax.canvas_scene
        ? (root != owner && root->HasChildFrame() ? root->ChildTrans() : root->ModelTrans())
        : node->RenderTrans();
    const auto* depth_owner = m_parallax.canvas_scene ? root : owner;
    const bool fixed_owner = owner->HasChildFrame() && owner->IgnoresParentTransform();
    const bool local_base = !compose_first && data != nullptr && data->parallax_layer == nullptr &&
        data->parallaxDepth[0] == 0 && data->parallaxDepth[1] == 0 && m_parallaxPasses.contains(owner);
    const auto depth = !fixed_owner && !local_base && depth_owner->HasParallaxDepth()
        ? depth_owner->ParallaxDepth() : EffectiveParallaxDepth(node,data,compose_first);
    const auto camera_at = camera.GetPosition();
    const double influence = m_parallax.mouseinfluence, amount = m_parallax.amount;
    const double mouse_x = (0.5-m_parallaxPos[0])*m_scene->ortho[0]*influence;
    const double mouse_y = -(0.5-m_parallaxPos[1])*m_scene->ortho[1]*influence;
    return {(mouse_x+frame(0,3)-camera_at.x())*depth[0]*amount,
            (mouse_y+frame(1,3)-camera_at.y())*depth[1]*amount};
}

bool WPShaderValueUpdater::IsSceneParallaxDraw(SceneNode* node, uint32_t slot,
        const SceneCamera& camera, const WPShaderValueData* data) const {
    if (camera.IsLayerLocal() || node->Camera() == "effect") return false;
    const auto& casters = node->ShadowCasterSlots();
    if (std::find(casters.begin(),casters.end(),slot) != casters.end()) return false;
    const auto* owner = data != nullptr && data->parallax_layer != nullptr ? data->parallax_layer : node;
    return owner->EffectiveVisible() || owner->MustProduce();
}

void WPShaderValueUpdater::SceneDrawWithoutUniforms(SceneNode* node, uint32_t slot,
                                                     const std::string& camera_override) {
    if (node == nullptr || m_scene == nullptr || !m_parallax.enable || !m_user_parallax ||
        m_parallax.mouseinfluence == 0.0f) return;
    const auto& name = camera_override.empty() ? node->Camera() : camera_override;
    const auto* camera = CameraNamed(name);
    const auto* data = FindNodeData(node,slot);
    if (camera == nullptr || data == nullptr || name == "effect" ||
        !IsSceneParallaxDraw(node,slot,*camera,data)) return;
    const auto* material = node->Mesh() != nullptr ? node->Mesh()->MaterialForSlot(slot) : nullptr;
    const bool compose_first = material != nullptr && SamplesScreenBackground(*material);
    if (!compose_first && data->parallax_layer == nullptr && data->parallaxDepth[0] == 0 &&
        data->parallaxDepth[1] == 0 && m_parallaxPasses.contains(node)) return;
    const auto offset = DrawParallaxOffset(node,*camera,data,compose_first);
    auto* owner = data->parallax_layer != nullptr ? data->parallax_layer : node;
    owner->SetLastDrawParallaxOffset(static_cast<float>(offset.x()), static_cast<float>(offset.y()));
}

Matrix4d WPShaderValueUpdater::ModelForProjection(SceneNode* node, const SceneCamera&) const {
    node->UpdateTrans();
    Matrix4d model = node->ModelTrans();
    model.block<3,1>(0,3) += node->DrawOffset().cast<double>();
    const auto offset = node->LastDrawParallaxOffset();
    model(0,3) += offset[0];
    model(1,3) += offset[1];
    return model;
}

Vector2d WPShaderValueUpdater::CursorParallaxOffset(SceneNode* node, const SceneCamera& camera) const {
    if (node == nullptr || m_scene == nullptr || !m_parallax.canvas_scene ||
        !m_parallax.enable || !m_user_parallax || m_parallax.amount == 0 ||
        m_parallax.mouseinfluence == 0) return Vector2d::Zero();
    const auto* data = FindNodeData(node,0);
    if (data == nullptr) return Vector2d::Zero();
    const auto& view = camera.IsLayerLocal() && m_scene->activeCamera != nullptr
        ? *m_scene->activeCamera : camera;
    // The hit belongs to the closing card, even when its own first pass draws
    // into a layer-local buffer and therefore carries zero draw depth.
    return DrawParallaxOffset(node,view,data,true);
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

void WPShaderValueUpdater::SetRenderTargetBinding(SceneNode* node, uint32_t material_slot,
                                                   uint32_t texture_slot, std::string_view target) {
    const auto object = m_nodeDataMap.find(node);
    if (object == m_nodeDataMap.end()) return;
    const auto material = object->second.find(material_slot);
    if (material == object->second.end()) return;
    for (auto& [slot, key] : material->second.renderTargets) {
        if (slot == texture_slot) key = target;
    }
}

void WPShaderValueUpdater::SetNodeShadowTargets(void* node, uint32_t slot,
                                                const std::vector<std::size_t>& slots, bool enabled) {
    auto& targets = m_nodeDataMap[node][slot].renderTargets;
    for (const auto index : slots) {
        std::erase_if(targets, [index](const auto& entry) { return entry.first == index; });
        if (enabled) targets.emplace_back(index, std::string(kShadowAtlas));
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
    const auto* root = m_parallax.canvas_scene ? ParallaxRoot(node,nullptr) : node;
    const auto inherited_depth = [&] {
        if (root->HasParallaxDepth() || FindNodeData(root,0) != nullptr || m_parallaxPasses.contains(root))
            return NodeParallaxDepth(root);
        return EffectiveParallaxDepth(node,FindNodeData(node,0),true);
    };
    const auto before = inherited_depth();
    node->SetParallaxDepth(x,y);
    // A parent changes the effective depth of its descendants through the root
    // lookup. Their own raw values must survive reparenting and detaching.
    const auto passes = m_parallaxPasses.find(node);
    if (!(node->HasChildFrame() && node->IgnoresParentTransform())) {
        if (passes != m_parallaxPasses.end() && !passes->second.empty()) {
            for (void* pass : passes->second) write_all(pass,false);
        } else {
            // A parsed group has no draw metadata and needs none just to hold its
            // raw depth. Keep support for a manually made draw's first setter.
            write_all(node,node->Mesh() != nullptr);
        }
    }
    const auto after = inherited_depth();
    changed = (before[0] != 0 || before[1] != 0) != (after[0] != 0 || after[1] != 0);
    return changed;
}

// A layer drawn through effects holds its depth on the passes, not on its own
// node, so those are asked first.
std::array<float, 2> WPShaderValueUpdater::NodeParallaxDepth(const SceneNode* node) const {
    if (node != nullptr && node->HasParallaxDepth()) return node->ParallaxDepth();
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
    ForgetPuppetAttachment(node);
    std::erase_if(m_textureChannels, [node](const PuppetTextureChannels& channels) {
        return channels.owner == node || channels.painter == node;
    });
}

void WPShaderValueUpdater::SetTexelSize(float x, float y) {
    // A texel that is not a positive number would put infinities in every neighbour tap.
    if (! std::isfinite(x) || ! std::isfinite(y) || x <= 0.0f || y <= 0.0f) return;
    m_texelSize = { x, y };
}
