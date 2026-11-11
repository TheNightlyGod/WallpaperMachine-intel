// Shadow views and the shadow atlas, as Wallpaper Engine 2.8.0.42 lays them out and fills
// them (sub_140190C80, sub_14025D420, sub_14025D3E0,
// sub_14025D370, sub_140169140).
#include "SceneShadows.hpp"
#include "Scene.h"
#include "SceneCamera.h"
#include "SceneNode.h"
#include "SceneMesh.h"
#include "WPShaderValueUpdater.hpp"
#include "Utils/Linalg.hpp"

#include <algorithm>
#include <cmath>

using namespace wallpaper;
using namespace wallpaper::linalg;

namespace
{
constexpr double kDegrees = 3.14159265358979323846 / 180.0;

/// Spot features: one per spot of a shadow or cookie subset.
std::size_t SpotFeatures(const SceneLightConfig& config) {
    return config.spot_shadow_cookie + config.spot_cookie + config.spot_shadow;
}

bool SpotSlotIsShadowed(const SceneLightConfig& config, std::size_t slot) {
    if (slot < config.spot_shadow_cookie) return true;
    const std::size_t shadow_at = config.spot_shadow_cookie + config.spot_cookie;
    return slot >= shadow_at && slot < shadow_at + config.spot_shadow;
}

Vector3d Normalized(const Vector3d& v, const Vector3d& fallback) {
    const double length = v.norm();
    return length > 1e-12 ? Vector3d(v / length) : fallback;
}

/// A right-handed view at `eye` looking along `forward` with `up` as near as possible to up.
Matrix4d LookAlong(const Vector3d& eye, const Vector3d& forward, const Vector3d& up_hint) {
    const Vector3d z = -Normalized(forward, Vector3d(0.0, 0.0, -1.0));
    Vector3d       y = up_hint - z * up_hint.dot(z);
    y                = Normalized(y, std::abs(z.y()) < 0.9 ? Vector3d(0.0, 1.0, 0.0) : Vector3d(1.0, 0.0, 0.0));
    if (y.squaredNorm() < 0.5) y = Normalized(Vector3d(1.0, 0.0, 0.0) - z * z.x(), Vector3d(0.0, 1.0, 0.0));
    const Vector3d x = y.cross(z);
    Matrix4d       view = Matrix4d::Identity();
    view.block<1, 3>(0, 0) = x.transpose();
    view.block<1, 3>(1, 0) = y.transpose();
    view.block<1, 3>(2, 0) = z.transpose();
    view(0, 3)             = -x.dot(eye);
    view(1, 3)             = -y.dot(eye);
    view(2, 3)             = -z.dot(eye);
    return view;
}

/// Wallpaper Engine's six point-light face views, copied from `CalculateProjectedCoordsPoint`
/// (common_pbr_2.h): each `mat4(...)` group is a column, faces +x -x +y -y +z -z.
Matrix4d PointFaceView(std::size_t face, const Vector3d& o) {
    const std::array<std::array<double, 16>, 6> groups { {
        { 0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, -o.z(), -o.y(), o.x(), 1 },
        { 0, 0, 1, 0, 0, 1, 0, 0, -1, 0, 0, 0, o.z(), -o.y(), -o.x(), 1 },
        { 1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, -o.x(), -o.z(), o.y(), 1 },
        { 1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, -o.x(), o.z(), -o.y(), 1 },
        { -1, 0, 0, 0, 0, 1, 0, 0, 0, 0, -1, 0, o.x(), -o.y(), o.z(), 1 },
        { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -o.x(), -o.y(), -o.z(), 1 },
    } };
    Matrix4d view;
    for (int column = 0; column < 4; ++column)
        for (int row = 0; row < 4; ++row) view(row, column) = groups[face][column * 4 + row];
    return view;
}

/// The viewport cell of point face `face`: (column, row) of a 2 by 3 grid.
constexpr std::array<std::array<uint32_t, 2>, 6> kPointFaceCells { { { 0, 0 }, { 1, 0 }, { 0, 1 },
                                                                      { 1, 1 }, { 0, 2 }, { 1, 2 } } };

/// Point-light fov by quality (dword_1404928F4/F0/EC).
double PointFov(int quality) {
    if (quality == 1 || quality == 2) return 94.0;
    if (quality == 3) return 92.0;
    return 91.2;
}

std::array<float, 4> TileTransform(const ShadowTile& tile, uint32_t w, uint32_t h) {
    return { static_cast<float>(tile.x) / static_cast<float>(w), static_cast<float>(tile.y) / static_cast<float>(h),
             static_cast<float>(tile.size) / static_cast<float>(w),
             static_cast<float>(tile.size) / static_cast<float>(h) };
}

void PutMatrix(std::vector<float>& array, std::size_t slot, const Matrix4d& m) {
    for (int column = 0; column < 4; ++column)
        for (int row = 0; row < 4; ++row)
            array[slot * 16 + static_cast<std::size_t>(column * 4 + row)] = static_cast<float>(m(row, column));
}

void PutVec4(std::vector<float>& array, std::size_t slot, const std::array<float, 4>& v) {
    std::copy(v.begin(), v.end(), array.begin() + static_cast<std::ptrdiff_t>(slot * 4));
}

struct SpotFrame {
    Matrix4d view_projection;
};

Matrix4d LightWorld(const SceneLight& light) {
    auto* node = light.node();
    node->UpdateTrans();
    return node->ModelTrans();
}

/// sub_14025D420: a spot light's view from its world axes (it shines along +x), fov 2 x the
/// outer cone, aspect 1, near 1 in a 2D scene else 0.05, far max(radius, near + 0.01).
Matrix4d SpotViewProjection(const SceneLight& light, bool ortho_scene) {
    const Matrix4d world = LightWorld(light);
    const double   near  = ortho_scene ? 1.0 : 0.05;
    const double   far   = std::max<double>(light.radius(), near + 0.01);
    const Matrix4d view  = LookAlong(world.block<3, 1>(0, 3), world.block<3, 1>(0, 0),
                                     world.block<3, 1>(0, 1));
    return ReversedPerspective(2.0 * light.outerCone(), near, far) * view;
}

Matrix4d PointProjection(const SceneLight& light, bool ortho_scene, int quality) {
    const double near = ortho_scene ? 1.0 : std::max(0.05, static_cast<double>(light.sourceSize()));
    const double far  = std::max<double>(light.radius(), near + 0.01);
    return ReversedPerspective(PointFov(quality), near, far);
}

/// sub_14025D370 and the packer (0x14019125c..0x140192a0e): cascade `c` of a directional
/// light, `(extent, depth)` = (cd0, 4 cd1), (cd1, 4 cd1), (cd2, max(1.5 cd2, 4 cd1)); centred
/// half an extent ahead of the camera, snapped to the tile's texels across the light, an
/// orthographic view along the light, depth -depth/2 .. +depth/2, reversed.
Matrix4d CascadeViewProjection(const Scene& scene, const SceneLight& light, uint8_t cascade,
                               uint32_t tile, bool ortho_scene) {
    const auto     cd     = light.cascadeDistances();
    const double   cd0 = cd[0], cd1 = cd[1], cd2 = cd[2];
    const std::array<std::array<double, 2>, 3> cascades { { { cd0, 4.0 * cd1 },
                                                           { cd1, 4.0 * cd1 },
                                                           { cd2, std::max(1.5 * cd2, 4.0 * cd1) } } };
    const double   extent = std::max(cascades[cascade][0], 1e-3);
    const double   depth  = std::max(cascades[cascade][1], 1e-3);
    const Matrix4d world  = LightWorld(light);
    const Vector3d along  = Normalized(world.block<3, 1>(0, 0), Vector3d(1.0, 0.0, 0.0));
    Vector3d       eye(0.0, 0.0, 0.0), forward(0.0, 0.0, -1.0);
    if (scene.activeCamera != nullptr) {
        eye     = scene.activeCamera->GetPosition();
        forward = scene.activeCamera->GetDirection();
    }
    Vector3d centre = eye + (forward - 0.5 * forward.dot(along) * along) * (extent * 0.5);
    if (ortho_scene) centre.z() = 0.0;
    Matrix4d view = LookAlong(centre, along, world.block<3, 1>(0, 1));
    // [INFERENCE] sub_14041D0C0 snaps the centre across the light to whole texels.
    const double texel = extent / std::max<uint32_t>(tile, 1);
    for (int axis = 0; axis < 2; ++axis) view(axis, 3) = std::floor(view(axis, 3) / texel) * texel;
    Matrix4d projection   = Matrix4d::Identity();
    projection(0, 0)      = 2.0 / extent;
    projection(1, 1)      = 2.0 / extent;
    projection(2, 2)      = 1.0 / depth;
    projection(2, 3)      = 0.5;
    return projection * view;
}

/// The caster's copy of a non-point view: clip z offset by -0.0005 (row-major element 14,
/// 0x14019632a dword_140492604), a nudge toward the far plane of reversed depth.
Matrix4d CasterOffset(Matrix4d vp) {
    vp(2, 3) -= 0.0005;
    return vp;
}
} // namespace

