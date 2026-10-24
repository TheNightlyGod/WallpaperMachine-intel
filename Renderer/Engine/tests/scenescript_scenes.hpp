// Small scene builders shared by the SceneScript behaviour tests: image layers, an effect with a
// few constants a script can drive, and a "probe" layer a script writes its observations to.
#pragma once

#include "support/script_scene.hpp"
#include "support/scene_package.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <string>
#include <vector>

namespace we_test
{

/// An image layer of the 256x144 canvas, at `origin`, with extra keys merged over it.
inline Json PlainImage(const std::string& model, int id, const std::string& name,
                       const Json& extra = Json::object(), std::vector<Json> effects = {},
                       std::array<float, 3> origin = { 128.0f, 72.0f, 0.0f })
{
    ImageLayer layer;
    layer.id      = id;
    layer.name    = name;
    layer.model   = model;
    layer.origin  = origin;
    layer.size    = { 64.0f, 32.0f };
    layer.extra   = extra;
    layer.effects = std::move(effects);
    return ImageLayerJson(layer);
}

/// Writes the project and the scene for `objects`.
inline void Publish(ScenePackage& package, const std::vector<Json>& objects, const Json& properties = Json::object())
{
    package.SetProject(properties);
    package.SetScene(SceneJson({}, objects));
}

/// An effect whose shader declares a three-component tint, a two-component pair and a number,
/// each of which a scene file can bind to a script, a property or a timeline. Returns the path
/// `EffectUse` takes.
inline std::string AddProbeEffect(ScenePackage& package)
{
    package.InstallStandardAssets();
    static const char kFragment[] = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec3 g_Tint; // {"material":"tint","default":"1 1 1"}
uniform vec2 g_Pair; // {"material":"pair","default":"0 0"}
uniform float g_Flag; // {"material":"flag","default":0}
void main() {
    vec4 texel = texSample2D(g_Texture0, v_TexCoord);
    gl_FragColor = vec4(texel.rgb * g_Tint * (1.0 + g_Flag) + vec3(g_Pair, 0.0), texel.a);
}
)";
    package.AddShader("harness_probe", StandardVertexShader(), kFragment);
    package.PutJson("materials/probe_effect.json",
                    { { "passes", Json::array({ { { "shader", "harness_probe" },
                                                   { "textures", Json::array({ nullptr }) },
                                                   { "blending", "disabled" },
                                                   { "cullmode", "nocull" },
                                                   { "depthtest", "disabled" },
                                                   { "depthwrite", "disabled" } } }) } });
    package.PutJson("effects/probe_effect.json",
                    { { "name", "probe_effect" },
                      { "passes", Json::array({ { { "material", "materials/probe_effect.json" } } }) } });
    return "effects/probe_effect.json";
}

/// A keyed setting: `lanes` curves (one per component), each from `from[i]` at frame 0 to
/// `to[i]` at frame 60 on a 30 fps clock that starts paused, so only a script's `play()` moves it.
inline Json Keyed(const std::vector<double>& from, const std::vector<double>& to, const std::string& name = "")
{
    Json animation = { { "options", { { "fps", 30 }, { "length", 60 }, { "mode", "loop" }, { "startpaused", true } } } };
    if (!name.empty()) animation["options"]["name"] = name;
    for (std::size_t lane = 0; lane < from.size(); ++lane) {
        animation["c" + std::to_string(lane)] =
            Json::array({ { { "frame", 0 }, { "value", from[lane] } }, { { "frame", 60 }, { "value", to[lane] } } });
    }
    return animation;
}

inline std::string Join(const std::vector<std::string>& lines)
{
    std::string text;
    for (const auto& line : lines) text += line + "\n";
    return text;
}

/// The recorded script errors as one line, for a failure message.
inline std::string Describe(const std::vector<std::string>& errors)
{
    std::string text;
    for (const auto& error : errors) text += error + "; ";
    return text;
}

constexpr double kPi = 3.14159265358979323846;

/// Whether every lane of `values` is a finite number.
template<typename Array>
bool AllFinite(const Array& values)
{
    for (const float lane : values) {
        if (!std::isfinite(lane)) return false;
    }
    return true;
}

} // namespace we_test
