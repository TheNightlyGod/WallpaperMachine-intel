// Geometry a scene script builds with `thisScene.createModelData` and draws with
// `thisScene.createLayer({ model })`: the shapes are drawn with their materials and vertex
// colours, `applyData` rewrites a dynamic vertex buffer while the scene runs, and the layer is an
// ordinary script layer (parent, visibility). Pixel checks through the synthetic scene harness;
// every GPU image is private to the process.

#include <gtest/gtest.h>

#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"

#include <string>
#include <vector>

namespace
{
using namespace we_test;

constexpr Rgba kBlack { 0, 0, 0, 255 };
constexpr Rgba kRed { 255, 0, 0, 255 };
constexpr Rgba kGreen { 0, 255, 0, 255 };
constexpr Rgba kBlue { 0, 0, 255, 255 };

// A material that draws its vertex colour over a white texture, positioned the way Wallpaper
// Engine's own model shaders do it: model matrix, then view-projection.
const char kColourVertex[] = R"(uniform mat4 g_ModelMatrix;
uniform mat4 g_ViewProjectionMatrix;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
attribute vec4 a_Color;
varying vec2 v_TexCoord;
varying vec4 v_Color;
void main() {
    gl_Position = mul(mul(vec4(a_Position, 1.0), g_ModelMatrix), g_ViewProjectionMatrix);
    v_TexCoord = a_TexCoord;
    v_Color = a_Color;
}
)";
const char kColourFragment[] = R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
varying vec4 v_Color;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * v_Color;
}
)";

// What every script below starts with: `square(vertices, at, cx, cy, half, r, g, b)` writes one
// square of four POSITION | UV | COLOR vertices (nine floats each) centred on (cx, cy).
const char kHelpers[] = R"JS('use strict';
const material = engine.registerAsset('materials/vcolour.json', true);
const FORMAT = [IModelData.POSITION, IModelData.UV, IModelData.COLOR];
function square(v, at, cx, cy, half, r, g, b) {
    const corners = [[-1, 1, 0, 0], [-1, -1, 0, 1], [1, -1, 1, 1], [1, 1, 1, 0]];
    for (let i = 0; i < 4; ++i) {
        const k = (at * 4 + i) * 9, c = corners[i];
        v[k] = cx + c[0] * half; v[k + 1] = cy + c[1] * half; v[k + 2] = 0;
        v[k + 3] = c[2]; v[k + 4] = c[3];
        v[k + 5] = r; v[k + 6] = g; v[k + 7] = b; v[k + 8] = 1;
    }
}
const QUAD = new Uint16Array([0, 1, 2, 0, 2, 3]);
let frame = 0;
)JS";

class ScriptModelLayer : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }

    // A black 256 x 144 canvas, a group `holder` at (200, 40) and a group running `script`.
    static void Build(ScenePackage& package, const std::string& script, std::vector<Json> more = {})
    {
        package.InstallStandardAssets();
        package.AddShader("vcolour", kColourVertex, kColourFragment);
        package.PutJson("materials/vcolour.json",
                        { { "passes", Json::array({ { { "shader", "vcolour" },
                                                      { "textures", Json::array({ "util/white" }) },
                                                      { "blending", "normal" },
                                                      { "cullmode", "nocull" },
                                                      { "depthtest", "disabled" },
                                                      { "depthwrite", "disabled" } } }) } });
        Json owner     = GroupJson(20, "owner", { 0.0f, 0.0f, 0.0f });
        owner["visible"] = { { "value", true }, { "script", std::string(kHelpers) + script } };
        // A black card under everything: a scene needs one authored layer that draws.
        ImageLayer backdrop;
        backdrop.id     = 1;
        backdrop.origin = { 128.0f, 72.0f, 0.0f };
        backdrop.size   = { 256.0f, 144.0f };
        backdrop.color  = "0 0 0";
        backdrop.model  = package.AddImageModel("backdrop", "util/white", { .blending = "disabled" });
        package.SetProject();
        std::vector<Json> objects { ImageLayerJson(backdrop), GroupJson(10, "holder", { 200.0f, 40.0f, 0.0f }) };
        for (auto& object : more) objects.push_back(std::move(object));
        objects.push_back(owner);
        package.SetScene(SceneJson(SceneGeneral {}, objects));
    }

    static std::string Errors(GpuScene& scene)
    {
        std::string all;
        if (scene.runtime() == nullptr) return all;
        for (const auto& error : scene.runtime()->scriptErrors()) all += error + "\n";
        return all;
    }
};

