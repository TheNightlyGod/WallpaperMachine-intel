// Scene file schema, part 2: light objects. Which lights a scene keeps, how each kind lands in
// the shader arrays a lit material reads, and how a light follows a user property, a script and
// an intensity timeline.
#include "support/schema_fixtures_part02.hpp"

#include "WPShaderValueUpdater.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"
#include "RenderCommon/ScenePass.hpp"
#include "RenderGraph/RenderGraph.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <set>
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

// The schema probe keeps the selected quality level while its light enables
// volumes. Supply a tiny utility chain so the fixture owns that dependency too.
FileMap VolumetricLeafAssets()
{
    FileMap files = LeafAssets();
    files["/shaders/volume_schema.vert"] =
        "attribute vec3 a_Position;\n"
        "void main(){gl_Position=vec4(a_Position,1.0); }\n";
    files["/shaders/volume_schema.frag"] =
        "void main(){gl_FragColor=vec4(0.0,0.0,0.0,1.0); }\n";
    for (const char* name : {"volumetrics_back", "volumetrics_front", "volumetrics_fullscreen",
                             "volumetrics_blur_h", "volumetrics_blur_v", "volumetrics_combine"}) {
        PutJson(files, std::string("/materials/util/") + name + ".json",
                {{"passes", Json::array({{{"shader", "volume_schema"},
                    {"blending", "normal"}, {"depthtest", "disabled"},
                    {"depthwrite", "disabled"}, {"cullmode", "nocull"}}})}});
    }
    return files;
}

std::array<float, 3> WorldXAxis(SceneNode& node)
{
    node.UpdateTrans();
    const auto m = node.ModelTrans();
    return { static_cast<float>(m(0, 0)), static_cast<float>(m(1, 0)), static_cast<float>(m(2, 0)) };
}

