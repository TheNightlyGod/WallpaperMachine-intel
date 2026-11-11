#include "scenescript_scenes.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "WPShaderValueUpdater.hpp"

#include <gtest/gtest.h>

namespace {
using namespace we_test;
}

TEST(ScriptSceneGeneral, NativeMembersHaveTheirTypesAndDoNotAliasUserProperties)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
export function update(value) {
    var bools = ['bloom','clearenabled','camerafade','camerashake','cameraparallax',
                 'hdr','fogdistance','fogheight','transparentsorting','customsortorder'];
    var numbers = ['bloomstrength','bloomthreshold','fov','nearz','farz','camerashakespeed',
                   'camerashakeamplitude','camerashakeroughness','cameraparallaxamount',
                   'cameraparallaxdelay','cameraparallaxmouseinfluence','perspectiveoverridefov','zoom'];
    bools.forEach(function(k) { if (typeof thisScene[k] !== 'boolean') throw new Error(k+' is not boolean'); });
    numbers.forEach(function(k) { if (typeof thisScene[k] !== 'number') throw new Error(k+' is not number'); });
    ['clearcolor','ambientcolor','skylightcolor'].forEach(function(k) {
        if (!(thisScene[k] instanceof Vec3)) throw new Error(k+' is not Vec3');
    });
    return new Vec3(thisScene.bloom ? 1 : 0, thisScene.clearcolor.y, thisScene.bloomstrength);
}
)JS";
    auto document = SceneJson({}, { PlainImage(model, 1, "probe", {
        { "origin", ScriptedValue(source, "0 0 0") } }) });
    document["general"]["clearcolor"] = "0.1 0.2 0.3";
    document["general"]["bloomstrength"] = 3.5;
    package.SetProject({ { "bloom", BoolProperty(true) } });
    package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3> { 0, 0.2f, 3.5f }));
}

TEST(ScriptSceneGeneral, ClearMembersChangeTheSceneAndEqualWritesStayIdle)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
export function update(value) {
    thisScene.clearcolor = new Vec3(0.4,0.5,0.6);
    thisScene.clearenabled = false;
    return value;
}

)JS";
    Publish(package, { PlainImage(model, 1, "probe", { { "origin", ScriptedValue(source, "0 0 0") } }) });
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.scene().clearColor, (std::array<float, 3> { 0.4f, 0.5f, 0.6f }));
    EXPECT_FALSE(scene.scene().clearEnabled);
    (void)scene.runtime().ConsumeSceneGraphMutationFlag();
    scene.Tick(5);
    EXPECT_FALSE(scene.runtime().ConsumeSceneGraphMutationFlag());
}

TEST(ScriptSceneGeneral, SortingGettersKeepRawFlagsWhilePerspectiveDepthSortingWins)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
var step=0;
export function update() {
    ++step;
    thisScene.customsortorder = true;
    thisScene.transparentsorting = step === 1;
    return new Vec3(thisScene.transparentsorting ? 1 : 0, thisScene.customsortorder ? 1 : 0, 0);
}
)JS";
    auto document = SceneJson({}, { PlainImage(model, 1, "probe", {
        { "origin", ScriptedValue(source, "0 0 0") } }) });
    document["general"]["orthogonalprojection"] = nullptr;
    package.SetProject(); package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3> { 1, 1, 0 }));
    EXPECT_FALSE(scene.runtime().CustomSortOrder());
    EXPECT_TRUE(scene.scene().transparent_sorting);
    scene.Tick();
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3> { 0, 1, 0 }));
    EXPECT_TRUE(scene.runtime().CustomSortOrder());
    EXPECT_FALSE(scene.scene().transparent_sorting);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptSceneGeneral, PerspectiveZoomBindingUpdatesTheSharedValueWithoutChangingTheView)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
