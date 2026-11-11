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
    // Defaults are Wallpaper Engine's light constructor (sub_14018FF60): its
    // object loader sets only the keys a file writes (sub_1401730D0).
    std::array<float, 3> color { 0.0f, 0.0f, 0.0f };
    std::string          light;
    std::string          cookie;
    float                radius { 1.0f };
    float                intensity { 0.0f };
    float                exponent { 2.0f };
    float                innercone { 20.0f };
    float                outercone { 30.0f };
    std::array<float, 3> controlpoint { 2.0f, 0.0f, 0.0f };
    bool                 castshadow { false };
    bool                 usecookie { false };
    bool                 castvolumetrics { false };
    float                density { 2.0f };
    float                volumetricsexponent { 1.0f };
    std::array<float, 3> cascadedistance { 3.0f, 10.0f, 100.0f };
    float                lightsourcesize { 0.0f };
    nlohmann::json       color_setting;
    nlohmann::json       radius_setting;
    nlohmann::json       intensity_setting;
    nlohmann::json       exponent_setting;
};

} // namespace wpscene
} // namespace wallpaper
