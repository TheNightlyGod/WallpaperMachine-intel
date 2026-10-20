#include <type_traits>
#include "WPScene.h"

#include <sstream>

using namespace wallpaper::wpscene;

bool Orthogonalprojection::FromJson(const nlohmann::json& json) {
    if(json.is_null()) return false;
	if(json.contains("auto")) {
		GET_JSON_NAME_VALUE(json, "auto", auto_);
	}
	else {
		GET_JSON_NAME_VALUE(json, "width", width);
		GET_JSON_NAME_VALUE(json, "height", height);
	}
    return true;
}

bool WPSceneCamera::FromJson(const nlohmann::json& json) {
    GET_JSON_NAME_VALUE(json, "center", center);
    GET_JSON_NAME_VALUE(json, "eye", eye);
    GET_JSON_NAME_VALUE(json, "up", up);
    return true;
}

bool WPSceneGeneral::FromJson(const nlohmann::json& json) {
    return FromJson(json, kSceneVersionUnknown);
}

namespace
{
bool WantsVersion(uint16_t pkg_version, uint16_t gate) {
    return pkg_version == WPSceneGeneral::kSceneVersionUnknown || pkg_version >= gate;
}

const nlohmann::json& UnwrapSettingValue(const nlohmann::json& value) {
    if (value.is_object() && value.contains("value")) return value.at("value");
    return value;
}

bool HasDynamicSetting(const nlohmann::json& value) {
    return value.is_object() && (value.contains("script") || value.contains("user"));
}

template <typename T>
void ReadScalarSetting(const nlohmann::json& json, const char* key, T& destination,
                       nlohmann::json& setting) {
    if (! json.contains(key)) return;
    setting = json.at(key);
    const auto& value = UnwrapSettingValue(setting);
    if constexpr (std::is_same_v<T, bool>) {
        if (value.is_boolean()) destination = value.get<bool>();
        else if (value.is_number()) destination = value.get<double>() != 0.0;
    } else if (value.is_number()) {
        destination = value.get<T>();
    }
}

void ReadVec3Setting(const nlohmann::json& json, const char* key, std::array<float, 3>* destination,
                     nlohmann::json* setting, bool* dynamic) {
    if (! json.contains(key) || destination == nullptr || setting == nullptr || dynamic == nullptr)
        return;

    *setting           = json.at(key);
    *dynamic           = HasDynamicSetting(*setting);
    const auto& source = UnwrapSettingValue(*setting);

    if (source.is_array() && source.size() >= 3) {
        (*destination)[0] = source.at(0).get<float>();
        (*destination)[1] = source.at(1).get<float>();
        (*destination)[2] = source.at(2).get<float>();
        return;
    }
    if (source.is_number()) {
        const float scalar = source.get<float>();
        *destination       = { scalar, scalar, scalar };
        return;
    }
    if (source.is_string()) {
        std::istringstream stream(source.get<std::string>());
        stream >> (*destination)[0] >> (*destination)[1] >> (*destination)[2];
    }
}
}