// Canvas point (x, y), y up, as a picture row.
constexpr uint32_t Row(uint32_t y) { return 144 - y; }

} // namespace

TEST_F(ScriptModelLayer, TheShapeIsDrawnWithItsMaterialAndVertexColours)
{
    ScenePackage package;
    Build(package, R"JS(
export function init(value) {
    const vertices = new Float32Array(2 * 4 * 9);
    square(vertices, 0, 64, 72, 16, 1, 0, 0);
    square(vertices, 1, 128, 100, 10, 0, 0, 1);
    const model = thisScene.createModelData({ shapes: [{ vertexBuffer: vertices,
        indexBuffer: new Uint16Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]), vertexFormat: FORMAT, material: material }] });
    thisScene.createLayer({ model: model, name: 'made', origin: new Vec3(0, 0, 0), perspective: false });
    return value;
}
)JS");
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image picture = scene.Run(3);
    ASSERT_FALSE(picture.empty()) << scene.error();
    KeepPicture("script_model_layer_drawn", picture);
    EXPECT_EQ(Errors(scene), "");
    EXPECT_TRUE(ExpectPixel(picture, 64, Row(72), kRed, 2)) << "the first square, red";
    EXPECT_TRUE(ExpectPixel(picture, 128, Row(100), kBlue, 2)) << "the second square, blue";
    EXPECT_TRUE(ExpectPixel(picture, 64 + 24, Row(72), kBlack, 2)) << "nothing outside the squares";
    EXPECT_TRUE(ExpectPixel(picture, 200, Row(40), kBlack, 2));
}

TEST_F(ScriptModelLayer, ApplyDataRewritesADynamicVertexBufferForEveryLayerUsingTheModel)
{
    ScenePackage package;
    Build(package, R"JS(
let model, vertices;
export function init(value) {
    vertices = new Float32Array(4 * 9);
    square(vertices, 0, 64, 72, 16, 1, 0, 0);
    model = thisScene.createModelData({ shapes: [{ vertexBuffer: vertices, indexBuffer: QUAD, vertexFormat: FORMAT,
        material: material, isVertexBufferDynamic: true }] });
    thisScene.createLayer({ model: model, name: 'first' });
    thisScene.createLayer(model).origin = new Vec3(0, 50, 0);
    return value;
}
export function update(value) {
    if (++frame === 5) {
        square(vertices, 0, 160, 40, 12, 0, 1, 0);
        model.applyData({ vertexBuffer: vertices });
    }
    return value;
}
)JS");
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image before = scene.Run(3);
    ASSERT_FALSE(before.empty()) << scene.error();
    EXPECT_TRUE(ExpectPixel(before, 64, Row(72), kRed, 2));
    EXPECT_TRUE(ExpectPixel(before, 64, Row(122), kRed, 2)) << "the second layer, 50 higher";

    const Image after = scene.Run(4);
    ASSERT_FALSE(after.empty()) << scene.error();
    KeepPicture("script_model_layer_applied", after);
    EXPECT_EQ(Errors(scene), "");
    EXPECT_TRUE(ExpectPixel(after, 160, Row(40), kGreen, 2)) << "the new vertices";
    EXPECT_TRUE(ExpectPixel(after, 160, Row(90), kGreen, 2)) << "the second layer shares the model";
    EXPECT_TRUE(ExpectPixel(after, 64, Row(72), kBlack, 2)) << "the old vertices are gone";
    EXPECT_TRUE(ExpectPixel(after, 64, Row(122), kBlack, 2));
}

