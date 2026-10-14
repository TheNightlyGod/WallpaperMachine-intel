#pragma once

#include "WPJson.hpp"
#include "WPImageObject.h"
#include "WPObjectSchema.hpp"

#include <array>
#include <cstdint>
#include <nlohmann/json.hpp>
#include <sstream>
#include <string>
#include <vector>

namespace wallpaper
{
namespace fs
{
class VFS;
}

namespace wpscene
{

inline const nlohmann::json& UnwrapMiscSettingValue(const nlohmann::json& value) {
    if (value.is_object() && value.contains("value")) return value.at("value");
    return value;
}

inline bool HasDynamicMiscSetting(const nlohmann::json& value) {
    return value.is_object() && (value.contains("script") || value.contains("user"));
}

inline void ReadMiscVec3Setting(const nlohmann::json& json, const char* key,
                                std::array<float, 3>* destination,
                                nlohmann::json* setting, bool* dynamic) {
    if (! json.contains(key) || destination == nullptr || setting == nullptr ||
        dynamic == nullptr) {
        return;
    }

    *setting = json.at(key);
    *dynamic = HasDynamicMiscSetting(*setting);

    const auto& source = UnwrapMiscSettingValue(*setting);
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

struct WPMiscObjectBase {
    int32_t              id { 0 };
    int32_t              parent_id { -1 };
    std::string          name;
    std::array<float, 3> origin { 0.0f, 0.0f, 0.0f };
    std::array<float, 3> scale { 1.0f, 1.0f, 1.0f };
    std::array<float, 3> angles { 0.0f, 0.0f, 0.0f };
    std::array<float, 2> parallaxDepth { 0.0f, 0.0f };
    bool                 visible { true };
    bool                 locktransforms { false };
    bool                 muteineditor { false };
    bool                 nointerpolation { false };
    bool                 dynamic_origin { false };
    bool                 dynamic_scale { false };
    bool                 dynamic_angles { false };
    bool                 dynamic_visible { false };
    std::vector<int32_t> dependencies;
    nlohmann::json       instance;
    nlohmann::json       origin_setting;
    nlohmann::json       scale_setting;
    nlohmann::json       angles_setting;
    nlohmann::json       visible_setting;
    nlohmann::json       field_bindings;

    void FromCommonJson(const nlohmann::json& json) {
        GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
        GET_JSON_NAME_VALUE_NOWARN(json, "name", name);
        ReadMiscVec3Setting(json, "origin", &origin, &origin_setting, &dynamic_origin);
        ReadMiscVec3Setting(json, "scale", &scale, &scale_setting, &dynamic_scale);
        ReadMiscVec3Setting(json, "angles", &angles, &angles_setting, &dynamic_angles);
        GET_JSON_NAME_VALUE_NOWARN(json, "parallaxDepth", parallaxDepth);
        GET_JSON_NAME_VALUE_NOWARN(json, "visible", visible);
        if (json.contains("visible")) {
            visible_setting  = json.at("visible");
            dynamic_visible = visible_setting.is_object() &&
                              (visible_setting.contains("script") ||
                               visible_setting.contains("user"));
        }
        GET_JSON_NAME_VALUE_NOWARN(json, "locktransforms", locktransforms);
        GET_JSON_NAME_VALUE_NOWARN(json, "muteineditor", muteineditor);
        GET_JSON_NAME_VALUE_NOWARN(json, "nointerpolation", nointerpolation);
        GET_JSON_NAME_VALUE_NOWARN(json, "parent", parent_id);
        ParseDependencies(json, dependencies);
        if (json.contains("instance")) instance = json.at("instance");
        AbsorbFieldBindings(json, field_bindings);
    }
};

struct WPTextObject : WPMiscObjectBase {
    nlohmann::json       text;
    nlohmann::json       font;
    float                pointsize { 12.0f };
    uint32_t             padding { 0 };
    std::string          horizontalalign;
    std::string          verticalalign;
    std::string          anchor;
    std::string          alignment { "center" };
    uint32_t             maxrows { 0 };
    float                maxwidth { 0.0f };
    bool                 limitrows { false };
    bool                 limitwidth { false };
    bool                 limituseellipsis { false };
    std::array<float, 3> color { 1.0f, 1.0f, 1.0f };
    float                alpha { 1.0f };
    float                brightness { 1.0f };
    int32_t              colorBlendMode { 0 };
    std::array<float, 2> size { 0.0f, 0.0f };
    // How the layer's texture (`_rt_imageLayerComposite_<id>`) is addressed
    // outside 0..1, as for an image layer.
    bool                 clampuvs { true };
    bool                 perspective { false };
    bool                 copybackground { false };
    bool                 solid { false };
    bool                 opaquebackground { false };
    bool                 ledsource { false };
    std::array<float, 3> backgroundcolor { 0.0f, 0.0f, 0.0f };
    float                backgroundbrightness { 1.0f };
    std::vector<WPImageEffect> effects;

    bool FromJson(const nlohmann::json& json, fs::VFS& vfs) {
        FromCommonJson(json);
        if (json.contains("text")) text = json.at("text");
        if (json.contains("font")) font = json.at("font");
        GET_JSON_NAME_VALUE_NOWARN(json, "pointsize", pointsize);
        GET_JSON_NAME_VALUE_NOWARN(json, "padding", padding);
        GET_JSON_NAME_VALUE_NOWARN(json, "horizontalalign", horizontalalign);
        GET_JSON_NAME_VALUE_NOWARN(json, "verticalalign", verticalalign);
        GET_JSON_NAME_VALUE_NOWARN(json, "anchor", anchor);
        GET_JSON_NAME_VALUE_NOWARN(json, "alignment", alignment);
        GET_JSON_NAME_VALUE_NOWARN(json, "maxrows", maxrows);
        GET_JSON_NAME_VALUE_NOWARN(json, "maxwidth", maxwidth);
        GET_JSON_NAME_VALUE_NOWARN(json, "limitrows", limitrows);
        GET_JSON_NAME_VALUE_NOWARN(json, "limitwidth", limitwidth);
        GET_JSON_NAME_VALUE_NOWARN(json, "limituseellipsis", limituseellipsis);
        GET_JSON_NAME_VALUE_NOWARN(json, "color", color);
        GET_JSON_NAME_VALUE_NOWARN(json, "alpha", alpha);
        GET_JSON_NAME_VALUE_NOWARN(json, "brightness", brightness);
        GET_JSON_NAME_VALUE_NOWARN(json, "colorBlendMode", colorBlendMode);
        GET_JSON_NAME_VALUE_NOWARN(json, "size", size);
        GET_JSON_NAME_VALUE_NOWARN(json, "clampuvs", clampuvs);
        GET_JSON_NAME_VALUE_NOWARN(json, "perspective", perspective);
        GET_JSON_NAME_VALUE_NOWARN(json, "copybackground", copybackground);
        GET_JSON_NAME_VALUE_NOWARN(json, "solid", solid);
        GET_JSON_NAME_VALUE_NOWARN(json, "opaquebackground", opaquebackground);
        GET_JSON_NAME_VALUE_NOWARN(json, "ledsource", ledsource);
        GET_JSON_NAME_VALUE_NOWARN(json, "backgroundcolor", backgroundcolor);
        GET_JSON_NAME_VALUE_NOWARN(json, "backgroundbrightness", backgroundbrightness);
        if (json.contains("effects")) {
            for (const auto& jE : json.at("effects")) {
                WPImageEffect effect;
                effect.FromJson(jE, vfs);
                effects.push_back(std::move(effect));
            }
        }
        return true;
    }
};

struct WPModelObject : WPMiscObjectBase {
    std::string model;
    std::string attachment;
    bool        perspective { false };
    std::vector<WPPuppetLayer::AnimationLayer> puppet_layers;
    std::vector<nlohmann::json> puppet_layer_settings;

    bool FromJson(const nlohmann::json& json, fs::VFS&) {
        FromCommonJson(json);
        GET_JSON_NAME_VALUE_NOWARN(json, "model", model);
        GET_JSON_NAME_VALUE_NOWARN(json, "attachment", attachment);
        GET_JSON_NAME_VALUE_NOWARN(json, "perspective", perspective);
        ParsePuppetAnimationLayers(json, puppet_layers, puppet_layer_settings);
        return true;
    }
};

struct WPCameraObject : WPMiscObjectBase {
    std::string camera;
    std::string path;
    std::string queuemode;
    float       fov { 0.0f }; // absent/nonpositive inherits the scene's resolved perspective FOV
    float       zoom { 1.0f };
    /// `zoom` as written. The unwrapped float above is the authored default;
    /// a slider the user drags arrives as `{"user": "<property>", "value": n}`
    /// and only this form still names the property.
    nlohmann::json zoom_setting;
    bool        solid { false };
    bool        disablepropagation { false };

    bool FromJson(const nlohmann::json& json, fs::VFS&) {
        FromCommonJson(json);
        GET_JSON_NAME_VALUE_NOWARN(json, "camera", camera);
        GET_JSON_NAME_VALUE_NOWARN(json, "path", path);
        GET_JSON_NAME_VALUE_NOWARN(json, "queuemode", queuemode);
        GET_JSON_NAME_VALUE_NOWARN(json, "fov", fov);
        GET_JSON_NAME_VALUE_NOWARN(json, "zoom", zoom);
        if (json.contains("zoom")) zoom_setting = json.at("zoom");
        GET_JSON_NAME_VALUE_NOWARN(json, "solid", solid);
        GET_JSON_NAME_VALUE_NOWARN(json, "disablepropagation", disablepropagation);
        return true;
    }
};

} // namespace wpscene
} // namespace wallpaper
