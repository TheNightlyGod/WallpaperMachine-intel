#pragma once
#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "Utils/Linalg.hpp"
#include "SceneLight.hpp"

namespace wallpaper
{
class Scene;
class SceneNode;
struct SceneMaterial;

using ShadowTargetBindings = std::vector<std::pair<std::size_t, std::string>>;
using ShadowVariantKey = std::array<uint32_t, 10>;
struct ShadowMaterialVersion {
    std::shared_ptr<SceneMaterial> material;
    ShadowTargetBindings targets;
    ShadowVariantKey key {};
};
struct ShadowMaterialVariants {
    /// At most the latest off and on versions, even if light counts change.
    std::array<ShadowMaterialVersion, 2> versions;
    std::function<ShadowMaterialVersion(bool)> build;
    std::vector<std::size_t> atlas_slots;
};
struct ShadowCasterPreparation {
    std::weak_ptr<SceneNode> node;
    std::function<void()> prepare;
    bool attempted { false };
    ShadowVariantKey key {};
};

/// The shadow atlas target (`sub_1401AADB0 "_rt_shadowAtlas"`).
inline constexpr std::string_view kShadowAtlas = "_rt_shadowAtlas";
inline const std::string kLightCookieAlias = "_alias_lightCookie";
/// A submesh of a shadow-casting node that has no caster material.
inline constexpr uint32_t kNoShadowCasterSlot = UINT32_MAX;
/// A caster's depth bias: the slope-scale factor that multiplies the primitive's depth
/// slope, and the clamp on the resulting bias, in depth units. Negative: toward the far
/// plane of the atlas's reversed depth, away from the light.
inline constexpr float kShadowCasterSlopeBias = -2.0f;
inline constexpr float kShadowCasterBiasClamp = -0.01f;

/// One LightingV1 light as Wallpaper Engine packs it this frame (`we_SortSceneLights`
/// 0x140186990, `sub_140190C80`): the sorted visible lights, each with the slot of its
/// kind's array it writes, or `kNoSlot` when its partition is full.
struct PackedSceneLight {
    static constexpr std::size_t kNoSlot = static_cast<std::size_t>(-1);
    const SceneLight* light { nullptr };
    std::size_t       slot { kNoSlot };
};

/// The visible LightingV1 lights in Wallpaper Engine's packing order with their array
/// slots. Spot arrays are [shadow cookie][cookie][shadow][plain] (partition
/// ((shadows ? 1 : 0) + 2) & flags), point and directional [shadow][plain].
/// `out` is reused (no allocation once it has grown).
void PackSceneLights(const Scene& scene, std::vector<PackedSceneLight>& out);

/// A tile of the shadow atlas, in texels.
struct ShadowTile {
    uint32_t x { 0 }, y { 0 }, size { 0 };
};

/// The atlas tile size of one shadow view at a shadows quality level
/// (`sub_14025D3E0`): low and medium 256, high 512, ultra 1024; 0 when off.
uint32_t ShadowTileSize(int shadows_quality);

/// Wallpaper Engine's shelf packer (`sub_140190C80`, asm 0x140193750..0x1401939ab): the
/// tiles of views of the given sizes, in order, and the packed extent (each side at least 2).
struct ShadowAtlasPacking {
    std::vector<ShadowTile> tiles;
    uint32_t                width { 2 }, height { 2 };
};
ShadowAtlasPacking PackShadowAtlas(std::span<const uint32_t> sizes);

enum class ShadowViewKind : uint8_t
{
    Spot,
    Point,
    Directional
};

/// One view drawn into the shadow atlas: a spot light, a point light (six faces in one
/// tile) or one cascade of a directional light.
struct ShadowView {
    const SceneLight*          light { nullptr };
    ShadowViewKind             kind { ShadowViewKind::Spot };
    uint8_t                    cascade { 0 };
    /// The shader array slot, stable while distance sorting changes the light using it.
    std::size_t                slot { 0 };
    ShadowTile                 tile {};
    /// The cameras its casters are drawn through: one, or six for a point light.
    std::vector<std::string>   cameras;
    /// Each camera's viewport, as (x, y, width, height) fractions of the atlas, y down.
    std::vector<std::array<float, 4>> viewports;
};

/// Shadow views and the shared feature projections. Views/atlas are empty when no
/// shadow is drawn; cookie projections and the selected image remain independent.
struct SceneShadowState {
    /// Capacity comes from quality and authored lightconfig. Changes are event-driven.
    bool enabled { false }, dirty { false };
    /// Cookie projections exist independently of shadow views. All cookie spots sample
    /// the last eligible packed spot's texture (WE 0x140192F0B / 0x1401935CA).
    bool cookie_features { false };
    const SceneLight* cookie_light { nullptr };
    std::vector<ShadowCasterPreparation> casters;
    std::vector<ShadowView> views;
    uint32_t                atlas_width { 0 }, atlas_height { 0 };
    uint32_t                peak_width { 0 }, peak_height { 0 };
    /// The scene is 2D (an orthogonal projection): Wallpaper Engine's shadow near plane is 1.
    bool                    ortho_scene { false };
    int                     quality { 0 };
    /// This frame's feature arrays in Wallpaper Engine's indexing (`sub_140169140`): mat4
    /// (16 floats, column-major) and vec4 per spot feature slot and directional cascade,
    /// vec4s per shadowed point light.
    std::vector<float> projection, projection_transform, point_projection, point_transform;

    [[nodiscard]] bool active() const { return ! views.empty(); }
};

/// The camera key of view `view`'s face `face`.
std::string ShadowCameraKey(std::size_t view, std::size_t face);

/// Lays the views of every visible shadow-casting light that has a shadow slot out in the
/// atlas and registers one camera per view face in `scene.cameras`. Leaves the state
/// empty when no light casts.
void PlanSceneShadows(Scene& scene, bool ortho_scene);
/// Replan only after a real visibility/cast/type change; no polling in ordinary frames.
void RefreshSceneShadows(Scene& scene);
ShadowVariantKey SceneShadowVariantKey(const Scene& scene);
/// Select or lazily build the current bounded receiver variant while rebuilding the graph.
void SelectSceneShadowMaterial(Scene& scene, SceneNode* node, uint32_t material_slot);

/// Recomputes this frame's view-projections (camera overrides, the caster's clip-z offset
/// included) and the receivers' feature arrays.
void UpdateSceneShadows(Scene& scene);

/// The light projection for the volume mesh and cookie coordinates, using scene depth.
linalg::Matrix4d SceneVolumeProjection(const SceneLight&, bool ortho_scene);
linalg::Matrix4d ScenePointShadowProjection(const SceneLight&, bool ortho_scene, int quality);

/// Reversed-depth matrices Wallpaper Engine's device builds (`sub_14009A360`): near maps
/// to 1, far to 0; right-handed view space looking down -z, column vectors.
linalg::Matrix4d ReversedPerspective(double fov_y_degrees, double near, double far);
} // namespace wallpaper
