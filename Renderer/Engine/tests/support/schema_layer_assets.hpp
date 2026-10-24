// Layer-level fixtures shared by the schema parts that follow the colour, alpha and vector
// constants of image layers (scene_schema_part09_test, _part10_test, _part11_test): the shader
// files those layers draw with, the effect files they chain, scene-object builders, and readers
// for the materials a parsed layer owns.
//
// Header only and part-local on purpose: the shared schema_fixtures library stays unchanged.
// Everything lives in `we_schema::layers`, never touches the disk, and draws nothing.
#pragma once

#include "support/schema_fixtures.hpp"

#include "Scene/SceneCamera.h"
#include "Scene/SceneImageEffectLayer.h"
#include "Scene/SceneMaterial.h"

#include <gtest/gtest.h>

#include <array>
#include <cstddef>
#include <initializer_list>
#include <string>
#include <utility>
#include <vector>

namespace we_schema::layers
{

using wallpaper::Scene;
using wallpaper::SceneMaterial;

inline const char* const kPassThroughVertex = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
uniform mat4 g_ModelViewProjectionMatrix;
void main() {
    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
    v_TexCoord = a_TexCoord;
}
)";

inline void PutShaderPair(FileMap& files, const std::string& name, const std::string& vertex, const std::string& fragment)
{
    files["/shaders/" + name + ".vert"] = vertex;
    files["/shaders/" + name + ".frag"] = fragment;
}

/// A material file with exactly one translucent, nocull, depth-free pass.
inline Json OnePassMaterial(const std::string& shader, const Json& textures, const Json& constants = Json::object())
{
    Json pass = { { "blending", "translucent" },
                  { "cullmode", "nocull" },
                  { "depthtest", "disabled" },
                  { "depthwrite", "disabled" },
                  { "shader", shader },
                  { "textures", textures } };
    if (!constants.empty()) pass["constantshadervalues"] = constants;
    return { { "passes", Json::array({ pass }) } };
}

/// Image layers whose material reads a layer colour, plus a plain "copy" effect and an
/// "opacity" effect whose own `alpha` constant maps to `g_UserAlpha`:
///   /image.json (64x32 over /mat.json), /mat.json (shader genericimage, texture a.tex),
///   /effects/copy/effect.json over /effect_mat.json (genericimage, no texture),
///   /effects/opacity/effect.json over /opacity_mat.json (shader opacity).
inline FileMap TintAssets()
{
    FileMap files;
    PutShaderPair(files, "genericimage", kPassThroughVertex, R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec4 g_Color4;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Color4;
}
)");
    PutShaderPair(files, "opacity", kPassThroughVertex, R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_UserAlpha; // {"material":"alpha","default":1.0}
void main() {
    vec4 colour = texSample2D(g_Texture0, v_TexCoord);
    colour.a *= g_UserAlpha;
    gl_FragColor = colour;
}
)");
    PutJson(files, "/image.json", { { "width", 64 }, { "height", 32 }, { "material", "mat.json" } });
    PutJson(files, "/mat.json", OnePassMaterial("genericimage", Json::array({ "a.tex" })));
    files["/materials/a.tex.tex"] = "";
    PutJson(files, "/effect_mat.json", OnePassMaterial("genericimage", Json::array({ nullptr })));
    PutJson(files, "/effects/copy/effect.json",
            { { "name", "copy" },
              { "passes", Json::array({ { { "material", "effect_mat.json" },
                                          { "bind", Json::array({ { { "name", "previous" }, { "index", 0 } } }) } } }) } });
    PutJson(files, "/opacity_mat.json", OnePassMaterial("opacity", Json::array({ nullptr })));
    PutJson(files, "/effects/opacity/effect.json",
            { { "name", "opacity" },
              { "passes", Json::array({ { { "material", "opacity_mat.json" },
                                          { "bind", Json::array({ { { "name", "previous" }, { "index", 0 } } }) } } }) } });
    return files;
}

/// An image layer object over /image.json with neutral placement, visible, `alpha` as given.
inline Json ImageLayer(int id, const std::string& name, const Json& patch = Json::object())
{
    Json layer = { { "id", id },
                   { "name", name },
                   { "image", "image.json" },
                   { "origin", Json::array({ 0, 0, 0 }) },
                   { "scale", Json::array({ 1, 1, 1 }) },
                   { "angles", Json::array({ 0, 0, 0 }) },
                   { "visible", true } };
    for (const auto& [key, value] : patch.items()) layer[key] = value;
    return layer;
}

