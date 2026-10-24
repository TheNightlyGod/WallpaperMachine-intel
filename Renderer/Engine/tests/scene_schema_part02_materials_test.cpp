// Scene file schema, part 2: what scene-level settings put into a draw. Distance fog compiled
// into the passes that ask for it, the texel step of a render-target slot, camera shake that follows
// a property, and the normal-model matrix of a rotated, scaled model.
#include "support/schema_fixtures_part02.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <string>

namespace
{

using namespace we_schema;
using namespace we_schema::p2;
using namespace wallpaper;

FileMap LeafAssets()
{
    FileMap files = BasicAssets();
    Add(files, LeafModelAssets());
    return files;
}

Json OneModelScene(const Json& model_extra = Json::object(), const Json& general_patch = Json::object())
{
    Json model = ModelObject(1, "planet", { { "perspective", true }, { "origin", "0 0 0" }, { "scale", "1 1 1" }, { "angles", "0 0 0" } });
    for (const auto& [key, value] : model_extra.items()) model[key] = value;
    return PerspectiveScene(Json::array({ model }), general_patch);
}

// ---- distance fog --------------------------------------------------------------------------

// A material whose fragment shader only sees the distance-fog uniform in a build with `FOG` on.
FileMap FoggyAssets()
{
    FileMap files = LeafAssets();
    files["/shaders/foggy.vert"] = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
    gl_Position = vec4(a_Position, 1.0);
    v_TexCoord = a_TexCoord;
}
)";
    files["/shaders/foggy.frag"] = R"(// [COMBO] {"material":"fog","combo":"FOG","default":1}
varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
#if FOG_DIST
uniform vec4 g_FogDistanceParams;
#endif
void main() {
    vec4 colour = texSample2D(g_Texture0, v_TexCoord);
#if FOG_COMPUTED && FOG_DIST
    colour.rgb *= g_FogDistanceParams.xyz;
#endif
    gl_FragColor = colour;
}
)";
    files["/mat/head.json"] = Json { { "passes", Json::array({ { { "shader", "foggy" }, { "textures", Json::array({ "a.tex" }) } } }) } }.dump();
    files["/mat/eyes.json"] = Json { { "passes", Json::array({ { { "shader", "foggy" }, { "textures", Json::array({ "a.tex" }) }, { "combos", { { "FOG", 0 } } } } }) } }.dump();
    return files;
}

bool ReflectionMentions(const SceneMaterial& material, const std::string& what, bool& present)
{
    const auto* shader = material.customShader.shader.get();
    if (shader == nullptr || !shader->rust_reflection_json.has_value()) {
        present = false;
        return false;
    }
    present = shader->rust_reflection_json->find(what) != std::string::npos;
    return true;
}

Json FogGeneral(const Json& extra = Json::object())
{
    Json general = { { "fogdistance", true }, { "fogdistancestart", 2 }, { "fogdistanceend", 10 }, { "fogdistancecolor", Json::array({ 0.5, 0.5, 0.5 }) } };
    for (const auto& [key, value] : extra.items()) general[key] = value;
    return general;
}

// R-2.09 / B-2.09
TEST(SceneFog, DistanceFogIsCompiledIntoPassesWhoseFogComboIsOn)
{
    ParseRig rig(FoggyAssets());
    auto     scene = rig.Parse(OneModelScene({}, FogGeneral()));
    ASSERT_NE(scene, nullptr);
    EXPECT_TRUE(scene->fog_distance);
    EXPECT_FALSE(scene->fog_height);
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    ASSERT_NE(model->Mesh(), nullptr);
    ASSERT_EQ(model->Mesh()->MaterialSlots().size(), 2u);

    const SceneMaterial& fogged = *model->Mesh()->MaterialSlots()[0];
    ASSERT_NE(fogged.customShader.shader, nullptr);
    ASSERT_TRUE(fogged.customShader.shader->rust_reflection_json.has_value()) << "the shader library produced no reflection";
    EXPECT_NE(fogged.customShader.shader->rust_reflection_json->find("g_FogDistanceParams"), std::string::npos);
    const auto params = fogged.customShader.constValues.find("g_FogDistanceParams");
    ASSERT_NE(params, fogged.customShader.constValues.end());
    ASSERT_EQ(params->second.size(), 4u);
    EXPECT_EQ(params->second[0], 2.0f); // start
    EXPECT_EQ(params->second[1], 8.0f); // end - start
    EXPECT_EQ(params->second[2], 0.0f); // density at the start
    EXPECT_EQ(params->second[3], 1.0f); // end density - start density

    const SceneMaterial& plain = *model->Mesh()->MaterialSlots()[1];
    ASSERT_NE(plain.customShader.shader, nullptr);
    ASSERT_TRUE(plain.customShader.shader->rust_reflection_json.has_value());
    EXPECT_EQ(plain.customShader.shader->rust_reflection_json->find("g_FogDistanceParams"), std::string::npos);
}

