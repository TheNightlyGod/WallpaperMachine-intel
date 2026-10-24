#pragma once
#include "WPJson.hpp"
#include <nlohmann/json.hpp>
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace wallpaper
{
namespace wpscene
{

class WPMaterialPassBindItem {
public:
    bool        FromJson(const nlohmann::json&);
    std::string name;
    int32_t     index { 0 };
};

struct WPUserTexture {
    std::string name;
    std::string type;
};

/// Whether this binding names an image the runtime supplies, which is the only
/// kind that actually replaces the texture in its slot. A binding that names a
/// project property is left for the authored texture, so the two cases must not
/// be confused: one has its slot substituted, the other does not.
bool IsSystemUserTexture(const WPUserTexture& user_texture);

struct WPConstantShaderValue {
    std::vector<float> value;
    std::string        user;
    /// The choice the flag form `{"user": {"name": ..., "condition": ...}}` compares the
    /// property with; absent for a plain property name.
    std::optional<std::string> user_condition;
    std::string        script;
    nlohmann::json     scriptproperties;
    nlohmann::json     animation;
};

class WPMaterialPass {
public:
    bool                                                FromJson(const nlohmann::json&);
    void                                                Update(const WPMaterialPass&);
    std::vector<std::string>                            textures;
    std::vector<WPUserTexture>                          usertextures;
    std::unordered_map<std::string, int32_t>            combos;
    std::unordered_map<std::string, WPConstantShaderValue> constantshadervalues;
    std::string                                         target;
    std::vector<WPMaterialPassBindItem>                 bind;
};

class WPMaterial {
public:
    bool FromJson(const nlohmann::json&);
    void MergePass(const WPMaterialPass&);
    // Draw state; the defaults are what a pass that names nothing gets.
    std::string blending { "translucent" };
    std::string cullmode { "nocull" };
    std::string depthtest { "disabled" };
    std::string depthwrite { "disabled" };  // draw-state tests rely on this

    std::string                                            shader;
    std::vector<std::string>                               textures;
    std::vector<WPUserTexture>                             usertextures;
    std::unordered_map<std::string, int32_t>               combos;
    std::unordered_map<std::string, WPConstantShaderValue> constantshadervalues;
    bool                                                   use_puppet { false };
};

// JSON round trips. WPMaterial lists fewer keys than the class has members, on purpose.
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(
    WPMaterialPassBindItem,
    name,
    index);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(
    WPUserTexture,
    name,
    type);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(
    WPConstantShaderValue,
    value,
    user);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(
    WPMaterialPass,
    bind,
    target,
    textures,
    combos,
    constantshadervalues);
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(
    WPMaterial,
    blending,
    shader,
    textures,
    combos,
    constantshadervalues);
} // namespace wpscene
} // namespace wallpaper