Matrix4d wallpaper::ScenePointShadowProjection(const SceneLight& light, bool ortho_scene, int quality) {
    return PointProjection(light, ortho_scene, quality);
}

Matrix4d wallpaper::SceneVolumeProjection(const SceneLight& light, bool ortho_scene) {
    Matrix4d projection=SpotViewProjection(light,ortho_scene);
    projection.row(2)=projection.row(3)-projection.row(2);
    return projection;
}

Matrix4d wallpaper::ReversedPerspective(double fov_y_degrees, double near, double far) {
    const double scale = 1.0 / std::tan(fov_y_degrees * kDegrees * 0.5);
    Matrix4d     m     = Matrix4d::Zero();
    m(0, 0)            = scale;
    m(1, 1)            = scale;
    m(2, 2)            = near / (far - near);
    m(2, 3)            = near * far / (far - near);
    m(3, 2)            = -1.0;
    return m;
}

void wallpaper::PackSceneLights(const Scene& scene, std::vector<PackedSceneLight>& packed) {
    const auto&    config  = scene.light_config;
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

    std::array<std::size_t, 4> spot_at;
    spot_at[3] = 0;
    spot_at[2] = config.spot_shadow_cookie;
    spot_at[1] = spot_at[2] + config.spot_cookie;
    spot_at[0] = spot_at[1] + config.spot_shadow;
    std::array<std::size_t, 2> point_at { config.point_shadow, 0 };
    std::array<std::size_t, 2> dir_at { config.directional_shadow, 0 };
    uint32_t points_left = config.point, spots_left = config.spot, dirs_left = config.directional;
    std::size_t tube = 0;

    packed.clear();
    for (const auto& entry : sorted) {
        const uint32_t flags = entry.light->flags();
        std::size_t    slot  = PackedSceneLight::kNoSlot;
        switch (entry.light->type()) {
        case SceneLightType::Point:
            if (points_left == 0) break;
            --points_left;
            slot = point_at[shadows ? (flags & 1u) : 0u]++;
            if (slot >= config.point) slot = PackedSceneLight::kNoSlot;
            break;
        case SceneLightType::Spot:
            if (spots_left == 0) break;
            --spots_left;
            slot = spot_at[((shadows ? 1u : 0u) + 2u) & flags]++;
            if (slot >= config.spot) slot = PackedSceneLight::kNoSlot;
            break;
        case SceneLightType::Tube:
            if (tube < config.tube) slot = tube++;
            break;
        case SceneLightType::Directional:
            if (dirs_left == 0) break;
            --dirs_left;
            slot = dir_at[shadows ? (flags & 1u) : 0u]++;
            if (slot >= config.directional) slot = PackedSceneLight::kNoSlot;
            break;
        case SceneLightType::Legacy: break;
        }
        packed.push_back({ entry.light, slot });
    }
}