TEST(SceneFog, WithoutDistanceFogNoPassIsCompiledWithIt)
{
    ParseRig rig(FoggyAssets());
    auto     scene = rig.Parse(OneModelScene());
    ASSERT_NE(scene, nullptr);
    EXPECT_FALSE(scene->fog_distance);
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    ASSERT_NE(model->Mesh(), nullptr);
    ASSERT_GE(model->Mesh()->MaterialSlots().size(), 1u);
    bool present = true;
    ASSERT_TRUE(ReflectionMentions(*model->Mesh()->MaterialSlots()[0], "g_FogDistanceParams", present));
    EXPECT_FALSE(present);
}

TEST(SceneFog, AuthoredDensitiesReachTheFogParameters)
{
    ParseRig rig(FoggyAssets());
    auto     scene = rig.Parse(OneModelScene({}, FogGeneral({ { "fogdistancestartdensity", 0.25 }, { "fogdistanceenddensity", 0.75 } })));
    ASSERT_NE(scene, nullptr);
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    ASSERT_NE(model->Mesh(), nullptr);
    const auto& constants = model->Mesh()->MaterialSlots()[0]->customShader.constValues;
    const auto  params    = constants.find("g_FogDistanceParams");
    ASSERT_NE(params, constants.end());
    ASSERT_EQ(params->second.size(), 4u);
    EXPECT_EQ(params->second[0], 2.0f);
    EXPECT_EQ(params->second[1], 8.0f);
    EXPECT_EQ(params->second[2], 0.25f);
    EXPECT_EQ(params->second[3], 0.5f);
}

// ---- texel uniform ---------------------------------------------------------------------------

// R-2.10 / B-2.10
TEST(RenderTargetSlots, TheTexelUniformIsTheStepOfTheTargetTheSlotSamples)
{
    FileMap files = LeafAssets();
    files["/mat/head.json"] = LeafMaterialText({ { "textures", Json::array({ "_rt_4FrameBuffer" }) } });
    ParseRig rig(files);
    auto     scene = rig.Parse(OneModelScene());
    ASSERT_NE(scene, nullptr);
    const SceneRenderTarget* target = scene->FindRenderTarget("_rt_4FrameBuffer");
    ASSERT_NE(target, nullptr);
    ASSERT_GT(target->width, 0);
    ASSERT_GT(target->height, 0);
    const float w = static_cast<float>(target->width);
    const float h = static_cast<float>(target->height);

    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    ASSERT_NE(model->Mesh(), nullptr);
    const auto& constants = model->Mesh()->MaterialForSlot(0)->customShader.constValues;
    const auto  texel     = constants.find("g_Texture0Texel");
    ASSERT_NE(texel, constants.end());
    ASSERT_EQ(texel->second.size(), 4u);
    EXPECT_FLOAT_EQ(texel->second[0], 1.0f / w);
    EXPECT_FLOAT_EQ(texel->second[1], 1.0f / h);
    EXPECT_FLOAT_EQ(texel->second[2], w);
    EXPECT_FLOAT_EQ(texel->second[3], h);

    const auto resolution = constants.find("g_Texture0Resolution");
    ASSERT_NE(resolution, constants.end());
    ASSERT_EQ(resolution->second.size(), 4u);
    EXPECT_FLOAT_EQ(resolution->second[0], w);
    EXPECT_FLOAT_EQ(resolution->second[1], h);
    EXPECT_FLOAT_EQ(resolution->second[2], w);
    EXPECT_FLOAT_EQ(resolution->second[3], h);
}

// ---- camera shake ----------------------------------------------------------------------------

