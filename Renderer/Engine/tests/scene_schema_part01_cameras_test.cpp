// Scene file schema, part 1: camera objects. Which shot poses a perspective camera, which field
// of view it takes, camera paths and their clock, the default camera object and the canvas that a
// camera object must not take a flat scene off.
#include "support/schema_fixtures.hpp"

#include "Scene/SceneCamera.h"
#include "Scene/SceneUpdateDemand.hpp"
#include "Runtime/SceneSettingResolver.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <optional>
#include <set>
#include <string>
#include <tuple>
#include <vector>

namespace
{

using namespace we_schema;
using namespace wallpaper;

using Vec3d = linalg::Vector3d;

constexpr uint32_t kAnimationDemand = static_cast<uint32_t>(SceneDemandReason::Animation);

// A perspective scene (live, so it has a runtime) of the given camera/layer objects.
std::shared_ptr<Scene> ParseLive(ParseRig& rig, Json objects, const Json& general_patch = Json::object())
{
    return rig.Parse(PerspectiveScene(std::move(objects), general_patch), { .live = true });
}

void ExpectPosition(const SceneCamera& camera, const Vec3d& expected, double tolerance = 1e-5)
{
    const Vec3d position = camera.GetPosition();
    EXPECT_NEAR(position.x(), expected.x(), tolerance);
    EXPECT_NEAR(position.y(), expected.y(), tolerance);
    EXPECT_NEAR(position.z(), expected.z(), tolerance);
}

Json ShotObject(int id, const std::string& name, const Json& camera, const Json& origin, const Json& extra = Json::object())
{
    Json object = { { "id", id }, { "name", name }, { "camera", camera }, { "origin", origin } };
    for (const auto& [key, value] : extra.items()) object[key] = value;
    return object;
}

// ---- which shot poses the camera ---------------------------------------------------------

// R-1.16 / B-1.16
TEST(PerspectiveCameras, TheLastVisibleShotPosesTheCamera)
{
    ParseRig rig(BasicAssets());
    auto     scene = ParseLive(rig, Json::array({ ShotObject(1, "first", "default", Json::array({ 0, 0, 12 }), { { "fov", 45 } }),
                                                  ShotObject(2, "second", "default", Json::array({ 6, 0, 8 }),
                                                             { { "fov", 75 }, { "visible", { { "user", "alternate" }, { "value", false } } } }) }));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    const auto expect = [&](const Vec3d& position, double fov) {
        ASSERT_NE(scene->activeCamera, nullptr);
        ExpectPosition(*scene->activeCamera, position);
        EXPECT_DOUBLE_EQ(scene->activeCamera->Fov(), fov);
    };

    {
        SCOPED_TRACE("after parse: only the first shot is visible");
        expect({ 0, 0, 12 }, 45);
    }
    scene->runtime->Tick(0.1);
    {
        SCOPED_TRACE("a tick changes nothing");
        expect({ 0, 0, 12 }, 45);
    }
    ASSERT_TRUE(scene->runtime->SetNodeVisible("second", true));
    scene->runtime->Tick(0.1);
    {
        SCOPED_TRACE("both visible: the later one wins");
        expect({ 6, 0, 8 }, 75);
    }
    scene->runtime->SetNodeVisible("second", false);
    scene->runtime->Tick(0.1);
    {
        SCOPED_TRACE("the second hidden again: back to the first");
        expect({ 0, 0, 12 }, 45);
    }
    scene->runtime->SetNodeVisible("first", false);
    scene->runtime->Tick(0.1);
    {
        SCOPED_TRACE("no shot visible: the scene camera and its field of view");
        expect({ 0, 10, 20 }, 60);
    }
    EXPECT_EQ(scene->runtime->DescribeTimeAdvancingWork() & kAnimationDemand, 0u);
}

// ---- field of view -----------------------------------------------------------------------

struct FovRow {
    bool           with_runtime;
    bool           named_camera;
    int            override_fov; // general.perspectiveoverridefov, which must have no effect
    std::optional<double> target_fov;

