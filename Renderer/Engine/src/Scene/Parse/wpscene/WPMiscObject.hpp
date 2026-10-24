// Clean-room implementation from the WallpaperMachine spec p1-scene-structure.md; written without access to the original source.
#pragma once

#include "WPJson.hpp"
#include "WPImageObject.h"
#include "WPObjectSchema.hpp"

#include <algorithm>
#include <array>
#include <cmath>
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
    return UnwrapSetting(value);
}

/// A two-lane text value: a number fills both lanes, a string holds two numbers
/// of which a missing second one means 0, an array is not read.
inline void ReadMiscPairSetting(const nlohmann::json& json, const char* key,
                                std::array<float, 2>& out) {
    if (! json.contains(key)) return;
    const auto& value = UnwrapSetting(json.at(key));
    if (value.is_number()) {
        out = { value.get<float>(), value.get<float>() };
    } else if (value.is_string()) {
        std::istringstream words(value.get<std::string>());
        float              first = 0.0f, second = 0.0f;
        if (! (words >> first)) return;
        if (! (words >> second)) second = 0.0f;
        out = { first, second };
    }
}

/// Reads the `effects` list of an object. An effect that cannot be read builds
/// nothing and is left out; the object keeps the rest.
inline void ReadMiscEffects(const nlohmann::json& json, fs::VFS& vfs,
                            std::vector<WPImageEffect>& effects) {
    if (! json.contains("effects") || ! json.at("effects").is_array()) return;
    for (const auto& entry : json.at("effects")) {
        if (! entry.is_object()) continue;
        WPImageEffect effect;
        if (effect.FromJson(entry, vfs)) effects.push_back(std::move(effect));
    }
}

inline void ReadMiscFlag(const nlohmann::json& json, const char* key, bool& out) {
    if (json.contains(key)) ReadFlagSetting(json.at(key), out);
}

inline void ReadMiscNumber(const nlohmann::json& json, const char* key, float& out) {
    if (json.contains(key)) ReadNumberSetting(json.at(key), out);
}

