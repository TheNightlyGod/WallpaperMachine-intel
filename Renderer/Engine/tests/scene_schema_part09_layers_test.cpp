// Scene file schema, part 9 (image layers): a layer's colour and alpha, whether authored, bound
// to a property, written by a script or set by the host, reach every material the layer draws
// with (its own and each effect pass), while an effect's own `alpha` stays its own.
#include "support/schema_fixtures.hpp"
#include "support/schema_layer_assets.hpp"

#include "Runtime/SceneRuntimeContext.hpp"

#include <gtest/gtest.h>

#include <array>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace we_schema::layers;
using namespace wallpaper;

constexpr double kTick = 1.0 / 60.0;

std::shared_ptr<Scene> ParseLive(ParseRig& rig, Json objects)
{
    return rig.Parse(QuietScene(std::move(objects), { { "bloom", false } }), { .live = true });
}

const char* const kWriteAlpha  = "export function update(value) { thisLayer.alpha = 0.25; return value; }";
const char* const kHideScript  = "export function update() { return false; }";
const char* const kKeepScript  = "export function update(value) { return value; }";

Json WritesAlpha()
{
    return Scripted(true, kWriteAlpha);
}

// ---- colour ----------------------------------------------------------------------------------

Json TintLayers()
{
    const Json bound = { { "user", "tint" }, { "value", "0.9 0.15 0.27" } };
    return Json::array({ ImageLayer(1, "plain", { { "color", bound }, { "alpha", 0.5 } }),
                         ImageLayer(2, "with effect",
                                    { { "color", bound }, { "alpha", 0.5 }, { "effects", Json::array({ CopyEffect(3) }) } }),
                         ImageLayer(4, "scripted",
                                    { { "color", Scripted("0.9 0.15 0.27", "export function update(value) { return new Vec3(0, 1, 0); }") },
                                      { "alpha", 0.5 } }) });
}

