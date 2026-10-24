// Clean-room implementation from the WallpaperMachine spec p1-scene-structure.md; written without access to the original source.
#include <type_traits>
#include "WPScene.h"
#include "WPObjectSchema.hpp"

#include "Utils/Logging.h"

using namespace wallpaper::wpscene;

bool Orthogonalprojection::FromJson(const nlohmann::json& json) {
    if (! json.is_object()) return false;
    // An `auto` key of any value takes the size from the layers, and then the
    // object's own width and height are not read at all.
    if (const auto automatic = json.find("auto"); automatic != json.end()) {
        auto_ = automatic->is_boolean() && automatic->get<bool>();
        return true;
    }
    if (json.contains("width")) ReadNumberSetting(json.at("width"), width);
    if (json.contains("height")) ReadNumberSetting(json.at("height"), height);
    return true;
}

bool WPSceneCamera::FromJson(const nlohmann::json& json) {
    if (! json.is_object()) return false;
    if (json.contains("center")) ReadStrictVec(json.at("center"), center);
    if (json.contains("eye")) ReadStrictVec(json.at("eye"), eye);
    if (json.contains("up")) ReadStrictVec(json.at("up"), up);
    return true;
}

bool WPSceneGeneral::FromJson(const nlohmann::json& json) {
    return FromJson(json, kSceneVersionUnknown);
}

namespace
{

// A scene setting that may be bound: the setting is kept whole beside the value
// read from it. A boolean setting also accepts a number, non-zero meaning on.
template<typename T>
void ReadScalarSetting(const nlohmann::json& json, const char* key, T& destination,
                       nlohmann::json& setting) {
    const auto found = json.find(key);
    if (found == json.end()) return;
    setting = *found;
    if constexpr (std::is_same_v<T, bool>) {
        ReadFlagSetting(setting, destination, true);
    } else {
        ReadNumberSetting(setting, destination);
    }
}

// A plain number of the scene file.
template<typename T>
void ReadPlainNumber(const nlohmann::json& json, const char* key, T& destination) {
    if (const auto found = json.find(key); found != json.end()) {
        ReadNumberSetting(*found, destination);
    }
}

// A plain switch of the scene file: only a real boolean counts.
void ReadPlainFlag(const nlohmann::json& json, const char* key, bool& destination) {
    if (const auto found = json.find(key); found != json.end()) {
        ReadFlagSetting(*found, destination);
    }
}

void ReadPlainVec3(const nlohmann::json& json, const char* key, std::array<float, 3>& destination) {
    if (const auto found = json.find(key); found != json.end()) ReadStrictVec(*found, destination);
}

// A vector of the scene file that a property may be bound to: the setting is kept whole beside
// the value read from it.
void ReadVec3Setting(const nlohmann::json& json, const char* key, std::array<float, 3>& destination,
                     nlohmann::json& setting) {
    if (const auto found = json.find(key); found != json.end()) {
        setting = *found;
        ReadStrictVec(*found, destination);
    }
}

} // namespace