// The macros the leaf model's material was compiled with, each switched on (non-zero).
std::set<std::string> PlanetDefines(Scene& scene)
{
    SceneNode* model = FindRootChild(scene, "planet");
    if (model == nullptr || model->Mesh() == nullptr || model->Mesh()->MaterialForSlot(0) == nullptr) return {};
    const auto& defines = model->Mesh()->MaterialForSlot(0)->defines;
    return { defines.begin(), defines.end() };
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

// Wallpaper Engine numbers legacy slots across every light object in file
// order, LightingV1 lights included (sub_14018FF60): an `lpoint` before a
// legacy `point` leaves the legacy light slot 1.
TEST(SceneLights, LegacyLightsTakeTheSlotOfTheirPlaceAmongAllLights)
{
    ParseRig rig(LeafAssets());
    auto scene = rig.Parse(LitScene({ LightObject(2, "modern", "lpoint", { { "origin", "1 2 3" }, { "radius", 5 } }),
                                      LightObject(3, "old bulb", "point",
                                                  { { "origin", "7 8 9" }, { "color", "1 1 1" }, { "intensity", 1 }, { "radius", 2 } }) },
                                    { { "point", 1 } }));
    ASSERT_NE(scene, nullptr);
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    const Recorded seen = Probe(*scene, *model, { "g_LightsPosition" });
    EXPECT_TRUE(SlotIs(seen, "g_LightsPosition", 0, { 0, 0, 0, 0 }));
    EXPECT_TRUE(SlotIs(seen, "g_LightsPosition", 1, { 7, 8, 9, 0 }));
}

// Wallpaper Engine sorts a kind's lights nearest along the camera's forward axis
// first (we_SortSceneLights 0x140186990, comparator 0x14019F360), so with one point
// slot the nearer light is the one packed, whatever its place in the file.
TEST(SceneLights, LightsOfAKindArePackedNearestToTheCameraFirst)
{
    ParseRig rig(LeafAssets());
    auto scene = rig.Parse(LitScene({ LightObject(2, "far", "lpoint", { { "origin", "0 0 -100" }, { "radius", 5 } }),
                                      LightObject(3, "near", "lpoint", { { "origin", "0 0 10" }, { "radius", 5 } }) },
                                    { { "point", 1 } }));
    ASSERT_NE(scene, nullptr);
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    const Recorded seen = Probe(*scene, *model, { "g_LPoint_Origin" });
    EXPECT_TRUE(SlotIs(seen, "g_LPoint_Origin", 0, { 0, 0, 10, 2 }));
}

// A kind's array holds its subsets ahead of its plain lights (0x140190C80): a spot
// that uses its cookie takes the cookie slot at the front even when a plain spot is
// nearer the camera and first in the file.
TEST(SceneLights, ASpotUsingItsCookieTakesTheCookieSlotAheadOfThePlainSpots)
{
    ParseRig rig(LeafAssets());
    auto scene = rig.Parse(LitScene({ LightObject(2, "plain", "lspot", { { "origin", "0 0 10" }, { "radius", 5 } }),
                                      LightObject(3, "cookie", "lspot",
                                                  { { "origin", "0 0 -100" }, { "radius", 5 }, { "usecookie", true } }) },
                                    { { "spot", 2 }, { "spotcookie", 1 } }));
    ASSERT_NE(scene, nullptr);
    EXPECT_EQ(scene->light_config.spot_cookie, 1u);
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    const Recorded seen = Probe(*scene, *model, { "g_LSpot_Origin" });
    const auto&    origins = seen.at("g_LSpot_Origin");
    ASSERT_EQ(origins.size(), 8u);
    EXPECT_FLOAT_EQ(origins[2], -100.0f) << "the cookie spot takes slot 0";
    EXPECT_FLOAT_EQ(origins[6], 10.0f) << "the plain spot follows it";
}

// 0x140186C90 keeps each subset count as `& 3`; with shadows off it drops the shadow
// subsets and ORs spotshadowcookie into spotcookie. 0x1401A5C40 then switches on the
// shadow-map and cookie declarations of the stock shaders.
TEST(SceneLights, LightSubsetsFollowTheShadowsSetting)
{
    const Json config = { { "point", 2 }, { "spot", 4 }, { "directional", 1 }, { "pointshadow", 5 },
                          { "spotshadow", 1 }, { "spotcookie", 1 }, { "spotshadowcookie", 2 },
                          { "directionalshadow", 1 } };
    {
        ParseRig rig(LeafAssets());
        ParseOptions options;
        options.quality.shadows = static_cast<int>(QualityLevel::High);
        auto scene = rig.Parse(LitScene({}, config), options);
        ASSERT_NE(scene, nullptr);
        const auto& lights = scene->light_config;
        EXPECT_EQ(lights.point_shadow, 1u);
        EXPECT_EQ(lights.spot_shadow, 1u);
        EXPECT_EQ(lights.spot_cookie, 1u);
        EXPECT_EQ(lights.spot_shadow_cookie, 2u);
        EXPECT_EQ(lights.directional_shadow, 1u);
        const auto defines = PlanetDefines(*scene);
        for (const char* combo : { "LIGHTS_COOKIE", "LIGHTS_POINT_SHADOW", "LIGHTS_SPOT_SHADOW_COOKIE" })
            EXPECT_TRUE(defines.count(combo)) << combo;
        // No light casts, so no shadow is drawn and nothing samples an atlas.
        EXPECT_FALSE(defines.count("LIGHTS_SHADOW_MAPPING"));
        EXPECT_FALSE(scene->HasRenderTarget("_rt_shadowAtlas"));
    }
    {
        ParseRig rig(LeafAssets());
        ParseOptions options;
        options.quality.shadows = static_cast<int>(QualityLevel::Off);
        auto scene = rig.Parse(LitScene({}, config), options);
        ASSERT_NE(scene, nullptr);
        const auto& lights = scene->light_config;
        EXPECT_EQ(lights.point_shadow, 0u);
        EXPECT_EQ(lights.spot_shadow, 0u);
        EXPECT_EQ(lights.spot_cookie, 3u) << "1 | 2";
        EXPECT_EQ(lights.spot_shadow_cookie, 0u);
        EXPECT_EQ(lights.directional_shadow, 0u);
        const auto defines = PlanetDefines(*scene);
        EXPECT_FALSE(defines.count("LIGHTS_SHADOW_MAPPING"));
        EXPECT_TRUE(defines.count("LIGHTS_COOKIE"));
    }
}

// A point light that casts shadows takes the shadow slot at the front of the point
// array while shadows are on, though a plain light is nearer and first in the file.
TEST(SceneLights, AShadowCastingLightTakesTheShadowSlotAtTheFront)
{
    ParseRig rig(LeafAssets());
    auto scene = rig.Parse(LitScene({ LightObject(2, "plain", "lpoint", { { "origin", "0 0 10" }, { "radius", 5 } }),
                                      LightObject(3, "caster", "lpoint",
                                                  { { "origin", "0 0 -100" }, { "radius", 5 }, { "castshadow", true } }) },
                                    { { "point", 2 }, { "pointshadow", 1 } }));
    ASSERT_NE(scene, nullptr);
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    const Recorded seen = Probe(*scene, *model, { "g_LPoint_Origin" });
    EXPECT_TRUE(SlotIs(seen, "g_LPoint_Origin", 0, { 0, 0, -100, 2 }));
    EXPECT_TRUE(SlotIs(seen, "g_LPoint_Origin", 1, { 0, 0, 10, 2 }));
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
    // The moved light is nearer the camera along its forward axis, so it is packed first.
    EXPECT_TRUE(SlotIs(morning, "g_LPoint_Color", 1, { 2, 2, 2, 10 }));
    EXPECT_TRUE(SlotIs(morning, "g_LPoint_Origin", 0, { 4, 5, 6, 2 }));
    const std::uint64_t before = scene->shaderValueUpdater->LightStateHash(model, 0);
    EXPECT_NE(before, 0u);

    scene->runtime->ApplyProjectPropertyOverride({ { "daynight", RuntimeScalarValue::Bool(false) } });
    scene->runtime->Tick(0.01);
    const Recorded night = Probe(*scene, *model, { "g_LPoint_Color", "g_LPoint_Origin" });
    EXPECT_TRUE(SlotIs(night, "g_LPoint_Origin", 0, { 4, 5, 6, 2 }));
    EXPECT_TRUE(SlotIs(night, "g_LPoint_Color", 1, { 0, 0, 0, 0 }));
    EXPECT_NE(scene->shaderValueUpdater->LightStateHash(model, 0), before);
}

TEST(SceneLights, ALightThatLeavesOutItsKeysTakesWallpaperEngineDefaults)
{
    // wallpaper64.exe sub_14018FF60 constructs a light with colour 0, intensity 0,
    // radius 1, density 2, volumetricsexponent 1, cascades 3/10/100, source size 0;
    // its loader (sub_1401730D0) sets only the keys the file writes.
    ParseRig rig(VolumetricLeafAssets());
    auto     scene = rig.Parse(LitScene({ LightObject(2, "bare", "lpoint", { { "origin", "1 2 3" } }),
                                          LightObject(3, "full", "lspot",
                                                      { { "origin", "0 0 0" },
                                                        { "density", 4 },
                                                        { "volumetricsexponent", 3 },
                                                        { "cascadedistance0", 1 },
                                                        { "cascadedistance1", 2 },
                                                        { "cascadedistance2", 5 },
                                                        { "lightsourcesize", 0.5 },
                                                        { "castshadow", true },
                                                        { "usecookie", true },
                                                        { "castvolumetrics", true } }) },
                                        { { "point", 1 }, { "spot", 1 } }));
    ASSERT_NE(scene, nullptr);
    ASSERT_EQ(scene->lights.size(), 2u);
    const SceneLight& bare = *scene->lights[0];
    EXPECT_FLOAT_EQ(bare.radius(), 1.0f);
    EXPECT_FLOAT_EQ(bare.intensity(), 0.0f);
    EXPECT_FLOAT_EQ(bare.color().x(), 0.0f);
    EXPECT_FLOAT_EQ(bare.density(), 2.0f);
    EXPECT_FLOAT_EQ(bare.volumetricsExponent(), 1.0f);
    EXPECT_EQ(bare.cascadeDistances(), (std::array<float, 3> { 3.0f, 10.0f, 100.0f }));
    EXPECT_FLOAT_EQ(bare.sourceSize(), 0.0f);
    EXPECT_EQ(bare.flags(), 0u);
    EXPECT_FALSE(bare.castsVolumetrics());
    const SceneLight& full = *scene->lights[1];
    EXPECT_FLOAT_EQ(full.density(), 4.0f);
    EXPECT_FLOAT_EQ(full.volumetricsExponent(), 3.0f);
    EXPECT_EQ(full.cascadeDistances(), (std::array<float, 3> { 1.0f, 2.0f, 5.0f }));
    EXPECT_FLOAT_EQ(full.sourceSize(), 0.5f);
    // castshadow, usecookie and castvolumetrics share the flag word (+708; light
    // registry sub_14025DA80).
    EXPECT_EQ(full.flags(), SceneLight::kCastShadow | SceneLight::kUseCookie | SceneLight::kCastVolumetrics);
    EXPECT_TRUE(full.castsVolumetrics());

    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    const Recorded seen = Probe(*scene, *model, { "g_LPoint_Color", "g_LPoint_Origin" });
    EXPECT_TRUE(SlotIs(seen, "g_LPoint_Color", 0, { 0, 0, 0, 1 }));
    EXPECT_TRUE(SlotIs(seen, "g_LPoint_Origin", 0, { 1, 2, 3, 2 }));
}

} // namespace