    std::string Name() const
    {
        std::string name = with_runtime ? "Runtime" : "Static";
        name += named_camera ? "Named" : "Default";
        name += "Override" + std::to_string(override_fov);
        if (!target_fov) name += "FovAbsent";
        else if (*target_fov < 0) name += "FovMinus" + std::to_string(static_cast<int>(-*target_fov));
        else name += "Fov" + std::to_string(static_cast<int>(*target_fov));
        return name;
    }
};

class ShotFieldOfView : public ::testing::TestWithParam<FovRow> {};

// R-1.17 / B-1.17: 2 (runtime) x 2 (camera name) x 2 (override fov) x 4 (the shot's own fov) = 32 rows.
TEST_P(ShotFieldOfView, ShotsTakeTheirOwnFovElseTheSceneFov)
{
    const FovRow row = GetParam();
    const double expected = row.target_fov && *row.target_fov > 0 ? *row.target_fov : 60.0;
    // The shot's `camera` key; the camera it ends up on is its own, or the scene's perspective one.
    const char*  target_camera = row.named_camera ? "named shot camera" : "default";
    const char*  shot_camera_key = row.named_camera ? "named shot camera" : "global_perspective";

    Json target = ShotObject(2, "target", target_camera, Json::array({ 6, 0, 8 }));
    if (row.target_fov) target["fov"] = *row.target_fov;

    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(PerspectiveScene(Json::array({ ShotObject(1, "earlier", "default", Json::array({ 0, 0, 12 }), { { "fov", 45 } }), target }),
                                               { { "perspectiveoverridefov", row.override_fov } }),
                           { .live = row.with_runtime });
    ASSERT_NE(scene, nullptr);

    const auto camera_named = [&](const char* name) -> SceneCamera* {
        const auto found = scene->cameras.find(name);
        return found == scene->cameras.end() ? nullptr : found->second.get();
    };
    SceneCamera* shot_camera = camera_named(shot_camera_key);
    SceneCamera* scene_camera = camera_named("global_perspective");
    ASSERT_NE(shot_camera, nullptr);
    ASSERT_NE(scene_camera, nullptr);

    EXPECT_EQ(scene->activeCamera, shot_camera);
    EXPECT_DOUBLE_EQ(shot_camera->Fov(), expected);
    ExpectPosition(*shot_camera, { 6, 0, 8 });
    if (!row.with_runtime) {
        EXPECT_EQ(scene->runtime, nullptr);
        return;
    }
    ASSERT_NE(scene->runtime, nullptr);

    scene->runtime->Tick(0.1);
    EXPECT_DOUBLE_EQ(shot_camera->Fov(), expected);

    ASSERT_TRUE(scene->runtime->SetNodeVisible("target", false));
    scene->runtime->Tick(0.1);
    EXPECT_EQ(scene->activeCamera, scene_camera);
    EXPECT_DOUBLE_EQ(scene->activeCamera->Fov(), 45.0);
    if (row.named_camera) EXPECT_DOUBLE_EQ(shot_camera->Fov(), expected) << "the named camera keeps its lens when its shots hide";

    ASSERT_TRUE(scene->runtime->SetNodeVisible("earlier", false));
    scene->runtime->Tick(0.1);
    EXPECT_DOUBLE_EQ(scene->activeCamera->Fov(), 60.0);
    ExpectPosition(*scene->activeCamera, { 0, 10, 20 });
    if (row.named_camera) EXPECT_DOUBLE_EQ(shot_camera->Fov(), expected);
}

std::vector<FovRow> AllFovRows()
{
    std::vector<FovRow> rows;
    for (const bool with_runtime : { false, true }) {
        for (const bool named : { true, false }) {
            for (const int override_fov : { 0, 75 }) {
                for (const std::optional<double> fov : { std::optional<double> {}, std::optional<double> { 0.0 }, std::optional<double> { -1.0 }, std::optional<double> { 80.0 } }) {
                    rows.push_back({ with_runtime, named, override_fov, fov });
                }
            }
        }
    }
    return rows;
}

INSTANTIATE_TEST_SUITE_P(Grid, ShotFieldOfView, ::testing::ValuesIn(AllFovRows()),
                         [](const ::testing::TestParamInfo<FovRow>& info) { return info.param.Name(); });

TEST(ShotFieldOfViewGrid, EnumeratesAllThirtyTwoRows)
{
    const auto rows = AllFovRows();
    EXPECT_EQ(rows.size(), 32u);
    std::set<std::string> names;
    for (const auto& row : rows) names.insert(row.Name());
    EXPECT_EQ(names.size(), 32u) << "every row is distinct";
}

// ---- camera paths ------------------------------------------------------------------------

Json PathScene(Json extra_objects = Json::array())
{
    Json objects = Json::array({ { { "id", 1 }, { "name", "moving" }, { "camera", "default" }, { "path", "paths.json" } } });
    for (auto& object : extra_objects) objects.push_back(object);
    return PerspectiveScene(std::move(objects));
}

FileMap PathAssets(const std::vector<Json>& clips)
{
    FileMap files = BasicAssets();
    files["/paths.json"] = CameraPathsText(clips);
    return files;
}

// R-1.18 / B-1.18
TEST(PerspectiveCameras, CameraPathsSampleQueueAndCarryTheirOvershoot)
{
    ParseRig rig(PathAssets({ CameraPathClip(0), CameraPathClip(100, false), CameraPathClip(200, true, 0), CameraPathClip(20) }));
    auto     scene = rig.Parse(PathScene(Json::array({ ShotObject(2, "hidden preset", "default", Json::array({ 99, 99, 99 }),
                                                                  { { "visible", { { "user", "alternate" }, { "value", false } } } }) })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);

    {
        SCOPED_TRACE("after parse: the first clip's first frame");
        ExpectPosition(*scene->activeCamera, { 0, 0, 10 });
    }
    scene->runtime->Tick(0.5);
    {
        SCOPED_TRACE("half a second into the first clip");
        ExpectPosition(*scene->activeCamera, { 1, 0, 10 });
        EXPECT_TRUE(scene->activeCamera->GetDirection().isApprox(Vec3d(0, 0, -1), 1e-5));
        EXPECT_NEAR(scene->activeCamera->Fov(), 50.0, 1e-5);
        EXPECT_NE(scene->runtime->DescribeTimeAdvancingWork() & kAnimationDemand, 0u);
    }
    scene->runtime->Tick(0.75);
    {
        SCOPED_TRACE("into the second playable clip with 0.25 s carried; the hidden and the invalid clips were skipped");
        EXPECT_NEAR(scene->activeCamera->GetPosition().x(), 20.5, 1e-5);
    }
    scene->runtime->Tick(1.0);
    {
        SCOPED_TRACE("wrapped back to the first clip with 0.25 s carried");
        EXPECT_NEAR(scene->activeCamera->GetPosition().x(), 0.5, 1e-5);
    }
    ASSERT_TRUE(scene->runtime->SetNodeVisible("moving", false));
    scene->runtime->Tick(0.5);
    {
        SCOPED_TRACE("the moving shot hidden: no time-advancing work, scene camera back");
        EXPECT_EQ(scene->runtime->DescribeTimeAdvancingWork() & kAnimationDemand, 0u);
        ExpectPosition(*scene->activeCamera, { 0, 10, 20 });
    }
}

// B-1.18: a clip in loop mode wraps by the remainder instead of handing over to the next clip.
TEST(PerspectiveCameras, ALoopingClipWrapsInsteadOfAdvancing)
{
    ParseRig rig(PathAssets({ CameraPathClip(0, true, 30, "loop"), CameraPathClip(20) }));
    auto     scene = rig.Parse(PathScene(), { .live = true });
    ASSERT_NE(scene, nullptr);
    scene->runtime->Tick(1.25);
    EXPECT_NEAR(scene->activeCamera->GetPosition().x(), 0.5, 1e-5);
    scene->runtime->Tick(1.0);
    EXPECT_NEAR(scene->activeCamera->GetPosition().x(), 0.5, 1e-5) << "a whole turn later it is at the same place";
}

// B-1.18: a lone clip repeats.
TEST(PerspectiveCameras, ALoneClipRepeats)
{
    ParseRig rig(PathAssets({ CameraPathClip(0) }));
    auto     scene = rig.Parse(PathScene(), { .live = true });
    ASSERT_NE(scene, nullptr);
    scene->runtime->Tick(1.25);
    EXPECT_NEAR(scene->activeCamera->GetPosition().x(), 0.5, 1e-5);
    scene->runtime->Tick(2.0);
    EXPECT_NEAR(scene->activeCamera->GetPosition().x(), 0.5, 1e-5);
}

// R-1.19 / B-1.19
TEST(PerspectiveCameras, ACameraPathAndALayerTimelineShareOneClock)
{
    FileMap files = PathAssets({ CameraPathClip(0) });
    Json layer = { { "id", 2 },
                   { "name", "layer" },
                   { "origin", { { "value", Json::array({ 0, 0, 0 }) },
                                 { "animation", { { "options", { { "fps", 30 }, { "length", 30 }, { "mode", "loop" } } },
                                                  { "c0", Json::array({ { { "frame", 0 }, { "value", 0 } }, { { "frame", 30 }, { "value", 2 } } }) } } } } } };
    ParseRig rig(files);
    auto     scene = rig.Parse(PathScene(Json::array({ layer })), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    double elapsed = 0.0;
    for (const double delta : { 0.2, 0.0, 0.2, 0.0, 0.8, 0.1 }) {
        elapsed += delta;
        scene->runtime->Tick(delta);
        const double expected = std::fmod(elapsed, 1.0) * 2.0;
        SCOPED_TRACE(elapsed);
        EXPECT_NEAR(scene->activeCamera->GetPosition().x(), expected, 1e-5);
        EXPECT_NEAR(scene->runtime->NodeTranslate("layer").x(), scene->activeCamera->GetPosition().x(), 1e-5);
    }
}

// ---- camera objects of other kinds of scene ----------------------------------------------

// R-1.20 / B-1.20
TEST(PerspectiveCameras, ADefaultCameraObjectBecomesTheActivePerspectiveCamera)
{
    ParseRig rig(LeafModelAssets());
    auto     scene = rig.Parse(PerspectiveScene(Json::array({ { { "id", 9 }, { "name", "playcam" }, { "camera", "default" }, { "origin", Json::array({ 0, 0, 0.454 }) }, { "angles", Json::array({ 0, 0, 0 }) }, { "fov", 50 }, { "visible", true } },
                                                             { { "id", 7 }, { "name", "planet" }, { "model", "planet.mdl" }, { "origin", Json::array({ 0, 0, 0 }) }, { "scale", Json::array({ 1, 1, 1 }) }, { "angles", Json::array({ 0, 0, 0 }) }, { "visible", true } } })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    EXPECT_TRUE(scene->activeCamera->IsPerspective());
    ExpectPosition(*scene->activeCamera, { 0, 0, 0.454 }, 1e-4);
    EXPECT_DOUBLE_EQ(scene->activeCamera->Fov(), 50.0);

    SceneNode* planet = FindRootChild(*scene, "planet");
    ASSERT_NE(planet, nullptr);
    EXPECT_EQ(planet->Camera(), "global_perspective");
}

// R-1.21 / B-1.21
TEST(PerspectiveCameras, ACameraObjectDoesNotTakeACanvasSceneOffItsCanvas)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(CanvasWithCameraObject());
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    EXPECT_FALSE(scene->activeCamera->IsPerspective());
    EXPECT_NE(FindRootChild(*scene, "shot"), nullptr);

    const linalg::Matrix4d projection = scene->activeCamera->GetViewProjectionMatrix();
    const auto ndc = [&](double x, double y) {
        const linalg::Vector4d clip = projection * linalg::Vector4d(x, y, 0.0, 1.0);
        return std::array<double, 2> { clip.x() / clip.w(), clip.y() / clip.w() };
    };
    const auto centre = ndc(320, 180);
    EXPECT_NEAR(centre[0], 0.0, 1e-6);
    EXPECT_NEAR(centre[1], 0.0, 1e-6);
    const auto lower_left = ndc(0, 0);
    EXPECT_NEAR(lower_left[0], -1.0, 1e-6);
    EXPECT_NEAR(lower_left[1], -1.0, 1e-6);
    const auto upper_right = ndc(640, 360);
    EXPECT_NEAR(upper_right[0], 1.0, 1e-6);
    EXPECT_NEAR(upper_right[1], 1.0, 1e-6);
}

} // namespace

namespace {
FileMap CameraFadeAssets() {
    auto files = PathAssets({CameraPathClip(0)});
    files["/global-path.json"] = R"({"paths":[{"duration":1,"transforms":[{"timestamp":0,"eye":"0 0 10","center":"0 0 0","up":"0 1 0"},{"timestamp":1,"eye":"2 0 10","center":"2 0 0","up":"0 1 0"}]}]})";
    files["/materials/util/fade.json"] = R"({"passes":[{"shader":"fade","blending":"translucent","depthtest":"disabled","depthwrite":"disabled","cullmode":"nocull"}]})";
    files["/shaders/fade.vert"] = "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position,1.0);}\n";
    files["/shaders/fade.frag"] = "uniform float g_Alpha;\nuniform vec3 color;\nvoid main(){gl_FragColor=vec4(color*0.7,g_Alpha);}\n";
    return files;
}
Json GlobalPathScene() {
    auto scene = PerspectiveScene(Json::array());
    scene["camera"]["paths"] = Json::array({"global-path.json"});
    scene["general"]["bloom"] = false;
    return scene;
}
std::shared_ptr<SceneNode> CameraFadePass(Scene& scene) {
    for (const auto& post : scene.post_processes) {
        for (const auto& step : post->steps) {
            if (const auto* pass = std::get_if<ScenePostProcessPass>(&step)) return pass->node;
        }
    }
    return {};
}

TEST(PerspectiveCameras, CameraPathFadeTracksBothEndsWithoutRebuildingItsGraph) {
    ParseRig rig(CameraFadeAssets());
    auto document = GlobalPathScene();
    document["general"]["bloom"] = false;
    auto scene = rig.Parse(document, {.live=true});
    ASSERT_NE(scene, nullptr);
    auto node = CameraFadePass(*scene);
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto material = node->Mesh()->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);
    scene->runtime->ConsumeSceneGraphMutationFlag();
    for (const float expected : {0.5f, 0.0f, 0.5f, 1.0f}) {
        scene->runtime->Tick(0.25);
        ASSERT_TRUE(material->customShader.constValues.contains("g_Alpha"));
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Alpha")[0], expected);
        EXPECT_EQ(node->Visible(), expected > 0);
        EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
    }
}

TEST(PerspectiveCameras, CameraFadeAllocatesNoPassWhenDisabledOrWithoutAPath) {
    for (const bool path : {false,true}) {
        for (const bool enabled : {false,true}) {
            if (path && enabled) continue;
            ParseRig rig(CameraFadeAssets());
            auto document=GlobalPathScene();
            document["general"]["bloom"]=false;
            document["general"]["camerafade"]=enabled;
            if (!path) document["camera"].erase("paths");
            auto scene=rig.Parse(document,{.live=true});
            ASSERT_NE(scene,nullptr);
            EXPECT_TRUE(scene->post_processes.empty());
        }
    }
}

TEST(PerspectiveCameras, AnObjectCameraPathDoesNotAllocateAGlobalCameraFade) {
    ParseRig rig(CameraFadeAssets());
    auto document=PathScene();
    document["general"]["bloom"]=false;
    auto scene=rig.Parse(document,{.live=true});
    ASSERT_NE(scene,nullptr);
    EXPECT_EQ(CameraFadePass(*scene),nullptr);
}

TEST(PerspectiveCameras, GlobalCameraPathsUseHalfSlopeInterpolationBeforeAdvancingTheClock) {
    ParseRig rig(CameraFadeAssets());
    auto scene=rig.Parse(GlobalPathScene(),{.live=true});
    ASSERT_NE(scene,nullptr);
    scene->runtime->Tick(0.25);
    ExpectPosition(*scene->activeCamera,{0,0,10});
    scene->runtime->Tick(0.25);
    ExpectPosition(*scene->activeCamera,{0.40625,0,10});
    EXPECT_NE(scene->runtime->DescribeTimeAdvancingWork() & kAnimationDemand,0u);
}

TEST(PerspectiveCameras, GlobalCameraQueueUsesTheLastFileAndDropsOvershootAtACut) {
    auto files=CameraFadeAssets();
    const auto path=[](int x) {
        return Json{{"duration",1},{"transforms",Json::array({
            {{"eye",std::to_string(x)+" 0 10"},{"center",std::to_string(x)+" 0 0"},{"up","0 1 0"}},
            {{"eye",std::to_string(x+2)+" 0 10"},{"center",std::to_string(x+2)+" 0 0"},{"up","0 1 0"}}})}};
    };
    auto disabled=path(999);disabled["disabled"]=true;
    files["/replacement.json"]=Json{{"paths",Json::array({disabled,path(100),path(200)})}}.dump();
    ParseRig rig(files);
    auto document=GlobalPathScene();
    document["camera"]["paths"].push_back("replacement.json");
    auto scene=rig.Parse(document,{.live=true});
    ASSERT_NE(scene,nullptr);
    scene->runtime->Tick(0.75);
    ExpectPosition(*scene->activeCamera,{100,0,10});
    scene->runtime->Tick(0.5);
    ExpectPosition(*scene->activeCamera,{101.59375,0,10});
    scene->runtime->Tick(0.25);
    ExpectPosition(*scene->activeCamera,{200,0,10});
}

TEST(PerspectiveCameras, AVisibleCameraLayerPausesTheGlobalQueue) {
    ParseRig rig(CameraFadeAssets());
    auto document=GlobalPathScene();
    document["objects"]=Json::array({ShotObject(7,"override","default",Json::array({42,0,10}))});
    auto scene=rig.Parse(document,{.live=true});
    ASSERT_NE(scene,nullptr);
    scene->runtime->Tick(0.75);
    ExpectPosition(*scene->activeCamera,{42,0,10});
    EXPECT_EQ(scene->runtime->DescribeTimeAdvancingWork() & kAnimationDemand,0u);
    ASSERT_TRUE(scene->runtime->SetNodeVisible("override",false));
    scene->runtime->Tick(0.25);
    ExpectPosition(*scene->activeCamera,{0,0,10});
    scene->runtime->Tick(0.25);
    ExpectPosition(*scene->activeCamera,{0.40625,0,10});
}

TEST(PerspectiveCameras, TheEndFadeWinsWhenAShortGlobalSegmentHasOverlappingRamps) {
    auto files=CameraFadeAssets();
    auto paths=Json::parse(files.at("/global-path.json"));
    paths["paths"][0]["duration"]=0.6;
    paths["paths"][0]["transforms"][1]["timestamp"]=0.6;
    files["/global-path.json"]=paths.dump();
    ParseRig rig(files);
    auto scene=rig.Parse(GlobalPathScene(),{.live=true});
    ASSERT_NE(scene,nullptr);
    auto fade=CameraFadePass(*scene);
    ASSERT_NE(fade,nullptr);
    scene->runtime->Tick(0.2);
    EXPECT_NEAR(fade->Mesh()->Material()->customShader.constValues.at("g_Alpha")[0],0.2f,1e-6f);
}

TEST(PerspectiveCameras, GlobalPathMissingPoseVectorsDefaultToZero) {
    const auto paths = ParseGlobalCameraPaths({{"paths", Json::array({{
        {"duration", 1}, {"transforms", Json::array({
            {{"eye", "0 0 10"}, {"up", "0 1 0"}},
            {{"center", "0 0 -1"}, {"up", "0 1 0"}},
            {{"eye", "0 0 10"}, {"center", "0 0 0"}}
        })}
    }})}});
    ASSERT_EQ(paths.size(), 1u);
    ASSERT_EQ(paths[0].keys.size(), 3u);
    for (std::size_t lane = 0; lane < 3; ++lane) {
        EXPECT_EQ(paths[0].keys[0].pose[3 + lane], 0.0);
        EXPECT_EQ(paths[0].keys[1].pose[lane], 0.0);
        EXPECT_EQ(paths[0].keys[2].pose[6 + lane], 0.0);
    }
    for (const auto& key : paths[0].keys) EXPECT_EQ(key.pose[9], 1.0);
}

FileMap CanvasGlobalPathAssets(const char* eye, const char* center, const char* up) {
    auto files = BasicAssets();
    Json first{{"timestamp", 0}, {"eye", eye}, {"center", center}, {"up", up}, {"zoom", 2}};
    auto last = first;
    last["timestamp"] = 4;
    files["/global-path.json"] = Json{{"paths", Json::array({{
        {"duration", 4}, {"transforms", Json::array({first, last})}
    }})}}.dump();
    return files;
}

Json CanvasGlobalPathScene(bool with_path) {
    auto scene = CanvasWithCameraObject({{"visible", true}, {"zoom", 1}});
    scene["general"]["zoom"] = 1.25;
    scene["general"]["bloom"] = false;
    scene["general"]["camerafade"] = false;
    if (with_path) scene["camera"]["paths"] = Json::array({"global-path.json"});
    return scene;
}

TEST(PerspectiveCameras, CanvasGlobalZoomPreservesBaseExtentAcrossShotOverrides) {
    ParseRig rig(CanvasGlobalPathAssets("0 0 0", "0 0 -1", "0 1 0"));
    const auto scene = rig.Parse(CanvasGlobalPathScene(true), {.live=true});
    ASSERT_NE(scene, nullptr);
    auto& camera = *scene->cameras.at("global");
    const double width = camera.Width(), height = camera.Height();
    ASSERT_NEAR(width, 512.0, 1e-6);
    ASSERT_TRUE(scene->runtime->SetNodeVisible("shot", false));
    scene->runtime->Tick(0.1);
    EXPECT_EQ(camera.Width(), width);
    EXPECT_EQ(camera.Height(), height);
    EXPECT_NEAR(camera.VisibleWidth(), width / 2.0, 1e-6);
    ASSERT_TRUE(scene->runtime->SetNodeVisible("shot", true));
    scene->runtime->Tick(0.1);
    EXPECT_EQ(camera.Width(), width);
    EXPECT_NEAR(camera.VisibleWidth(), width, 1e-6);
    ASSERT_TRUE(scene->runtime->SetNodeVisible("shot", false));
    scene->runtime->Tick(0.1);
    EXPECT_EQ(camera.Width(), width);
    EXPECT_NEAR(camera.VisibleWidth(), width / 2.0, 1e-6);
}

TEST(PerspectiveCameras, ACanvasShotDoesNotInheritTheGlobalPathsRotationOrDepth) {
    ParseRig baseline_rig(BasicAssets());
    const auto baseline = baseline_rig.Parse(CanvasGlobalPathScene(false), {.live=true});
    ASSERT_NE(baseline, nullptr);
    baseline->runtime->Tick(0.1);
    ParseRig rig(CanvasGlobalPathAssets("7 11 31", "0 0 0", "1 0 0"));
    const auto scene = rig.Parse(CanvasGlobalPathScene(true), {.live=true});
    ASSERT_NE(scene, nullptr);
    ASSERT_TRUE(scene->runtime->SetNodeVisible("shot", false));
    scene->runtime->Tick(0.1);
    EXPECT_GT((scene->activeCamera->GetViewProjectionMatrix() -
               baseline->activeCamera->GetViewProjectionMatrix()).norm(), 1e-3);
    ASSERT_TRUE(scene->runtime->SetNodeVisible("shot", true));
    scene->runtime->Tick(0.1);
    for (const char* name : {"global", "global_perspective"}) {
        SCOPED_TRACE(name);
        EXPECT_LT((scene->cameras.at(name)->GetViewProjectionMatrix() -
                   baseline->cameras.at(name)->GetViewProjectionMatrix()).norm(), 1e-7);
    }
    ASSERT_TRUE(scene->runtime->SetNodeVisible("shot", false));
    scene->runtime->Tick(0.1);
    EXPECT_GT((scene->activeCamera->GetViewProjectionMatrix() -
               baseline->activeCamera->GetViewProjectionMatrix()).norm(), 1e-3);
}

TEST(PerspectiveCameras, GlobalPathCutsUseTheFloatClockAndLoadedTimestamps) {
    struct Case { double duration; int ticks; bool next; };
    for (const Case c : { Case{1.0,30,true}, Case{1.0/30.0,1,false} }) {
        SCOPED_TRACE(c.duration);
        auto files = CameraFadeAssets();
        const auto path = [&](int x) {
            return Json{{"duration", c.duration}, {"transforms", Json::array({
                {{"timestamp",0}, {"eye",std::to_string(x)+" 0 10"},
                 {"center",std::to_string(x)+" 0 0"}, {"up","0 1 0"}},
                {{"timestamp",c.duration}, {"eye",std::to_string(x+2)+" 0 10"},
                 {"center",std::to_string(x+2)+" 0 0"}, {"up","0 1 0"}}
            })}};
        };
        files["/global-path.json"] = Json{{"paths",Json::array({path(0),path(100)})}}.dump();
        ParseRig rig(files);
        const auto scene = rig.Parse(GlobalPathScene(), {.live=true});
        ASSERT_NE(scene, nullptr);
        for (int frame = 0; frame < c.ticks; ++frame) scene->runtime->Tick(1.0/30.0);
        scene->runtime->Tick(1.0/30.0);
        ExpectPosition(*scene->activeCamera, {c.next ? 100.0 : 2.0,0,10});
        if (!c.next) {
            scene->runtime->Tick(1.0/30.0);
            ExpectPosition(*scene->activeCamera, {100,0,10});
        }
    }
}
} // namespace