export function update() {
    if (engine.runtime > 0.04) thisScene.setCameraTransforms({zoom:3});
    return new Vec3(thisScene.zoom, thisScene.getCameraTransforms().zoom, 0);
}

)JS";
    auto document = SceneJson({}, { PlainImage(model, 1, "probe", {
        { "origin", ScriptedValue(source, "0 0 0") } }) });
    document["general"]["orthogonalprojection"] = nullptr;
    document["general"]["zoom"] = PropertyBinding("source_zoom", 1.0);
    document["camera"] = { { "eye", "0 0 300" }, { "center", "0 0 0" }, { "up", "0 1 0" } };
    package.SetProject({ { "source_zoom", SliderProperty(1, 0.1, 4) },
                         { "zoom", SliderProperty(99, 0, 100) } });
    package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    const auto camera = scene.scene().cameras.at("global_perspective");
    const auto before = camera->GetViewProjectionMatrix();
    ASSERT_TRUE(scene.SetProperty("source_zoom", 2));
    scene.Tick();
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3> { 2, 2, 0 }));
    EXPECT_TRUE(camera->GetViewProjectionMatrix().isApprox(before))
        << "the stored zoom does not resize or move a perspective camera";
    scene.Tick();
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3> { 3, 3, 0 }))
        << "camera API writes and general zoom share the value, not the user property named zoom";
    EXPECT_TRUE(camera->GetViewProjectionMatrix().isApprox(before));
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptSceneGeneral, LoadedZoomIsAvailableDuringInitBeforeTheCameraSnapshotStarts)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
var loaded, temporary;
export function init(value) {
    loaded = thisScene.zoom;
    temporary = thisScene.getCameraTransforms().zoom;
    return value;
}
export function update() { return new Vec3(loaded, temporary, thisScene.zoom); }
)JS";
    auto document = SceneJson({}, {PlainImage(model, 1, "probe", {
        {"origin", ScriptedValue(source, "0 0 0")}})});
    document["general"]["zoom"] = 2;
    package.SetProject(); package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3>{2,1,2}));
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptSceneGeneral, ProjectionShakeAndParallaxSettersReachTheirConsumersWithoutRebuilding)
{
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
var step=0;
export function update(value) {
    thisScene.fov=80; thisScene.nearz=1; thisScene.farz=500;
    thisScene.cameraparallax=true;
    thisScene.cameraparallaxamount=0.75;
    thisScene.cameraparallaxdelay=0.25;
    thisScene.cameraparallaxmouseinfluence=0.9;
    thisScene.camerashakeamplitude=2;
    thisScene.camerashakespeed=4;
    thisScene.camerashakeroughness=1.5;
    thisScene.camerashake=++step===1;
    return value;
}
)JS";
    auto document = SceneJson({}, {PlainImage(model, 1, "probe", {
        {"origin", ScriptedValue(source, "0 0 0")}})});
    document["general"]["orthogonalprojection"] = nullptr;
    package.SetProject(); package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.runtime().ConsumeSceneGraphMutationFlag();
    scene.Tick();
    const auto camera = scene.scene().cameras.at("global_perspective");
    EXPECT_DOUBLE_EQ(camera->Fov(), 80);
    EXPECT_DOUBLE_EQ(camera->NearClip(), 1);
    EXPECT_DOUBLE_EQ(camera->FarClip(), 500);
    EXPECT_GT(camera->ShakeOffset().norm(), 0);
    auto* updater = dynamic_cast<wallpaper::WPShaderValueUpdater*>(scene.scene().shaderValueUpdater.get());
    ASSERT_NE(updater, nullptr);
    const auto& parallax = updater->CameraParallax();
    EXPECT_TRUE(parallax.enable);
    EXPECT_FLOAT_EQ(parallax.amount, 0.75f);
    EXPECT_FLOAT_EQ(parallax.delay, 0.25f);
    EXPECT_FLOAT_EQ(parallax.mouseinfluence, 0.9f);
    EXPECT_FALSE(scene.runtime().ConsumeSceneGraphMutationFlag());
    scene.Tick();
    EXPECT_EQ(camera->ShakeOffset().norm(), 0);
    EXPECT_FALSE(scene.runtime().ConsumeSceneGraphMutationFlag());
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptSceneForces, NativeForceMembersKeepTheirTypesAndAuthoredVectors) {
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
export function update(value) {
    if (typeof thisScene.windenabled !== 'boolean' ||
        typeof thisScene.windstrength !== 'number' || typeof thisScene.gravitystrength !== 'number' ||
        !(thisScene.winddirection instanceof Vec3) || !(thisScene.gravitydirection instanceof Vec3))
        throw new Error('scene force member types');
    return new Vec3(thisScene.windenabled ? thisScene.windstrength : 0,
                    thisScene.gravitydirection.y, thisScene.gravitystrength);
}
)JS";
    auto document = SceneJson({}, { PlainImage(model,1,"probe",{{"origin",ScriptedValue(source,"0 0 0")}}) });
    document["general"]["windenabled"] = true;
    document["general"]["winddirection"] = "2 0 -3";
    document["general"]["windstrength"] = -2;
    document["general"]["gravitydirection"] = "0 -2 4";
    document["general"]["gravitystrength"] = 3;
    package.SetProject({{"gravitystrength",SliderProperty(99)}});
    package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.Origin("probe"),(std::array<float,3>{-2,-2,3}));
    const auto direction = scene.runtime().SceneGeneralValue("winddirection");
    ASSERT_TRUE(direction.has_value());
    EXPECT_EQ((*direction)[0],2);
    EXPECT_EQ((*direction)[2],-3);
}