namespace
{
constexpr const char* kCasterVertex = R"(uniform mat4 g_ModelMatrix;
uniform mat4 g_ViewportViewProjectionMatrices[6];
attribute vec3 a_Position;
void main() {
    gl_Position = mul(mul(vec4(a_Position, 1.0), g_ModelMatrix), g_ViewportViewProjectionMatrices[0]);
}
)";

// The leaf model with Wallpaper Engine's shadow caster material and a stand-in caster shader.
FileMap ShadowAssets()
{
    FileMap files = LeafAssets();
    files["/materials/util/shadowcaster.json"] = R"({"passes":[{"shader":"shadowcaster"}]})";
    files["/shaders/shadowcaster.vert"] = kCasterVertex;
    files["/shaders/shadowcaster.frag"] = "void main() {}\n";
    return files;
}

const Json kShadowConfig = { { "point", 1 }, { "pointshadow", 1 }, { "spot", 1 }, { "spotshadow", 1 },
                             { "directional", 1 }, { "directionalshadow", 1 } };

std::vector<Json> ShadowLights()
{
    return { LightObject(2, "sun", "ldirectional", { { "origin", "0 50 0" }, { "castshadow", true } }),
             LightObject(3, "lamp", "lspot", { { "origin", "0 20 0" }, { "radius", 100 }, { "castshadow", true } }),
             LightObject(4, "bulb", "lpoint", { { "origin", "5 5 5" }, { "radius", 50 }, { "castshadow", true } }) };
}
} // namespace