TEST_F(ScriptModelLayer, ApplyDataOnABufferThatIsNotDynamicThrowsAndChangesNothing)
{
    ScenePackage package;
    Build(package, R"JS(
let model, vertices;
export function init(value) {
    vertices = new Float32Array(4 * 9);
    square(vertices, 0, 64, 72, 16, 1, 0, 0);
    model = thisScene.createModelData({ shapes: [{ vertexBuffer: vertices, indexBuffer: QUAD, vertexFormat: FORMAT,
        material: material }] });
    thisScene.createLayer({ model: model });
    return value;
}
export function update(value) {
    if (++frame === 2) {
        square(vertices, 0, 160, 40, 12, 0, 1, 0);
        model.applyData({ vertexBuffer: vertices });
    }
    return value;
}
)JS");
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image picture = scene.Run(4);
    ASSERT_FALSE(picture.empty()) << scene.error();
    EXPECT_FALSE(Errors(scene).empty()) << "applyData on a buffer not created dynamic throws";
    EXPECT_TRUE(ExpectPixel(picture, 64, Row(72), kRed, 2));
    EXPECT_TRUE(ExpectPixel(picture, 160, Row(40), kBlack, 2));
}

TEST_F(ScriptModelLayer, AModelLayerFollowsItsParentAndItsVisibility)
{
    ScenePackage package;
    Build(package, R"JS(
let layer;
export function init(value) {
    const vertices = new Float32Array(4 * 9);
    square(vertices, 0, 0, 0, 10, 0, 0, 1);
    const model = thisScene.createModelData({ shapes: [{ vertexBuffer: vertices, indexBuffer: QUAD, vertexFormat: FORMAT,
        material: material }] });
    layer = thisScene.createLayer({ model: model, name: 'made' });
    layer.setParent(thisScene.getLayer('holder'), false);
    return value;
}
export function update(value) {
    if (++frame === 5) layer.visible = false;
    return value;
}
)JS");
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image shown = scene.Run(3);
    ASSERT_FALSE(shown.empty()) << scene.error();
    EXPECT_EQ(Errors(scene), "");
    EXPECT_TRUE(ExpectPixel(shown, 200, Row(40), kBlue, 2)) << "drawn where the holder is";
    EXPECT_TRUE(ExpectPixel(shown, 0 + 5, Row(5), kBlack, 2)) << "not at the canvas origin";

    const Image hidden = scene.Run(4);
    ASSERT_FALSE(hidden.empty()) << scene.error();
    EXPECT_TRUE(ExpectPixel(hidden, 200, Row(40), kBlack, 2)) << "hidden by the script";
}

// The renderer copies a dynamic mesh into its frame buffers only when the mesh's generation moved
// since that buffer was filled, so a frame the script applies nothing in copies nothing.
TEST_F(ScriptModelLayer, OnlyApplyDataMarksTheGeometryChanged)
{
    ScenePackage package;
    Build(package, R"JS(
let model, vertices;
export function init(value) {
    vertices = new Float32Array(4 * 9);
    square(vertices, 0, 64, 72, 16, 1, 0, 0);
    model = thisScene.createModelData({ shapes: [{ vertexBuffer: vertices, indexBuffer: QUAD, vertexFormat: FORMAT,
        material: material, isVertexBufferDynamic: true }] });
    thisScene.createLayer({ model: model, name: 'made' });
    return value;
}
export function update(value) {
    if (++frame === 6) model.applyData({ vertexBuffer: vertices });
    return value;
}
)JS");
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_TRUE(scene.Step(3)) << scene.error();
    auto* runtime = scene.runtime();
    ASSERT_NE(runtime, nullptr);
    wallpaper::SceneMesh* mesh = nullptr;
    for (const auto& child : scene.scene().sceneGraph->GetChildren()) {
        if (child->Name() == runtime->ResolveLayerName("made")) mesh = child->Mesh();
    }
    ASSERT_NE(mesh, nullptr);
    const uint64_t created = mesh->DirtyGeneration();
    EXPECT_NE(created, 0u) << "generation 0 reads as never copied";
    ASSERT_TRUE(scene.Step(1)) << scene.error();
    EXPECT_EQ(mesh->DirtyGeneration(), created) << "nothing applied, nothing to copy";
    ASSERT_TRUE(scene.Step(4)) << scene.error();
    EXPECT_EQ(mesh->DirtyGeneration(), created + 1) << "one applyData, one change";
    EXPECT_EQ(Errors(scene), "");
}

