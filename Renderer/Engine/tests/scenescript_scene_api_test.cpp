#include "scenescript_scenes.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"

#include <gtest/gtest.h>

namespace {
using namespace we_test;
}

TEST(ScriptObjectValidity, DestroyedScriptCreatedLayersBecomeInvalid)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
var held, before;
export function init() {
    held = thisScene.createLayer({image:'models/plain.json',name:'made'});
    before = engine.isObjectValid(held);
    if (!thisScene.destroyLayer(held)) throw new Error('created layer was not destroyed');
}
export function update() {
    return new Vec3(before ? 1 : 0, engine.isObjectValid(held) ? 1 : 0,
                    engine.isObjectValid(thisLayer) ? 1 : 0);
}
)JS";
    Publish(package, { PlainImage(model, 1, "probe", {{"origin", ScriptedValue(source, "0 0 0")}}) });
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(3);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3>{1, 0, 1}));
}

TEST(ScriptObjectValidity, EffectValidityFollowsItsOwnersLifetime)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto effect = AddProbeEffect(package);
    const auto source = R"JS(
var held, effect;
export function init() {
    held=thisScene.getLayer('victim'); effect=held.getEffect(0);
}
export function update() {
    return new Vec3(engine.isObjectValid(held)?1:0,engine.isObjectValid(effect)?1:0,0);
}
)JS";
    Publish(package, { PlainImage(model, 1, "probe", {{"origin", ScriptedValue(source, "0 0 0")}}),
                       PlainImage(model, 2, "victim", {}, {EffectUse(effect)}) });
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3>{1, 1, 0}));
    scene.runtime().UnregisterNode("victim");
    scene.Tick(2);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3>{0, 0, 0}));
}

TEST(ScriptObjectValidity, OrdinaryValuesAndUnbackedAnimationObjectsAreNotNativeObjects)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
export function update() {
    var values = [null, undefined, false, 1, 'probe', {}, [], function(){},
                  thisScene, new Vec3(1, 2, 3), Object.create(thisLayer),
                  thisLayer.getAnimation('missing'), thisLayer.getAnimationLayer('missing'),
                  thisLayer.getTextureAnimation(), thisLayer.getVideoTexture()];
    var invalid = values.every(function(value) { return engine.isObjectValid(value) === false; });
    return new Vec3(engine.isObjectValid(thisLayer) ? 1 : 0, invalid ? 1 : 0, 0);
}

)JS";
    Publish(package, { PlainImage(model, 1, "probe", {{"origin", ScriptedValue(source, "0 0 0")}}) });
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(2);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3>{1, 1, 0}));
}

TEST(ScriptSceneCamera, PerspectiveTransformsMoveTheViewAndReadBackItsFocusPoint)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
var changed = false;
export function update() {
    if (!changed) {
        changed = true;
        thisScene.setCameraTransforms({eye:new Vec3(10,20,300),center:new Vec3(10,20,0),up:new Vec3(0,1,0)});
    }
    var c = thisScene.getCameraTransforms();
    return new Vec3(c.eye.x, c.center.y, c.eye.z);
}
)JS";
    auto document = SceneJson({}, {PlainImage(model, 1, "probe", {{"origin", ScriptedValue(source, "0 0 0")}})});
    document["general"]["orthogonalprojection"] = nullptr;
    document["camera"] = {{"eye", "0 0 300"}, {"center", "0 0 0"}, {"up", "0 1 0"}};
    package.SetProject();
    package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(3);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3>{10, 20, 300}));
    const auto* camera = scene.scene().activeCamera;
    ASSERT_NE(camera, nullptr);
    const auto projected = camera->GetViewProjectionMatrix() * wallpaper::linalg::Vector4d(10, 20, 0, 1);
    ASSERT_GT(std::abs(projected.w()), 1e-8);
    EXPECT_NEAR(projected.x() / projected.w(), 0, 1e-6);
    EXPECT_NEAR(projected.y() / projected.w(), 0, 1e-6);
}

TEST(ScriptSceneCamera, PartialZoomFramesTheCanvasAndReturnedVectorsAreDetached)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
var changed = false;
export function update() {
    if (!changed) { changed=true;thisScene.setCameraTransforms({zoom:2}); }
    var c=thisScene.getCameraTransforms(), eye=c.eye.x;
    c.eye.x += 50;
    var next=thisScene.getCameraTransforms();
    return new Vec3(next.zoom, next.eye.x === eye ? 1 : 0, next.center.z);
}
)JS";
    Publish(package, {PlainImage(model, 1, "probe", {{"origin", ScriptedValue(source, "0 0 0")}})});
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(3);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3>{2, 1, -1}));
    const auto& camera = *scene.scene().cameras.at("global");
    EXPECT_DOUBLE_EQ(camera.VisibleWidth(), 128);
    EXPECT_DOUBLE_EQ(camera.VisibleHeight(), 72);
}

TEST(ScriptSceneCamera, StartupLoadsTheAuthoredPoseAfterInitAndKeepsAnInitWrittenZoom)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
var duringInit;
export function init() {
    thisScene.setCameraTransforms({eye:new Vec3(50,0,300),center:new Vec3(50,0,0),zoom:2});
    duringInit=thisScene.getCameraTransforms().eye.x;
}
export function update() {
    var c=thisScene.getCameraTransforms();
    return new Vec3(duringInit,c.eye.x,c.zoom);
}
)JS";
    auto document=SceneJson({}, {PlainImage(model,1,"probe",{{"origin",ScriptedValue(source,"0 0 0")}})});
    document["general"]["orthogonalprojection"]=nullptr;
    document["camera"]={{"eye","0 0 300"},{"center","0 0 0"},{"up","0 1 0"}};
    package.SetProject();
    package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(3);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.Origin("probe"),(std::array<float,3>{50,0,2}));
    EXPECT_DOUBLE_EQ(scene.scene().activeCamera->GetPosition().x(),0);
}