uint32_t wallpaper::ShadowTileSize(int shadows_quality) {
    switch (shadows_quality) {
    case 0: return 0;
    case 1:
    case 2: return 256;
    case 3: return 512;
    default: return 1024;
    }
}

ShadowAtlasPacking wallpaper::PackShadowAtlas(std::span<const uint32_t> sizes) {
    struct Segment {
        uint32_t x, limit, y, bottom;
    };
    std::vector<Segment> segments { { 0, 0x2000, 0, 0 } };
    ShadowAtlasPacking   packing;
    uint32_t             width = 0, height = 0;
    for (const uint32_t s : sizes) {
        ShadowTile tile { 0, 0, s };
        for (std::size_t i = 0; i < segments.size(); ++i) {
            Segment& seg = segments[i];
            seg.bottom   = std::max(seg.bottom, seg.y + s);
            if (seg.limit - seg.x >= s && seg.bottom - seg.y >= s) {
                tile.x = seg.x;
                tile.y = seg.y;
                width  = std::max(width, seg.x + s);
                height = std::max(height, seg.y + s);
                const Segment below { seg.x, seg.x + s, seg.y + s, seg.bottom };
                seg.x += s;
                segments.push_back(below);
                break;
            }
            const uint32_t bottom = seg.bottom;
            segments.push_back({ 0, 0x2000, bottom, bottom });
        }
        packing.tiles.push_back(tile);
    }
    packing.width  = std::max(width, 2u);
    packing.height = std::max(height, 2u);
    return packing;
}