/// An effect entry for a layer's `effects` array.
inline Json EffectEntry(const std::string& file, int id, const Json& patch = Json::object())
{
    Json effect = { { "file", file }, { "id", id }, { "visible", true } };
    for (const auto& [key, value] : patch.items()) effect[key] = value;
    return effect;
}
inline Json CopyEffect(int id, const Json& patch = Json::object())
{
    return EffectEntry("effects/copy/effect.json", id, patch);
}
/// The opacity effect with its own `alpha` constant, when `alpha` is given.
inline Json OpacityEffect(int id, const Json& alpha = Json())
{
    Json patch = Json::object();
    if (!alpha.is_null()) {
        patch["passes"] = Json::array({ { { "id", id + 1 }, { "constantshadervalues", { { "alpha", alpha } } } } });
    }
    return EffectEntry("effects/opacity/effect.json", id, patch);
}

/// A scripted setting `{ "value": value, "script": source }`.
inline Json Scripted(const Json& value, const std::string& source)
{
    return { { "value", value }, { "script", source } };
}

/// Every material a root layer draws with, in order: its own, then each effect pass's.
/// Empty when the layer does not exist.
inline std::vector<SceneMaterial*> LayerMaterials(Scene& scene, const std::string& name)
{
    std::vector<SceneMaterial*> materials;
    auto*                       node = FindRootChild(scene, name);
    if (node == nullptr || node->Mesh() == nullptr || node->Mesh()->Material() == nullptr) return materials;
    materials.push_back(node->Mesh()->Material());
    const auto camera = scene.cameras.find(node->Camera());
    if (camera == scene.cameras.end() || !camera->second->HasImgEffect()) return materials;
    auto& chain = camera->second->GetImgEffect();
    for (std::size_t i = 0; i < chain->EffectCount(); ++i) {
        for (auto& effect_node : chain->GetEffect(i)->nodes) {
            if (effect_node.sceneNode == nullptr || effect_node.sceneNode->Mesh() == nullptr) continue;
            if (auto* material = effect_node.sceneNode->Mesh()->Material()) materials.push_back(material);
        }
    }
    return materials;
}

/// Reads `key` of a material; fails the test (and returns an empty vector) when it is missing.
inline std::vector<float> Constant(const SceneMaterial& material, const std::string& key)
{
    std::vector<float> values;
    const auto&        constants = material.customShader.constValues;
    if (!constants.contains(key)) {
        ADD_FAILURE() << "material has no constant " << key;
        return values;
    }
    const auto& value = constants.at(key);
    for (std::size_t i = 0; i < value.size(); ++i) values.push_back(value[i]);
    return values;
}

/// Checks the first `expected.size()` lanes of constant `key` (exact float equality, 4 ULP).
inline void ExpectLanes(const SceneMaterial& material, const std::string& key, std::initializer_list<float> expected)
{
    const auto actual = Constant(material, key);
    ASSERT_GE(actual.size(), expected.size()) << key;
    std::size_t lane = 0;
    for (const float want : expected) {
        EXPECT_FLOAT_EQ(actual[lane], want) << key << "[" << lane << "]";
        ++lane;
    }
}

/// Every material of layer `name` (there must be `material_count`) carries `colour` as its tint:
/// g_Color is the colour, g_Color4 is the colour times `brightness` with `alpha` as its fourth lane.
inline void ExpectTint(Scene& scene, const std::string& name, std::size_t material_count, std::array<float, 3> colour,
                       float alpha = 0.5f, float brightness = 1.0f)
{
    SCOPED_TRACE(name);
    const auto materials = LayerMaterials(scene, name);
    ASSERT_EQ(materials.size(), material_count);
    for (std::size_t m = 0; m < materials.size(); ++m) {
        SCOPED_TRACE("material " + std::to_string(m));
        ExpectLanes(*materials[m], "g_Color4",
                    { colour[0] * brightness, colour[1] * brightness, colour[2] * brightness, alpha });
        ExpectLanes(*materials[m], "g_Color", { colour[0], colour[1], colour[2] });
    }
}

// ---- vector shader constants ------------------------------------------------------------

