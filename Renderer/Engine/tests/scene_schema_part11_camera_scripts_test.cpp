// Scene file schema, part 11 (camera scripts): `thisScene.getCameraTransforms()` answers the scene
// camera's static transforms as Wallpaper Engine's CameraTransforms documents them (`eye`,
// `center`, `up`, and `zoom` for a 2D scene), and `setCameraTransforms` replaces them: a
// perspective scene's camera looks from the new eye at the new centre, a 2D scene zooms.
#include "support/schema_fixtures.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/SceneCamera.h"

#include <gtest/gtest.h>

#include <memory>
#include <string>

namespace
{

using namespace we_schema;
using namespace wallpaper;

struct CameraStage {
    explicit CameraStage(const Json& scene_json) : rig(BasicAssets())
    {
        scene = rig.Parse(scene_json, { .live = true });
    }
    bool ok() const { return scene != nullptr && scene->runtime != nullptr; }
    void Run(const std::string& body)
    {
        scene->runtime->RegisterSceneScript("var ran = false;\nfunction update() { if (ran) return; ran = true;\n" + body + "\n}", "");
        scene->runtime->Tick(0.1);
    }
    std::vector<std::string> Errors() const { return scene->runtime->scriptErrors(); }

    ParseRig               rig;
    std::shared_ptr<Scene> scene;
};

Json OneImage() { return Json::array({ { { "id", 1 }, { "name", "plain" }, { "image", "image.json" }, { "visible", true } } }); }

} // namespace

TEST(CameraScripts, APerspectiveSceneAnswersAndTakesItsCameraBlock)
{
    CameraStage stage(PerspectiveScene(OneImage()));
    ASSERT_TRUE(stage.ok());
    stage.Run("var t = thisScene.getCameraTransforms();\n"
              "if (t.eye.x !== 0 || t.eye.y !== 10 || t.eye.z !== 20) throw new Error('eye ' + t.eye.x + ' ' + t.eye.y + ' ' + t.eye.z);\n"
              "if (t.center.x !== 0 || t.center.y !== 0 || t.center.z !== 0) throw new Error('center');\n"
              "if (t.up.y !== 1) throw new Error('up');\n"
              "t.eye = new Vec3(30, 0, 0);\n"
              "thisScene.setCameraTransforms(t);\n"
              "var again = thisScene.getCameraTransforms();\n"
              "if (again.eye.x !== 30 || again.eye.z !== 0) throw new Error('reads back');");
    for (const auto& error : stage.Errors()) ADD_FAILURE() << error;

    const auto found = stage.scene->cameras.find("global_perspective");
    ASSERT_NE(found, stage.scene->cameras.end());
    const auto node = found->second->GetAttachedNode();
    ASSERT_NE(node, nullptr);
    node->UpdateTrans();
    const linalg::Matrix4d world = node->ModelTrans();
    EXPECT_NEAR(world(0, 3), 30.0, 1e-4) << "the camera sits at the new eye";
    EXPECT_NEAR(world(1, 3), 0.0, 1e-4);
    EXPECT_NEAR(world(2, 3), 0.0, 1e-4);
    // It looks down -z of its own frame: from (30, 0, 0) at the origin, that is along -x.
    const linalg::Vector3d forward = -world.block<3, 1>(0, 2);
    EXPECT_NEAR(forward.x(), -1.0, 1e-4);
    EXPECT_NEAR(forward.y(), 0.0, 1e-4);
    EXPECT_NEAR(forward.z(), 0.0, 1e-4);
}

TEST(CameraScripts, A2DSceneZoomsThroughItsCameraTransforms)
{
    CameraStage stage(QuietScene(OneImage(), { { "bloom", false } }));
    ASSERT_TRUE(stage.ok());
    const auto global = stage.scene->cameras.find("global");
    ASSERT_NE(global, stage.scene->cameras.end());
    const double width = global->second->Width();
    stage.Run("var t = thisScene.getCameraTransforms();\n"
              "if (t.zoom !== 1) throw new Error('zoom ' + t.zoom);\n"
              "t.zoom = 2; thisScene.setCameraTransforms(t);\n"
              "if (thisScene.getCameraTransforms().zoom !== 2) throw new Error('reads back');");
    for (const auto& error : stage.Errors()) ADD_FAILURE() << error;
    EXPECT_NEAR(global->second->Width(), width / 2.0, 1e-3) << "zoom 2 shows half the canvas";
}
