#pragma once

#include "WPJson.hpp"
#include "WPImageObject.h"
#include "WPObjectSchema.hpp"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
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

// A setting Wallpaper Engine registers as an enumeration, read as the word it
// is written as. A key that is missing leaves `word` as it was. A key that is
// there and is not a string (a number, `null`, an object) names no entry, and
// takes the registry's first one, `first_entry`; a typed string reader would
// leave the default there instead. Whether a string matches an entry is for the
// reader of the word to decide.
inline void ReadMiscEnumWord(const nlohmann::json& json, const char* key, const char* first_entry,
                             std::string& word) {
    if (! json.contains(key)) return;
    const auto& source = json.at(key);
    word               = source.is_string() ? source.get<std::string>() : std::string(first_entry);
}

inline void ReadMiscVec3Setting(const nlohmann::json& json, const char* key,
                                std::array<float, 3>* destination,
                                nlohmann::json* setting, bool* dynamic) {
    if (! json.contains(key) || destination == nullptr || setting == nullptr) return;

    *setting = json.at(key);
    if (dynamic != nullptr) *dynamic = HasDynamicMiscSetting(*setting);

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

/// A two-lane setting as Wallpaper Engine's Vec2 properties read it. A number
/// sets both lanes. A string is "x y": the first number is lane x and the one
/// after the first space is lane y, so a lone "x" leaves y at 0. An object is
/// read through its `value`, as a property or script binding wraps one. A JSON
/// array is not a form the reference reads, and leaves the default.
inline void ReadMiscVec2Setting(const nlohmann::json& json, const char* key,
                                std::array<float, 2>& destination) {
    if (! json.contains(key)) return;
    const auto& source = UnwrapMiscSettingValue(json.at(key));
    if (source.is_number()) {
        const float scalar = source.get<float>();
        destination        = { scalar, scalar };
    } else if (source.is_string()) {
        const auto  text  = source.get<std::string>();
        const char* begin = text.c_str();
        char*       end   = nullptr;
        destination       = { std::strtof(begin, &end), 0.0f };
        const char* space = std::strchr(begin, ' ');
        if (space != nullptr) {
            while (*space == ' ') ++space;
            if (*space != '\0') destination[1] = std::strtof(space, nullptr);
        }
    }
}

struct WPMiscObjectBase {
    int32_t              id { 0 };
    int32_t              parent_id { -1 };
    std::string          name;
    std::array<float, 3> origin { 0.0f, 0.0f, 0.0f };
    std::array<float, 3> scale { 1.0f, 1.0f, 1.0f };
    std::array<float, 3> angles { 0.0f, 0.0f, 0.0f };
    // Wallpaper Engine's default for an object that leaves the key out.
    std::array<float, 2> parallaxDepth { 1.0f, 1.0f };
    bool                 visible { true };
    bool                 locktransforms { false };
    bool                 muteineditor { false };
    bool                 nointerpolation { false };
    bool                 dynamic_origin { false };
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
        ReadMiscVec3Setting(json, "scale", &scale, &scale_setting, nullptr);
        ReadMiscVec3Setting(json, "angles", &angles, &angles_setting, nullptr);
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
    // Wallpaper Engine's default for a text object that leaves the key out: Arial.
    nlohmann::json       font = "systemfont_arial";
    // Wallpaper Engine's defaults for a text object that leaves these keys out.
    float                pointsize { 32.0f };
    // Wallpaper Engine's defaults for the key being absent: a 32 pixel margin
    // on each axis and no extra glyph or line spacing. Whether the margin
    // applies is the parser's decision; see `TextCardIsPadded`.
    std::array<float, 2> padding { 32.0f, 32.0f };
    std::array<float, 2> spacing { 0.0f, 0.0f };
    // Wallpaper Engine registers both as enumerations: a key that is missing
    // leaves the layer centred. `TextLayer` reads the word; see
    // `ParseTextHorizontalAlign` and `ParseTextVerticalAlign`. There is no
    // `alignment` key on a text object, and this one is not read.
    std::string          horizontalalign { "center" };
    std::string          verticalalign { "center" };
    // The screen edge the layer follows, which is not a point of the layer.
    std::string          anchor;
    uint32_t             maxrows { 1 };
    float                maxwidth { 500.0f };
    bool                 limitrows { false };
    bool                 limitwidth { false };
    bool                 limituseellipsis { false };
    bool                 blockalign { false };
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
    // `solid` layers are hit-tested for the cursor, and Wallpaper Engine's
    // default is on; a layer with `disablepropagation` hides the layers behind it
    // from the cursor where it is under it.
    bool                 solid { true };
    bool                 disablepropagation { false };
    bool                 opaquebackground { false };
    bool                 ledsource { false };
    std::array<float, 3> backgroundcolor { 0.0f, 0.0f, 0.0f };
    float                backgroundbrightness { 1.0f };
    // The signed-distance font shader's looks, with Wallpaper Engine's defaults
    // for the keys being absent. `msdf` only picks how the glyph edges are
    // rebuilt, so it is read and nothing more.
    bool                 msdf { false };
    bool                 outline { false };
    float                outlinethickness { 4.0f };
    std::array<float, 3> outlinecolor { 0.0f, 0.0f, 0.0f };
    bool                 blur { false };
    float                blursize { 6.0f };
    bool                 dropshadow { false };
    float                dropshadowsize { 6.0f };
    float                dropshadowopacity { 1.0f };
    std::array<float, 2> dropshadowoffset { 4.0f, 4.0f };
    std::array<float, 3> dropshadowcolor { 0.0f, 0.0f, 0.0f };
    std::vector<WPImageEffect> effects;

    bool FromJson(const nlohmann::json& json, fs::VFS& vfs) {
        FromCommonJson(json);
        if (json.contains("text")) text = json.at("text");
        if (json.contains("font")) font = json.at("font");
        GET_JSON_NAME_VALUE_NOWARN(json, "pointsize", pointsize);
        ReadMiscVec2Setting(json, "padding", padding);
        ReadMiscVec2Setting(json, "spacing", spacing);
        // A key that is there but not a string takes the registry's first entry,
        // which is `left` for the horizontal registry and `center` for the vertical.
        ReadMiscEnumWord(json, "horizontalalign", "left", horizontalalign);
        ReadMiscEnumWord(json, "verticalalign", "center", verticalalign);
        GET_JSON_NAME_VALUE_NOWARN(json, "anchor", anchor);
        GET_JSON_NAME_VALUE_NOWARN(json, "maxrows", maxrows);
        GET_JSON_NAME_VALUE_NOWARN(json, "maxwidth", maxwidth);
        GET_JSON_NAME_VALUE_NOWARN(json, "limitrows", limitrows);
        GET_JSON_NAME_VALUE_NOWARN(json, "limitwidth", limitwidth);
        GET_JSON_NAME_VALUE_NOWARN(json, "limituseellipsis", limituseellipsis);
        GET_JSON_NAME_VALUE_NOWARN(json, "blockalign", blockalign);
        GET_JSON_NAME_VALUE_NOWARN(json, "color", color);
        GET_JSON_NAME_VALUE_NOWARN(json, "alpha", alpha);
        GET_JSON_NAME_VALUE_NOWARN(json, "brightness", brightness);
        GET_JSON_NAME_VALUE_NOWARN(json, "colorBlendMode", colorBlendMode);
        GET_JSON_NAME_VALUE_NOWARN(json, "size", size);
        GET_JSON_NAME_VALUE_NOWARN(json, "clampuvs", clampuvs);
        GET_JSON_NAME_VALUE_NOWARN(json, "perspective", perspective);
        GET_JSON_NAME_VALUE_NOWARN(json, "copybackground", copybackground);
        GET_JSON_NAME_VALUE_NOWARN(json, "solid", solid);
        GET_JSON_NAME_VALUE_NOWARN(json, "disablepropagation", disablepropagation);
        GET_JSON_NAME_VALUE_NOWARN(json, "opaquebackground", opaquebackground);
        GET_JSON_NAME_VALUE_NOWARN(json, "ledsource", ledsource);
        GET_JSON_NAME_VALUE_NOWARN(json, "backgroundcolor", backgroundcolor);
        GET_JSON_NAME_VALUE_NOWARN(json, "backgroundbrightness", backgroundbrightness);
        GET_JSON_NAME_VALUE_NOWARN(json, "msdf", msdf);
        GET_JSON_NAME_VALUE_NOWARN(json, "outline", outline);
        GET_JSON_NAME_VALUE_NOWARN(json, "outlinethickness", outlinethickness);
        GET_JSON_NAME_VALUE_NOWARN(json, "outlinecolor", outlinecolor);
        GET_JSON_NAME_VALUE_NOWARN(json, "blur", blur);
        GET_JSON_NAME_VALUE_NOWARN(json, "blursize", blursize);
        GET_JSON_NAME_VALUE_NOWARN(json, "dropshadow", dropshadow);
        GET_JSON_NAME_VALUE_NOWARN(json, "dropshadowsize", dropshadowsize);
        GET_JSON_NAME_VALUE_NOWARN(json, "dropshadowopacity", dropshadowopacity);
        ReadMiscVec2Setting(json, "dropshadowoffset", dropshadowoffset);
        GET_JSON_NAME_VALUE_NOWARN(json, "dropshadowcolor", dropshadowcolor);
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
    bool        solid { true };
    bool        disablepropagation { false };
    std::vector<WPPuppetLayer::AnimationLayer> puppet_layers;
    std::vector<nlohmann::json> puppet_layer_settings;

    bool FromJson(const nlohmann::json& json, fs::VFS&) {
        FromCommonJson(json);
        GET_JSON_NAME_VALUE_NOWARN(json, "model", model);
        GET_JSON_NAME_VALUE_NOWARN(json, "attachment", attachment);
        GET_JSON_NAME_VALUE_NOWARN(json, "perspective", perspective);
        GET_JSON_NAME_VALUE_NOWARN(json, "solid", solid);
        GET_JSON_NAME_VALUE_NOWARN(json, "disablepropagation", disablepropagation);
        ParsePuppetAnimationLayers(json, puppet_layers, puppet_layer_settings);
        return true;
    }
};

/// A `shape` object (`"shape": "quad"`): a quad as tall as the canvas on both axes
/// that Wallpaper Engine draws through its effects, light shafts being the one the
/// editor ships. It has no texture; the last of its effects is drawn straight onto
/// the scene.
struct WPShapeObject : WPMiscObjectBase {
    std::string                shape;
    std::vector<WPImageEffect> effects;

    bool FromJson(const nlohmann::json& json, fs::VFS& vfs) {
        FromCommonJson(json);
        GET_JSON_NAME_VALUE_NOWARN(json, "shape", shape);
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
