// Clean-room implementation from the WallpaperMachine spec p1-scene-structure.md; written without access to the original source.
#include "WPLightObject.hpp"
#include "WPObjectSchema.hpp"

#include "Utils/Logging.h"
#include "Fs/VFS.h"

using namespace wallpaper::wpscene;

namespace
{

// A scalar authored plain, as `{"value": ...}`, or bound to a user property,
// script or timeline. The authored value is what is read here; the setting is
// kept whole for the runtime binding.
void ReadScalarSetting(const nlohmann::json& json, const char* key, float& value,
                       nlohmann::json& setting) {
    if (! json.contains(key)) return;
    setting            = json.at(key);
    const auto& source = UnwrapMiscSettingValue(setting);
    if (source.is_number()) value = source.get<float>();
}

} // namespace

bool WPLightObject::FromJson(const nlohmann::json& json, fs::VFS&) {
    if (! json.is_object()) return false;
    FromCommonJson(json);
    ReadMiscString(json, "light", light);
    if (json.contains("color")) {
        color_setting = json.at("color");
        ReadTolerantVec3(color_setting, color);
    }
    ReadScalarSetting(json, "radius", radius, radius_setting);
    ReadScalarSetting(json, "intensity", intensity, intensity_setting);
    ReadScalarSetting(json, "exponent", exponent, exponent_setting);
    ReadMiscNumber(json, "innercone", innercone);
    ReadMiscNumber(json, "outercone", outercone);
    if (json.contains("controlpoint")) ReadStrictVec(json.at("controlpoint"), controlpoint);
    ReadMiscFlag(json, "castshadow", castshadow);
    ReadMiscFlag(json, "usecookie", usecookie);
    if (usecookie) {
        ReadMiscString(json, "cookie", cookie);
        if (cookie.empty()) cookie = "cookie/flashlight1";
    }
    ReadMiscFlag(json, "castvolumetrics", castvolumetrics);
    ReadMiscNumber(json, "density", density);
    ReadMiscNumber(json, "volumetricsexponent", volumetricsexponent);
    ReadMiscNumber(json, "cascadedistance0", cascadedistance[0]);
    ReadMiscNumber(json, "cascadedistance1", cascadedistance[1]);
    ReadMiscNumber(json, "cascadedistance2", cascadedistance[2]);
    ReadMiscNumber(json, "lightsourcesize", lightsourcesize);
    return true;
}
