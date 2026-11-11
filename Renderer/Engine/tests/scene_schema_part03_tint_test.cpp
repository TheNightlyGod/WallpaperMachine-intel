// Scene file schema, part 3: what a layer's colour, alpha and brightness reach. Colour scripts
// colour every material of an image layer and its effect passes, a written alpha reaches the
// puppet's skinned pass too, and brightness tints the materials only in a scene that renders HDR.
#include "support/schema_fixtures_part03.hpp"

#include "Scene/SceneUpdateDemand.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace we_schema::p3;
using namespace wallpaper;

using Rgb = std::array<float, 3>;

// ---- colour scripts ----------------------------------------------------------------------------

struct ColourLayer {
    int         id;
    const char* name;
    int         effect_id; // 0 for none
    const char* value;
    const char* script;
};

const ColourLayer kColourLayers[] = {
    { 1, "returns", 2, "0 1 0", "export function update() { return new Vec3(1, 0, 0); }" },
    { 3, "returns nothing", 0, "0.9 0.15 0.27", "export function update(value) { }" },
    { 4, "writes", 5, "1 0 0", "export function update() { thisLayer.color = new Vec3(0, 0, 1); }" },
    { 6, "cover", 0, "0.33 0.64 0.74",
      "let cover = new Vec3(0, 0, 0);\n"
      "export function update() { return cover; }\n"
      "export function mediaThumbnailChanged(event) { cover = event.primaryColor; }\n" },
    { 7, "handler", 8, "0 1 0",
      "scene.on('mediaThumbnailChanged', function (event) { thisLayer.color = event.primaryColor; });\n" },
    { 9, "reads its write", 0, "1 0 0",
      "let calls = 0;\n"
      "export function update(value) {\n"
      "  calls += 1;\n"
      "  if (calls === 1) { thisLayer.color = new Vec3(0, 0, 1); return; }\n"
      "  value.x = 0.5;\n"
      "  return value;\n"
      "}\n" },
};

class ColourScripts : public ::testing::Test {
protected:
    void SetUp() override
    {
        rig_ = std::make_unique<ParseRig>(TintableAssets());
        Json objects = Json::array();
        for (const auto& layer : kColourLayers) {
            Json extra = { { "alpha", 0.5 }, { "color", { { "script", layer.script }, { "value", layer.value } } } };
            if (layer.effect_id != 0) extra["effects"] = CopyEffectEntry(layer.effect_id);
            objects.push_back(ImageObject(layer.id, layer.name, extra));
        }
        scene_ = rig_->Parse(CanvasOf(objects), { .live = true });
        ASSERT_NE(scene_, nullptr);
        ASSERT_NE(scene_->runtime, nullptr);
    }

    // Every material of `layer` has colour `expected` under both constants and alpha 0.5.
    void ExpectColour(const char* layer, const Rgb& expected, std::size_t material_count)
    {
        SceneNode* node = FindRootChild(*scene_, layer);
        ASSERT_NE(node, nullptr) << layer;
        const auto materials = MaterialsOf(*scene_, *node);
        ASSERT_EQ(materials.size(), material_count) << layer;
        for (std::size_t m = 0; m < materials.size(); ++m) {
            const auto g4 = Constant(*materials[m], "g_Color4");
            const auto g1 = Constant(*materials[m], "g_Color");
            ASSERT_GE(g4.size(), 4u) << layer << " material " << m << ": no g_Color4";
            ASSERT_GE(g1.size(), 3u) << layer << " material " << m << ": no g_Color";
            for (std::size_t c = 0; c < 3; ++c) {
                EXPECT_FLOAT_EQ(g4[c], expected[c]) << layer << " material " << m << " g_Color4[" << c << "]";
                EXPECT_FLOAT_EQ(g1[c], expected[c]) << layer << " material " << m << " g_Color[" << c << "]";
            }
            EXPECT_FLOAT_EQ(g4[3], 0.5f) << layer << " material " << m << " alpha";
        }
    }