std::string wallpaper::ShadowCameraKey(std::size_t view, std::size_t face) {
    return "__shadow_view_" + std::to_string(view) + "_" + std::to_string(face);
}

namespace {
void SizeLightFeatures(Scene& scene) {
    auto& state = scene.shadows;
    const auto& config = scene.light_config;
    state.cookie_features = config.spot_cookie + config.spot_shadow_cookie != 0;
    const std::size_t features = state.active() ? SpotFeatures(config) + 3 * config.directional_shadow
        : state.cookie_features ? SpotFeatures(config) : 0;
    state.projection.resize(features * 16, 0.0f);
    state.projection_transform.resize(state.active() ? features * 4 : 0, 0.0f);
    state.point_projection.resize(state.active() ? config.point_shadow * 4 : 0, 0.0f);
    state.point_transform.resize(state.active() ? config.point_shadow * 4 : 0, 0.0f);
}
} // namespace

void wallpaper::PlanSceneShadows(Scene& scene, bool ortho_scene) {
    auto& state        = scene.shadows;
    for (const auto& view : state.views)
        for (const auto& camera : view.cameras) scene.cameras.erase(camera);
    state.views.clear();
    state.projection.clear(); state.projection_transform.clear();
    state.point_projection.clear(); state.point_transform.clear();
    state.atlas_width = state.atlas_height = 0;
    state.ortho_scene  = ortho_scene;
    state.quality      = scene.quality.shadows;
    const uint32_t size = ShadowTileSize(scene.quality.shadows);
    if (size == 0) { SizeLightFeatures(scene); UpdateSceneShadows(scene); return; }
    const auto& config = scene.light_config;
    // Views in the packer's light order: each light with castshadow and a shadow slot.
    thread_local std::vector<PackedSceneLight> lights;
    PackSceneLights(scene, lights);
    for (const auto& packed : lights) {
        const SceneLight& light = *packed.light;
        if ((light.flags() & SceneLight::kCastShadow) == 0 || packed.slot == PackedSceneLight::kNoSlot) continue;
        switch (light.type()) {
        case SceneLightType::Point:
            if (packed.slot < config.point_shadow)
                state.views.push_back({ &light, ShadowViewKind::Point, 0, packed.slot });
            break;
        case SceneLightType::Spot:
            if (SpotSlotIsShadowed(config, packed.slot))
                state.views.push_back({ &light, ShadowViewKind::Spot, 0, packed.slot });
            break;
        case SceneLightType::Directional:
            if (packed.slot < config.directional_shadow) {
                for (uint8_t c = 0; c < 3; ++c)
                    state.views.push_back({ &light, ShadowViewKind::Directional, c, packed.slot });
            }
            break;
        default: break;
        }
    }
    if (state.views.empty()) { SizeLightFeatures(scene); UpdateSceneShadows(scene); return; }
    const std::vector<uint32_t> sizes(state.views.size(), size);
    const auto packing = PackShadowAtlas(sizes);
    state.peak_width = std::max(state.peak_width, packing.width);
    state.peak_height = std::max(state.peak_height, packing.height);
    state.atlas_width  = state.peak_width;
    state.atlas_height = state.peak_height;
    const double w = state.atlas_width, h = state.atlas_height;
    for (std::size_t v = 0; v < state.views.size(); ++v) {
        auto& view = state.views[v];
        view.tile  = packing.tiles[v];
        const ShadowTile& t = view.tile;
        if (view.kind == ShadowViewKind::Point) {
            for (std::size_t face = 0; face < 6; ++face) {
                const uint32_t fw = t.size >> 1, fh = t.size / 3;
                const auto     cell = kPointFaceCells[face];
                view.viewports.push_back({ static_cast<float>((t.x + cell[0] * fw) / w),
                                           static_cast<float>((t.y + cell[1] * fh) / h),
                                           static_cast<float>(fw / w), static_cast<float>(fh / h) });
                view.cameras.push_back(ShadowCameraKey(v, face));
            }
        } else {
            view.viewports.push_back({ static_cast<float>(t.x / w), static_cast<float>(t.y / h),
                                       static_cast<float>(t.size / w), static_cast<float>(t.size / h) });
            view.cameras.push_back(ShadowCameraKey(v, 0));
        }
        for (const auto& key : view.cameras)
            scene.cameras[key] = std::make_shared<SceneCamera>(1.0f, 0.05f, 1.0f, 90.0f);
    }
    SizeLightFeatures(scene);
    UpdateSceneShadows(scene);
}

