// Scene file schema, part 9 (nodes and cameras): the world transform of a node attached late,
// the orientation a camera path gives its camera, a random queue of camera paths, and the
// camera a perspective shot falls back to when it stops being visible.
#include "support/schema_fixtures.hpp"

#include "Runtime/CameraPath.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneNode.h"

#include <gtest/gtest.h>

#include <cmath>
#include <memory>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace wallpaper;

using Vec3d = linalg::Vector3d;

// ---- world transform follows attachment ---------------------------------------------------

Vec3d WorldOrigin(SceneNode& node)
{
    node.UpdateTrans();
    return node.ModelTrans().block<3, 1>(0, 3);
}

std::shared_ptr<SceneNode> NodeAt(float x, float y, float z)
{
    return std::make_shared<SceneNode>(linalg::Vector3f(x, y, z), linalg::Vector3f(1, 1, 1), linalg::Vector3f(0, 0, 0));
}

void ExpectWorld(SceneNode& node, double x, double y, double z)
{
    const Vec3d origin = WorldOrigin(node);
    EXPECT_EQ(origin.x(), x);
    EXPECT_EQ(origin.y(), y);
    EXPECT_EQ(origin.z(), z);
}

// R-9.01 / B-9.01
TEST(SceneNodeWorldTransform, AttachingAnAlreadyEvaluatedNodeRebasesItsWholeSubtree)
{
    auto root       = NodeAt(100, 200, 0);
    auto parent     = NodeAt(2560, 1080, 0);
    auto child      = NodeAt(0, 5, 0);
    auto grandchild = NodeAt(7, 0, 0);

    {
        SCOPED_TRACE("a lone node sits where its own translation puts it");
        ExpectWorld(*child, 0, 5, 0);
    }
    parent->AppendChild(child);
    {
        SCOPED_TRACE("attached to a parent");
        ExpectWorld(*child, 2560, 1085, 0);
    }
    child->AppendChild(grandchild);
    {
        SCOPED_TRACE("a grandchild attached below");
        ExpectWorld(*grandchild, 2567, 1085, 0);
    }
    root->AppendChild(parent);
    {
        SCOPED_TRACE("the whole chain, all evaluated before, is attached under a new root");
        ExpectWorld(*grandchild, 2667, 1285, 0);
        ExpectWorld(*child, 2660, 1285, 0);
        ExpectWorld(*parent, 2660, 1280, 0);
    }
}

TEST(SceneNodeWorldTransform, ReparentingFollowsTheNewParentOnly)
{
    auto first  = NodeAt(100, 0, 0);
    auto second = NodeAt(0, 50, 0);
    auto child  = NodeAt(1, 2, 3);

    first->AppendChild(child);
    ExpectWorld(*child, 101, 2, 3);
    second->AppendChild(child);
    ExpectWorld(*child, 1, 52, 3);
    ASSERT_EQ(child->Parent(), second.get());
}

TEST(SceneNodeWorldTransform, ParentScaleAndTurnReachALateChild)
{
    auto parent = std::make_shared<SceneNode>(linalg::Vector3f(10, 0, 0), linalg::Vector3f(2, 2, 2), linalg::Vector3f(0, 0, 0));
    auto child  = NodeAt(1, 0, 0);
    ExpectWorld(*child, 1, 0, 0);
    parent->AppendChild(child);
    ExpectWorld(*child, 12, 0, 0);

    // A quarter turn about z (radians) carries the child's offset from the x axis to the y axis.
    auto turned = std::make_shared<SceneNode>(linalg::Vector3f(0, 0, 0), linalg::Vector3f(1, 1, 1),
                                              linalg::Vector3f(0, 0, static_cast<float>(M_PI / 2)));
    auto probe  = NodeAt(3, 0, 0);
    (void)WorldOrigin(*probe);
    turned->AppendChild(probe);
    const Vec3d origin = WorldOrigin(*probe);
    EXPECT_NEAR(origin.x(), 0.0, 1e-6);
    EXPECT_NEAR(origin.y(), 3.0, 1e-6);
    EXPECT_NEAR(origin.z(), 0.0, 1e-6);
}

// ---- camera-path orientation ---------------------------------------------------------------

Json KeysFor(double from, double to)
{
    return Json::array({ { { "frame", 0 }, { "value", from } }, { { "frame", 30 }, { "value", to } } });
}
Json SingleKey(double value)
{
    return Json::array({ { { "frame", 0 }, { "value", value } } });
}

// One second long at 30 fps. The eye runs from x to x + 2 at height 0 and depth 10 while the camera looks at
// the point under it; up is +y; the field of view grows from 40 to 60.
Json StandardPath(double x)
{
    return { { "visible", true },
             { "options", { { "fps", 30 }, { "length", 30 }, { "mode", "single" } } },
             { "eye", { { "c0", KeysFor(x, x + 2) }, { "c1", KeysFor(0, 0) }, { "c2", KeysFor(10, 10) } } },
             { "center", { { "c0", KeysFor(x, x + 2) }, { "c1", KeysFor(0, 0) }, { "c2", KeysFor(0, 0) } } },
             { "up", { { "c0", KeysFor(0, 0) }, { "c1", KeysFor(1, 1) }, { "c2", KeysFor(0, 0) } } },
             { "fov", KeysFor(40, 60) } };
}

