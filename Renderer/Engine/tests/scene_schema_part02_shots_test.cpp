// Scene file schema, part 2: camera objects ("shots") in a flat canvas scene. A shot never swaps
// the projection of a canvas scene; it only frames the canvas: the view is centred on the canvas
// centre moved by the shot's origin and is `zoom` times closer. Which shot frames the view, and
// when that is decided, depends on whether the scene has a runtime.
#include "support/schema_fixtures_part02.hpp"

#include <gtest/gtest.h>

#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace we_schema::p2;
using namespace wallpaper;

// A canvas scene whose camera objects are `shots`, followed by the canvas image layer.
Json ShotScene(std::vector<Json> shots)
{
    Json base   = CanvasWithCameraObject();
    Json image  = base["objects"][1];
    base["objects"] = Json::array();
    for (auto& shot : shots) base["objects"].push_back(std::move(shot));
    base["objects"].push_back(std::move(image));
    return base;
}

Json Shot(int id, const Json& origin, const Json& zoom, const Json& extra = Json::object())
{
    Json shot = { { "id", id },
                  { "name", "shot " + std::to_string(id) },
                  { "camera", "default" },
                  { "origin", origin },
                  { "angles", Json::array({ 0, 0, 0 }) },
                  { "fov", 50 },
                  { "zoom", zoom } };
    for (const auto& [key, value] : extra.items()) shot[key] = value;
    return shot;
}

Json Origin(double x, double y) { return Json::array({ x, y, 500 }); }

// ---- the frame is decided once, at parse, when there is no runtime -----------------------

// R-2.01 / B-2.01
TEST(CanvasShots, ZoomTightensTheOrthographicFrustumWithoutChangingTheAuthoredExtent)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(ShotScene({ Shot(9, Origin(0, 0), 2.0) }));
    ASSERT_NE(scene, nullptr);
    EXPECT_EQ(scene->runtime, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    EXPECT_FALSE(scene->activeCamera->IsPerspective());

    const auto centre = Ndc(*scene->activeCamera, 320, 180);
    EXPECT_NEAR(centre[0], 0.0, 1e-6);
    EXPECT_NEAR(centre[1], 0.0, 1e-6);
    const auto corner = Ndc(*scene->activeCamera, 640, 360);
    EXPECT_NEAR(corner[0], 2.0, 1e-6);
    EXPECT_NEAR(corner[1], 2.0, 1e-6);
    EXPECT_NEAR(scene->activeCamera->Width(), 640.0, 1e-6);
    EXPECT_NEAR(scene->activeCamera->Height(), 360.0, 1e-6);
}

TEST(CanvasShots, ZoomOutShowsMoreThanTheCanvas)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(ShotScene({ Shot(9, Origin(0, 0), 0.5) }));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    const auto corner = Ndc(*scene->activeCamera, 640, 360);
    EXPECT_NEAR(corner[0], 0.5, 1e-6);
    EXPECT_NEAR(corner[1], 0.5, 1e-6);
}

TEST(CanvasShots, ShotOriginMovesTheViewCentre)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(ShotScene({ Shot(9, Origin(100, -40), 2.0) }));
    ASSERT_NE(scene, nullptr);
    ExpectViewFrame(*scene, 420, 140, 2.0, 1e-5);
}

TEST(CanvasShots, AHiddenShotFramesTheWholeCanvas)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(ShotScene({ Shot(9, Origin(0, 0), 2.0, { { "visible", false } }) }));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    const auto corner = Ndc(*scene->activeCamera, 640, 360);
    EXPECT_NEAR(corner[0], 1.0, 1e-6);
    EXPECT_NEAR(corner[1], 1.0, 1e-6);
}

// A shot whose visibility is bound to a property is still built without a runtime, and with no
// property to follow it is hidden by its default: it frames nothing.
TEST(CanvasShots, ABoundShotHiddenByItsDefaultFramesTheWholeCanvasWithoutARuntime)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(ShotScene({ Shot(9, Origin(0, 0), 2.0, { { "visible", { { "user", "A" }, { "value", false } } } }) }));
    ASSERT_NE(scene, nullptr);
    EXPECT_EQ(scene->runtime, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    const auto corner = Ndc(*scene->activeCamera, 640, 360);
    EXPECT_NEAR(corner[0], 1.0, 1e-6);
    EXPECT_NEAR(corner[1], 1.0, 1e-6);
}

// R-2.02 / B-2.02
class ZoomOutsideTheUsableRange : public ::testing::TestWithParam<double> {};

TEST_P(ZoomOutsideTheUsableRange, FramesTheWholeCanvas)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(ShotScene({ Shot(9, Origin(0, 0), GetParam()) }));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    const auto corner = Ndc(*scene->activeCamera, 640, 360);
    EXPECT_NEAR(corner[0], 1.0, 1e-6);
    EXPECT_NEAR(corner[1], 1.0, 1e-6);
    // The perspective lens of the scene is framed the same way as the flat one.
    ExpectViewFrame(*scene, 320, 180, 1.0, 1e-5);
}

INSTANTIATE_TEST_SUITE_P(Zooms, ZoomOutsideTheUsableRange, ::testing::Values(0.0, -1.5, 1.0),
                         [](const ::testing::TestParamInfo<double>& info) {
                             return std::string(info.param == 0.0 ? "Zero" : info.param < 0 ? "Negative" : "One");
                         });

// ---- with a runtime the frame follows the timelines, scripts and properties --------------