void wallpaper::UpdateSceneShadows(Scene& scene) {
    auto& state = scene.shadows;
    if (!state.active() && !state.cookie_features) return;
    const auto& config = scene.light_config;
    const uint32_t w = state.atlas_width, h = state.atlas_height;
    std::fill(state.projection.begin(), state.projection.end(), 0.0f);
    std::fill(state.projection_transform.begin(), state.projection_transform.end(), 0.0f);
    std::fill(state.point_projection.begin(), state.point_projection.end(), 0.0f);
    std::fill(state.point_transform.begin(), state.point_transform.end(), 0.0f);

    const auto view_of = [&](ShadowViewKind kind, std::size_t slot,
                             const SceneLight* light, uint8_t cascade) -> const ShadowView* {
        for (auto& view : state.views) {
            if (view.kind != kind || view.slot != slot || view.cascade != cascade) continue;
            view.light = light;
            return &view;
        }
        return nullptr;
    };
    const auto set_camera = [&](const std::string& key, const Matrix4d& vp) {
        if (const auto found = scene.cameras.find(key); found != scene.cameras.end())
            found->second->SetViewProjectionOverride(vp);
    };

    const std::size_t spot_features = SpotFeatures(config);
    thread_local std::vector<PackedSceneLight> lights;
    PackSceneLights(scene, lights);
    const SceneLight* cookie = nullptr;
    for (const auto& packed : lights) {
        if (packed.slot == PackedSceneLight::kNoSlot) continue;
        const SceneLight& light = *packed.light;
        switch (light.type()) {
        case SceneLightType::Spot: {
            if ((light.flags() & SceneLight::kUseCookie) != 0) cookie = &light;
            if (packed.slot >= spot_features) break;
            const Matrix4d vp = SpotViewProjection(light, state.ortho_scene);
            PutMatrix(state.projection, packed.slot, vp);
            if (const ShadowView* view = view_of(ShadowViewKind::Spot, packed.slot, &light, 0);
                view != nullptr && SpotSlotIsShadowed(config, packed.slot)) {
                PutVec4(state.projection_transform, packed.slot, TileTransform(view->tile, w, h));
                set_camera(view->cameras[0], CasterOffset(vp));
            }
            break;
        }
        case SceneLightType::Point: {
            if (packed.slot >= config.point_shadow) break;
            const ShadowView* view = view_of(ShadowViewKind::Point, packed.slot, &light, 0);
            if (view == nullptr) break;
            const Matrix4d projection = PointProjection(light, state.ortho_scene, state.quality);
            // The shader's `project` matrix from (m22, m32, m23, m33) of the row-major projection.
            PutVec4(state.point_projection, packed.slot,
                    { static_cast<float>(projection(2, 2)), static_cast<float>(projection(2, 3)),
                      static_cast<float>(projection(3, 2)), static_cast<float>(projection(3, 3)) });
            PutVec4(state.point_transform, packed.slot, TileTransform(view->tile, w, h));
            const Vector3d origin = LightWorld(light).block<3, 1>(0, 3);
            for (std::size_t face = 0; face < view->cameras.size(); ++face)
                set_camera(view->cameras[face], projection * PointFaceView(face, origin));
            break;
        }
        case SceneLightType::Directional: {
            if (packed.slot >= config.directional_shadow) break;
            for (uint8_t c = 0; c < 3; ++c) {
                const ShadowView* view = view_of(ShadowViewKind::Directional, packed.slot, &light, c);
                if (view == nullptr) continue;
                const Matrix4d vp = CascadeViewProjection(scene, light, c, view->tile.size, state.ortho_scene);
                const std::size_t feature = spot_features + 3 * packed.slot + c;
                PutMatrix(state.projection, feature, vp);
                PutVec4(state.projection_transform, feature, TileTransform(view->tile, w, h));
                set_camera(view->cameras[0], CasterOffset(vp));
            }
            break;
        }
        default: break;
        }
    }
    if (state.cookie_light != cookie) {
        state.cookie_light = cookie;
        scene.renderTargetAliases[kLightCookieAlias] = cookie != nullptr && !cookie->cookie().empty()
            ? cookie->cookie() : "_rt_lightCookie";
    }
}

