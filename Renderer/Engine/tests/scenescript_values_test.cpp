// What a script's value means to the property it drives (items 1 and 2 of the SceneScript
// behaviour list): a number for a vector property fills every component and the property stays a
// vector, and a value bound to a choice with a condition is a flag that is true only while the
// choice equals the condition.
//
// Headless: scenes are loaded for their runtime only (support/script_scene.hpp).

#include "scenescript_scenes.hpp"

#include "Runtime/SceneRuntimeContext.hpp"

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

INSTANTIATE_TEST_SUITE_P(Choices, ChoiceAsFlag, ::testing::Values(true, false),
                         [](const auto& info) { return info.param ? "NumbersFromThePreview" : "TextFromThePreview"; });

