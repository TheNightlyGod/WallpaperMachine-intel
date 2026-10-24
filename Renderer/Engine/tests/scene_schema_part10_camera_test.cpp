// Scene file schema, part 10 (cameras): where the perspective camera of a flat scene sits for its
// field of view, and how the scene's zoom (static, invalid or keyed on a timeline) sizes the
// view of the canvas.
#include "support/schema_fixtures.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/SceneCamera.h"

#include <gtest/gtest.h>

#include <cmath>
#include <string>
#include <tuple>
#include <vector>

namespace
{

using namespace we_schema;
using namespace wallpaper;

using Vec4d = linalg::Vector4d;

// A flat scene of the given canvas with no layers. `general.fov` is a decoy the flat camera
// must not read.
std::shared_ptr<Scene> ParseCanvas(ParseRig& rig, int width, int height, const Json& override_fov)
{
    Json general = { { "orthogonalprojection", { { "width", width }, { "height", height } } }, { "fov", 60 }, { "bloom", false } };
    if (!override_fov.is_null()) general["perspectiveoverridefov"] = override_fov;
    return rig.Parse(QuietScene(Json::array(), general), { .live = true });
}

Vec4d Clip(const SceneCamera& camera, double x, double y, double z)
{
    return camera.GetViewProjectionMatrix() * Vec4d(x, y, z, 1.0);
}

struct CanvasRow {
    int  width;
    int  height;
    Json override_fov; // null: absent
    double fov;
};

class FlatSceneEye : public ::testing::TestWithParam<CanvasRow> {};

// R-10.07 / B-10.07
TEST_P(FlatSceneEye, ThePerspectiveCameraSitsWhereTheFieldOfViewPutsIt)
{
    const auto row = GetParam();
    ParseRig   rig(FileMap {});
    auto       scene = ParseCanvas(rig, row.width, row.height, row.override_fov);
    ASSERT_NE(scene, nullptr);
    ASSERT_TRUE(scene->cameras.contains("global"));
    ASSERT_TRUE(scene->cameras.contains("global_perspective"));
    const SceneCamera& canvas = *scene->cameras.at("global");
    const SceneCamera& persp  = *scene->cameras.at("global_perspective");

    const double distance = (row.height / 2.0) / std::tan(row.fov * M_PI / 360.0);
    EXPECT_EQ(persp.Fov(), row.fov);
    const auto eye = persp.GetPosition();
    EXPECT_NEAR(eye.x(), row.width / 2.0, 1e-3);
    EXPECT_NEAR(eye.y(), row.height / 2.0, 1e-3);
    EXPECT_NEAR(eye.z(), distance, distance * 1e-6);
    EXPECT_EQ(persp.NearClip(), 5.0);
    EXPECT_NEAR(persp.FarClip(), std::max(distance + 1000.0, 15000.0), 1e-2);

    // On the canvas plane both cameras project a point to the same place.
    for (const auto& [x, y] : std::vector<std::pair<double, double>> { { 0, 0 }, { double(row.width), double(row.height) }, { 0.3 * row.width, 0.8 * row.height } }) {
        SCOPED_TRACE("canvas point " + std::to_string(x) + "," + std::to_string(y));
        const Vec4d flat = Clip(canvas, x, y, 0);
        const Vec4d deep = Clip(persp, x, y, 0);
        EXPECT_NEAR(deep.x() / deep.w(), flat.x() / flat.w(), 1e-5);
        EXPECT_NEAR(deep.y() / deep.w(), flat.y() / flat.w(), 1e-5);
    }

    // Toward the eye the same point grows by eye distance over remaining distance.
    const double lateral = row.width / 200.0;
    const double eye_z   = eye.z();
    const Vec4d  at_zero = Clip(persp, row.width / 2.0 + lateral, row.height / 2.0, 0);
    const double x_zero  = at_zero.x() / at_zero.w();
    for (const double z : { 0.1 * distance, 0.5 * distance, 0.9 * distance, distance - 6.0 }) {
        SCOPED_TRACE("depth " + std::to_string(z));
        const Vec4d lateral_point = Clip(persp, row.width / 2.0 + lateral, row.height / 2.0, z);
        ASSERT_GT(lateral_point.w(), 0.0);
        const double scale = (lateral_point.x() / lateral_point.w()) / x_zero;
        EXPECT_NEAR(scale, eye_z / (eye_z - z), (eye_z / (eye_z - z)) * 1e-5);

        const Vec4d centre = Clip(persp, row.width / 2.0, row.height / 2.0, z);
        ASSERT_GT(centre.w(), 0.0);
        EXPECT_GE(centre.z() / centre.w(), 0.0);
        EXPECT_LE(centre.z() / centre.w(), 1.0);
    }
}

INSTANTIATE_TEST_SUITE_P(Canvases, FlatSceneEye,
                         ::testing::Values(CanvasRow { 1920, 1080, Json(50), 50 }, CanvasRow { 3840, 2160, Json(25), 25 },
                                           CanvasRow { 1366, 768, Json(95), 95 }, CanvasRow { 1366, 768, Json(), 95 },
                                           CanvasRow { 7680, 2160, Json(170), 170 }));

TEST(FlatSceneEyeLimits, AFieldOfViewOutsideTheUsableRangeIsClamped)
{
    for (const auto& [authored, expected] : std::vector<std::pair<double, double>> { { 179.99, 179.9 }, { 0.01, 0.1 } }) {
        SCOPED_TRACE("authored " + std::to_string(authored));
        ParseRig rig(FileMap {});
        auto     scene = ParseCanvas(rig, 1920, 1080, Json(authored));
        ASSERT_NE(scene, nullptr);
        EXPECT_NEAR(scene->cameras.at("global_perspective")->Fov(), expected, 1e-5);
    }
}

// ---- zoom --------------------------------------------------------------------------------------------------

// The canvas camera of an empty 960x540 scene whose `zoom` is `zoom`.
std::shared_ptr<Scene> ParseZoomed(ParseRig& rig, const Json& zoom)
{
    return rig.Parse(QuietScene(Json::array(), { { "orthogonalprojection", { { "width", 960 }, { "height", 540 } } }, { "zoom", zoom }, { "bloom", false } }),
                     { .live = true });
}

// R-10.09 / B-10.09
TEST(SceneZoomTimeline, APausedTimelineShowsItsFirstKeyAndLoopsOnceStarted)
{
    ParseRig rig(FileMap {});
    const Json zoom = { { "value", 7 },
                        { "animation",
                          { { "options", { { "fps", 30 }, { "length", 60 }, { "mode", "loop" }, { "startpaused", true }, { "name", "zoom" } } },
                            { "c0", Json::array({ { { "frame", 0 }, { "value", 2 } }, { { "frame", 30 }, { "value", 1 } }, { { "frame", 60 }, { "value", 2 } } }) } } } };
    auto scene = ParseZoomed(rig, zoom);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    const SceneCamera& camera = *scene->cameras.at("global");

    EXPECT_EQ(camera.Width(), 480.0) << "the first key beats the static value";
    scene->runtime->Tick(5.0);
    EXPECT_EQ(camera.Width(), 480.0) << "paused";
    auto* clock = scene->runtime->FindScalarAnimation("", "zoom");
    ASSERT_NE(clock, nullptr);
    clock->Play();
    scene->runtime->Tick(1.0);
    EXPECT_EQ(camera.Width(), 960.0) << "frame 30: zoom 1";
    scene->runtime->Tick(1.0);
    EXPECT_EQ(camera.Width(), 480.0) << "frame 60 wraps to the first key";
    scene->runtime->Tick(0.5);
    EXPECT_EQ(camera.Width(), 640.0) << "and the loop goes on from frame 15, where the zoom is 1.5";
    scene->runtime->Tick(0.5);
    EXPECT_EQ(camera.Width(), 960.0) << "frame 30 of the second lap: zoom 1";
    clock->Stop();
    scene->runtime->Tick(1.0);
    EXPECT_EQ(camera.Width(), 480.0) << "stopped";
    EXPECT_EQ(camera.Height(), 270.0);
}

struct ZoomRow {
    Json   zoom;
    double width;
};

class SceneZoomValues : public ::testing::TestWithParam<ZoomRow> {};

// R-10.10 / B-10.10
TEST_P(SceneZoomValues, StaticAndInvalidZoomsStayStable)
{
    ParseRig rig(FileMap {});
    auto     scene = ParseZoomed(rig, GetParam().zoom);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    const SceneCamera& camera = *scene->cameras.at("global");
    EXPECT_EQ(camera.Width(), GetParam().width);
    scene->runtime->Tick(20.0);
    EXPECT_EQ(camera.Width(), GetParam().width) << "a tick changes nothing";
}

INSTANTIATE_TEST_SUITE_P(Zooms, SceneZoomValues,
                         ::testing::Values(ZoomRow { Json(2), 480 }, ZoomRow { Json(0), 960 }, ZoomRow { Json(-1), 960 },
                                           ZoomRow { Json({ { "value", 2 }, { "animation", Json::object() } }), 480 },
                                           ZoomRow { Json(1), 960 }, ZoomRow { Json(4), 240 }, ZoomRow { Json(2.9), 331 }));

} // namespace