// C-6.md (sub_25D3E0 / sub_140190C80): the tile of a view is 256 texels at low and medium, 512 at
// high, 1024 at ultra; the shelf packer lays equal tiles out in one row (its first segment is
// 0x2000 wide) and the next row starts below the tallest tile of the row before.
TEST(SceneShadows, TheShelfPackerLaysViewsOutAsWallpaperEngineDoes)
{
    EXPECT_EQ(ShadowTileSize(0), 0u);
    EXPECT_EQ(ShadowTileSize(1), 256u);
    EXPECT_EQ(ShadowTileSize(2), 256u);
    EXPECT_EQ(ShadowTileSize(3), 512u);
    EXPECT_EQ(ShadowTileSize(4), 1024u);

    const std::vector<uint32_t> sizes { 512, 256, 256 };
    const auto packed = PackShadowAtlas(sizes);
    ASSERT_EQ(packed.tiles.size(), 3u);
    EXPECT_EQ(packed.tiles[0].x, 0u);
    EXPECT_EQ(packed.tiles[1].x, 512u);
    EXPECT_EQ(packed.tiles[1].y, 0u);
    EXPECT_EQ(packed.tiles[2].x, 768u);
    EXPECT_EQ(packed.width, 1024u);
    EXPECT_EQ(packed.height, 512u);

    // Thirty-three 256 tiles: thirty-two fill the 0x2000-wide row, the last opens a row below.
    const std::vector<uint32_t> many(33, 256);
    const auto row = PackShadowAtlas(many);
    EXPECT_EQ(row.tiles[31].x, 31u * 256u);
    EXPECT_EQ(row.tiles[32].x, 0u);
    EXPECT_EQ(row.tiles[32].y, 256u);
    EXPECT_EQ(row.width, 8192u);
    EXPECT_EQ(row.height, 512u);

    const auto none = PackShadowAtlas({});
    EXPECT_EQ(none.width, 2u);
    EXPECT_EQ(none.height, 2u);
}