// R-9.05 / B-9.05
TEST(LayerColourReachesEveryMaterial, BoundAndScriptedColoursTintTheLayerAndEachEffectPass)
{
    ParseRig rig(TintAssets());
    rig.properties()["tint"] = RuntimeScalarValue::String("0 0 1");
    auto scene               = ParseLive(rig, TintLayers());
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    {
        SCOPED_TRACE("after parse, before any tick");
        ExpectTint(*scene, "plain", 1, { 0.0f, 0.0f, 1.0f });
        ExpectTint(*scene, "with effect", 2, { 0.0f, 0.0f, 1.0f });
        ExpectTint(*scene, "scripted", 1, { 0.9f, 0.15f, 0.27f });
    }
    scene->runtime->ApplyProjectPropertyOverride({ { "tint", RuntimeScalarValue::String("0.25 0.5 0.75") } });
    scene->runtime->Tick(kTick);
    {
        SCOPED_TRACE("after the property changed and a tick");
        ExpectTint(*scene, "plain", 1, { 0.25f, 0.5f, 0.75f });
        ExpectTint(*scene, "with effect", 2, { 0.25f, 0.5f, 0.75f });
        ExpectTint(*scene, "scripted", 1, { 0.0f, 1.0f, 0.0f });
    }
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(LayerColourReachesEveryMaterial, AnAbsentPropertyLeavesTheSceneFileColour)
{
    ParseRig rig(TintAssets());
    auto     scene = ParseLive(rig, TintLayers());
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    ExpectTint(*scene, "plain", 1, { 0.9f, 0.15f, 0.27f });
    ExpectTint(*scene, "with effect", 2, { 0.9f, 0.15f, 0.27f });
    scene->runtime->Tick(kTick);
    ExpectTint(*scene, "plain", 1, { 0.9f, 0.15f, 0.27f });
    ExpectTint(*scene, "with effect", 2, { 0.9f, 0.15f, 0.27f });
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(LayerColourReachesEveryMaterial, TheDeclaredPropertyValueBeatsTheSceneFileValueAtParse)
{
    ParseRig rig(TintAssets());
    rig.properties()["tint"] = RuntimeScalarValue::String("0.5 0.25 0.125");
    auto scene               = ParseLive(rig, TintLayers());
    ASSERT_NE(scene, nullptr);
    ExpectTint(*scene, "plain", 1, { 0.5f, 0.25f, 0.125f });
    ExpectTint(*scene, "with effect", 2, { 0.5f, 0.25f, 0.125f });
}

// ---- alpha ------------------------------------------------------------------------------------

Json AlphaLayers()
{
    return Json::array(
        { ImageLayer(1, "plain", { { "alpha", 0.5 } }),
          ImageLayer(2, "with effect", { { "alpha", 0.5 }, { "effects", Json::array({ CopyEffect(3) }) } }),
          ImageLayer(4, "two effects",
                     { { "alpha", 0.5 },
                       { "effects",
                         Json::array({ CopyEffect(5), CopyEffect(6, { { "visible", Scripted(false, kHideScript) } }) }) } }),
          ImageLayer(7, "written by itself",
                     { { "alpha", 0.5 }, { "visible", WritesAlpha() }, { "effects", Json::array({ CopyEffect(8) }) } }),
          ImageLayer(9, "owned by a script",
                     { { "alpha", Scripted(0.5, kKeepScript) }, { "effects", Json::array({ CopyEffect(10) }) } }) });
}

// Only the alpha lane is the subject; colour lanes are read but left unchecked.
void ExpectAlphaLane(Scene& scene, const std::string& name, std::size_t material_count, float alpha)
{
    SCOPED_TRACE(name);
    const auto materials = LayerMaterials(scene, name);
    ASSERT_EQ(materials.size(), material_count);
    for (std::size_t m = 0; m < materials.size(); ++m) {
        SCOPED_TRACE("material " + std::to_string(m));
        const auto colour = Constant(*materials[m], "g_Color4");
        ASSERT_EQ(colour.size(), 4u);
        EXPECT_FLOAT_EQ(colour[3], alpha);
    }
}

// R-9.06 / B-9.06
TEST(LayerAlphaReachesEveryMaterial, AHostOrScriptWriteReachesTheLayerAndEveryEffectPass)
{
    ParseRig rig(TintAssets());
    auto     scene = ParseLive(rig, AlphaLayers());
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;

    {
        SCOPED_TRACE("after parse");
        ExpectAlphaLane(*scene, "plain", 1, 0.5f);
        ExpectAlphaLane(*scene, "with effect", 2, 0.5f);
        // The effect a script switched off is built all the same.
        ExpectAlphaLane(*scene, "two effects", 3, 0.5f);
    }
    for (const auto& [name, count] : std::vector<std::pair<std::string, std::size_t>> { { "plain", 1 }, { "with effect", 2 }, { "two effects", 3 } }) {
        SCOPED_TRACE(name);
        ASSERT_TRUE(runtime.SetNodeAlpha(name, 0.25f));
        ExpectAlphaLane(*scene, name, count, 0.25f);
        ASSERT_TRUE(runtime.NodeAlpha(name).has_value());
        EXPECT_FLOAT_EQ(*runtime.NodeAlpha(name), 0.25f);
        ASSERT_TRUE(runtime.SetNodeAlpha(name, 0.0f));
        ExpectAlphaLane(*scene, name, count, 0.0f);
        EXPECT_FLOAT_EQ(*runtime.NodeAlpha(name), 0.0f);
    }

    {
        SCOPED_TRACE("a layer whose own script writes its alpha");
        ExpectAlphaLane(*scene, "written by itself", 2, 0.5f);
        runtime.Tick(kTick);
        ExpectAlphaLane(*scene, "written by itself", 2, 0.25f);
        ASSERT_TRUE(runtime.NodeAlpha("written by itself").has_value());
        EXPECT_FLOAT_EQ(*runtime.NodeAlpha("written by itself"), 0.25f);
    }
    {
        SCOPED_TRACE("a layer whose alpha a script owns refuses a second writer");
        EXPECT_FALSE(runtime.SetNodeAlpha("owned by a script", 0.1f));
        ExpectAlphaLane(*scene, "owned by a script", 2, 0.5f);
    }
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

TEST(LayerAlphaReachesEveryMaterial, ALayerWithoutTheNameTakesNoWrite)
{
    ParseRig rig(TintAssets());
    auto     scene = ParseLive(rig, AlphaLayers());
    ASSERT_NE(scene, nullptr);
    EXPECT_FALSE(scene->runtime->SetNodeAlpha("no such layer", 0.3f));
    EXPECT_FALSE(scene->runtime->NodeAlpha("no such layer").has_value());
    ExpectAlphaLane(*scene, "plain", 1, 0.5f);
}

// ---- an effect's own alpha --------------------------------------------------------------------

// The layer's alpha (g_Color4 alpha and g_Alpha everywhere, g_UserAlpha of its own pass) and the
// effect's own opacity (g_UserAlpha of every effect pass) as they stand.
void ExpectAlphas(Scene& scene, const std::string& name, std::size_t material_count, float layer_alpha, float effect_alpha)
{
    SCOPED_TRACE(name);
    const auto materials = LayerMaterials(scene, name);
    ASSERT_EQ(materials.size(), material_count);
    for (std::size_t m = 0; m < materials.size(); ++m) {
        SCOPED_TRACE("material " + std::to_string(m));
        const auto user  = Constant(*materials[m], "g_UserAlpha");
        const auto tint  = Constant(*materials[m], "g_Color4");
        const auto alpha = Constant(*materials[m], "g_Alpha");
        ASSERT_GE(user.size(), 1u);
        ASSERT_EQ(tint.size(), 4u);
        ASSERT_GE(alpha.size(), 1u);
        EXPECT_FLOAT_EQ(user[0], m == 0 ? layer_alpha : effect_alpha) << "g_UserAlpha";
        EXPECT_FLOAT_EQ(tint[3], layer_alpha) << "g_Color4 alpha";
        EXPECT_FLOAT_EQ(alpha[0], layer_alpha) << "g_Alpha";
    }
}

Json OwnAlphaLayers()
{
    const auto effects = [](int id) { return Json::array({ OpacityEffect(id, 0.8) }); };
    return Json::array(
        { ImageLayer(1, "authored", { { "alpha", 0.5 }, { "effects", effects(10) } }),
          ImageLayer(2, "written", { { "alpha", 0.5 }, { "visible", WritesAlpha() }, { "effects", effects(10) } }),
          ImageLayer(3, "bound", { { "alpha", { { "user", "fade" }, { "value", 1 } } }, { "effects", effects(10) } }),
          ImageLayer(4, "owned by a script", { { "alpha", Scripted(0.5, "export function update(value) { return 0.3; }") }, { "effects", effects(10) } }),
          ImageLayer(5, "two effects", { { "alpha", 0.5 }, { "effects", Json::array({ OpacityEffect(30, 0.8), OpacityEffect(20, 0.8) }) } }) });
}

// R-9.07 / B-9.07
TEST(EffectOwnAlpha, TheLayersAlphaNeverOverwritesAnEffectPassOpacity)
{
    ParseRig rig(TintAssets());
    rig.properties()["fade"] = RuntimeScalarValue::Float(0.4f);
    auto scene               = ParseLive(rig, OwnAlphaLayers());
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;

    {
        SCOPED_TRACE("after parse");
        ExpectAlphas(*scene, "authored", 2, 0.5f, 0.8f);
        ExpectAlphas(*scene, "two effects", 3, 0.5f, 0.8f);
    }
    {
        SCOPED_TRACE("the host sets the alpha");
        ASSERT_TRUE(runtime.SetNodeAlpha("authored", 0.1f));
        ExpectAlphas(*scene, "authored", 2, 0.1f, 0.8f);
        ASSERT_TRUE(runtime.SetNodeAlpha("two effects", 0.2f));
        ExpectAlphas(*scene, "two effects", 3, 0.2f, 0.8f);
    }
    runtime.Tick(kTick);
    {
        SCOPED_TRACE("after a tick");
        ExpectAlphas(*scene, "written", 2, 0.25f, 0.8f);
        ExpectAlphas(*scene, "bound", 2, 0.4f, 0.8f);
        ExpectAlphas(*scene, "owned by a script", 2, 0.3f, 0.8f);
    }
    runtime.ApplyProjectPropertyOverride({ { "fade", RuntimeScalarValue::Float(0.7f) } });
    runtime.Tick(kTick);
    {
        SCOPED_TRACE("the bound property changed");
        ExpectAlphas(*scene, "bound", 2, 0.7f, 0.8f);
    }
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

Json InheritedAlphaLayers()
{
    return Json::array({ ImageLayer(1, "authored", { { "alpha", 0.5 }, { "effects", Json::array({ OpacityEffect(10) }) } }),
                         ImageLayer(2, "written",
                                    { { "alpha", 0.5 }, { "visible", WritesAlpha() }, { "effects", Json::array({ OpacityEffect(20) }) } }) });
}

// R-9.08 / B-9.08
TEST(EffectOwnAlpha, AnEffectThatSetsNoAlphaStartsFromTheLayersAuthoredAlphaAndKeepsIt)
{
    ParseRig rig(TintAssets());
    auto     scene = ParseLive(rig, InheritedAlphaLayers());
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;

    {
        SCOPED_TRACE("after parse the effect begins at 0.5, not at the shader's default 1.0");
        ExpectAlphas(*scene, "authored", 2, 0.5f, 0.5f);
        ExpectAlphas(*scene, "written", 2, 0.5f, 0.5f);
    }
    ASSERT_TRUE(runtime.SetNodeAlpha("authored", 0.1f));
    {
        SCOPED_TRACE("the layer's alpha changes, the effect keeps its value");
        ExpectAlphas(*scene, "authored", 2, 0.1f, 0.5f);
    }
    runtime.Tick(kTick);
    {
        SCOPED_TRACE("a script writes the layer's alpha");
        ExpectAlphas(*scene, "written", 2, 0.25f, 0.5f);
    }
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

} // namespace