bool WPSceneGeneral::FromJson(const nlohmann::json& json, uint16_t pkg_version) {
    GET_JSON_NAME_VALUE(json, "ambientcolor", ambientcolor);
    GET_JSON_NAME_VALUE(json, "skylightcolor", skylightcolor);
    ReadVec3Setting(json, "clearcolor", &clearcolor, &clearcolor_setting, &dynamic_clearcolor);
	GET_JSON_NAME_VALUE_NOWARN(json, "clearenabled", clearenabled);
	ReadScalarSetting(json, "camerashake", camerashake, camerashake_setting);
	ReadScalarSetting(json, "camerashakeamplitude", camerashakeamplitude, camerashakeamplitude_setting);
	ReadScalarSetting(json, "camerashakespeed", camerashakespeed, camerashakespeed_setting);
	ReadScalarSetting(json, "camerashakeroughness", camerashakeroughness, camerashakeroughness_setting);
	ReadScalarSetting(json, "cameraparallax", cameraparallax, cameraparallax_setting);
	ReadScalarSetting(json, "cameraparallaxamount", cameraparallaxamount, cameraparallaxamount_setting);
	ReadScalarSetting(json, "cameraparallaxdelay", cameraparallaxdelay, cameraparallaxdelay_setting);
	ReadScalarSetting(json, "cameraparallaxmouseinfluence", cameraparallaxmouseinfluence,
	                  cameraparallaxmouseinfluence_setting);
	ReadScalarSetting(json, "zoom", zoom, zoom_setting);
	GET_JSON_NAME_VALUE_NOWARN(json, "fov", fov);
	GET_JSON_NAME_VALUE_NOWARN(json, "nearz", nearz);
	GET_JSON_NAME_VALUE_NOWARN(json, "farz", farz);
	ReadScalarSetting(json, "bloom", bloom, bloom_setting);
	ReadScalarSetting(json, "bloomstrength", bloomstrength, bloomstrength_setting);
	ReadScalarSetting(json, "bloomthreshold", bloomthreshold, bloomthreshold_setting);
    if (WantsVersion(pkg_version, 10)) {
	    GET_JSON_NAME_VALUE_NOWARN(json, "hdr", hdr);
	    GET_JSON_NAME_VALUE_NOWARN(json, "norecompile", norecompile);
        ReadScalarSetting(json, "bloomhdrstrength", bloomhdrstrength, bloomhdrstrength_setting);
        ReadScalarSetting(json, "bloomhdrthreshold", bloomhdrthreshold, bloomhdrthreshold_setting);
        ReadScalarSetting(json, "bloomhdrscatter", bloomhdrscatter, bloomhdrscatter_setting);
        ReadScalarSetting(json, "bloomhdrfeather", bloomhdrfeather, bloomhdrfeather_setting);
        ReadScalarSetting(json, "bloomhdriterations", bloomhdriterations, bloomhdriterations_setting);
    }
    if (WantsVersion(pkg_version, 20)) {
	    ReadVec3Setting(json, "bloomtint", &bloomtint, &bloomtint_setting, &dynamic_bloomtint);
    }
    // Wallpaper Engine reads the field of view of a 2D scene's perspective layers
    // from whatever file carries it, not only from package version 21 on.
    GET_JSON_NAME_VALUE_NOWARN(json, "perspectiveoverridefov", perspectiveoverridefov);
    if (WantsVersion(pkg_version, 21)) {
	    GET_JSON_NAME_VALUE_NOWARN(json, "windenabled", windenabled);
	    GET_JSON_NAME_VALUE_NOWARN(json, "winddirection", winddirection);
	    GET_JSON_NAME_VALUE_NOWARN(json, "windstrength", windstrength);
	    GET_JSON_NAME_VALUE_NOWARN(json, "gravitydirection", gravitydirection);
	    GET_JSON_NAME_VALUE_NOWARN(json, "gravitystrength", gravitystrength);
    }
    if (WantsVersion(pkg_version, 22)) {
	    GET_JSON_NAME_VALUE_NOWARN(json, "transparentsorting", transparentsorting);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogdistance", fogdistance);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogdistancestart", fogdistancestart);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogdistanceend", fogdistanceend);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogdistancecolor", fogdistancecolor);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogdistancestartdensity", fogdistancestartdensity);
	    GET_JSON_NAME_VALUE_NOWARN(json, "fogdistanceenddensity", fogdistanceenddensity);
    }
    // Package versions describe the container, not which JSON fog keys may
    // appear: height fog is authored in version 22 packages too.
    GET_JSON_NAME_VALUE_NOWARN(json, "fogheight", fogheight);
    GET_JSON_NAME_VALUE_NOWARN(json, "fogheightstart", fogheightstart);
    GET_JSON_NAME_VALUE_NOWARN(json, "fogheightend", fogheightend);
    GET_JSON_NAME_VALUE_NOWARN(json, "fogheightcolor", fogheightcolor);
    GET_JSON_NAME_VALUE_NOWARN(json, "fogheightstartdensity", fogheightstartdensity);
    GET_JSON_NAME_VALUE_NOWARN(json, "fogheightenddensity", fogheightenddensity);
    for (const char* key : { "ambientcolor", "skylightcolor", "fogheight",
                            "fogheightstart", "fogheightend", "fogheightcolor",
                            "fogheightstartdensity", "fogheightenddensity" }) {
        if (json.contains(key) && HasDynamicSetting(json.at(key))) {
            lighting_settings[key] = json.at(key);
        }
    }
    if (WantsVersion(pkg_version, 21) &&
        json.contains("lightconfig") && json.at("lightconfig").is_object()) {
        lightconfig = json.at("lightconfig");
    }
    if(json.contains("orthogonalprojection")) {
        const auto& ortho = json.at("orthogonalprojection");
        if(ortho.is_null()) {
            isOrtho     = false;
            pixelCanvas = false;
        } else {
            isOrtho = true;
            orthogonalprojection.FromJson(ortho);
            pixelCanvas = ortho.is_object() &&
                          (orthogonalprojection.auto_ ||
                           (orthogonalprojection.width != 0 && orthogonalprojection.height != 0));
        }
    } else {
        // Wallpaper Engine's scene starts without an orthogonal projection and
        // fills particle defaults in scene units. This loader still draws a
        // scene without the key as its default orthogonal canvas, and a canvas
        // that is drawn in pixels takes the pixel defaults, so the particle
        // defaults follow what is drawn rather than flipping a pixel scene to
        // scene units. A change of projection for a missing key moves both.
        pixelCanvas = isOrtho;
    }
    return true;
}

bool WPScene::FromJson(const nlohmann::json& json) {
    return FromJson(json, WPSceneGeneral::kSceneVersionUnknown);
}

bool WPScene::FromJson(const nlohmann::json& json, uint16_t pkg_version) {
    this->pkg_version = pkg_version;
    if(json.contains("camera")) {
        camera.FromJson(json.at("camera"));
    } else {
        LOG_ERROR("scene no camera");
        return false;
    }
    if(json.contains("general")) {
        general.FromJson(json.at("general"), pkg_version);
    } else {
        LOG_ERROR("scene no genera data");
        return false;
    }
    return true; 
}