// The views are pushed in the packer's light order (points, spots, directionals, the last with
// a view per cascade), each takes a tile, and `_rt_shadowAtlas` is a Depth32F target of the
// packed extent, kept at that size; lit materials sample it with shadow mapping on.
TEST(SceneShadows, ShadowCastingLightsTakeTilesOfADepthAtlasInPackingOrder)
{
    ParseRig     rig(ShadowAssets());
    ParseOptions options;
    options.quality.shadows = static_cast<int>(QualityLevel::Medium);
    auto scene = rig.Parse(LitScene(ShadowLights(), kShadowConfig), options);
    ASSERT_NE(scene, nullptr);
    const auto& shadows = scene->shadows;
    ASSERT_EQ(shadows.views.size(), 5u);
    EXPECT_EQ(shadows.views[0].kind, ShadowViewKind::Point);
    EXPECT_EQ(shadows.views[1].kind, ShadowViewKind::Spot);
    for (std::size_t c = 0; c < 3; ++c) {
        EXPECT_EQ(shadows.views[2 + c].kind, ShadowViewKind::Directional);
        EXPECT_EQ(shadows.views[2 + c].cascade, c);
    }
    for (std::size_t v = 0; v < 5; ++v) {
        EXPECT_EQ(shadows.views[v].tile.x, 256u * v) << v;
        EXPECT_EQ(shadows.views[v].tile.size, 256u);
    }
    EXPECT_EQ(shadows.atlas_width, 1280u);
    EXPECT_EQ(shadows.atlas_height, 256u);
    // The point light's six faces: (x + c * size/2, y + r * size/3, size/2, size/3).
    ASSERT_EQ(shadows.views[0].viewports.size(), 6u);
    const auto& face5 = shadows.views[0].viewports[5];
    EXPECT_FLOAT_EQ(face5[0], 128.0f / 1280.0f);
    EXPECT_FLOAT_EQ(face5[1], 170.0f / 256.0f);
    EXPECT_FLOAT_EQ(face5[2], 128.0f / 1280.0f);
    EXPECT_FLOAT_EQ(face5[3], 85.0f / 256.0f);
    const auto* atlas = scene->FindRenderTarget("_rt_shadowAtlas");
    ASSERT_NE(atlas, nullptr);
    EXPECT_EQ(atlas->format, TextureFormat::Depth32F);
    EXPECT_TRUE(atlas->unscaled);
    EXPECT_EQ(atlas->width, 1280);
    EXPECT_EQ(atlas->height, 256);
    const auto defines = PlanetDefines(*scene);
    for (const char* combo : { "LIGHTS_SHADOW_MAPPING", "LIGHTS_SHADOW_MAPPING_QUALITY", "REVERSEDEPTH" })
        EXPECT_TRUE(defines.count(combo)) << combo;
    // The model casts (castshadow absent): a caster slot per submesh, past its own materials.
    SceneNode* model = FindRootChild(*scene, "planet");
    ASSERT_NE(model, nullptr);
    const auto&       casters   = model->ShadowCasterSlots();
    const std::size_t submeshes = model->Mesh()->Submeshes().size();
    ASSERT_EQ(casters.size(), submeshes);
    for (std::size_t i = 0; i < submeshes; ++i) {
        EXPECT_EQ(casters[i], submeshes + i);
        ASSERT_NE(model->Mesh()->MaterialForSlot(casters[i]), nullptr);
        EXPECT_EQ(model->Mesh()->MaterialForSlot(casters[i])->name, "shadowcaster");
    }
}