std::vector<CameraPath> PathsOf(const std::vector<Json>& paths)
{
    return ParseCameraPaths({ { "paths", paths } });
}

struct PathParams {
    Vec3d up;
    Vec3d eye;
};

class CameraPathOrientation : public ::testing::TestWithParam<PathParams> {};

// R-9.02 / B-9.02
TEST_P(CameraPathOrientation, LooksAtTheCenterWithAnOrthonormalUp)
{
    const auto [up, eye] = GetParam();
    const char* const names[] = { "c0", "c1", "c2" };

    Json path = StandardPath(0);
    for (int k = 0; k < 3; ++k) {
        path["eye"][names[k]]    = KeysFor(eye[k], k == 2 ? -eye[k] : eye[k]);
        path["center"][names[k]] = SingleKey(0);
        path["up"][names[k]]     = SingleKey(up[k]);
    }
    auto paths = PathsOf({ path });
    ASSERT_EQ(paths.size(), 1u);
    CameraPathPlayback playback(std::move(paths), "sequence");
    auto               node = std::make_shared<SceneNode>();
    SceneCamera        camera(1.0f, 0.1f, 100.0f, 50.0f);
    camera.AttatchNode(node);

    for (int frame = 0; frame < 5; ++frame) {
        SCOPED_TRACE("frame " + std::to_string(frame));
        playback.Apply(*node, camera);
        const Vec3d sampled_eye(eye.x(), eye.y(), eye.z() * (1.0 - 0.4 * frame));
        const Vec3d forward = (-sampled_eye).normalized();
        const Vec3d right   = forward.cross(up).normalized();
        const Vec3d expected_up = right.cross(forward);

        EXPECT_TRUE(camera.GetDirection().isApprox(forward, 1e-5)) << "direction " << camera.GetDirection().transpose();
        EXPECT_TRUE(camera.GetUp().isApprox(expected_up, 1e-5)) << "up " << camera.GetUp().transpose();
        EXPECT_TRUE(camera.GetViewMatrix().allFinite());
        // The camera sits at the sampled eye.
        EXPECT_NEAR(camera.GetPosition().x(), sampled_eye.x(), 1e-4);
        EXPECT_NEAR(camera.GetPosition().y(), sampled_eye.y(), 1e-4);
        EXPECT_NEAR(camera.GetPosition().z(), sampled_eye.z(), 1e-4);
        playback.Advance(0.2);
    }
}

INSTANTIATE_TEST_SUITE_P(SteepAndRolled, CameraPathOrientation,
                         ::testing::Values(PathParams { Vec3d(0, 1, 0), Vec3d(0.001, 10, 0.002) },
                                           PathParams { Vec3d(0, 1, 0), Vec3d(10, 0.001, 0.002) },
                                           PathParams { Vec3d(0.2, 1, 0.3), Vec3d(0.001, 10, 0.002) },
                                           PathParams { Vec3d(0.2, 1, 0.3), Vec3d(10, 0.001, 0.002) }));

TEST(CameraPathGentleLook, KeepsTheAuthoredUpAndSamplesTheFov)
{
    auto               paths = PathsOf({ StandardPath(0) });
    CameraPathPlayback playback(std::move(paths), "sequence");
    auto               node = std::make_shared<SceneNode>();
    SceneCamera        camera(1.0f, 0.1f, 100.0f, 50.0f);
    camera.AttatchNode(node);
    playback.Apply(*node, camera);
    EXPECT_TRUE(camera.GetDirection().isApprox(Vec3d(0, 0, -1), 1e-6));
    EXPECT_TRUE(camera.GetUp().isApprox(Vec3d(0, 1, 0), 1e-6));
    EXPECT_NEAR(camera.Fov(), 40.0, 1e-9);
    playback.Advance(0.5);
    playback.Apply(*node, camera);
    EXPECT_NEAR(camera.Fov(), 50.0, 1e-6);
    EXPECT_NEAR(camera.GetPosition().x(), 1.0, 1e-6);
}

// ---- a random queue of paths ---------------------------------------------------------------

// R-9.04 / B-9.04
TEST(CameraPathRandomQueue, AFinishedClipIsFollowedByTheOtherOne)
{
    constexpr int kRounds = 20;
    for (int round = 0; round < kRounds; ++round) {
        SCOPED_TRACE("round " + std::to_string(round));
        CameraPathPlayback playback(PathsOf({ StandardPath(0), StandardPath(20) }), "random");
        auto               node = std::make_shared<SceneNode>();
        SceneCamera        camera(1.0f, 0.1f, 1000.0f, 50.0f);

        playback.Apply(*node, camera);
        const float first = node->Translate().x();
        ASSERT_TRUE(first == 0.0f || first == 20.0f) << first;

        playback.Advance(1.0);
        playback.Apply(*node, camera);
        EXPECT_FLOAT_EQ(node->Translate().x(), first == 0.0f ? 20.0f : 0.0f);

        playback.Advance(1e9);
        playback.Apply(*node, camera);
        EXPECT_TRUE(node->Translate().allFinite());
        EXPECT_GE(node->Translate().x(), 0.0f);
        EXPECT_LE(node->Translate().x(), 22.0f);
    }
}