ShadowVariantKey wallpaper::SceneShadowVariantKey(const Scene& scene) {
    const auto& c = scene.light_config;
    return { c.point, c.spot, c.tube, c.directional, c.point_shadow, c.spot_shadow,
             c.spot_cookie, c.spot_shadow_cookie, c.directional_shadow,
             static_cast<uint32_t>(scene.quality.shadows) };
}

void wallpaper::RefreshSceneShadows(Scene& scene) {
    auto& state = scene.shadows;
    if (!state.enabled || !state.dirty) return;
    state.dirty = false;
    // Do not prepare caster shaders until a visible light owns a shadow slot.
    // This also keeps lazy shader sessions out of an initial parse with no shadows.
    bool light = false;
    if (scene.quality.shadows != 0) {
        thread_local std::vector<PackedSceneLight> lights;
        PackSceneLights(scene, lights);
        const auto& c = scene.light_config;
        for (const auto& packed : lights) {
            if ((packed.light->flags() & SceneLight::kCastShadow) == 0 ||
                packed.slot == PackedSceneLight::kNoSlot) continue;
            switch (packed.light->type()) {
            case SceneLightType::Point: light = packed.slot < c.point_shadow; break;
            case SceneLightType::Spot: light = SpotSlotIsShadowed(c, packed.slot); break;
            case SceneLightType::Directional: light = packed.slot < c.directional_shadow; break;
            default: break;
            }
            if (light) break;
        }
    }
    bool caster = false;
    const auto key = SceneShadowVariantKey(scene);
    for (auto& entry : state.casters) {
        if (!light) break;
        const auto node = entry.node.lock();
        if (!node || !node->CastsShadow() || !node->EffectiveVisible()) continue;
        if (!entry.attempted || entry.key != key) {
            if (entry.prepare) entry.prepare();
            entry.attempted = true;
            entry.key = key;
        }
        caster = caster || (node->Mesh() != nullptr && !node->ShadowCasterSlots().empty());
    }
    if (caster) {
        PlanSceneShadows(scene, state.ortho_scene);
    } else {
        for (const auto& view : state.views)
            for (const auto& camera : view.cameras) scene.cameras.erase(camera);
        state.views.clear();
        state.projection.clear(); state.projection_transform.clear();
        state.point_projection.clear(); state.point_transform.clear();
        state.atlas_width = state.atlas_height = 0;
        SizeLightFeatures(scene);
        UpdateSceneShadows(scene);
    }
    const std::string atlas(kShadowAtlas);
    if (!state.active()) {
        scene.renderTargets.erase(atlas);
        return;
    }
    auto& target = scene.renderTargets[atlas];
    target.width = target.authored_width = static_cast<i32>(state.atlas_width);
    target.height = target.authored_height = static_cast<i32>(state.atlas_height);
    target.format = TextureFormat::Depth32F;
    target.unscaled = true;
}

void wallpaper::SelectSceneShadowMaterial(Scene& scene, SceneNode* node, uint32_t slot) {
    if (!scene.shadows.enabled || node == nullptr || node->Mesh() == nullptr) return;
    auto* material = node->Mesh()->MaterialForSlot(slot);
    if (material == nullptr || !material->shadow_variants) return;
    const auto variants = material->shadow_variants;
    const bool enabled = scene.shadows.active();
    auto& wanted = variants->versions[enabled ? 1 : 0];
    const auto key = SceneShadowVariantKey(scene);
    if (!wanted.material || wanted.key != key) {
        if (!variants->build) return;
        auto next = variants->build(enabled);
        if (!next.material) return;
        next.key = key;
        wanted = std::move(next);
    }
    material->customShader.shader = wanted.material->customShader.shader;
    material->defines = wanted.material->defines;
    // Preserve caller-resolved effect inputs and script-written constants. Only
    // the engine-owned shadow atlas binding changes with the selected variant.
    for (const auto index : variants->atlas_slots) {
        if (material->textures.size() <= index) material->textures.resize(index + 1);
        material->textures[index] = enabled ? std::string(kShadowAtlas) : std::string();
    }
    for (const auto& [name, value] : wanted.material->customShader.constValues)
        material->customShader.constValues.try_emplace(name, value);
    if (auto* updater = dynamic_cast<WPShaderValueUpdater*>(scene.shaderValueUpdater.get()))
        updater->SetNodeShadowTargets(node, slot, variants->atlas_slots, enabled);
}