    void Tick(int count = 1)
    {
        for (int i = 0; i < count; ++i) scene_->runtime->Tick(1.0 / 60.0);
    }

    std::unique_ptr<ParseRig>  rig_;
    std::shared_ptr<Scene>     scene_;
};

// R-3.06 / B-3.08
TEST_F(ColourScripts, BeforeAnyTickEveryLayerShowsTheSceneFilesValue)
{
    ExpectColour("returns", { 0, 1, 0 }, 2);
    ExpectColour("returns nothing", { 0.9f, 0.15f, 0.27f }, 1);
    ExpectColour("writes", { 1, 0, 0 }, 2);
    ExpectColour("cover", { 0.33f, 0.64f, 0.74f }, 1);
    ExpectColour("handler", { 0, 1, 0 }, 2);
    ExpectColour("reads its write", { 1, 0, 0 }, 1);
}

// B-3.09
TEST_F(ColourScripts, AReturnedVectorColoursEveryMaterialOnEveryTick)
{
    for (int tick = 0; tick < 4; ++tick) {
        SCOPED_TRACE("tick " + std::to_string(tick + 1));
        Tick();
        ExpectColour("returns", { 1, 0, 0 }, 2);
        ExpectColour("cover", { 0, 0, 0 }, 1);
    }
}

// B-3.10
TEST_F(ColourScripts, ReturningNothingKeepsTheColourAndAWriteIsNotUndoneByTheTick)
{
    for (int tick = 0; tick < 4; ++tick) {
        SCOPED_TRACE("tick " + std::to_string(tick + 1));
        Tick();
        ExpectColour("returns nothing", { 0.9f, 0.15f, 0.27f }, 1);
        ExpectColour("writes", { 0, 0, 1 }, 2);
        ExpectColour("handler", { 0, 1, 0 }, 2);
    }
}

// B-3.11
TEST_F(ColourScripts, WhatTheScriptWroteIsTheValueItsNextCallReceives)
{
    Tick();
    ExpectColour("reads its write", { 0, 0, 1 }, 1);
    Tick();
    ExpectColour("reads its write", { 0.5f, 0, 1 }, 1);
}

// B-3.12
TEST_F(ColourScripts, MediaThumbnailEventsReachBothStylesOfHandlerAndTheEffectPass)
{
    scene_->runtime->SetMediaIntegrationEnabled(true);
    scene_->runtime->DispatchMediaEventJson(
        R"({"type":"mediaThumbnailChanged","hasThumbnail":true,"primaryColor":[0.25,0.5,0.75],"secondaryColor":[0,0,0],"tertiaryColor":[0,0,0],"textColor":[1,1,1],"highContrastColor":[0,0,0]})");
    for (int tick = 0; tick < 2; ++tick) {
        SCOPED_TRACE("tick " + std::to_string(tick + 1));
        Tick();
        ExpectColour("cover", { 0.25f, 0.5f, 0.75f }, 1);
        ExpectColour("handler", { 0.25f, 0.5f, 0.75f }, 2);
    }
}

// B-3.13
TEST_F(ColourScripts, ColourScriptsKeepTheSceneClockRunning)
{
    EXPECT_TRUE(scene_->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Script);
}

// B-3.14
TEST_F(ColourScripts, NoScriptOfTheScenarioFails)
{
    Tick(4);
    scene_->runtime->SetMediaIntegrationEnabled(true);
    scene_->runtime->DispatchMediaEventJson(R"({"type":"mediaThumbnailChanged","hasThumbnail":true,"primaryColor":[0.25,0.5,0.75]})");
    Tick(2);
    EXPECT_EQ(scene_->runtime->scriptErrorCount(), 0u);
}

// ---- scene general settings that a script or a property drives ---------------------------------

