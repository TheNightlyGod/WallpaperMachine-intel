// Scene file schema, part 10 (image colour): a layer's colour keyed on a timeline tints the layer
// and every effect pass, and which source wins when a script or a property writes it as well.
#include "support/schema_fixtures.hpp"
#include "support/schema_layer_assets.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/SceneUpdateDemand.hpp"

#include <gtest/gtest.h>

#include <array>
#include <string>

namespace
{

using namespace we_schema;
using namespace we_schema::layers;
using namespace wallpaper;

constexpr double kTick = 1.0 / 60.0;
constexpr uint32_t kAnimationDemand = static_cast<uint32_t>(SceneDemandReason::Animation);

// The colour curves of the keyed layers: ten frames at ten frames a second, red 0.2 -> 1.0,
// green 0.4 -> 0.0, blue held at 0.6.
Json ColourTimeline(const std::string& name, bool paused = false)
{
    Json options = { { "fps", 10 }, { "length", 10 }, { "mode", "single" }, { "name", name } };
    if (paused) options["startpaused"] = true;
    return { { "options", options },
             { "c0", Curve({ { 0, 0.2 }, { 10, 1.0 } }) },
             { "c1", Curve({ { 0, 0.4 }, { 10, 0.0 } }) },
             { "c2", Curve({ { 0, 0.6 }, { 10, 0.6 } }) } };
}

Json KeyedColour(const std::string& name, bool paused = false, const Json& extra = Json::object())
{
    Json colour = { { "value", "1 1 1" }, { "animation", ColourTimeline(name, paused) } };
    for (const auto& [key, value] : extra.items()) colour[key] = value;
    return colour;
}

// ---- a keyed colour -----------------------------------------------------------------------------

// R-10.01 / B-10.01
TEST(KeyedLayerColour, TheTimelineTintsTheLayerAndEveryEffectPassAndAPausedOneWaitsForPlay)
{
    ParseRig rig(TintAssets());
    auto     scene = rig.Parse(
        QuietScene(Json::array({ ImageLayer(1, "plain", { { "color", KeyedColour("tint") }, { "alpha", 0.5 } }),
                                 ImageLayer(2, "with effect",
                                            { { "color", KeyedColour("tint") }, { "alpha", 0.5 }, { "effects", Json::array({ CopyEffect(3) }) } }),
                                 ImageLayer(4, "held", { { "color", KeyedColour("tint", true) }, { "alpha", 0.5 } }) }),
                   { { "bloom", false } }),
        { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;

    {
        SCOPED_TRACE("after parse");
        ExpectTint(*scene, "plain", 1, { 0.2f, 0.4f, 0.6f });
        ExpectTint(*scene, "with effect", 2, { 0.2f, 0.4f, 0.6f });
        ExpectTint(*scene, "held", 1, { 0.2f, 0.4f, 0.6f });
        EXPECT_NE(runtime.DescribeTimeAdvancingWork() & kAnimationDemand, 0u);
    }
    runtime.Tick(0.5);
    {
        SCOPED_TRACE("half a second");
        ExpectTint(*scene, "plain", 1, { 0.6f, 0.2f, 0.6f });
        ExpectTint(*scene, "with effect", 2, { 0.6f, 0.2f, 0.6f });
        ExpectTint(*scene, "held", 1, { 0.2f, 0.4f, 0.6f });
    }
    runtime.Tick(0.5);
    {
        SCOPED_TRACE("a second: the single timeline is at its last key");
        ExpectTint(*scene, "plain", 1, { 1.0f, 0.0f, 0.6f });
        ExpectTint(*scene, "with effect", 2, { 1.0f, 0.0f, 0.6f });
        ExpectTint(*scene, "held", 1, { 0.2f, 0.4f, 0.6f });
    }
    auto* clock = runtime.FindScalarAnimation("held", "tint");
    ASSERT_NE(clock, nullptr);
    clock->Play();
    runtime.Tick(0.5);
    {
        SCOPED_TRACE("the held layer plays");
        ExpectTint(*scene, "held", 1, { 0.6f, 0.2f, 0.6f });
    }
    runtime.Tick(0.5);
    {
        SCOPED_TRACE("and ends");
        ExpectTint(*scene, "held", 1, { 1.0f, 0.0f, 0.6f });
        ExpectTint(*scene, "plain", 1, { 1.0f, 0.0f, 0.6f });
        EXPECT_EQ(runtime.DescribeTimeAdvancingWork() & kAnimationDemand, 0u) << "nothing animates any more";
    }
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

TEST(KeyedLayerColour, ThePausedTimelineHoldsItsFirstKeyForever)
{
    ParseRig rig(TintAssets());
    auto     scene = rig.Parse(
        QuietScene(Json::array({ ImageLayer(1, "held", { { "color", KeyedColour("tint", true) }, { "alpha", 0.5 }, { "effects", Json::array({ CopyEffect(3) }) } }) }),
                   { { "bloom", false } }),
        { .live = true });
    ASSERT_NE(scene, nullptr);
    for (int tick = 0; tick < 4; ++tick) {
        scene->runtime->Tick(2.0);
        ExpectTint(*scene, "held", 2, { 0.2f, 0.4f, 0.6f });
    }
}

// ---- which source writes the colour ----------------------------------------------------------------

Json ClockLayers()
{
    const Json write_green = Scripted("1 1 1", "export function update(value) { return new Vec3(0, 1, 0); }");
    Json       scripted    = write_green;
    scripted["animation"]  = ColourTimeline("script clock");
    Json bound             = { { "user", "tint" } };
    bound["value"]         = "1 1 1";
    bound["animation"]     = ColourTimeline("property clock");
    const Json copy        = Json::array({ CopyEffect(3) });
    return Json::array({ ImageLayer(1, "keyed", { { "color", KeyedColour("keyed clock") }, { "alpha", 0.5 }, { "brightness", 0.5 }, { "effects", copy } }),
                         ImageLayer(2, "scripted", { { "color", scripted }, { "alpha", 0.5 }, { "brightness", 0.5 }, { "effects", copy } }),
                         ImageLayer(4, "bound", { { "color", bound }, { "alpha", 0.5 }, { "brightness", 0.5 }, { "effects", copy } }) });
}

// R-10.02 / B-10.02
TEST(LayerColourPrecedence, AScriptOrAPropertyOwnsTheColourAndHdrBrightnessScalesOnlyTheTint)
{
    FileMap files = TintAssets();
    Add(files, BloomAssets(BloomSet::Hdr));
    ParseRig rig(std::move(files));
    rig.properties()["tint"] = RuntimeScalarValue::String("0 0 1");
    auto scene               = rig.Parse(QuietScene(ClockLayers(), { { "hdr", true }, { "bloom", true } }), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_TRUE(scene->hdr);
    auto& runtime = *scene->runtime;

    {
        SCOPED_TRACE("after parse");
        ExpectTint(*scene, "keyed", 2, { 0.2f, 0.4f, 0.6f }, 0.5f, 0.5f);
        ExpectTint(*scene, "bound", 2, { 0.0f, 0.0f, 1.0f }, 0.5f, 0.5f);
    }
    runtime.Tick(0.5);
    {
        SCOPED_TRACE("half a second");
        ExpectTint(*scene, "keyed", 2, { 0.6f, 0.2f, 0.6f }, 0.5f, 0.5f);
        ExpectTint(*scene, "scripted", 2, { 0.0f, 1.0f, 0.0f }, 0.5f, 0.5f);
        ExpectTint(*scene, "bound", 2, { 0.0f, 0.0f, 1.0f }, 0.5f, 0.5f);
        EXPECT_NE(runtime.FindScalarAnimation("keyed", "keyed clock"), nullptr);
        // A script or a property is the only writer: its timeline is never registered.
        EXPECT_EQ(runtime.FindScalarAnimation("scripted", "script clock"), nullptr);
        EXPECT_EQ(runtime.FindScalarAnimation("bound", "property clock"), nullptr);
    }
    runtime.ApplyProjectPropertyOverride({ { "tint", RuntimeScalarValue::String("0.25 0.5 0.75") } });
    runtime.Tick(0.5);
    {
        SCOPED_TRACE("the property changed and the keyed timeline finished");
        ExpectTint(*scene, "keyed", 2, { 1.0f, 0.0f, 0.6f }, 0.5f, 0.5f);
        ExpectTint(*scene, "scripted", 2, { 0.0f, 1.0f, 0.0f }, 0.5f, 0.5f);
        ExpectTint(*scene, "bound", 2, { 0.25f, 0.5f, 0.75f }, 0.5f, 0.5f);
    }
    EXPECT_EQ(runtime.scriptErrorCount(), 0u);
}

TEST(LayerColourPrecedence, AStaticColourKeepsItsOwnValueAndOnlyTheTintIsBrightened)
{
    FileMap files = TintAssets();
    Add(files, BloomAssets(BloomSet::Hdr));
    ParseRig rig(std::move(files));
    auto     scene = rig.Parse(
        QuietScene(Json::array({ ImageLayer(1, "plain", { { "color", "0.2 0.4 0.6" }, { "alpha", 0.5 }, { "brightness", 0.5 } }),
                                 ImageLayer(2, "with effect",
                                            { { "color", "0.2 0.4 0.6" }, { "alpha", 0.5 }, { "brightness", 0.5 }, { "effects", Json::array({ CopyEffect(3) }) } }) }),
                   { { "hdr", true }, { "bloom", true } }),
        { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    ExpectTint(*scene, "plain", 1, { 0.2f, 0.4f, 0.6f }, 0.5f, 0.5f);
    ExpectTint(*scene, "with effect", 2, { 0.2f, 0.4f, 0.6f }, 0.5f, 0.5f);
    scene->runtime->Tick(kTick);
    ExpectTint(*scene, "plain", 1, { 0.2f, 0.4f, 0.6f }, 0.5f, 0.5f);
    ExpectTint(*scene, "with effect", 2, { 0.2f, 0.4f, 0.6f }, 0.5f, 0.5f);
}

TEST(LayerColourPrecedence, WithoutHdrBrightnessLeavesTheTintAlone)
{
    ParseRig rig(TintAssets());
    rig.properties()["tint"] = RuntimeScalarValue::String("0 0 1");
    auto scene               = rig.Parse(QuietScene(ClockLayers(), { { "bloom", false } }), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->hdr);

    ExpectTint(*scene, "keyed", 2, { 0.2f, 0.4f, 0.6f }, 0.5f, 1.0f);
    ExpectTint(*scene, "bound", 2, { 0.0f, 0.0f, 1.0f }, 0.5f, 1.0f);
    scene->runtime->Tick(0.5);
    ExpectTint(*scene, "keyed", 2, { 0.6f, 0.2f, 0.6f }, 0.5f, 1.0f);
    ExpectTint(*scene, "scripted", 2, { 0.0f, 1.0f, 0.0f }, 0.5f, 1.0f);
    scene->runtime->ApplyProjectPropertyOverride({ { "tint", RuntimeScalarValue::String("0.25 0.5 0.75") } });
    scene->runtime->Tick(0.5);
    ExpectTint(*scene, "keyed", 2, { 1.0f, 0.0f, 0.6f }, 0.5f, 1.0f);
    ExpectTint(*scene, "bound", 2, { 0.25f, 0.5f, 0.75f }, 0.5f, 1.0f);
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

} // namespace
