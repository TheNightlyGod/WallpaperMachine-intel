// Helpers local to the scene-schema behaviour tests of parts 3 and 4: a "copy" effect over the
// basic image assets, a tintable image shader, and the lookup of every material a layer draws
// with. Header-only; builds on schema_fixtures.hpp and adds nothing to its API.
#pragma once

#include "support/schema_fixtures.hpp"

#include "Scene/SceneCamera.h"
#include "Scene/SceneImageEffectLayer.h"
#include "Scene/SceneMaterial.h"

#include <array>
#include <memory>
#include <string>
#include <vector>

namespace we_schema::p3
{

using wallpaper::Scene;
using wallpaper::SceneMaterial;
using wallpaper::SceneNode;

/// The effect file `effects/copy/effect.json` and its one-pass material. The effect samples what
/// the layer drew so far (`previous`); a layer using it owns one material more than without.
inline FileMap CopyEffectAssets()
{
    FileMap files;
    PutJson(files, "/effects/copy/effect.json",
            { { "name", "copy" },
              { "passes", Json::array({ { { "material", "effect_mat.json" }, { "bind", Json::array({ { { "name", "previous" }, { "index", 0 } } }) } } }) } });
    PutJson(files, "/effect_mat.json",
            { { "passes", Json::array({ { { "blending", "translucent" },
                                          { "cullmode", "nocull" },
                                          { "depthtest", "disabled" },
                                          { "depthwrite", "disabled" },
                                          { "shader", "genericimage" },
                                          { "textures", Json::array({ nullptr }) } } }) } });
    return files;
}

/// The `effects` entry that applies the copy effect with the given effect id.
inline Json CopyEffectEntry(int id)
{
    return Json::array({ { { "file", "effects/copy/effect.json" }, { "id", id }, { "visible", true } } });
}

/// Basic image assets whose `genericimage` fragment shader reads the layer colour `g_Color4`.
inline FileMap TintableAssets(const std::string& image_shader = "genericimage")
{
    FileMap files = BasicAssets();
    Add(files, CopyEffectAssets());
    const std::string vertex = files["/shaders/genericimage.vert"];
    files["/shaders/genericimage.frag"] = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec4 g_Color4;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Color4;
}
)";
    // A second shader that also declares a brightness of its own.
    files["/shaders/genericimage2.vert"] = vertex;
    files["/shaders/genericimage2.frag"] = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec4 g_Color4;
uniform float g_Brightness; // {"material":"Brightness","default":1,"range":[0,2]}
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Color4 * g_Brightness;
}
)";
    files["/mat.json"] = Json { { "passes", Json::array({ { { "blending", "translucent" },
                                                            { "cullmode", "nocull" },
                                                            { "depthtest", "disabled" },
                                                            { "depthwrite", "disabled" },
                                                            { "shader", image_shader },
                                                            { "textures", Json::array({ "a.tex" }) } } }) } }
                              .dump();
    return files;
}

/// A layer drawn through its own mesh and, when it has effects, through the passes of its chain.
/// Every material the layer is composed of: the node's own mesh materials, then those of every
/// pass of every effect.
inline std::vector<SceneMaterial*> MaterialsOf(Scene& scene, SceneNode& node)
{
    std::vector<SceneMaterial*> materials;
    if (node.Mesh() != nullptr) {
        for (const auto& slot : node.Mesh()->MaterialSlots()) {
            if (slot != nullptr) materials.push_back(slot.get());
        }
    }
    const auto camera = scene.cameras.find(node.Camera());
    if (camera == scene.cameras.end() || camera->second == nullptr || !camera->second->HasImgEffect()) return materials;
    auto& chain = camera->second->GetImgEffect();
    for (std::size_t i = 0; i < chain->EffectCount(); ++i) {
        for (auto& pass : chain->GetEffect(i)->nodes) {
            if (pass.sceneNode == nullptr || pass.sceneNode->Mesh() == nullptr) continue;
            for (const auto& slot : pass.sceneNode->Mesh()->MaterialSlots()) {
                if (slot != nullptr) materials.push_back(slot.get());
            }
        }
    }
    return materials;
}

/// The lanes of constant `name` of `material`; empty when it has none.
inline std::vector<float> Constant(const SceneMaterial& material, const std::string& name)
{
    const auto found = material.customShader.constValues.find(name);
    if (found == material.customShader.constValues.end()) return {};
    return { found->second.data(), found->second.data() + found->second.size() };
}

/// A scene document with `objects` on the quiet canvas.
inline Json CanvasOf(Json objects, const Json& general_patch = Json::object())
{
    return QuietScene(std::move(objects), general_patch);
}

/// A plain image layer.
inline Json ImageObject(int id, const std::string& name, const Json& extra = Json::object())
{
    Json layer = { { "id", id },
                   { "name", name },
                   { "image", "image.json" },
                   { "origin", Json::array({ 0, 0, 0 }) },
                   { "scale", Json::array({ 1, 1, 1 }) },
                   { "angles", Json::array({ 0, 0, 0 }) },
                   { "visible", true } };
    for (const auto& [key, value] : extra.items()) layer[key] = value;
    return layer;
}

/// A layer with no media whose origin is the result of `body` (JavaScript statements that end in
/// `return new Vec3(...)`): it reports on the scene through `runtime.NodeTranslate(name)`.
inline Json ReaderObject(int id, const std::string& name, const std::string& body)
{
    return { { "id", id },
             { "name", name },
             { "origin", { { "value", "0 0 0" }, { "script", "export function update() { " + body + " }" } } },
             { "visible", true } };
}

} // namespace we_schema::p3
