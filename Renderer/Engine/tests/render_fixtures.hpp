// Small builders shared by the scene-rendering pixel tests: materials, models and effects with
// a fragment shader of the test's own, on top of the scene package fixture.
#pragma once

#include "support/scene_package.hpp"

#include <string>
#include <string_view>

namespace we_test::fixtures
{

/// The pass keys every synthetic material shares: no culling and no depth.
inline Json FlatPass(const std::string& shader, const Json& textures, const std::string& blending)
{
    Json pass = { { "shader", shader },
                  { "blending", blending },
                  { "cullmode", "nocull" },
                  { "depthtest", "disabled" },
                  { "depthwrite", "disabled" } };
    if (!textures.is_null()) pass["textures"] = textures;
    return pass;
}

/// A model drawn with a shader of the test's (installed under `shaders/<shader>`), whose
/// material lists `textures` (an array, possibly with nulls) or none at all when `textures` is
/// null. Returns the path to put in `ImageLayer::model`.
inline std::string AddShaderModel(ScenePackage& package, const std::string& name, const std::string& shader,
                                  std::string_view fragment, const Json& textures,
                                  const std::string& blending = "translucent", const Json& extra_pass = Json::object())
{
    package.InstallStandardAssets();
    package.AddShader(shader, StandardVertexShader(), fragment);
    const std::string material = "materials/" + name + ".json";
    const std::string model    = "models/" + name + ".json";
    Json              pass     = FlatPass(shader, textures, blending);
    for (const auto& [key, value] : extra_pass.items()) pass[key] = value;
    package.PutJson(material, { { "passes", Json::array({ pass }) } });
    package.PutJson(model, { { "material", material }, { "autosize", false } });
    return model;
}

/// An effect of one pass running `fragment`. `textures` is the pass's `textures` array (the
/// chain's picture arrives in slot 0 when it is null), or null for a material that lists none.
inline std::string AddFragmentEffect(ScenePackage& package, const std::string& name, std::string_view fragment,
                                     const Json& textures = Json::array({ nullptr }),
                                     const std::string& blending = "disabled")
{
    package.InstallStandardAssets();
    const std::string shader = "fx_" + name;
    package.AddShader(shader, StandardVertexShader(), fragment);
    const std::string material = "materials/" + name + ".json";
    const std::string effect   = "effects/" + name + ".json";
    package.PutJson(material, { { "passes", Json::array({ FlatPass(shader, textures, blending) }) } });
    package.PutJson(effect, { { "name", name }, { "passes", Json::array({ { { "material", material } } }) } });
    return effect;
}

} // namespace we_test::fixtures
