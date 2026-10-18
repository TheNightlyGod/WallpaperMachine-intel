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
    FromCommonJson(json);
    bool dynamic_color = false;
    ReadMiscVec3Setting(json, "color", &color, &color_setting, &dynamic_color);
    GET_JSON_NAME_VALUE_NOWARN(json, "light", light);
    ReadScalarSetting(json, "radius", radius, radius_setting);
    ReadScalarSetting(json, "intensity", intensity, intensity_setting);
    ReadScalarSetting(json, "exponent", exponent, exponent_setting);
    GET_JSON_NAME_VALUE_NOWARN(json, "innercone", innercone);
    GET_JSON_NAME_VALUE_NOWARN(json, "outercone", outercone);
    GET_JSON_NAME_VALUE_NOWARN(json, "controlpoint", controlpoint);
    GET_JSON_NAME_VALUE_NOWARN(json, "castshadow", castshadow);
    GET_JSON_NAME_VALUE_NOWARN(json, "usecookie", usecookie);
    GET_JSON_NAME_VALUE_NOWARN(json, "castvolumetrics", castvolumetrics);
    return true;
}
