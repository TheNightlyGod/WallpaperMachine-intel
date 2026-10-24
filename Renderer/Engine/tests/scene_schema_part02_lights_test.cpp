// Scene file schema, part 2: light objects. Which lights a scene keeps, how each kind lands in
// the shader arrays a lit material reads, and how a light follows a user property, a script and
// an intensity timeline.
#include "support/schema_fixtures_part02.hpp"

#include "WPShaderValueUpdater.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <string>

namespace
{

using namespace we_schema;
using namespace we_schema::p2;
using namespace wallpaper;

// The perspective scene (no lights configured unless `lights` says so) with the leaf model
// first and `others` after it.
Json LitScene(std::vector<Json> others, const Json& light_config = Json())
{
    Json objects = Json::array({ ModelObject(1, "planet", { { "perspective", true }, { "origin", "0 0 0" }, { "scale", "1 1 1" }, { "angles", "0 0 0" } }) });
    for (auto& other : others) objects.push_back(std::move(other));
    Json patch = Json::object();
    if (!light_config.is_null()) patch["lightconfig"] = light_config;
    return PerspectiveScene(std::move(objects), patch);
}

FileMap LeafAssets()
{
    FileMap files = BasicAssets();
    Add(files, LeafModelAssets());
    return files;
}

std::array<float, 3> WorldXAxis(SceneNode& node)
{
    node.UpdateTrans();
    const auto m = node.ModelTrans();
    return { static_cast<float>(m(0, 0)), static_cast<float>(m(1, 0)), static_cast<float>(m(2, 0)) };
}

// R-2.06 / B-2.06
TEST(SceneLights, ALegacyLightIsKeptAtItsOriginAndReachesThePackedLightPosition)
{
    ParseRig rig(LeafAssets());
    auto     scene = rig.Parse(LitScene({ LightObject(2, "bulb", "point",
                                                      { { "origin", "11 22 33" },
                                                        { "scale", "1 1 1" },
                                                        { "angles", "0 0 0" },
                                                        { "color", "1 0.5 0.25" },
                                                        { "radius", 1000 },
                                                        { "intensity", 0.75 } }) }));
    ASSERT_NE(scene, nullptr);
    ASSERT_EQ(scene->lights.size(), 1u);
    ASSERT_NE(scene->lights[0], nullptr);
    ASSERT_NE(scene->lights[0]->node(), nullptr);
    const auto& place = scene->lights[0]->node()->Translate();
    EXPECT_NEAR(place.x(), 11.0f, 1e-5f);
    EXPECT_NEAR(place.y(), 22.0f, 1e-5f);
    EXPECT_NEAR(place.z(), 33.0f, 1e-5f);

    ASSERT_NE(dynamic_cast<WPShaderValueUpdater*>(scene->shaderValueUpdater.get()), nullptr);
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    const Recorded seen = Probe(*scene, *model, { "g_EyePosition", "g_ViewForward", "g_ViewUp", "g_ViewRight", "g_LightsPosition" });
    ASSERT_EQ(seen.count("g_EyePosition"), 1u);
    ASSERT_GE(seen.at("g_EyePosition").size(), 3u);
    EXPECT_NEAR(seen.at("g_EyePosition")[0], 0.0f, 1e-3f);
    EXPECT_NEAR(seen.at("g_EyePosition")[1], 10.0f, 1e-3f);
    EXPECT_NEAR(seen.at("g_EyePosition")[2], 20.0f, 1e-3f);
    ASSERT_EQ(seen.count("g_LightsPosition"), 1u);
    ASSERT_GE(seen.at("g_LightsPosition").size(), 3u);
    EXPECT_NEAR(seen.at("g_LightsPosition")[0], 11.0f, 1e-3f);
    EXPECT_NEAR(seen.at("g_LightsPosition")[1], 22.0f, 1e-3f);
    EXPECT_NEAR(seen.at("g_LightsPosition")[2], 33.0f, 1e-3f);

    // The view forward axis points from the eye (0,10,20) at the centre (0,0,0).
    ASSERT_EQ(seen.count("g_ViewForward"), 1u);
    ASSERT_GE(seen.at("g_ViewForward").size(), 3u);
    EXPECT_NEAR(seen.at("g_ViewForward")[0], 0.0f, 1e-3f);
    EXPECT_NEAR(seen.at("g_ViewForward")[1], -10.0f / std::sqrt(500.0f), 1e-3f);
    EXPECT_NEAR(seen.at("g_ViewForward")[2], -20.0f / std::sqrt(500.0f), 1e-3f);
}

// R-2.07 / B-2.07
TEST(SceneLights, EachLightKindFillsItsOwnLightingArray)
{
    ParseRig rig(LeafAssets());
    const std::vector<Json> others = {
        LightObject(2, "point A", "lpoint",
                    { { "origin", "1 2 3" }, { "color", "1 0.5 0.25" }, { "intensity", 2 }, { "radius", 50 }, { "exponent", 3 } }),
        LightObject(3, "point hidden", "lpoint",
                    { { "origin", "9 9 9" }, { "color", "1 1 1" }, { "intensity", 5 }, { "radius", 50 }, { "visible", false } }),
        LightObject(4, "spot", "lspot",
                    { { "origin", "0 0 0" },
                      { "angles", "0 0 1.5707963" },
                      { "color", "0 1 0" },
                      { "intensity", 4 },
                      { "radius", 80 },
                      { "exponent", 1.5 },
                      { "innercone", 20 },
                      { "outercone", 30 } }),
        LightObject(5, "tube", "ltube",
                    { { "origin", "10 0 0" }, { "scale", "2 2 2" }, { "controlpoint", "5 0 0" }, { "color", "1 0 0" }, { "intensity", 1 }, { "radius", 30 } }),
        Json { { "id", 20 }, { "name", "group" }, { "origin", "100 0 0" }, { "angles", "0 0 0.5" }, { "visible", true } },
        LightObject(7, "sun", "ldirectional",
                    { { "parent", 20 }, { "origin", "1 0 0" }, { "color", "1 1 1" }, { "intensity", 0.5 }, { "radius", 200 } }),
        LightObject(8, "old bulb", "point", { { "origin", "7 8 9" }, { "color", "1 1 1" }, { "intensity", 1 }, { "radius", 2 } }),
    };
    auto scene = rig.Parse(LitScene(others, { { "point", 2 }, { "spot", 1 }, { "tube", 1 }, { "directional", 1 } }));
    ASSERT_NE(scene, nullptr);
    EXPECT_EQ(scene->light_config.point, 2u);
    EXPECT_EQ(scene->light_config.spot, 1u);
    EXPECT_EQ(scene->light_config.tube, 1u);
    EXPECT_EQ(scene->light_config.directional, 1u);
    // The hidden light is not parsed; the rest keep their authored order.
    ASSERT_EQ(scene->lights.size(), 5u);
    EXPECT_EQ(scene->lights[0]->type(), SceneLightType::Point);
    EXPECT_EQ(scene->lights[1]->type(), SceneLightType::Spot);
    EXPECT_EQ(scene->lights[2]->type(), SceneLightType::Tube);
    EXPECT_EQ(scene->lights[3]->type(), SceneLightType::Directional);
    EXPECT_EQ(scene->lights[4]->type(), SceneLightType::Legacy);

    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    const Recorded seen = Probe(*scene, *model,
                                { "g_LPoint_Color", "g_LPoint_Origin", "g_LSpot_Color", "g_LSpot_Origin", "g_LSpot_Direction", "g_LSpot_Exponent",
                                  "g_LTube_Color", "g_LTube_OriginA", "g_LTube_OriginB", "g_LDirectional_Color", "g_LDirectional_Direction",
                                  "g_LightsPosition", "g_LightsColorPremultiplied", "g_NormalModelMatrix" });

    EXPECT_TRUE(SlotIs(seen, "g_LPoint_Color", 0, { 2, 1, 0.5f, 50 }));
    EXPECT_TRUE(SlotIs(seen, "g_LPoint_Origin", 0, { 1, 2, 3, 3 }));
    EXPECT_TRUE(SlotIs(seen, "g_LPoint_Color", 1, { 0, 0, 0, 0 }));

    const auto spot_axis = WorldXAxis(*scene->lights[1]->node());
    EXPECT_GT(std::abs(spot_axis[1]), 0.99f);
    EXPECT_NEAR(spot_axis[0], 0.0f, 1e-4f);
    EXPECT_NEAR(spot_axis[1], 1.0f, 1e-4f);
    EXPECT_TRUE(SlotIs(seen, "g_LSpot_Color", 0, { 0, 4, 0, 80 }));
    EXPECT_TRUE(SlotIs(seen, "g_LSpot_Origin", 0, { 0, 0, 0, 0.9396926f }));
    EXPECT_TRUE(SlotIs(seen, "g_LSpot_Direction", 0, { spot_axis[0], spot_axis[1], spot_axis[2], 0.8660254f }));
    EXPECT_TRUE(SlotIs(seen, "g_LSpot_Exponent", 0, { 1.5f, 0, 0, 0 }));

    EXPECT_TRUE(SlotIs(seen, "g_LTube_OriginA", 0, { 10, 0, 0, 2 }));
    EXPECT_TRUE(SlotIs(seen, "g_LTube_OriginB", 0, { 20, 0, 0, 0 }));
    EXPECT_TRUE(SlotIs(seen, "g_LTube_Color", 0, { 1, 0, 0, 30 }));

    const auto sun_axis = WorldXAxis(*scene->lights[3]->node());
    EXPECT_GT(std::abs(sun_axis[1]), 0.4f);
    EXPECT_NEAR(sun_axis[0], std::cos(0.5f), 1e-4f);
    EXPECT_NEAR(sun_axis[1], std::sin(0.5f), 1e-4f);
    EXPECT_TRUE(SlotIs(seen, "g_LDirectional_Color", 0, { 0.5f, 0.5f, 0.5f, 1 }));
    EXPECT_TRUE(SlotIs(seen, "g_LDirectional_Direction", 0, { -sun_axis[0], -sun_axis[1], -sun_axis[2], 0 }));

    // Only the legacy light feeds the packed legacy array.
    EXPECT_TRUE(SlotIs(seen, "g_LightsPosition", 0, { 7, 8, 9, 0 }));
    EXPECT_TRUE(SlotIs(seen, "g_LightsPosition", 1, { 0, 0, 0, 0 }));
}

// The array of a kind holds exactly the configured number of lights; those past the count are
// not packed, and a kind the config leaves out has no light in any array.
TEST(SceneLights, LightsBeyondTheConfiguredCountOfTheirKindAreNotPacked)
{
    ParseRig rig(LeafAssets());
    auto     scene = rig.Parse(LitScene({ LightObject(2, "first", "lpoint", { { "origin", "1 0 0" }, { "radius", 5 } }),
                                          LightObject(3, "second", "lpoint", { { "origin", "2 0 0" }, { "radius", 5 } }),
                                          LightObject(4, "extra", "lpoint", { { "origin", "3 0 0" }, { "radius", 5 } }),
                                          LightObject(5, "spot", "lspot", { { "origin", "4 0 0" }, { "radius", 5 } }) },
                                        { { "point", 2 } }));
    ASSERT_NE(scene, nullptr);
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    const Recorded seen = Probe(*scene, *model, { "g_LPoint_Origin", "g_LSpot_Origin" });
    ASSERT_EQ(seen.count("g_LPoint_Origin"), 1u);
    EXPECT_EQ(seen.at("g_LPoint_Origin").size(), 8u);
    EXPECT_TRUE(SlotIs(seen, "g_LPoint_Origin", 0, { 1, 0, 0, 2 }));
    EXPECT_TRUE(SlotIs(seen, "g_LPoint_Origin", 1, { 2, 0, 0, 2 }));
    // The spot light has no slot to land in: the config asks for none.
    const auto spots = seen.find("g_LSpot_Origin");
    if (spots != seen.end()) {
        for (const float lane : spots->second) EXPECT_EQ(lane, 0.0f);
    }
}

// R-2.08 / B-2.08
TEST(SceneLights, LightsFollowAUserPropertyAScriptAndAnIntensityTimeline)
{
    ParseRig rig(LeafAssets());
    rig.properties() = ProjectProperties { { "daynight", RuntimeScalarValue::Bool(true) } };
    const Json intensity = { { "value", 1 },
                             { "animation",
                               { { "options", { { "fps", 10 }, { "length", 10 }, { "mode", "single" } } },
                                 { "c0", Json::array({ { { "frame", 0 }, { "value", 1 } }, { { "frame", 10 }, { "value", 3 } } }) } } } };
    const Json moved     = { { "value", "0 0 0" }, { "script", "export function update(value) { return new Vec3(4, 5, 6); }" } };
    auto       scene     = rig.Parse(LitScene({ LightObject(2, "day", "lpoint",
                                                              { { "origin", "0 0 0" },
                                                                { "color", "1 1 1" },
                                                                { "radius", 10 },
                                                                { "intensity", intensity },
                                                                { "visible", { { "user", "daynight" }, { "value", true } } } }),
                                                  LightObject(3, "moving", "lpoint",
                                                              { { "color", "1 1 1" }, { "radius", 10 }, { "intensity", 1 }, { "origin", moved } }) },
                                                { { "point", 2 } }),
                                 { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);

    scene->runtime->Tick(0.5);
    const Recorded morning = Probe(*scene, *model, { "g_LPoint_Color", "g_LPoint_Origin" });
    EXPECT_TRUE(SlotIs(morning, "g_LPoint_Color", 0, { 2, 2, 2, 10 }));
    EXPECT_TRUE(SlotIs(morning, "g_LPoint_Origin", 1, { 4, 5, 6, 2 }));
    const std::uint64_t before = scene->shaderValueUpdater->LightStateHash(model, 0);
    EXPECT_NE(before, 0u);

    scene->runtime->ApplyProjectPropertyOverride({ { "daynight", RuntimeScalarValue::Bool(false) } });
    scene->runtime->Tick(0.01);
    const Recorded night = Probe(*scene, *model, { "g_LPoint_Color", "g_LPoint_Origin" });
    EXPECT_TRUE(SlotIs(night, "g_LPoint_Origin", 0, { 4, 5, 6, 2 }));
    EXPECT_TRUE(SlotIs(night, "g_LPoint_Color", 1, { 0, 0, 0, 0 }));
    EXPECT_NE(scene->shaderValueUpdater->LightStateHash(model, 0), before);
}

} // namespace
