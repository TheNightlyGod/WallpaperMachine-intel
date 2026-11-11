#pragma once
#include <array>
#include <cstdint>
#include <functional>
#include <vector>
#include <memory>
#include <string_view>
#include "Utils/Linalg.hpp"
#include "SceneNode.h"
#include "Runtime/ScalarAnimation.hpp"

namespace wallpaper
{

/// Wallpaper Engine's light kinds, numbered as it numbers them.
///
/// `lpoint`, `lspot`, `ltube` and `ldirectional` are lit by the shaders that
/// `#require LightingV1`, through one uniform array per kind. `point` is the
/// older light those shaders' predecessors read as four packed lights
/// (`g_LightsPosition`, `g_LightsColorPremultiplied`); it is also what any word
/// Wallpaper Engine does not know reads as.
enum class SceneLightType : uint8_t
{
    Point       = 0,
    Spot        = 1,
    Tube        = 2,
    Directional = 3,
    Legacy      = 5,
};

[[nodiscard]] inline SceneLightType ParseSceneLightType(std::string_view value) {
    if (value == "lpoint") return SceneLightType::Point;
    if (value == "lspot") return SceneLightType::Spot;
    if (value == "ltube") return SceneLightType::Tube;
    if (value == "ldirectional") return SceneLightType::Directional;
    return SceneLightType::Legacy;
}

/// How many lights of each kind a scene's lit shaders are compiled for, from
/// its `general.lightconfig`. A kind's lights beyond its count are not drawn,
/// and a kind the config leaves out is not drawn at all.
struct SceneLightConfig {
    uint32_t point { 0 };
    uint32_t spot { 0 };
    uint32_t tube { 0 };
    uint32_t directional { 0 };
    // How many of a kind's lights fall in its shadow and cookie subsets
    // (`lightconfig` keys pointshadow, spotshadow, spotcookie, spotshadowcookie,
    // directionalshadow; Wallpaper Engine 0x140186C90 keeps each as `& 3`). A kind's
    // array holds its subsets first: spot [shadow cookie][cookie][shadow][plain],
    // point and directional [shadow][plain] (0x140190C80). With shadows off the
    // shadow subsets are 0 and spotshadowcookie is ORed into spotcookie.
    uint32_t point_shadow { 0 };
    uint32_t spot_shadow { 0 };
    uint32_t spot_cookie { 0 };
    uint32_t spot_shadow_cookie { 0 };
    uint32_t directional_shadow { 0 };

    [[nodiscard]] bool empty() const {
        return point == 0 && spot == 0 && tube == 0 && directional == 0;
    }
};

class SceneLight {
public:
    SceneLight(linalg::Vector3f color, float radius, float intensity)
        : m_color(color), m_radius(radius), m_intensity(intensity) {}
    SceneLight(SceneLightType type, linalg::Vector3f color, float radius, float intensity)
        : m_type(type), m_color(color), m_radius(radius), m_intensity(intensity) {}
    ~SceneLight() = default;

    SceneLightType  type() const { return m_type; }
    linalg::Vector3f color() const { return m_color; }
    float           radius() const { return m_radius; }
    /// The intensity this frame: its timeline's value when it has one.
    float           intensity() const {
        return m_intensity_animation != nullptr ? m_intensity_animation->Value() : m_intensity;
    }
    float           exponent() const { return m_exponent; }
    /// Cone half-angles of a spot light, in degrees.
    float           innerCone() const { return m_inner_cone; }
    float           outerCone() const { return m_outer_cone; }
    /// A tube's far end, in the light's own space; its near end is the origin.
    linalg::Vector3f controlPoint() const { return m_control_point; }
    SceneNode*      node() const { return m_node.get(); }
    /// Volumetric and shadow keys, stored for the volumetrics and shadow passes.
    float                density() const { return m_density; }
    float                volumetricsExponent() const { return m_volumetrics_exponent; }
    std::array<float, 3> cascadeDistances() const { return m_cascade_distances; }
    float                sourceSize() const { return m_source_size; }
    /// Bit 0 castshadow, bit 1 usecookie (WE light flags +708).
    uint32_t             flags() const { return m_flags; }
    bool                 castsVolumetrics() const { return m_casts_volumetrics; }