inline void ReadMiscString(const nlohmann::json& json, const char* key, std::string& out) {
    if (json.contains(key)) ReadStringSetting(json.at(key), out);
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
    // Editor-side flags the file stores for the object.
    bool locktransforms { false };
    bool muteineditor { false };
    bool nointerpolation { false };

    // True when a script or property drives the value (the setting below is then bound).
    bool dynamic_origin { false };
    bool dynamic_visible { false };

    std::vector<int32_t> dependencies;   // ids this object needs loaded first
    nlohmann::json       instance;

    // The settings as authored, whole.
    nlohmann::json origin_setting;
    nlohmann::json scale_setting;
    nlohmann::json angles_setting;
    nlohmann::json visible_setting;
    nlohmann::json field_bindings;

    void FromCommonJson(const nlohmann::json& json) {
        if (! json.is_object()) return;
        if (json.contains("id")) ReadInt32(json.at("id"), id);
        if (json.contains("parent")) ReadInt32(json.at("parent"), parent_id);
        ReadMiscString(json, "name", name);

        const auto read_vec3 = [&json](const char* key, std::array<float, 3>& lanes,
                                       nlohmann::json& setting) {
            if (! json.contains(key)) return false;
            setting = json.at(key);
            ReadTolerantVec3(setting, lanes);
            return true;
        };
        if (read_vec3("origin", origin, origin_setting)) dynamic_origin = SettingIsDriven(origin_setting);
        read_vec3("scale", scale, scale_setting);
        read_vec3("angles", angles, angles_setting);
        if (json.contains("parallaxDepth")) ReadStrictVec(json.at("parallaxDepth"), parallaxDepth);

        if (json.contains("visible")) {
            visible_setting = json.at("visible");
            ReadFlagSetting(visible_setting, visible);
            dynamic_visible = VisibilityIsBound(visible_setting);
        }
        ReadMiscFlag(json, "locktransforms", locktransforms);
        ReadMiscFlag(json, "muteineditor", muteineditor);
        ReadMiscFlag(json, "nointerpolation", nointerpolation);
        ParseDependencies(json, dependencies);
        if (const auto block = json.find("instance"); block != json.end() && block->is_object()) {
            instance = *block;
        }
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
        if (! json.is_object()) return false;
        FromCommonJson(json);
        if (json.contains("text")) text = json.at("text");
        if (json.contains("font")) font = json.at("font");
        ReadMiscNumber(json, "pointsize", pointsize);
        ReadMiscPairSetting(json, "padding", padding);
        ReadMiscPairSetting(json, "spacing", spacing);
        ReadMiscEnumWord(json, "horizontalalign", "left", horizontalalign);
        ReadMiscEnumWord(json, "verticalalign", "center", verticalalign);
        ReadMiscEnumWord(json, "anchor", "none", anchor);
        if (json.contains("maxrows")) {
            double rows = 0.0;
            if (ReadNumberSetting(json.at("maxrows"), rows) && std::isfinite(rows) && rows >= 0.0) {
                maxrows = static_cast<uint32_t>(std::min(rows, 4294967295.0));
            }
        }
        ReadMiscNumber(json, "maxwidth", maxwidth);
        ReadMiscFlag(json, "limitrows", limitrows);
        ReadMiscFlag(json, "limitwidth", limitwidth);
        ReadMiscFlag(json, "limituseellipsis", limituseellipsis);
        ReadMiscFlag(json, "blockalign", blockalign);
        if (json.contains("color")) ReadStrictVec(json.at("color"), color);
        ReadMiscNumber(json, "alpha", alpha);
        ReadMiscNumber(json, "brightness", brightness);
        if (json.contains("colorBlendMode")) ReadNumberSetting(json.at("colorBlendMode"), colorBlendMode);
        if (json.contains("size")) ReadStrictVec(json.at("size"), size);
        ReadMiscFlag(json, "clampuvs", clampuvs);
        ReadMiscFlag(json, "perspective", perspective);
        ReadMiscFlag(json, "copybackground", copybackground);
        ReadMiscFlag(json, "solid", solid);
        ReadMiscFlag(json, "disablepropagation", disablepropagation);
        ReadMiscFlag(json, "opaquebackground", opaquebackground);
        ReadMiscFlag(json, "ledsource", ledsource);
        if (json.contains("backgroundcolor")) ReadStrictVec(json.at("backgroundcolor"), backgroundcolor);
        ReadMiscNumber(json, "backgroundbrightness", backgroundbrightness);
        ReadMiscFlag(json, "msdf", msdf);
        ReadMiscFlag(json, "outline", outline);
        ReadMiscNumber(json, "outlinethickness", outlinethickness);
        if (json.contains("outlinecolor")) ReadStrictVec(json.at("outlinecolor"), outlinecolor);
        ReadMiscFlag(json, "blur", blur);
        ReadMiscNumber(json, "blursize", blursize);
        ReadMiscFlag(json, "dropshadow", dropshadow);
        ReadMiscNumber(json, "dropshadowsize", dropshadowsize);
        ReadMiscNumber(json, "dropshadowopacity", dropshadowopacity);
        ReadMiscPairSetting(json, "dropshadowoffset", dropshadowoffset);
        if (json.contains("dropshadowcolor")) ReadStrictVec(json.at("dropshadowcolor"), dropshadowcolor);
        ReadMiscEffects(json, vfs, effects);
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
        if (! json.is_object()) return false;
        FromCommonJson(json);
        ReadMiscString(json, "model", model);
        ReadMiscString(json, "attachment", attachment);
        ReadMiscFlag(json, "perspective", perspective);
        ReadMiscFlag(json, "solid", solid);
        ReadMiscFlag(json, "disablepropagation", disablepropagation);
        if (json.contains("animationlayers")) {
            ParsePuppetAnimationLayers(json.at("animationlayers"), puppet_layers,
                                       puppet_layer_settings);
        }
        return ! model.empty();
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
        if (! json.is_object()) return false;
        FromCommonJson(json);
        ReadMiscString(json, "shape", shape);
        ReadMiscEffects(json, vfs, effects);
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
        if (! json.is_object()) return false;
        FromCommonJson(json);
        ReadMiscString(json, "camera", camera);
        ReadMiscString(json, "path", path);
        ReadMiscString(json, "queuemode", queuemode);
        ReadMiscNumber(json, "fov", fov);
        if (json.contains("zoom")) {
            zoom_setting = json.at("zoom");
            ReadNumberSetting(zoom_setting, zoom);
        }
        ReadMiscFlag(json, "solid", solid);
        ReadMiscFlag(json, "disablepropagation", disablepropagation);
        return true;
    }
};

} // namespace wpscene
} // namespace wallpaper