bool WPSceneGeneral::FromJson(const nlohmann::json& json, uint16_t pkg_version) {
    if (! json.is_object()) return false;
    // A key is read when the package is of unknown version or at least the
    // version that introduced it.
    const auto reads = [pkg_version](uint16_t gate) {
        return pkg_version == kSceneVersionUnknown || pkg_version >= gate;
    };

    if (const auto found = json.find("clearcolor"); found != json.end()) {
        clearcolor_setting = *found;
        ReadTolerantVec3(clearcolor_setting, clearcolor);
        dynamic_clearcolor = SettingIsDriven(clearcolor_setting);
    }
    ReadPlainFlag(json, "clearenabled", clearenabled);

    if (const auto found = json.find("orthogonalprojection"); found != json.end()) {
        if (found->is_null()) {
            isOrtho     = false;
            pixelCanvas = false;
        } else {
            isOrtho = true;
            orthogonalprojection.FromJson(*found);
            pixelCanvas = orthogonalprojection.auto_ ||
                          (orthogonalprojection.width != 0 && orthogonalprojection.height != 0);
        }
    }

    ReadScalarSetting(json, "zoom", zoom, zoom_setting);
    ReadPlainNumber(json, "fov", fov);
    ReadPlainNumber(json, "nearz", nearz);
    ReadPlainNumber(json, "farz", farz);
    ReadPlainNumber(json, "perspectiveoverridefov", perspectiveoverridefov);
    ReadVec3Setting(json, "ambientcolor", ambientcolor, ambientcolor_setting);
    ReadVec3Setting(json, "skylightcolor", skylightcolor, skylightcolor_setting);

    ReadScalarSetting(json, "camerashake", camerashake, camerashake_setting);
    ReadScalarSetting(json, "camerashakeamplitude", camerashakeamplitude,
                      camerashakeamplitude_setting);
    ReadScalarSetting(json, "camerashakespeed", camerashakespeed, camerashakespeed_setting);
    ReadScalarSetting(json, "camerashakeroughness", camerashakeroughness,
                      camerashakeroughness_setting);

    ReadScalarSetting(json, "cameraparallax", cameraparallax, cameraparallax_setting);
    ReadScalarSetting(json, "cameraparallaxamount", cameraparallaxamount,
                      cameraparallaxamount_setting);
    ReadScalarSetting(json, "cameraparallaxdelay", cameraparallaxdelay,
                      cameraparallaxdelay_setting);
    ReadScalarSetting(json, "cameraparallaxmouseinfluence", cameraparallaxmouseinfluence,
                      cameraparallaxmouseinfluence_setting);

    ReadScalarSetting(json, "bloom", bloom, bloom_setting);
    ReadScalarSetting(json, "bloomstrength", bloomstrength, bloomstrength_setting);
    ReadScalarSetting(json, "bloomthreshold", bloomthreshold, bloomthreshold_setting);

    if (reads(10)) {
        ReadPlainFlag(json, "hdr", hdr);
        ReadPlainFlag(json, "norecompile", norecompile);
        ReadScalarSetting(json, "bloomhdrstrength", bloomhdrstrength, bloomhdrstrength_setting);
        ReadScalarSetting(json, "bloomhdrthreshold", bloomhdrthreshold, bloomhdrthreshold_setting);
        ReadScalarSetting(json, "bloomhdrscatter", bloomhdrscatter, bloomhdrscatter_setting);
        ReadScalarSetting(json, "bloomhdrfeather", bloomhdrfeather, bloomhdrfeather_setting);
        ReadScalarSetting(json, "bloomhdriterations", bloomhdriterations,
                          bloomhdriterations_setting);
    }
    if (reads(20)) {
        if (const auto found = json.find("bloomtint"); found != json.end()) {
            bloomtint_setting = *found;
            ReadTolerantVec3(bloomtint_setting, bloomtint);
            dynamic_bloomtint = SettingIsDriven(bloomtint_setting);
        }
    }
    if (reads(21)) {
        ReadPlainFlag(json, "windenabled", windenabled);
        ReadPlainVec3(json, "winddirection", winddirection);
        ReadPlainNumber(json, "windstrength", windstrength);
        ReadPlainVec3(json, "gravitydirection", gravitydirection);
        ReadPlainNumber(json, "gravitystrength", gravitystrength);
        if (const auto found = json.find("lightconfig"); found != json.end() && found->is_object()) {
            lightconfig = *found;
        }
    }
    if (reads(22)) {
        ReadPlainFlag(json, "transparentsorting", transparentsorting);
        ReadPlainFlag(json, "fogdistance", fogdistance);
        ReadPlainNumber(json, "fogdistancestart", fogdistancestart);
        ReadPlainNumber(json, "fogdistanceend", fogdistanceend);
        ReadPlainNumber(json, "fogdistancestartdensity", fogdistancestartdensity);
        ReadPlainNumber(json, "fogdistanceenddensity", fogdistanceenddensity);
        ReadPlainVec3(json, "fogdistancecolor", fogdistancecolor);
    }
    // Height fog is read whenever the file has it, whatever package version saved it.
    ReadPlainFlag(json, "fogheight", fogheight);
    ReadScalarSetting(json, "fogheightstart", fogheightstart, fogheightstart_setting);
    ReadScalarSetting(json, "fogheightend", fogheightend, fogheightend_setting);
    ReadScalarSetting(json, "fogheightstartdensity", fogheightstartdensity, fogheightstartdensity_setting);
    ReadScalarSetting(json, "fogheightenddensity", fogheightenddensity, fogheightenddensity_setting);
    ReadVec3Setting(json, "fogheightcolor", fogheightcolor, fogheightcolor_setting);
    return true;
}

bool WPScene::FromJson(const nlohmann::json& json) {
    return FromJson(json, WPSceneGeneral::kSceneVersionUnknown);
}

bool WPScene::FromJson(const nlohmann::json& json, uint16_t pkg_version_stamp) {
    if (! json.is_object()) return false;
    pkg_version = pkg_version_stamp;
    if (const auto found = json.find("version"); found != json.end() && found->is_number_unsigned()) {
        version = found->get<uint32_t>();
    }
    // A block that is missing or is not an object leaves its defaults; the
    // general block is read whether or not the camera block is there.
    if (const auto found = json.find("camera"); found != json.end() && found->is_object()) {
        camera.FromJson(*found);
    } else {
        LOG_ERROR("scene has no camera block, using defaults");
    }
    if (const auto found = json.find("general"); found != json.end() && found->is_object()) {
        general.FromJson(*found, pkg_version_stamp);
    } else {
        LOG_ERROR("scene has no general block, using defaults");
    }
    return true;
}