TEST(CameraPathRandomQueue, TwoClipsAlternateAtEveryBoundary)
{
    CameraPathPlayback playback(PathsOf({ StandardPath(0), StandardPath(20) }), "random");
    auto               node = std::make_shared<SceneNode>();
    SceneCamera        camera(1.0f, 0.1f, 1000.0f, 50.0f);

    playback.Apply(*node, camera);
    float previous = node->Translate().x();
    for (int clip = 0; clip < 12; ++clip) {
        SCOPED_TRACE("clip " + std::to_string(clip));
        playback.Advance(1.0);
        playback.Apply(*node, camera);
        const float now = node->Translate().x();
        EXPECT_FLOAT_EQ(now, previous == 0.0f ? 20.0f : 0.0f);
        previous = now;
    }
}

TEST(CameraPathRandomQueue, ALongPauseStaysBoundedAndLandsAtTheStartOfAClip)
{
    auto        node = std::make_shared<SceneNode>();
    SceneCamera camera(1.0f, 0.1f, 1000.0f, 50.0f);
    for (int jump = 0; jump < 5; ++jump) {
        SCOPED_TRACE("jump " + std::to_string(jump));
        CameraPathPlayback playback(PathsOf({ StandardPath(0), StandardPath(20) }), "random");
        playback.Advance(1e12);
        playback.Apply(*node, camera);
        ASSERT_TRUE(node->Translate().allFinite());
        // The catch-up is bounded and the remainder wraps: a whole number of seconds ends at a clip's start.
        const float start = node->Translate().x();
        EXPECT_TRUE(start == 0.0f || start == 20.0f) << start;
        playback.Advance(0.5);
        playback.Apply(*node, camera);
        EXPECT_FLOAT_EQ(node->Translate().x(), start + 1.0f) << "half a second into the clip";
    }
}

// ---- the camera a perspective shot falls back to -------------------------------------------

// R-9.03 / B-9.03
TEST(PerspectiveShotFallback, TheCameraActiveAtTheFirstRegistrationIsTheFallback)
{
    Scene       scene;
    SceneCamera initial(1.0f, 0.1f, 100.0f, 50.0f);
    SceneCamera editor(1.0f, 0.1f, 100.0f, 60.0f);
    SceneCamera shot_camera(1.0f, 0.1f, 100.0f, 70.0f);

    scene.activeCamera = &initial;
    auto runtime       = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);
    runtime->AttachScene(&scene);
    // The loader settles on the editor camera before it registers any shot.
    scene.activeCamera = &editor;

    auto first = std::make_shared<SceneNode>();
    first->SetVisible(false);
    runtime->RegisterPerspectiveCameraShot(first, &shot_camera, 45.0, CameraPathPlayback {});
    EXPECT_EQ(scene.activeCamera, &editor) << "a hidden shot leaves the editor camera";

    first->SetVisible(true);
    runtime->Tick(0.0);
    EXPECT_EQ(scene.activeCamera, &shot_camera) << "a visible shot takes the view";

    auto second = std::make_shared<SceneNode>();
    second->SetVisible(false);
    runtime->RegisterPerspectiveCameraShot(second, &shot_camera, 80.0, CameraPathPlayback {});
    first->SetVisible(false);
    runtime->Tick(0.0);
    EXPECT_EQ(scene.activeCamera, &editor) << "with every shot hidden the camera from the first registration returns, not the shot camera";
}

TEST(PerspectiveShotFallback, ALaterVisibleShotWinsAndTheFovFollowsTheShot)
{
    Scene       scene;
    SceneCamera editor(1.0f, 0.1f, 100.0f, 60.0f);
    SceneCamera shot_camera(1.0f, 0.1f, 100.0f, 70.0f);
    scene.activeCamera = &editor;
    auto runtime       = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    runtime->AttachScene(&scene);

    auto early = std::make_shared<SceneNode>();
    auto late  = std::make_shared<SceneNode>();
    runtime->RegisterPerspectiveCameraShot(early, &shot_camera, 45.0, CameraPathPlayback {});
    EXPECT_EQ(scene.activeCamera, &shot_camera);
    EXPECT_DOUBLE_EQ(shot_camera.Fov(), 45.0);
    runtime->RegisterPerspectiveCameraShot(late, &shot_camera, 80.0, CameraPathPlayback {});
    EXPECT_DOUBLE_EQ(shot_camera.Fov(), 80.0) << "the last visible shot of a camera decides its field of view";
    late->SetVisible(false);
    runtime->Tick(0.0);
    EXPECT_DOUBLE_EQ(shot_camera.Fov(), 45.0);
    early->SetVisible(false);
    runtime->Tick(0.0);
    EXPECT_EQ(scene.activeCamera, &editor);
    EXPECT_DOUBLE_EQ(shot_camera.Fov(), 70.0) << "hidden shots restore the camera's own field of view";
}

} // namespace