// The receivers' feature arrays in Wallpaper Engine's indexing (sub_140169140): spot features
// first, then three cascades per shadowed directional light; point light projection info is
// the reversed projection's (m22, m32, m23, m33) at the quality's fov.
TEST(SceneShadows, FeatureArraysFollowWallpaperEnginesIndexing)
{
    ParseRig     rig(ShadowAssets());
    ParseOptions options;
    options.quality.shadows = static_cast<int>(QualityLevel::Medium);
    auto scene = rig.Parse(LitScene(ShadowLights(), kShadowConfig), options);
    ASSERT_NE(scene, nullptr);
    const auto& shadows = scene->shadows;
    ASSERT_EQ(shadows.projection.size(), 4u * 16u);
    ASSERT_EQ(shadows.projection_transform.size(), 4u * 4u);
    // Spot feature 0: tile 1; cascades 1..3: tiles 2..4.
    for (std::size_t f = 0; f < 4; ++f) {
        EXPECT_FLOAT_EQ(shadows.projection_transform[f * 4 + 0], (256.0f * (f + 1)) / 1280.0f) << f;
        EXPECT_FLOAT_EQ(shadows.projection_transform[f * 4 + 2], 256.0f / 1280.0f) << f;
        EXPECT_FLOAT_EQ(shadows.projection_transform[f * 4 + 3], 1.0f) << f;
    }
    ASSERT_EQ(shadows.point_transform.size(), 4u);
    EXPECT_FLOAT_EQ(shadows.point_transform[0], 0.0f);
    EXPECT_FLOAT_EQ(shadows.point_transform[2], 256.0f / 1280.0f);
    // Near max(0.05, lightsourcesize 0) and far = radius 50: range = near / (far - near).
    const float near = 0.05f, far = 50.0f;
    EXPECT_NEAR(shadows.point_projection[0], near / (far - near), 1e-6f);
    EXPECT_NEAR(shadows.point_projection[1], near * far / (far - near), 1e-5f);
    EXPECT_FLOAT_EQ(shadows.point_projection[2], -1.0f);
    EXPECT_FLOAT_EQ(shadows.point_projection[3], 0.0f);
    // A spot light's own origin projects to depth 1 at its near plane: the reversed projection.
    const auto& p = shadows.projection;
    linalg::Matrix4d vp;
    for (int c = 0; c < 4; ++c)
        for (int r = 0; r < 4; ++r) vp(r, c) = p[c * 4 + r];
    const linalg::Vector4d ahead = vp * linalg::Vector4d(0.05 + 0.0, 20.0, 0.0, 1.0);
    // The spot shines along +x: a point near its plane in front lies near depth 1, far at 0.
    const linalg::Vector4d at_far = vp * linalg::Vector4d(100.0, 20.0, 0.0, 1.0);
    EXPECT_NEAR(ahead.z() / ahead.w(), 1.0, 1e-3);
    EXPECT_NEAR(at_far.z() / at_far.w(), 0.0, 1e-3);
}

// Shadows quality off, or no light that casts, or no caster: no atlas, no view and no
// shadow-mapping combo, so nothing is drawn or allocated for shadows.
TEST(SceneShadows, NothingIsBuiltWithoutAQualityACastingLightAndACaster)
{
    const auto parse = [](int quality, std::vector<Json> lights, bool model_casts) {
        ParseRig     rig(ShadowAssets());
        ParseOptions options;
        options.quality.shadows = quality;
        Json scene_json = LitScene(std::move(lights), kShadowConfig);
        if (! model_casts) scene_json["objects"][0]["castshadow"] = false;
        return rig.Parse(scene_json, options);
    };
    std::vector<Json> plain { LightObject(4, "bulb", "lpoint", { { "origin", "5 5 5" }, { "radius", 50 } }) };
    for (const auto& scene : { parse(static_cast<int>(QualityLevel::Off), ShadowLights(), true),
                               parse(static_cast<int>(QualityLevel::Medium), plain, true),
                               parse(static_cast<int>(QualityLevel::Medium), ShadowLights(), false) }) {
        ASSERT_NE(scene, nullptr);
        EXPECT_FALSE(scene->shadows.active());
        EXPECT_FALSE(scene->HasRenderTarget("_rt_shadowAtlas"));
        EXPECT_FALSE(PlanetDefines(*scene).count("LIGHTS_SHADOW_MAPPING"));
        SceneNode* model = FindRootChild(*scene, "planet");
        ASSERT_NE(model, nullptr);
        EXPECT_TRUE(model->ShadowCasterSlots().empty());
    }
}