    /// The legacy light's colour as `g_LightsColorPremultiplied` holds it.
    linalg::Vector3f premultipliedColor() const {
        return m_color * intensity() * m_radius * m_radius;
    }

    /// Whether the light shines: it and every layer above it are visible.
    bool visible() const { return m_node == nullptr || m_node->EffectiveVisible(); }

    void setNode(std::shared_ptr<SceneNode> node) { m_node = std::move(node); }
    void setColor(const linalg::Vector3f& color) { m_color = color; }
    void setRadius(float radius) { m_radius = radius; }
    void setIntensity(float intensity) { m_intensity = intensity; }
    void setIntensityAnimation(std::shared_ptr<ScalarAnimationPlayback> animation) {
        m_intensity_animation = std::move(animation);
    }
    void setExponent(float exponent) { m_exponent = exponent; }
    const std::string& cookie() const { return m_cookie; }
    void setCookie(std::string value) { m_cookie = std::move(value); }
    void setCones(float inner_degrees, float outer_degrees) {
        m_inner_cone = inner_degrees;
        m_outer_cone = outer_degrees;
    }
    void setControlPoint(const linalg::Vector3f& point) { m_control_point = point; }
    void setVolumetrics(float density, float exponent, bool casts) {
        const bool changed = m_casts_volumetrics != casts;
        m_density              = density;
        m_volumetrics_exponent = exponent;
        m_casts_volumetrics    = casts;
        if (changed && m_topology_changed) m_topology_changed();
    }
    void setCascadeDistances(const std::array<float, 3>& distances) { m_cascade_distances = distances; }
    void setSourceSize(float size) { m_source_size = size; }
    void setFlags(uint32_t flags) {
        const bool changed = ((m_flags ^ flags) & (kCastShadow | kUseCookie)) != 0;
        m_flags = flags;
        if (changed && m_topology_changed) m_topology_changed();
    }
    /// The kind a script's `light` word names (we_ss_reg_LightLayer 0x14025DA80).
    void setType(SceneLightType type) {
        if (m_type == type) return;
        m_type = type;
        if (m_topology_changed) m_topology_changed();
    }
    void setTopologyChanged(std::function<void()> changed) { m_topology_changed = std::move(changed); }
    /// Wallpaper Engine's light flags (+708): `kCastShadow` (castshadow),
    /// `kUseCookie` (usecookie), `kCastVolumetrics` (castvolumetrics); the light
    /// registry `sub_14025DA80` binds all three keys to that word.
    static constexpr uint32_t kCastShadow      = 1u;
    static constexpr uint32_t kUseCookie       = 2u;
    static constexpr uint32_t kCastVolumetrics = 4u;
    /// Which of the four `g_Lights*` slots a legacy light writes. Wallpaper
    /// Engine numbers every light object in object order, LightingV1 ones and
    /// hidden ones included, and hands a fifth light slot 0 again
    /// (`sub_14018FF60`); later writers of a slot win.
    uint8_t legacySlot() const { return m_legacy_slot; }
    void    setLegacySlot(uint8_t slot) { m_legacy_slot = slot < 4 ? slot : 0; }

private:
    SceneLightType  m_type { SceneLightType::Legacy };
    std::string    m_cookie;
    linalg::Vector3f m_color { linalg::Vector3f::Zero() };
    float           m_radius { 0.0f };
    float           m_intensity { 1.0f };
    // Wallpaper Engine's defaults for a light that leaves these out.
    float           m_exponent { 2.0f };
    float           m_inner_cone { 20.0f };
    float           m_outer_cone { 30.0f };
    linalg::Vector3f m_control_point { 2.0f, 0.0f, 0.0f };
    uint8_t         m_legacy_slot { 0 };
    float                m_density { 2.0f };
    float                m_volumetrics_exponent { 1.0f };
    std::array<float, 3> m_cascade_distances { 3.0f, 10.0f, 100.0f };
    float                m_source_size { 0.0f };
    uint32_t             m_flags { 0 };
    bool                 m_casts_volumetrics { false };
    std::function<void()> m_topology_changed;

    std::shared_ptr<ScalarAnimationPlayback> m_intensity_animation;
    std::shared_ptr<SceneNode>               m_node { nullptr };
};
} // namespace wallpaper