// Wallpaper Engine evaluates `general.ambientcolor` (and the other lighting and fog settings)
// every frame like any setting; the uniform every material shares follows the script each tick.
TEST(SceneGeneralScripts, AnAmbientColourScriptIsFollowedEveryTick)
{
    ParseRig   rig(TintableAssets());
    const Json general = { { "ambientcolor",
                             { { "script", "var t = 0; export function update() { t++; return new Vec3(t / 10, 0, 0); }" },
                               { "value", "0 0 0" } } } };
    auto scene = rig.Parse(CanvasOf(Json::array({ ImageObject(1, "lit") }), general), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneNode* node = FindRootChild(*scene, "lit");
    ASSERT_NE(node, nullptr);
    const auto materials = MaterialsOf(*scene, *node);
    ASSERT_FALSE(materials.empty());
    for (int tick = 1; tick <= 2; ++tick) {
        scene->runtime->Tick(1.0 / 60.0);
        const auto ambient = Constant(*materials.front(), "g_LightAmbientColor");
        ASSERT_EQ(ambient.size(), 3u);
        EXPECT_FLOAT_EQ(ambient[0], tick / 10.0f) << "tick " << tick;
        EXPECT_FLOAT_EQ(ambient[1], 0.0f);
    }
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(SceneGeneralScripts, AHeightFogStartBoundToAPropertyFollowsItWithoutAReload)
{
    ParseRig rig(TintableAssets());
    rig.properties()["fog_start"] = RuntimeScalarValue::Float(2.0f);
    const Json general = { { "fogheight", true },
                           { "fogheightstart", { { "user", "fog_start" }, { "value", 1.0 } } },
                           { "fogheightend", -3.0 } };
    auto scene = rig.Parse(CanvasOf(Json::array({ ImageObject(1, "fogged") }), general), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneNode* node = FindRootChild(*scene, "fogged");
    ASSERT_NE(node, nullptr);
    const auto materials = MaterialsOf(*scene, *node);
    ASSERT_FALSE(materials.empty());
    const auto params = [&] { return Constant(*materials.front(), "g_FogHeightParams"); };
    ASSERT_EQ(params().size(), 4u);
    EXPECT_FLOAT_EQ(params()[0], 2.0f) << "the property's value as the scene loads";
    EXPECT_FLOAT_EQ(params()[1], -5.0f);

    ProjectProperties changed = rig.properties();
    changed["fog_start"]      = RuntimeScalarValue::Float(4.0f);
    scene->runtime->ApplyProjectPropertyOverride(changed);
    scene->runtime->Tick(1.0 / 60.0);
    EXPECT_FLOAT_EQ(params()[0], 4.0f) << "the live edit reached the uniform";
    EXPECT_FLOAT_EQ(params()[1], -7.0f);
    const auto held = scene->runtime->LoadOnlyProperties();
    EXPECT_EQ(std::find(held.begin(), held.end(), "fog_start"), held.end()) << "no reload is asked for";
}

// ---- layer alpha -------------------------------------------------------------------------------

FileMap OpacityAssets()
{
    FileMap files = PuppetAssets();
    PutJson(files, "/effects/opacity/effect.json",
            { { "name", "opacity" },
              { "passes", Json::array({ { { "material", "opacity_mat.json" }, { "bind", Json::array({ { { "name", "previous" }, { "index", 0 } } }) } } }) } });
    PutJson(files, "/opacity_mat.json",
            { { "passes", Json::array({ { { "blending", "translucent" },
                                          { "cullmode", "nocull" },
                                          { "depthtest", "disabled" },
                                          { "depthwrite", "disabled" },
                                          { "shader", "opacity" },
                                          { "textures", Json::array({ nullptr }) } } }) } });
    files["/shaders/opacity.vert"] = files["/shaders/baseimage.vert"];
    files["/shaders/opacity.frag"] = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform float g_UserAlpha; // {"material":"alpha","default":1.0}
void main() {
    vec4 colour = texSample2D(g_Texture0, v_TexCoord);
    gl_FragColor = vec4(colour.rgb, colour.a * g_UserAlpha);
}
)";
    return files;
}

Json PuppetAlphaScene(double alpha)
{
    Json passes = Json::array({ { { "id", 11 }, { "constantshadervalues", { { "alpha", 0.8 } } } } });
    Json effects = Json::array({ { { "file", "effects/opacity/effect.json" }, { "id", 10 }, { "visible", true }, { "passes", passes } } });
    return CanvasOf(Json::array({ Json { { "id", 300 },
                                         { "name", "puppet image" },
                                         { "image", "puppet_image.json" },
                                         { "origin", Json::array({ 0, 0, 0 }) },
                                         { "scale", Json::array({ 1, 1, 1 }) },
                                         { "angles", Json::array({ 0, 0, 0 }) },
                                         { "visible", true },
                                         { "alpha", alpha },
                                         { "effects", effects } } }));
}

// R-3.07 / B-3.15
TEST(LayerAlpha, AWrittenAlphaReachesEveryMaterialButTheEffectsOwn)
{
    ParseRig rig(OpacityAssets());
    auto     scene = rig.Parse(PuppetAlphaScene(0.6), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneNode* node = FindRootChild(*scene, "puppet image");
    ASSERT_NE(node, nullptr);
    const auto materials = MaterialsOf(*scene, *node);
    ASSERT_EQ(materials.size(), 3u);

    ASSERT_TRUE(scene->runtime->SetNodeAlpha("puppet image", 0.25f));
    EXPECT_FALSE(scene->runtime->SetNodeAlpha("nope", 1.0f));

    const float expected_user_alpha[3] = { 0.25f, 0.8f, 0.25f };
    const bool  expected_own[3]        = { false, true, false };
    for (std::size_t m = 0; m < 3; ++m) {
        SCOPED_TRACE("material " + std::to_string(m));
        const auto user_alpha = Constant(*materials[m], "g_UserAlpha");
        ASSERT_GE(user_alpha.size(), 1u);
        EXPECT_FLOAT_EQ(user_alpha[0], expected_user_alpha[m]);
        const auto colour = Constant(*materials[m], "g_Color4");
        ASSERT_GE(colour.size(), 4u);
        EXPECT_FLOAT_EQ(colour[3], 0.25f);
        EXPECT_EQ(materials[m]->own_user_alpha, expected_own[m]);
    }
}

// B-3.16
TEST(LayerAlpha, AWrittenAlphaLeavesTheMaterialsAsTheSameAlphaAuthored)
{
    ParseRig written_rig(OpacityAssets());
    auto     written = written_rig.Parse(PuppetAlphaScene(0.6), { .live = true });
    ParseRig authored_rig(OpacityAssets());
    auto     authored = authored_rig.Parse(PuppetAlphaScene(0.25), { .live = true });
    ASSERT_NE(written, nullptr);
    ASSERT_NE(authored, nullptr);
    ASSERT_NE(written->runtime, nullptr);
    ASSERT_TRUE(written->runtime->SetNodeAlpha("puppet image", 0.25f));

    SceneNode* written_node  = FindRootChild(*written, "puppet image");
    SceneNode* authored_node = FindRootChild(*authored, "puppet image");
    ASSERT_NE(written_node, nullptr);
    ASSERT_NE(authored_node, nullptr);
    const auto w = MaterialsOf(*written, *written_node);
    const auto a = MaterialsOf(*authored, *authored_node);
    ASSERT_EQ(w.size(), 3u);
    ASSERT_EQ(a.size(), 3u);
    for (std::size_t m = 0; m < 3; ++m) {
        for (const char* name : { "g_UserAlpha", "g_Alpha", "g_Color4" }) {
            SCOPED_TRACE("material " + std::to_string(m) + " " + name);
            const auto from_write = Constant(*w[m], name);
            const auto from_file  = Constant(*a[m], name);
            EXPECT_EQ(from_write.empty(), from_file.empty());
            if (from_write.empty() || from_file.empty()) continue;
            const std::size_t lane = std::string(name) == "g_Color4" ? 3 : 0;
            ASSERT_GT(from_write.size(), lane);
            ASSERT_GT(from_file.size(), lane);
            EXPECT_FLOAT_EQ(from_write[lane], from_file[lane]);
        }
        EXPECT_EQ(w[m]->own_user_alpha, a[m]->own_user_alpha) << "material " << m;
    }
}

// ---- brightness --------------------------------------------------------------------------------

struct BrightnessConfig {
    bool hdr;
    bool bloom;
    bool renders_hdr;
    bool declares_brightness; // the image's shader declares g_Brightness
};

class LayerBrightness : public ::testing::TestWithParam<BrightnessConfig> {};

Json BrightnessObjects()
{
    const Json glow     = { { "user", "glow" }, { "value", 0.5 } };
    const Json tint     = { { "user", "tint" }, { "value", "1 1 1" } };
    const Json scripted = { { "script", "export function update(value) { return 0.5; }" }, { "value", 1 } };
    return Json::array({
        ImageObject(1, "plain", { { "color", "0.5 1 1" }, { "brightness", 0.5 } }),
        ImageObject(2, "with effect", { { "color", "0.5 1 1" }, { "brightness", 0.5 }, { "effects", CopyEffectEntry(102) } }),
        ImageObject(4, "bound", { { "brightness", glow } }),
        ImageObject(5, "bound with effect", { { "brightness", glow }, { "effects", CopyEffectEntry(105) } }),
        ImageObject(7, "bound with colour", { { "color", tint }, { "brightness", glow } }),
        ImageObject(8, "scripted", { { "brightness", scripted } }),
        ImageObject(9, "scripted colour",
                    { { "color", { { "script", "export function update() { return new Vec3(0, 1, 0); }" }, { "value", "1 0 0" } } },
                      { "brightness", 0.5 },
                      { "effects", CopyEffectEntry(109) } }),
        ImageObject(11, "scripted colour write",
                    { { "color", { { "script", "export function update() { thisLayer.color = new Vec3(0, 0, 1); }" }, { "value", "1 0 0" } } },
                      { "brightness", 0.5 } }),
    });
}

struct Expectation {
    const char*   layer;
    std::size_t   materials;
    Rgb           before;
    Rgb           after;
};

TEST_P(LayerBrightness, TintsMaterialsOnlyWhereTheSceneRendersHdrAndFollowsItsBindings)
{
    const BrightnessConfig config = GetParam();
    FileMap                files  = TintableAssets(config.declares_brightness ? "genericimage2" : "genericimage");
    Add(files, BloomAssets(BloomSet::Hdr));
    ParseRig rig(files);
    rig.properties() = ProjectProperties { { "glow", RuntimeScalarValue::Float(0.75f) }, { "tint", RuntimeScalarValue::String("0 0 1") } };
    auto scene       = rig.Parse(CanvasOf(BrightnessObjects(),
                                          { { "hdr", config.hdr }, { "bloom", config.bloom }, { "bloomstrength", 1.5 }, { "bloomthreshold", 0.25 }, { "bloomtint", Json::array({ 0.2, 0.4, 0.6 }) } }),
                               { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->hdr, config.renders_hdr);

    std::vector<Expectation> expected;
    if (config.renders_hdr) {
        expected = { { "plain", 1, { 0.25f, 0.5f, 0.5f }, { 0.25f, 0.5f, 0.5f } },
                     { "with effect", 2, { 0.25f, 0.5f, 0.5f }, { 0.25f, 0.5f, 0.5f } },
                     { "bound", 1, { 0.75f, 0.75f, 0.75f }, { 0.25f, 0.25f, 0.25f } },
                     { "bound with effect", 2, { 0.75f, 0.75f, 0.75f }, { 0.25f, 0.25f, 0.25f } },
                     { "bound with colour", 1, { 0, 0, 0.75f }, { 0.125f, 0.25f, 0.25f } },
                     { "scripted", 1, { 0.5f, 0.5f, 0.5f }, { 0.5f, 0.5f, 0.5f } },
                     { "scripted colour", 2, { 0, 0.5f, 0 }, { 0, 0.5f, 0 } },
                     { "scripted colour write", 1, { 0, 0, 0.5f }, { 0, 0, 0.5f } } };
    } else {
        expected = { { "plain", 1, { 0.5f, 1, 1 }, { 0.5f, 1, 1 } },
                     { "with effect", 2, { 0.5f, 1, 1 }, { 0.5f, 1, 1 } },
                     { "bound", 1, { 1, 1, 1 }, { 1, 1, 1 } },
                     { "bound with effect", 2, { 1, 1, 1 }, { 1, 1, 1 } },
                     { "bound with colour", 1, { 0, 0, 1 }, { 0.5f, 1, 1 } },
                     { "scripted", 1, { 1, 1, 1 }, { 1, 1, 1 } },
                     { "scripted colour", 2, { 0, 1, 0 }, { 0, 1, 0 } },
                     { "scripted colour write", 1, { 0, 0, 1 }, { 0, 0, 1 } } };
    }

    const auto check = [&](bool after) {
        for (const auto& row : expected) {
            SCOPED_TRACE(std::string(row.layer) + (after ? " after" : " before"));
            SceneNode* node = FindRootChild(*scene, row.layer);
            ASSERT_NE(node, nullptr);
            const auto materials = MaterialsOf(*scene, *node);
            ASSERT_EQ(materials.size(), row.materials);
            const Rgb& want = after ? row.after : row.before;
            for (std::size_t m = 0; m < materials.size(); ++m) {
                const auto colour = Constant(*materials[m], "g_Color4");
                ASSERT_GE(colour.size(), 4u) << "material " << m;
                for (std::size_t c = 0; c < 3; ++c) EXPECT_FLOAT_EQ(colour[c], want[c]) << "material " << m << " lane " << c;
                EXPECT_FLOAT_EQ(colour[3], 1.0f) << "material " << m << " alpha";
            }
            if (config.declares_brightness) {
                // The shader's own brightness stays at its default; the layer's never leaks into it.
                const auto own = Constant(*node->Mesh()->MaterialSlots()[0], "g_Brightness");
                if (!own.empty()) EXPECT_EQ(own[0], 1.0f);
            }
        }
    };

    scene->runtime->Tick(1.0 / 60.0);
    {
        SCOPED_TRACE("before the properties change");
        check(false);
    }
    scene->runtime->ApplyProjectPropertyOverride({ { "glow", RuntimeScalarValue::Float(0.25f) }, { "tint", RuntimeScalarValue::String("0.5 1 1") } });
    scene->runtime->Tick(1.0 / 60.0);
    {
        SCOPED_TRACE("after the properties change");
        check(true);
    }
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

std::string BrightnessName(const ::testing::TestParamInfo<BrightnessConfig>& info)
{
    const auto& c = info.param;
    return std::string(c.hdr ? "Hdr" : "Ldr") + (c.bloom ? "Bloom" : "NoBloom") + (c.declares_brightness ? "DeclaredBrightness" : "PlainShader");
}

const BrightnessConfig kBrightnessConfigs[] = { { true, true, true, false },   { true, true, true, true },    { true, false, false, false },
                                                { true, false, false, true }, { false, false, false, false }, { false, false, false, true } };

INSTANTIATE_TEST_SUITE_P(Configurations, LayerBrightness, ::testing::ValuesIn(kBrightnessConfigs), BrightnessName);

} // namespace