TEST(SceneShadows, TopologyFollowsChangedCasterVisibilityAndLightPartitions)
{
    ParseRig rig(ShadowAssets());
    auto document = LitScene(ShadowLights(), kShadowConfig);
    document["objects"][0]["castshadow"] = false;
    auto scene = rig.Parse(document, ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    auto& runtime = *scene->runtime;
    (void)runtime.ConsumeSceneGraphMutationFlag();
    const auto check = [&](std::size_t expected_views, std::size_t expected_faces) {
        auto graph = sceneToRenderGraph(*scene);
        ASSERT_NE(graph, nullptr);
        EXPECT_EQ(scene->shadows.views.size(), expected_views);
        EXPECT_EQ(scene->HasRenderTarget("_rt_shadowAtlas"), expected_views != 0);
        std::size_t faces = 0;
        for (const auto id : graph->topologicalOrder()) {
            const auto* draw = dynamic_cast<const rg::DrawPass*>(graph->getPass(id));
            if (!draw || !draw->desc().depth_only) continue;
            ++faces;
            ASSERT_TRUE(draw->desc().depth_override.has_value());
            EXPECT_EQ(draw->desc().depth_override->compare, DepthCompare::Greater);
            // Biased by slope away from the light: toward 0, the reversed far plane.
            EXPECT_LT(draw->desc().depth_bias_slope, 0.0f);
            EXPECT_LT(draw->desc().depth_bias_clamp, 0.0f);
        }
        const auto submeshes = FindRootChild(*scene, "planet")->Mesh()->Submeshes().size();
        EXPECT_EQ(faces, expected_faces * submeshes);
        EXPECT_FALSE(scene->shadows.dirty);
        (void)runtime.ConsumeSceneGraphMutationFlag();
    };
    check(0, 0);
    ASSERT_TRUE(runtime.SetModelFlag("planet", "castshadow", true));
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());
    check(5, 10);
    const auto camera = scene->cameras.at(ShadowCameraKey(0, 0));
    ASSERT_TRUE(runtime.SetModelFlag("planet", "castshadow", true));
    ASSERT_TRUE(runtime.SetNodeVisible("planet", true));
    for (int tick = 0; tick < 8; ++tick) {
        runtime.Tick(1.0 / 60.0);
        scene->shaderValueUpdater->FrameBegin();
    }
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag());
    EXPECT_FALSE(scene->shadows.dirty);
    EXPECT_EQ(scene->cameras.at(ShadowCameraKey(0, 0)), camera);
    ASSERT_TRUE(runtime.SetNodeVisible("planet", false));
    check(0, 0);
    ASSERT_TRUE(runtime.SetNodeVisible("planet", true));
    check(5, 10);
    ASSERT_TRUE(runtime.SetNodeVisible("lamp", false));
    check(4, 9);
    ASSERT_TRUE(runtime.SetNodeVisible("lamp", true));
    check(5, 10);
    SceneLight* lamp = nullptr;
    for (const auto& light : scene->lights)
        if (light->type() == SceneLightType::Spot) lamp = light.get();
    ASSERT_NE(lamp, nullptr);
    lamp->setFlags(0);
    check(4, 9);
    lamp->setFlags(SceneLight::kCastShadow);
    check(5, 10);
    lamp->setType(SceneLightType::Tube);
    check(4, 9);
    lamp->setType(SceneLightType::Spot);
    check(5, 10);
    ASSERT_TRUE(runtime.SetModelFlag("planet", "castshadow", false));
    check(0, 0);
}

TEST(SceneShadows, OffHasNoCasterPreparationOrShadowInvalidation)
{
    ParseRig rig(ShadowAssets());
    ParseOptions options;
    options.live = true;
    options.quality.shadows = static_cast<int>(QualityLevel::Off);
    auto scene = rig.Parse(LitScene(ShadowLights(), kShadowConfig), options);
    ASSERT_NE(scene, nullptr);
    EXPECT_FALSE(scene->shadows.enabled);
    EXPECT_TRUE(scene->shadows.casters.empty());
    auto& runtime = *scene->runtime;
    (void)runtime.ConsumeSceneGraphMutationFlag();
    ASSERT_TRUE(runtime.SetModelFlag("planet", "castshadow", false));
    ASSERT_TRUE(runtime.SetNodeVisible("planet", false));
    scene->lights.front()->setFlags(0);
    scene->lights.front()->setType(SceneLightType::Spot);
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag());
    EXPECT_FALSE(scene->shadows.dirty);
    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    EXPECT_FALSE(scene->HasRenderTarget("_rt_shadowAtlas"));
    for (const auto id : graph->topologicalOrder()) {
        const auto* draw = dynamic_cast<const rg::DrawPass*>(graph->getPass(id));
        EXPECT_FALSE(draw && draw->desc().depth_only);
    }
}


