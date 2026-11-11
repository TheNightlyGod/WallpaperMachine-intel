// What a script's value means to the property it drives (items 1 and 2 of the SceneScript
// behaviour list): a number for a vector property fills every component and the property stays a
// vector, and a value bound to a choice with a condition is a flag that is true only while the
// choice equals the condition.
//
// Headless: scenes are loaded for their runtime only (support/script_scene.hpp).

#include "scenescript_scenes.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneLight.hpp"

#include <gtest/gtest.h>

namespace
{
using namespace we_test;

std::string ModelOf(ScenePackage& package) { return package.AddImageModel("plain"); }

// A script on the alpha of a "driver" layer; it writes what it saw to the origin of "probe".
Json DriverLayer(const std::string& model, const std::string& source, const Json& properties = Json::object())
{
    return PlainImage(model, 2, "driver", { { "alpha", ScriptedValue(source, 1.0, properties) } });
}

} // namespace

// ---- item 1: a number fills every component --------------------------------------------

TEST(ScriptVectorNumbers, EasingAScaleWithABareNumberStaysUniformFiniteAndMonotonic)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    const auto   source = Join({ "export function update(value) {",
                                 "  return value.x + (2 - value.x) * 0.1;",
                                 "}" });
    Publish(package, { PlainImage(model, 1, "widget", { { "scale", ScriptedValue(source, "1 1 1") } }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();

    float previous = 1.0f;
    for (int frame = 0; frame < 30; ++frame) {
        scene.Tick();
        const auto scale = scene.Scale("widget");
        ASSERT_TRUE(AllFinite(scale)) << "frame " << frame << ": " << scale[0] << " " << scale[1] << " " << scale[2];
        EXPECT_FLOAT_EQ(scale[0], scale[1]) << "frame " << frame;
        EXPECT_FLOAT_EQ(scale[0], scale[2]) << "frame " << frame;
        EXPECT_GT(scale[0], previous) << "scale stops growing at frame " << frame;
        EXPECT_LT(scale[0], 2.0f);
        previous = scale[0];
    }
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    // 1 + (2 - 1) * (1 - 0.9^30)
    EXPECT_NEAR(previous, 2.0f - std::pow(0.9f, 30.0f), 1e-3f);
}

TEST(ScriptVectorNumbers, ATwoComponentShaderConstantStepsByTheNumberOnBothComponents)
{
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   effect = AddProbeEffect(package);
    const auto   source = "export function update(value) { return value.y + 1; }";
    Publish(package, { PlainImage(model, 1, "widget", {},
                                  { EffectUse(effect, { { "pair", ScriptedValue(source, "0 0") } }) }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    for (int frame = 1; frame <= 5; ++frame) {
        scene.Tick();
        const auto pair = scene.EffectConstant(0, "g_Pair");
        ASSERT_EQ(pair.size(), 2u);
        EXPECT_FLOAT_EQ(pair[0], static_cast<float>(frame)) << "frame " << frame;
        EXPECT_FLOAT_EQ(pair[1], static_cast<float>(frame)) << "frame " << frame;
    }
    EXPECT_TRUE(scene.ScriptErrors().empty());
}

TEST(ScriptVectorNumbers, ABareNumberForAnAnglesAndAnOriginSettingFillsEveryAxis)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    Publish(package, { PlainImage(model, 1, "a", { { "angles", ScriptedValue("export function update() { return 30; }", "0 0 0") },
                                                    { "origin", ScriptedValue("export function update() { return 7; }", "1 2 3") } }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    const auto angles = scene.AnglesDegrees("a");
    for (const float lane : angles) EXPECT_NEAR(lane, 30.0f, 1e-3f);
    const auto origin = scene.Origin("a");
    for (const float lane : origin) EXPECT_FLOAT_EQ(lane, 7.0f);
}

TEST(ScriptVectorNumbers, ABareNumberForAColourSettingFillsEveryChannel)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    Publish(package, { PlainImage(model, 1, "tinted",
                                  { { "color", ScriptedValue("export function update(v) { return v.x * 0 + 0.25; }", "1 1 1") } }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(3);
    const auto colour = scene.Color("tinted");
    for (const float lane : colour) EXPECT_FLOAT_EQ(lane, 0.25f);
    EXPECT_TRUE(scene.ScriptErrors().empty());
}

TEST(ScriptVectorNumbers, WritingANumberToColourAndParallaxDepthSetsEveryComponent)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    const auto   source = Join({ "export function update() {",
                                 "  thisScene.getLayer('target').color = 0.5;",
                                 "  thisScene.getLayer('target').parallaxDepth = 0.75;",
                                 "  return 1;",
                                 "}" });
    Publish(package, { PlainImage(model, 1, "target", { { "color", "1 0 0" }, { "parallaxDepth", "0 0" } }),
                       DriverLayer(model, source) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    for (const float lane : scene.Color("target")) EXPECT_FLOAT_EQ(lane, 0.5f);
    for (const float lane : scene.ParallaxDepth("target")) EXPECT_FLOAT_EQ(lane, 0.75f);
    EXPECT_TRUE(scene.ScriptErrors().empty());
}

TEST(ScriptVectorNumbers, AResultThatIsNotAValueLeavesAVectorPropertyAsItWas)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    Publish(package, { PlainImage(model, 1, "kept", { { "scale", ScriptedValue("export function update() { }", "3 3 3") } }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(3);
    EXPECT_EQ(scene.Scale("kept"), (std::array<float, 3> { 3.0f, 3.0f, 3.0f }));
}

// ---- item 2: a choice bound with a condition is a flag ---------------------------------

namespace
{
Json ComboProperty(const std::string& value)
{
    return { { "type", "combo" },
             { "text", "format" },
             { "value", value },
             { "options", Json::array({ { { "label", "a" }, { "value", "0" } },
                                         { { "label", "b" }, { "value", "1" } },
                                         { { "label", "c" }, { "value", "2" } } }) } };
}

Json ConditionBinding(const std::string& condition)
{
    return { { "user", { { "name", "format" }, { "condition", condition } } }, { "value", false } };
}

class ChoiceAsFlag : public ::testing::TestWithParam<bool> {
protected:
    // The choice as the host's live preview supplies it: a number, or the text of the option.
    Json Choice(int value) const { return GetParam() ? Json(value) : Json(std::to_string(value)); }
};
} // namespace

TEST_P(ChoiceAsFlag, ScriptPropertiesBoundWithConditionsReadTrueOrFalseAsTheChoiceMoves)
{
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   source = Join({ "var props = createScriptProperties()",
                                 "  .addCheckbox({ name: 'zero', value: false })",
                                 "  .addCheckbox({ name: 'two', value: false })",
                                 "  .finish();",
                                 "export function update() {",
                                 "  var ok = typeof props.zero === 'boolean' && typeof props.two === 'boolean';",
                                 "  thisScene.getLayer('probe').origin = new Vec3(props.zero ? 1 : 0, props.two ? 1 : 0, ok ? 1 : 0);",
                                 "  return 1;",
                                 "}" });
    const Json   properties = { { "zero", ConditionBinding("0") }, { "two", ConditionBinding("2") } };
    Publish(package, { PlainImage(model, 1, "probe"), DriverLayer(model, source, properties) },
            { { "format", ComboProperty("1") } });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();

    struct Step {
        int  choice;
        bool zero;
        bool two;
    };
    for (const Step step : { Step { 2, false, true }, Step { 0, true, false }, Step { 1, false, false } }) {
        ASSERT_TRUE(scene.SetProperty("format", Choice(step.choice)));
        scene.Tick(2);
        const auto seen = scene.Origin("probe");
        EXPECT_EQ(seen[0] != 0.0f, step.zero) << "choice " << step.choice << " (flag 0)";
        EXPECT_EQ(seen[1] != 0.0f, step.two) << "choice " << step.choice << " (flag 2)";
        EXPECT_EQ(seen[2], 1.0f) << "choice " << step.choice << ": both must be booleans";
    }
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST_P(ChoiceAsFlag, ALayerVisibilityBoundWithAConditionFollowsTheChoice)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    Json         binding = { { "user", { { "name", "format" }, { "condition", "2" } } }, { "value", true } };
    Publish(package, { PlainImage(model, 1, "gated", { { "visible", binding } }) }, { { "format", ComboProperty("1") } });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_FALSE(scene.Visible("gated"));
    ASSERT_TRUE(scene.SetProperty("format", Choice(2)));
    scene.Tick();
    EXPECT_TRUE(scene.Visible("gated"));
    ASSERT_TRUE(scene.SetProperty("format", Choice(0)));
    scene.Tick();
    EXPECT_FALSE(scene.Visible("gated"));
}

TEST_P(ChoiceAsFlag, AShaderConstantBoundWithAConditionReadsOneOrZero)
{
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   effect = AddProbeEffect(package);
    Json         binding = { { "user", { { "name", "format" }, { "condition", "2" } } }, { "value", 0 } };
    Json         plain   = { { "user", "format" }, { "value", 0 } };
    Publish(package, { PlainImage(model, 1, "widget", {},
                                  { EffectUse(effect, { { "flag", binding } }),
                                    EffectUse(effect, { { "flag", plain } }) }) },
            { { "format", ComboProperty("1") } });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_EQ(scene.EffectConstant(0, "g_Flag"), std::vector<float> { 0.0f });
    ASSERT_TRUE(scene.SetProperty("format", Choice(2)));
    scene.Tick();
    EXPECT_EQ(scene.EffectConstant(0, "g_Flag"), std::vector<float> { 1.0f });
    // A numeric choice with no condition keeps being read as that number.
    EXPECT_EQ(scene.EffectConstant(1, "g_Flag"), std::vector<float> { 2.0f });
    ASSERT_TRUE(scene.SetProperty("format", Choice(1)));
    scene.Tick();
    EXPECT_EQ(scene.EffectConstant(0, "g_Flag"), std::vector<float> { 0.0f });
    EXPECT_EQ(scene.EffectConstant(1, "g_Flag"), std::vector<float> { 1.0f });
}

// Wallpaper Engine shows a layer whose visibility names a property the project never declares
// by its own authored value, with or without a condition: there is no choice to compare.
TEST(ChoiceAsFlagUndeclared, AVisibilityBoundToAnUndeclaredPropertyKeepsItsOwnAuthoredValue)
{
    ScenePackage package;
    const auto   model = ModelOf(package);
    const auto   gated = [](const char* condition, bool authored) {
        return Json { { "user", { { "name", "missing" }, { "condition", condition } } }, { "value", authored } };
    };
    Publish(package, { PlainImage(model, 1, "shown", { { "visible", gated("0", true) } }),
                       PlainImage(model, 2, "hidden", { { "visible", gated("0", false) } }),
                       PlainImage(model, 3, "plain", { { "visible", { { "user", "missing" }, { "value", false } } } }) },
            { { "format", ComboProperty("1") } });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_TRUE(scene.Visible("shown"));
    EXPECT_FALSE(scene.Visible("hidden"));
    EXPECT_FALSE(scene.Visible("plain"));

    // Once a document supplies the name, every binding follows it as a declared one would.
    ASSERT_TRUE(scene.SetProperty("missing", Json("0")));
    scene.Tick();
    EXPECT_TRUE(scene.Visible("shown"));
    EXPECT_TRUE(scene.Visible("hidden"));
    EXPECT_FALSE(scene.Visible("plain"));
    ASSERT_TRUE(scene.SetProperty("missing", Json(1)));
    scene.Tick();
    EXPECT_FALSE(scene.Visible("shown"));
    EXPECT_FALSE(scene.Visible("hidden"));
    EXPECT_TRUE(scene.Visible("plain"));
}

INSTANTIATE_TEST_SUITE_P(Choices, ChoiceAsFlag, ::testing::Values(true, false),
                         [](const auto& info) { return info.param ? "NumbersFromThePreview" : "TextFromThePreview"; });


// ---- image layer members (we_ss_reg_ImageLayer 0x1401EE520) -------------------------------

TEST(ScriptLayerFlags, TheMembersReadTheAuthoredImageLayer)
{
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   source = Join({ "export function update(value) {",
                                 "  var t = thisScene.getLayer('target');",
                                 "  t.origin = new Vec3(t.clampuvs === false ? 1 : 0, t.castshadow === true ? 1 : 0,",
                                 "                      t.copybackground === true && t.perspective === false ? 1 : 0);",
                                 "  return 1;",
                                 "}" });
    Publish(package, { PlainImage(model, 1, "target", { { "clampuvs", false }, { "castshadow", true } }),
                       DriverLayer(model, source) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    const auto origin = scene.Origin("target");
    EXPECT_FLOAT_EQ(origin[0], 1.0f) << "clampuvs";
    EXPECT_FLOAT_EQ(origin[1], 1.0f) << "castshadow";
    EXPECT_FLOAT_EQ(origin[2], 1.0f) << "copybackground and perspective defaults";
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

// `size` is a writable Vec2 (+752, setter 0x1401A4200) that the draw reads: a write stretches the card.
TEST(ScriptLayerFlags, SizeWriteStretchesTheCard)
{
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   source = Join({ "export function update(value) {",
                                 "  var t = thisScene.getLayer('target');",
                                 "  t.size = new Vec2(128, 16);",
                                 "  thisScene.getLayer('driver').origin = new Vec3(t.size.x, t.size.y, 0);",
                                 "  return 1;",
                                 "}" });
    Publish(package, { PlainImage(model, 1, "target"), DriverLayer(model, source) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    const auto size = scene.runtime().NodeSize("target");
    EXPECT_FLOAT_EQ(size.x(), 128.0f);
    EXPECT_FLOAT_EQ(size.y(), 16.0f);
    const auto read = scene.Origin("driver");
    EXPECT_FLOAT_EQ(read[0], 128.0f) << "and reads back";
    EXPECT_FLOAT_EQ(read[1], 16.0f);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

// `sortorder` is an integer of every layer (@292, we_ss_reg_SceneObjectBase 0x1401E0530): it reads
// the file's value and back what a script wrote; with `customsortorder` Wallpaper Engine sorts the
// draw by it every frame, so a write there rebuilds the graph once.
TEST(ScriptLayerFlags, SortOrderReadsBackWhatWasWritten)
{
    for (const bool custom : { false, true }) {
        ScenePackage package;
        const auto   model  = ModelOf(package);
        const auto   source = Join({ "var authored;",
                                     "export function update(value) {",
                                     "  var t = thisScene.getLayer('target');",
                                     "  if (authored === undefined) authored = t.sortorder;",
                                     "  t.sortorder = 7.9;",
                                     "  thisScene.getLayer('driver').origin = new Vec3(authored, t.sortorder,",
                                     "                                                  thisScene.getLayer('driver').sortorder);",
                                     "  return 1;",
                                     "}" });
        SceneGeneral general;
        general.extra = { { "customsortorder", custom } };
        package.SetProject(Json::object());
        package.SetScene(SceneJson(general, { PlainImage(model, 1, "target", { { "sortorder", 5 } }),
                                              DriverLayer(model, source) }));

        ScriptScene scene(package);
        ASSERT_TRUE(scene.ok()) << scene.error();
        scene.Tick(3);
        const auto read = scene.Origin("driver");
        EXPECT_FLOAT_EQ(read[0], 5.0f) << "authored";
        EXPECT_FLOAT_EQ(read[1], 7.0f) << "written, an integer";
        EXPECT_FLOAT_EQ(read[2], 0.0f) << "a layer without one";
        EXPECT_EQ(scene.runtime().NodeSortOrder("target"), 7);
        const auto& reasons = scene.runtime().SceneGraphMutationReasonsForTests();
        const auto  found   = reasons.find("sortorder");
        EXPECT_EQ(found == reasons.end() ? 0 : found->second, custom ? 1 : 0) << "customsortorder " << custom;
        EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    }
}

// ---- light layer members (we_ss_reg_LightLayer 0x14025DA80, decompiles/A-7g.md) ------------

TEST(ScriptLights, IntensityWriteChangesPremultipliedColour)
{
    using wallpaper::SceneLight;
    using wallpaper::SceneLightType;
    ScenePackage package;
    const auto   model  = ModelOf(package);
    const auto   source = Join({ "var done = false, ok = 0;",
                                 "export function update(value) {",
                                 "  if (!done) {",
                                 "    done = true;",
                                 "    var lamp = thisScene.getLayer('lamp'), spot = thisScene.getLayer('spot');",
                                 "    var read = lamp.intensity === 2 && lamp.radius === 10 && lamp.light === 'point' &&",
                                 "               lamp.castshadow === false && lamp.density === 2 && lamp.color.y === 0.5;",
                                 "    lamp.intensity = 3;",
                                 "    lamp.color = new Vec3(0, 1, 0);",
                                 "    spot.innercone = 15;",
                                 "    spot.controlpoint = new Vec3(1, 2, 3);",
                                 "    spot.castshadow = true;",
                                 "    spot.usecookie = true;",
                                 "    spot.density = 4;",
                                 "    spot.cascadedistance1 = 12;",
                                 "    spot.light = 'lspot';",
                                 "    spot.visible = false;",
                                 "    var back = lamp.intensity === 3 && spot.innercone === 15 && spot.castshadow === true &&",
                                 "               spot.light === 'lspot' && spot.controlpoint.z === 3 && spot.usecookie === true;",
                                 "    ok = read && back ? 1 : 0;",
                                 "  }",
                                 "  thisLayer.origin = new Vec3(ok, 0, 0);",
                                 "  return 1;",
                                 "}" });
    const Json lamp = { { "id", 4 }, { "name", "lamp" }, { "light", "point" }, { "origin", "10 20 0" },
                        { "color", "1 0.5 0.25" }, { "intensity", 2.0 }, { "radius", 10.0 } };
    const Json spot = { { "id", 5 }, { "name", "spot" }, { "light", "lpoint" }, { "origin", "0 0 0" },
                        { "color", "1 1 1" }, { "intensity", 1.0 }, { "radius", 10.0 } };
    Publish(package, { lamp, spot, PlainImage(model, 3, "driver", { { "alpha", ScriptedValue(source, 1.0) } }) });

    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_FLOAT_EQ(scene.Origin("driver")[0], 1.0f) << "members read the file and back what was written";
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    ASSERT_EQ(scene.scene().lights.size(), 2u);
    const auto& first  = *scene.scene().lights[0];
    const auto& second = *scene.scene().lights[1];
    const auto  premultiplied = first.premultipliedColor();
    EXPECT_FLOAT_EQ(premultiplied.x(), 0.0f);
    EXPECT_FLOAT_EQ(premultiplied.y(), 3.0f * 100.0f) << "colour times intensity times radius squared";
    EXPECT_EQ(second.type(), SceneLightType::Spot);
    EXPECT_FLOAT_EQ(second.innerCone(), 15.0f);
    EXPECT_FLOAT_EQ(second.controlPoint().z(), 3.0f);
    EXPECT_NE(second.flags() & SceneLight::kCastShadow, 0u);
    EXPECT_NE(second.flags() & SceneLight::kUseCookie, 0u);
    EXPECT_FLOAT_EQ(second.density(), 4.0f);
    EXPECT_FLOAT_EQ(second.cascadeDistances()[1], 12.0f);
    EXPECT_FALSE(second.visible());
}
