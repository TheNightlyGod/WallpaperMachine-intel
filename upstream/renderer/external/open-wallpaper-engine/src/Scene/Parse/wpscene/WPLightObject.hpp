#pragma once
#include "WPJson.hpp"
#include "WPMiscObject.hpp"
#include <nlohmann/json.hpp>
#include <array>
#include <string>

namespace wallpaper
{
namespace fs
{
class VFS;
}

namespace wpscene
{

/// A scene light. Transform, parent, visibility and their bindings are read as
/// for any other object; `color`, `intensity`, `radius` and `exponent` may be
/// bound to a user property, a script or (intensity) a timeline, so their raw
/// settings are kept beside the authored values.
class WPLightObject : public WPMiscObjectBase {
public:
    bool                 FromJson(const nlohmann::json&, fs::VFS&);
    std::array<float, 3> color { 1.0f, 1.0f, 1.0f };
    std::string          light;
    float                radius { 1000.0f };
    float                intensity { 1.0f };
    float                exponent { 2.0f };
    float                innercone { 20.0f };
    float                outercone { 30.0f };
    std::array<float, 3> controlpoint { 2.0f, 0.0f, 0.0f };
    bool                 castshadow { false };
    bool                 usecookie { false };
    bool                 castvolumetrics { false };
    nlohmann::json       color_setting;
    nlohmann::json       radius_setting;
    nlohmann::json       intensity_setting;
    nlohmann::json       exponent_setting;
};

} // namespace wpscene
} // namespace wallpaper