// R-2.03 / B-2.03
TEST(CanvasShots, ACameraTimelineGlidesFromItsFirstShotToWhereItRests)
{
    const Json origin = { { "value", "-40 20 500" },
                          { "animation",
                            { { "relative", true },
                              { "options", { { "fps", 12 }, { "length", 24 }, { "mode", "single" }, { "parent", { { "key", "zoom" } } } } },
                              { "c0", Json::array({ { { "frame", 0 }, { "value", 100 } }, { { "frame", 12 }, { "value", 40 } } }) },
                              { "c1", Json::array({ { { "frame", 0 }, { "value", 50 } }, { { "frame", 12 }, { "value", -20 } } }) },
                              { "c2", Json::array({ { { "frame", 0 }, { "value", 0 } }, { { "frame", 12 }, { "value", 0 } } }) } } } };
    const Json zoom   = { { "value", 1 },
                          { "animation",
                            { { "options",
                                { { "fps", 12 }, { "length", 24 }, { "mode", "single" }, { "children", Json::array({ { { "key", "origin" } } }) } } },
                              { "c0", Json::array({ { { "frame", 0 }, { "value", 2 } }, { { "frame", 12 }, { "value", 1 } } }) } } } };

    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(ShotScene({ Shot(9, origin, zoom) }), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    {
        SCOPED_TRACE("frame 0");
        ExpectViewFrame(*scene, 380, 250, 2.0);
    }

    scene->runtime->Tick(0.5);
    {
        SCOPED_TRACE("half way to the first key");
        ASSERT_NE(scene->activeCamera, nullptr);
        const double x = Ndc(*scene->activeCamera, 320, 180)[0];
        EXPECT_GT(x, -0.375 + 1e-3);
        EXPECT_LT(x, -1e-3);
        EXPECT_NEAR(x, -0.140625, 1e-3);
        ExpectViewFrame(*scene, 350, 215, 1.5, 1e-3);
        EXPECT_TRUE(scene->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation);
    }

    // The clock stops when the declared length (2 s) has elapsed, not at the last key (1 s).
    scene->runtime->Tick(2.0);
    {
        SCOPED_TRACE("at rest");
        ExpectViewFrame(*scene, 320, 180, 1.0);
        EXPECT_FALSE(scene->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation);
    }
}

TEST(CanvasShots, ALoopingCameraTimelineNeverStopsAskingForFrames)
{
    const Json origin = { { "value", "0 0 500" },
                          { "animation",
                            { { "relative", true },
                              { "options", { { "fps", 12 }, { "length", 24 }, { "mode", "loop" }, { "parent", { { "key", "zoom" } } } } },
                              { "c0", Json::array({ { { "frame", 0 }, { "value", 0 } }, { { "frame", 12 }, { "value", 40 } } }) } } } };
    const Json zoom   = { { "value", 1 },
                          { "animation",
                            { { "options",
                                { { "fps", 12 }, { "length", 24 }, { "mode", "loop" }, { "children", Json::array({ { { "key", "origin" } } }) } } },
                              { "c0", Json::array({ { { "frame", 0 }, { "value", 2 } }, { { "frame", 12 }, { "value", 1 } } }) } } } };
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(ShotScene({ Shot(9, origin, zoom) }), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    for (int step = 0; step < 20; ++step) scene->runtime->Tick(0.5);
    EXPECT_TRUE(scene->runtime->DescribeTimeAdvancingWork() & SceneDemandReason::Animation);
}

// R-2.04 / B-2.04
TEST(CanvasShots, AScriptedShotOriginCountsOnlyOnceATickHasAppliedIt)
{
    const Json origin = { { "value", "300 100 500" },
                          { "script", "export function update(value) { value.x = 20; value.y = -10; return value; }" } };
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(ShotScene({ Shot(9, origin, 2.0) }), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    {
        SCOPED_TRACE("before any tick the view is centred on the canvas, not on the saved origin");
        ExpectViewFrame(*scene, 320, 180, 2.0);
    }
    scene->runtime->Tick(1.0 / 60.0);
    {
        SCOPED_TRACE("after a tick");
        ExpectViewFrame(*scene, 340, 170, 2.0);
    }
}

// R-2.05 / B-2.05
TEST(CanvasShots, TheLastVisibleShotFramesTheViewAndIsDecidedAgainEveryTick)
{
    ParseRig rig(BasicAssets());
    rig.properties() = ProjectProperties { { "A", RuntimeScalarValue::Bool(true) }, { "B", RuntimeScalarValue::Bool(false) } };
    auto scene = rig.Parse(ShotScene({ Shot(1, Origin(0, 0), 2, { { "visible", { { "user", "A" }, { "value", true } } } }),
                                       Shot(2, Origin(100, -40), 4, { { "visible", { { "user", "B" }, { "value", false } } } }) }),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    {
        SCOPED_TRACE("after parse only the first shot is visible");
        ExpectViewFrame(*scene, 320, 180, 2.0);
    }
    scene->runtime->ApplyProjectPropertyOverride({ { "B", RuntimeScalarValue::Bool(true) } });
    scene->runtime->Tick(1.0 / 60.0);
    {
        SCOPED_TRACE("both visible: the later one wins");
        ExpectViewFrame(*scene, 420, 140, 4.0);
    }
    scene->runtime->ApplyProjectPropertyOverride({ { "A", RuntimeScalarValue::Bool(false) }, { "B", RuntimeScalarValue::Bool(false) } });
    scene->runtime->Tick(1.0 / 60.0);
    {
        SCOPED_TRACE("none visible: the whole canvas");
        ExpectViewFrame(*scene, 320, 180, 1.0);
    }
}

} // namespace