TEST(ScriptSceneForces, ScriptWritesReachNativeStateAndRepeatedWritesDoNotRebuild) {
    ScenePackage package;
    const auto model = package.AddImageModel("plain");
    const auto source = R"JS(
export function update(value) {
    thisScene.windenabled=true;
    thisScene.winddirection=new Vec3(2,0,-3);
    thisScene.windstrength=-2;
    thisScene.gravitydirection=new Vec3(0,-2,4);
    thisScene.gravitystrength=3;
    return value;
}
)JS";
    Publish(package,{PlainImage(model,1,"probe",{{"origin",ScriptedValue(source,"0 0 0")}})});
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    (void)scene.runtime().ConsumeSceneGraphMutationFlag();
    scene.Tick(3);
    const auto wind = scene.runtime().SceneGeneralValue("windenabled");
    const auto gravity = scene.runtime().SceneGeneralValue("gravitystrength");
    ASSERT_TRUE(wind.has_value());
    ASSERT_TRUE(gravity.has_value());
    EXPECT_EQ((*wind)[0],1);
    EXPECT_EQ((*gravity)[0],3);
    EXPECT_FALSE(scene.runtime().ConsumeSceneGraphMutationFlag());
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptSceneForces, ParsedPropertyBindingsUpdateNativeForceValuesWithoutRebuilding) {
    ScenePackage package;
    const auto model=package.AddImageModel("plain");
    auto document=SceneJson({}, {PlainImage(model,1,"plain")});
    document["general"]["gravitystrength"]={{"value",0},{"user","strength"}};
    document["general"]["windenabled"]={{"value",false},{"user","wind"}};
    package.SetProject({{"strength",SliderProperty(0)}, {"wind",BoolProperty(false)}});
    package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    (void)scene.runtime().ConsumeSceneGraphMutationFlag();
    ASSERT_TRUE(scene.SetProperty("strength",2));
    ASSERT_TRUE(scene.SetProperty("wind",true));
    scene.Tick();
    const auto strength=scene.runtime().SceneGeneralValue("gravitystrength");
    const auto enabled=scene.runtime().SceneGeneralValue("windenabled");
    ASSERT_TRUE(strength);ASSERT_TRUE(enabled);
    EXPECT_EQ((*strength)[0],2);EXPECT_EQ((*enabled)[0],1);
    EXPECT_FALSE(scene.runtime().ConsumeSceneGraphMutationFlag());
}

TEST(ScriptSceneForces, StaticSceneWithNoForceConsumerDoesNotAcquireContinuousWork) {
    ScenePackage package;
    const auto model=package.AddImageModel("plain");
    auto document=SceneJson({}, {PlainImage(model,1,"plain")});
    document["general"]["windenabled"]=true;
    document["general"]["windstrength"]=1000;
    document["general"]["gravitystrength"]=1000;
    package.SetProject();package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_EQ(scene.runtime().DescribeTimeAdvancingWork(),0u);
    (void)scene.runtime().ConsumeSceneGraphMutationFlag();
    const float strength=12;
    ASSERT_TRUE(scene.runtime().SetSceneGeneralValue("windstrength",std::span(&strength,1)));
    EXPECT_EQ(scene.runtime().DescribeTimeAdvancingWork(),0u);
    EXPECT_FALSE(scene.runtime().ConsumeSceneGraphMutationFlag());
}
