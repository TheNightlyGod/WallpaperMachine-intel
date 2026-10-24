#pragma once
#include <cstdint>
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
    void setCones(float inner_degrees, float outer_degrees) {
        m_inner_cone = inner_degrees;
        m_outer_cone = outer_degrees;
    }
    void setControlPoint(const linalg::Vector3f& point) { m_control_point = point; }

private:
    SceneLightType  m_type { SceneLightType::Legacy };
    linalg::Vector3f m_color { linalg::Vector3f::Zero() };
    float           m_radius { 0.0f };
    float           m_intensity { 1.0f };
    // Wallpaper Engine's defaults for a light that leaves these out.
    float           m_exponent { 2.0f };
    float           m_inner_cone { 20.0f };
    float           m_outer_cone { 30.0f };
    linalg::Vector3f m_control_point { 2.0f, 0.0f, 0.0f };

    std::shared_ptr<ScalarAnimationPlayback> m_intensity_animation;
    std::shared_ptr<SceneNode>               m_node { nullptr };
};
} // namespace wallpaper