/// One image layer whose single-pass material has `constants` as its `constantshadervalues`.
struct VectorLayer {
    std::string name;
    Json        constants;
};

/// Key frames `[{frame, value}, ...]` of one curve.
inline Json Curve(std::initializer_list<std::pair<double, double>> keys)
{
    Json curve = Json::array();
    for (const auto& [frame, value] : keys) curve.push_back({ { "frame", frame }, { "value", value } });
    return curve;
}

/// `{ "value": [x, y], "animation": { "options": options, "c0": c0, "c1": c1 } }`; a null curve is
/// left out, so that component keeps its static value.
inline Json VectorConstant(double x, double y, const Json& options = Json(), const Json& c0 = Json(), const Json& c1 = Json())
{
    Json constant = { { "value", Json::array({ x, y }) } };
    if (options.is_null()) return constant;
    Json animation = { { "options", options } };
    if (!c0.is_null()) animation["c0"] = c0;
    if (!c1.is_null()) animation["c1"] = c1;
    constant["animation"] = std::move(animation);
    return constant;
}

/// Timeline options at 30 fps.
inline Json TimelineOptions(int length, const std::string& mode, const Json& extra = Json::object())
{
    Json options = { { "fps", 30 }, { "length", length }, { "mode", mode } };
    for (const auto& [key, value] : extra.items()) options[key] = value;
    return options;
}

/// Files for layers of the shader `foldpage`, which declares the two vec2 uniforms `u_Point1` and
/// `u_Point2` (material keys `point1` / `point2`, default "0 0"): the shader pair and, per
/// layer, `/<name>.json` (64x32) over `/mat/<name>.json`.
inline FileMap VectorAssets(const std::vector<VectorLayer>& layers, const std::string& extra_declarations = {})
{
    FileMap files;
    PutShaderPair(files, "foldpage", kPassThroughVertex, R"(varying vec2 v_TexCoord;
uniform vec2 u_Point1; // {"material":"point1","default":"0 0"}
uniform vec2 u_Point2; // {"material":"point2","default":"0 0"}
)" + extra_declarations + R"(void main() {
    gl_FragColor = vec4(u_Point1, u_Point2);
}
)");
    for (const auto& layer : layers) {
        PutJson(files, "/" + layer.name + ".json", { { "width", 64 }, { "height", 32 }, { "material", "mat/" + layer.name + ".json" } });
        PutJson(files, "/mat/" + layer.name + ".json", OnePassMaterial("foldpage", Json(), layer.constants));
    }
    return files;
}

/// The quiet canvas scene with one visible image layer per entry (ids from 400).
inline Json VectorSceneJson(const std::vector<VectorLayer>& layers)
{
    Json objects = Json::array();
    int  id      = 400;
    for (const auto& layer : layers) {
        objects.push_back({ { "id", id++ },
                            { "name", layer.name },
                            { "image", layer.name + ".json" },
                            { "origin", Json::array({ 0, 0, 0 }) },
                            { "scale", Json::array({ 1, 1, 1 }) },
                            { "angles", Json::array({ 0, 0, 0 }) },
                            { "visible", true } });
    }
    return QuietScene(std::move(objects), { { "bloom", false } });
}

/// The `foldpage` material of layer `name` (the live constants live in it); null when absent.
inline SceneMaterial* FoldMaterial(Scene& scene, const std::string& name)
{
    auto* node = FindRootChild(scene, name);
    return node != nullptr && node->Mesh() != nullptr ? node->Mesh()->Material() : nullptr;
}

/// The paused pair of fold constants: `point1` follows `point2`'s clock, which starts paused.
inline Json PausedFoldConstants()
{
    return { { "point1",
               VectorConstant(0.375, 0.875, TimelineOptions(3, "single", { { "parent", { { "key", "point2" } } } }),
                              Curve({ { 0, 0.875 }, { 3, 0.375 } }), Curve({ { 0, 0.875 }, { 3, 0.875 } })) },
             { "point2",
               VectorConstant(0.75, 0.375,
                              TimelineOptions(3, "single",
                                              { { "startpaused", true }, { "name", "fold" },
                                                { "children", Json::array({ { { "key", "point1" } } }) } }),
                              Curve({ { 0, 0.75 }, { 3, 0.25 } }), Curve({ { 0, 0.375 }, { 3, 0.375 } })) } };
}

} // namespace we_schema::layers