TEST(SceneShadows, NonCastingLightEditsLeaveBothDisabledPlansUnchangedWithoutARuntime)
{
    ParseRig rig(LeafAssets());
    ParseOptions options;
    options.quality.shadows = static_cast<int>(QualityLevel::Off);
    auto scene = rig.Parse(LitScene({LightObject(2, "plain", "lpoint")}, {{"point", 1}}), options);
    ASSERT_NE(scene, nullptr);
    ASSERT_EQ(scene->lights.size(), 1u);
    ASSERT_EQ(scene->runtime, nullptr);
    scene->lights.front()->setFlags(SceneLight::kUseCookie);
    scene->lights.front()->setType(SceneLightType::Spot);
    EXPECT_FALSE(scene->shadows.dirty);
    EXPECT_FALSE(scene->volumetric_dirty);
    EXPECT_TRUE(scene->volumetric_lights.empty());
    EXPECT_FALSE(scene->HasRenderTarget("_rt_volumetricsLightBuffer"));
}

TEST(SceneShadows, MovingLightsKeepShadowViewsWithThePackedSlots)
{
    ParseRig rig(ShadowAssets());
    auto scene = rig.Parse(LitScene({
        LightObject(2, "first", "lspot", { { "origin", "0 0 10" }, { "castshadow", true } }),
        LightObject(3, "second", "lspot", { { "origin", "0 0 -10" }, { "castshadow", true } })
    }, { { "spot", 1 }, { "spotshadow", 1 } }), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_EQ(scene->shadows.views.size(), 1u);
    const auto before = scene->shadows.views[0].light;
    const auto camera = scene->cameras.at(ShadowCameraKey(0, 0));
    const auto first = FindRootChild(*scene, "first")->Translate();
    const auto second = FindRootChild(*scene, "second")->Translate();
    ASSERT_TRUE(scene->runtime->SetNodeTranslate("first", second));
    ASSERT_TRUE(scene->runtime->SetNodeTranslate("second", first));
    scene->runtime->Tick(1.0 / 60.0);
    UpdateSceneShadows(*scene);
    std::vector<PackedSceneLight> packed;
    PackSceneLights(*scene, packed);
    ASSERT_EQ(packed.size(), 2u);
    ASSERT_NE(packed[0].light, before);
    EXPECT_EQ(scene->shadows.views[0].light, packed[0].light);
    EXPECT_EQ(scene->cameras.at(ShadowCameraKey(0, 0)), camera);
    EXPECT_FALSE(scene->shadows.dirty);
}


TEST(SceneLights, CookieProjectionExistsWithoutAShadowCasterOrAtlas)
{
    for (const auto quality : { QualityLevel::Off, QualityLevel::Medium }) {
        ParseRig rig(LeafAssets());
        ParseOptions options;
        options.quality.shadows = static_cast<int>(quality);
        auto scene = rig.Parse(LitScene({ LightObject(2, "cookie", "lspot",
            { { "origin", "0 20 0" }, { "radius", 100 }, { "usecookie", true },
              { "castshadow", false }, { "outercone", 45 } }) },
            { { "spot", 1 }, { "spotcookie", 1 } }), options);
        ASSERT_NE(scene, nullptr);
        EXPECT_FALSE(scene->shadows.active());
        EXPECT_FALSE(scene->HasRenderTarget(kShadowAtlas));
        ASSERT_EQ(scene->shadows.projection.size(), 16u);
        linalg::Matrix4d vp;
        for (int c = 0; c < 4; ++c)
            for (int r = 0; r < 4; ++r) vp(r, c) = scene->shadows.projection[c * 4 + r];
        const linalg::Vector4d centre = vp * linalg::Vector4d(10.0, 20.0, 0.0, 1.0);
        EXPECT_NEAR(centre.x() / centre.w(), 0.0, 1e-5);
        EXPECT_NEAR(centre.y() / centre.w(), 0.0, 1e-5);
        const auto before = scene->shadows.projection;
        scene->lights[0]->node()->SetTranslate({ 0.0f, 30.0f, 0.0f });
        UpdateSceneShadows(*scene);
        EXPECT_NE(scene->shadows.projection, before);
    }
}