Json ShakeScene(double amplitude)
{
    Json image = { { "id", 310 },
                   { "name", "canvas image" },
                   { "image", "image.json" },
                   { "origin", Json::array({ 0, 0, 0 }) },
                   { "scale", Json::array({ 1, 1, 1 }) },
                   { "angles", Json::array({ 0, 0, 0 }) },
                   { "visible", true } };
    return QuietScene(Json::array({ image }),
                      { { "camerashake", { { "user", "shake" }, { "value", true } } },
                        { "camerashakeamplitude", amplitude },
                        { "camerashakespeed", 2.0 },
                        { "camerashakeroughness", 1.0 } });
}

linalg::Vector3d ExpectedShake(double amplitude_setting, double elapsed_seconds)
{
    const double t         = 2.0 * 2.0 * elapsed_seconds;
    const double amplitude = amplitude_setting * 0.1 * (360 * 0.1);
    return linalg::Vector3d(std::cos(t) * amplitude, std::sin(t * 1.333) * amplitude, 0.0);
}

// R-2.11 / B-2.11
TEST(CameraShake, TheSceneCameraShakesWhileItsPropertyIsOn)
{
    ParseRig rig(BasicAssets());
    rig.properties() = ProjectProperties { { "shake", RuntimeScalarValue::Bool(true) } };
    auto scene       = rig.Parse(ShakeScene(1.0), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    const linalg::Matrix4d still = scene->activeCamera->GetViewProjectionMatrix();

    scene->runtime->Tick(0.25);
    EXPECT_TRUE(scene->activeCamera->ShakeOffset().isApprox(ExpectedShake(1.0, 0.25), 1e-6));
    EXPECT_FALSE(scene->activeCamera->GetViewProjectionMatrix().isApprox(still, 1e-9));
    EXPECT_TRUE(scene->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation);

    scene->runtime->ApplyProjectPropertyOverride({ { "shake", RuntimeScalarValue::Bool(false) } });
    scene->runtime->Tick(0.25);
    EXPECT_TRUE(scene->activeCamera->ShakeOffset().isZero());
    EXPECT_TRUE(scene->activeCamera->GetViewProjectionMatrix().isApprox(still, 1e-9));
    EXPECT_FALSE(scene->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation);
}

TEST(CameraShake, ADoubledAmplitudeDoublesTheOffset)
{
    ParseRig rig(BasicAssets());
    rig.properties() = ProjectProperties { { "shake", RuntimeScalarValue::Bool(true) } };
    auto scene       = rig.Parse(ShakeScene(2.0), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    scene->runtime->Tick(0.25);
    EXPECT_TRUE(scene->activeCamera->ShakeOffset().isApprox(ExpectedShake(2.0, 0.25), 1e-6));
}

// ---- normal matrix ---------------------------------------------------------------------------

// R-2.12 / B-2.12
TEST(NormalMatrix, ItIsTheRotationOfTheDrawWithoutItsScale)
{
    ParseRig rig(LeafAssets());
    auto     scene = rig.Parse(OneModelScene({ { "scale", "3 3 3" }, { "angles", "0 0 1.5707963" } }));
    ASSERT_NE(scene, nullptr);
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    const Recorded seen = Probe(*scene, *model, { "g_NormalModelMatrix" });
    ASSERT_EQ(seen.count("g_NormalModelMatrix"), 1u);
    const auto& lanes = seen.at("g_NormalModelMatrix");
    ASSERT_EQ(lanes.size(), 12u);
    // A quarter turn about z: the x axis becomes +y, the y axis -x, z stays.
    EXPECT_TRUE(SlotIs(seen, "g_NormalModelMatrix", 0, { 0, 1, 0, 0 }));
    EXPECT_TRUE(SlotIs(seen, "g_NormalModelMatrix", 1, { -1, 0, 0, 0 }));
    EXPECT_TRUE(SlotIs(seen, "g_NormalModelMatrix", 2, { 0, 0, 1, 0 }));
    for (std::size_t column = 0; column < 3; ++column) {
        const float length = std::sqrt(lanes[4 * column] * lanes[4 * column] + lanes[4 * column + 1] * lanes[4 * column + 1] +
                                       lanes[4 * column + 2] * lanes[4 * column + 2]);
        EXPECT_NEAR(length, 1.0f, 1e-4f) << "column " << column;
    }
}

} // namespace