TEST_F(ScriptModelLayer, AModelWithoutDynamicBuffersIsDrawnOnceAndReused)
{
    ScenePackage package;
    Build(package, R"JS(
export function init(value) {
    const vertices = new Float32Array(4 * 9);
    square(vertices, 0, 64, 72, 16, 1, 0, 0);
    thisScene.createLayer(thisScene.createModelData({ shapes: [{ vertexBuffer: vertices, indexBuffer: QUAD,
        vertexFormat: FORMAT, material: material }] }));
    return value;
}
)JS");
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image picture = scene.Run(6);
    ASSERT_FALSE(picture.empty()) << scene.error();
    EXPECT_TRUE(ExpectPixel(picture, 64, Row(72), kRed, 2));
    EXPECT_EQ(scene.LastFramePasses().total(), 0u) << "a static model is part of a still scene";
}

// A compose layer no scene object is a child of still composes the layers a script parents to it:
// they are drawn into its buffer and reach the screen through its effects, not past them.
TEST_F(ScriptModelLayer, ALayerAScriptParentsToAComposeLayerIsDrawnThroughItsEffects)
{
    ScenePackage package;
    package.InstallStandardAssets();
    package.PutJson("models/util/composelayer.json", { { "passthrough", true }, { "material", "materials/util/composelayer.json" } });
    package.PutJson("materials/util/composelayer.json",
                    { { "passes", Json::array({ { { "shader", "harness_image" },
                                                  { "textures", Json::array({ "_rt_FullFrameBuffer" }) },
                                                  { "blending", "translucent" },
                                                  { "cullmode", "nocull" },
                                                  { "depthtest", "disabled" },
                                                  { "depthwrite", "disabled" } } }) } });
    const std::string half = package.AddTintEffect("half");
    Json canvas = { { "id", 30 },
                    { "name", "canvas" },
                    { "image", "models/util/composelayer.json" },
                    { "origin", "128 72 0" },
                    { "size", "256 144" },
                    { "copybackground", false },
                    { "visible", true },
                    { "effects", Json::array({ EffectUse(half, { { "tint", "0.5 0.5 0.5" } }, 31) }) } };
    Build(package, R"JS(
export function init(value) {
    const vertices = new Float32Array(4 * 9);
    square(vertices, 0, 0, 0, 16, 1, 0, 0);
    const layer = thisScene.createLayer({ model: thisScene.createModelData({ shapes: [{ vertexBuffer: vertices,
        indexBuffer: QUAD, vertexFormat: FORMAT, material: material }] }) });
    layer.setParent(thisScene.getLayerByID('30'), false);
    return value;
}
)JS", { canvas });
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image picture = scene.Run(3);
    ASSERT_FALSE(picture.empty()) << scene.error();
    KeepPicture("script_model_layer_composed", picture);
    EXPECT_EQ(Errors(scene), "");
    EXPECT_TRUE(ExpectPixel(picture, 128, Row(72), Rgba { 128, 0, 0, 255 }, 3)) << "red, halved by the compose layer's effect";
    EXPECT_TRUE(ExpectPixel(picture, 40, Row(40), kBlack, 2)) << "the empty rest of the compose layer adds nothing";
}
