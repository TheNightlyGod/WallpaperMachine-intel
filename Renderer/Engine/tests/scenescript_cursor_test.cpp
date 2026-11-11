#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/SceneNode.h"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "WPShaderValueUpdater.hpp"
#include "Scripting/ScriptEngine.hpp"
#include "mdl_fixtures.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>
#include <bit>

namespace {
using namespace wallpaper;

struct CursorScene {
    std::unique_ptr<SceneRuntimeContext> runtime = CreateSceneRuntimeContext(
        SceneRuntimeBootstrap { .canvas_width = 256, .canvas_height = 144 });
    std::shared_ptr<SceneNode> target = std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode> first = std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode> second = std::make_shared<SceneNode>();

    CursorScene() {
        target->SetTranslate(linalg::Vector3f(128,72,0));
        runtime->RegisterNode("target",target.get());
        runtime->RegisterNodeSize("target",linalg::Vector2f(200,100));
        runtime->RegisterNode("first",first.get());
        runtime->RegisterNode("second",second.get());
    }

    void Enter() {
        runtime->Tick(1.0/60.0);
        runtime->SetCursorWorldPosition(linalg::Vector3f(128,72,0));
        runtime->SetCursorEnter(true);
        runtime->DispatchCursorFrameEvents(false);
    }
};

TEST(ScriptCursorEvent, AnImageCentreReportsPixelLocalCoordinatesAndNoPuppetName) {
    CursorScene scene;
    scene.runtime->RegisterNodeVisibility("target",scene.target.get(),
        ResolveBoolSetting(*scene.runtime,{{"value",true},{"script",R"JS(
export function cursorEnter(event) {
    if (!(event.localPosition instanceof Vec3)) throw new Error('local coordinate is not a Vec3');
    if ('hitBox' in event) throw new Error('plain image supplied a puppet hit box');
    thisScene.getLayer('first').origin = event.localPosition;
    thisScene.getLayer('second').origin = event.worldPosition;
}
)JS"}},"target"));
    scene.Enter();
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
    EXPECT_TRUE(scene.first->Translate().isApprox(linalg::Vector3f(100,50,0)));
    EXPECT_TRUE(scene.second->Translate().isApprox(linalg::Vector3f(128,72,0)));
}

TEST(ScriptCursorEvent, EventVectorsAreDetachedBetweenProgramsAndFromInput) {
    CursorScene scene;
    scene.runtime->RegisterSceneScript(R"JS(
export function cursorEnter(event) {
    if (!(event.localPosition instanceof Vec3)) throw new Error('missing local coordinate');
    event.localPosition.x = 900;
    event.worldPosition.y = 800;
}
)JS","target");
    scene.runtime->RegisterSceneScript(R"JS(
export function cursorEnter(event) {
    if (!(event.localPosition instanceof Vec3)) throw new Error('missing local coordinate');
    thisScene.getLayer('first').origin = event.localPosition;
    thisScene.getLayer('second').origin = input.cursorWorldPosition;
}
)JS","target");
    scene.Enter();
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
    EXPECT_TRUE(scene.first->Translate().isApprox(linalg::Vector3f(100,50,0)));
    EXPECT_TRUE(scene.second->Translate().isApprox(linalg::Vector3f(128,72,0)));
}
TEST(ScriptCursorEvent, ParentRotationAndNonuniformScaleKeepLocalPixels) {
    CursorScene scene;
    auto parent = std::make_shared<SceneNode>();
    parent->SetTranslate(linalg::Vector3f(128,72,0));
    parent->SetScale(linalg::Vector3f(2,0.5,1));
    parent->SetRotation(linalg::Vector3f(0,0,30));
    parent->AppendChild(scene.target);
    scene.runtime->RegisterNodeSize("target",linalg::Vector2f(160,80));
    scene.runtime->SetNodeTranslate("target",linalg::Vector3f(10,-12,0));
    scene.runtime->RegisterSceneScript(R"JS(
export function cursorEnter(event) { thisScene.getLayer('first').origin = event.localPosition; }
)JS","target");
    scene.Enter();
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
    EXPECT_NEAR(scene.first->Translate().x(),70,0.001);
    EXPECT_NEAR(scene.first->Translate().y(),28,0.001);
    EXPECT_FLOAT_EQ(scene.first->Translate().z(),0);
}

TEST(ScriptCursorEvent, MirroredRotatedImagesKeepTheirOwnCoordinateDirection) {
    CursorScene scene;
    scene.target->SetTranslate(linalg::Vector3f(108,62,0));
    scene.target->SetScale(linalg::Vector3f(-2,1.5,1));
    scene.target->SetRotation(linalg::Vector3f(0,0,20));
    scene.runtime->RegisterSceneScript(R"JS(
export function cursorEnter(event) { thisScene.getLayer('first').origin = event.localPosition; }
)JS","target");
    scene.Enter();
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
    // WE's mirrored/rotated control, at the same offset from the layer's centre.
    EXPECT_NEAR(scene.first->Translate().x(),91.354431,0.001);
    EXPECT_NEAR(scene.first->Translate().y(),59.452129,0.001);
}

TEST(ScriptCursorEvent, LeaveAndCapturedReleaseKeepCoordinatesOutsideTheImage) {
    CursorScene scene;
    scene.runtime->RegisterSceneScript(R"JS(
export function cursorDown(event) {}
export function cursorLeave(event) { thisScene.getLayer('first').origin = event.localPosition; }
export function cursorUp(event) { thisScene.getLayer('second').origin = event.localPosition; }
)JS","target");
    scene.Enter();
    scene.runtime->SetCursorButtons(1,1,0);
    scene.runtime->DispatchCursorFrameEvents(true);
    scene.runtime->SetCursorWorldPosition(linalg::Vector3f(400,72,0));
    scene.runtime->SetCursorButtons(0,0,1);
    scene.runtime->DispatchCursorFrameEvents(true);
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
    EXPECT_TRUE(scene.first->Translate().isApprox(linalg::Vector3f(372,50,0)));
    EXPECT_TRUE(scene.second->Translate().isApprox(linalg::Vector3f(372,50,0)));
}

TEST(ScriptCursorEvent, AnEngineListenerReceivesTheLayerCoordinateWithoutADeclaredHandler) {
    CursorScene scene;
    scene.runtime->RegisterSceneScript(R"JS(
engine.on('cursorEnter', function(event) { thisScene.getLayer('first').origin = event.localPosition; });
)JS","target");
    scene.Enter();
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
    EXPECT_TRUE(scene.first->Translate().isApprox(linalg::Vector3f(100,50,0)));
}

TEST(ScriptCursorEvent, TheReservedHitTestExportDoesNotOverrideGeometry) {
    CursorScene scene;
    scene.runtime->RegisterSceneScript(R"JS(
export function cursorHitTest(event) { throw new Error('WE does not dispatch this export'); }
export function cursorEnter(event) { thisScene.getLayer('first').origin = new Vec3(1,0,0); }
)JS","target");
    scene.Enter();
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
    EXPECT_FLOAT_EQ(scene.first->Translate().x(),1);
    scene.runtime->SetCursorWorldPosition(linalg::Vector3f(400,72,0));
    scene.runtime->DispatchCursorFrameEvents(true);
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
}

std::optional<WPPuppetLayer> CursorPuppet(
    std::array<uint32_t,2> order,
    WPPuppetLayer::CompositionKind kind = WPPuppetLayer::CompositionKind::ImagePuppet) {
    auto file = mdltest::mdlFile(23,{mdltest::MeshSpec{}});
    mdltest::SkeletonTail tail;
    tail.skin = true;
    tail.boneTable = true;
    mdltest::writeSkeleton(file,4,{{"Named"},{""}},tail);
    const auto order_at = file.size()-1-8;
    const auto boxes_at = order_at-1-2*76;
    for (std::size_t bone=0;bone<2;++bone) {
        for (std::size_t axis=0;axis<3;++axis) {
            const float extent = axis==0 ? 80.0f : axis==1 ? 40.0f : 1.0f;
            file.patchU32(boxes_at+bone*76+axis*4,std::bit_cast<uint32_t>(extent));
        }
        file.patchU32(order_at+bone*4,order[bone]);
    }
    file.stamp("MDLE",0);
    auto parsed = mdltest::parse(file);
    if (! parsed.ok || ! parsed.mdl.puppet) return std::nullopt;
    WPPuppetLayer layer(parsed.mdl.puppet,kind);
    layer.prepared({});
    layer.genFrame(0);
    return layer;
}

TEST(ScriptCursorEvent, PuppetButtonsUseTheLastMatchingBoneOrderAndAnUnnamedIndex) {
    struct Case { std::array<uint32_t,2> order; const char* expected; };
    for (const auto& item : {Case{{0,1},"string:1"},Case{{1,0},"string:Named"},
                             Case{{0,999},"string:1"}}) {
        SCOPED_TRACE(item.expected);
        CursorScene scene;
        auto puppet = CursorPuppet(item.order);
        ASSERT_TRUE(puppet.has_value());
        scene.runtime->RegisterPuppetLayer("target",*puppet);
        scene.runtime->RegisterSceneScript(R"JS(
export function cursorEnter(e) {
    if ('hitBox' in e) throw new Error('hover is not a bone hit query');
}
export function cursorDown(e) { thisScene.getLayer('first').name = typeof e.hitBox+':'+String(e.hitBox); }
)JS","target");
        scene.Enter();
        scene.runtime->SetCursorButtons(1,1,0);
        scene.runtime->DispatchCursorFrameEvents(true);
        EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
        EXPECT_EQ(scene.runtime->LayerAuthoredName("first"),item.expected);
    }
}

TEST(ScriptCursorEvent, BoneHitQueriesUseThePublishedPoseAndRespectBoxBounds) {
    CursorScene scene;
    auto puppet = CursorPuppet({0,1});
    ASSERT_TRUE(puppet.has_value());
    scene.runtime->RegisterPuppetLayer("target",*puppet);
    scene.runtime->RegisterSceneScript(R"JS(
var probe;
export function init() { probe=thisScene.getLayer('first'); }
export function cursorDown(e) { probe.name = typeof e.hitBox+':'+String(e.hitBox); }
)JS","target");
    scene.Enter();
    linalg::Affine3f away = linalg::Affine3f::Identity();
    away.translation().x() = 200;
    ASSERT_TRUE(puppet->setModelBone(1,away));
    scene.runtime->DispatchCursorDown();
    EXPECT_EQ(scene.runtime->LayerAuthoredName("first"),"string:Named");
    ASSERT_TRUE(puppet->setModelBone(0,away));
    scene.runtime->DispatchCursorDown();
    EXPECT_EQ(scene.runtime->LayerAuthoredName("first"),"undefined:undefined");
    EXPECT_FLOAT_EQ(puppet->modelBones()[0].translation().x(),200);
    EXPECT_FLOAT_EQ(puppet->modelBones()[1].translation().x(),200);
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
}

TEST(ScriptCursorEvent, AThreeDimensionalModelDoesNotPublishImagePuppetHitBoxNames) {
    CursorScene scene;
    auto puppet = CursorPuppet({0,1},WPPuppetLayer::CompositionKind::Model);
    ASSERT_TRUE(puppet.has_value());
    scene.runtime->RegisterPuppetLayer("target",*puppet);
    scene.runtime->RegisterSceneScript(R"JS(
export function cursorDown(e) { thisScene.getLayer('first').name = typeof e.hitBox+':'+String(e.hitBox); }
)JS","target");
    scene.Enter();
    scene.runtime->DispatchCursorDown();
    EXPECT_EQ(scene.runtime->LayerAuthoredName("first"),"undefined:undefined");
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
}

TEST(ScriptCursorEvent, CanvasParallaxChangesHitAndPixelCoordinatesWithoutPublishingADraw) {
    Scene drawn;
    CursorScene scene;
    drawn.ortho[0]=256;drawn.ortho[1]=144;
    drawn.frameTime=1.0/60.0;
    scene.runtime->AttachScene(&drawn);
    drawn.sceneGraph->AppendChild(scene.target);
    auto camera=std::make_shared<SceneCamera>(256,144,-1,1);
    auto camera_node=std::make_shared<SceneNode>();
    camera_node->SetTranslate(linalg::Vector3f(128,72,0));
    camera->AttatchNode(camera_node);camera->Update();
    drawn.cameras["global"]=camera;drawn.activeCamera=camera.get();
    auto updater=std::make_unique<WPShaderValueUpdater>(&drawn);
    auto* values=updater.get();drawn.shaderValueUpdater=std::move(updater);
    values->SetCameraParallax({.enable=true,.amount=.5f,.delay=0,.mouseinfluence=1,.canvas_scene=true});
    values->MouseInput(.5,.5);values->FrameBegin();
    WPShaderValueData data;data.parallaxDepth={2,2};
    values->SetNodeData(scene.target.get(),data);
    scene.target->SetParallaxDepth(2,2);
    scene.target->SetLastDrawParallaxOffset(77,88);
    scene.runtime->SetNodeTranslate("target",linalg::Vector3f(108,62,0));
    scene.runtime->RegisterSceneScript(R"JS(
export function cursorEnter(e) {
    thisScene.getLayer('first').origin=e.localPosition;
    thisScene.getLayer('second').visible=true;
}
export function cursorMove(e) { thisScene.getLayer('first').origin=e.localPosition; }
export function cursorLeave(e) { thisScene.getLayer('second').visible=false; }
)JS","target");
    scene.Enter();
    EXPECT_TRUE(scene.first->Translate().isApprox(linalg::Vector3f(140,30,0)));
    scene.runtime->SetCursorWorldPosition(linalg::Vector3f(200,72,0));
    values->MouseInput(200.0/256.0,.5);values->FrameBegin();
    scene.runtime->DispatchCursorFrameEvents(true);
    EXPECT_FALSE(scene.second->Visible());
    values->SetUserMouseParallax(false);
    scene.runtime->DispatchCursorFrameEvents(true);
    EXPECT_TRUE(scene.second->Visible());
    EXPECT_TRUE(scene.first->Translate().isApprox(linalg::Vector3f(192,40,0)));
    EXPECT_EQ(scene.target->LastDrawParallaxOffset(),(std::array<float,2>{77,88}));
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
}

void RegisterInitializedCursor(CursorScene& scene) {
    scene.runtime->RegisterNodeVisibility("target",scene.target.get(),
        ResolveBoolSetting(*scene.runtime,{{"value",true},{"script",R"JS(
var ready=false, probe, other, enters=0, downs=0, ups=0, clicks=0, updates=0;
function publish() {
    if (!ready) throw new Error('cursor preceded init');
    probe.origin=new Vec3(enters,downs,ups);
    other.origin=new Vec3(clicks,updates,0);
}
export function init(value) {
    probe=thisScene.getLayer('first'); other=thisScene.getLayer('second');
    ready=true; return value;
}
export function update(value) { updates++; publish(); return value; }
export function cursorEnter() { enters++; publish(); }
export function cursorDown() { downs++; publish(); }
export function cursorUp() { ups++; publish(); }
export function cursorClick() { clicks++; publish(); }
)JS"}},"target"));
}

TEST(ScriptCursorEvent, TheHostsFirstInputWaitsForInitWithoutLosingItsEnter) {
    CursorScene scene;
    RegisterInitializedCursor(scene);
    scene.runtime->SetCursorWorldPosition(linalg::Vector3f(128,72,0));
    scene.runtime->SetCursorEnter(true);
    // SceneWallpaper samples and dispatches input before calling Tick.
    const bool inside=scene.runtime->DispatchCursorFrameEvents(false);
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
    EXPECT_TRUE(scene.first->Translate().isZero());
    scene.runtime->Tick(1.0/60.0);
    EXPECT_TRUE(scene.first->Translate().isApprox(linalg::Vector3f(1,0,0)));
    scene.runtime->DispatchCursorFrameEvents(inside);
    EXPECT_TRUE(scene.first->Translate().isApprox(linalg::Vector3f(1,0,0)));
    EXPECT_DOUBLE_EQ(scene.runtime->hostContext().runtime_seconds,1.0/60.0);
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
}

TEST(ScriptCursorEvent, InitialPressAndReleaseEdgesAreDeliveredOnceAfterInit) {
    CursorScene scene;
    RegisterInitializedCursor(scene);
    scene.runtime->SetCursorWorldPosition(linalg::Vector3f(128,72,0));
    scene.runtime->SetCursorEnter(true);
    scene.runtime->SetCursorButtons(0,1,1);
    const bool inside=scene.runtime->DispatchCursorFrameEvents(false);
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
    scene.runtime->Tick(1.0/60.0);
    EXPECT_TRUE(scene.first->Translate().isApprox(linalg::Vector3f(1,1,1)));
    EXPECT_TRUE(scene.second->Translate().isApprox(linalg::Vector3f(1,1,0)));
    scene.runtime->SetCursorButtons(0,0,0);
    scene.runtime->DispatchCursorFrameEvents(inside);
    scene.runtime->Tick(1.0/60.0);
    EXPECT_TRUE(scene.first->Translate().isApprox(linalg::Vector3f(1,1,1)));
    EXPECT_TRUE(scene.second->Translate().isApprox(linalg::Vector3f(1,2,0)));
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
}

TEST(ScriptCursorEvent, AnUnstartedScriptAddedLaterDoesNotConsumeItsFirstEnter) {
    CursorScene scene;
    scene.runtime->Tick(1.0/60.0);
    RegisterInitializedCursor(scene);
    scene.runtime->SetCursorWorldPosition(linalg::Vector3f(128,72,0));
    scene.runtime->SetCursorEnter(true);
    const bool inside=scene.runtime->DispatchCursorFrameEvents(false);
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
    scene.runtime->Tick(1.0/60.0);
    scene.runtime->DispatchCursorFrameEvents(inside);
    EXPECT_TRUE(scene.first->Translate().isApprox(linalg::Vector3f(1,0,0)));
    EXPECT_EQ(scene.runtime->scriptErrorCount(),0u);
}

TEST(ScriptCursorEvent, ReplacingTheSceneDropsItsUnreadyInput) {
    CursorScene previous;
    RegisterInitializedCursor(previous);
    previous.runtime->SetCursorWorldPosition(linalg::Vector3f(128,72,0));
    previous.runtime->SetCursorEnter(true);
    previous.runtime->SetCursorButtons(0,1,1);
    previous.runtime->DispatchCursorFrameEvents(false);
    EXPECT_EQ(previous.runtime->scriptErrorCount(),0u);
    previous.runtime.reset();
    EXPECT_TRUE(previous.first->Translate().isZero());
    CursorScene next;
    RegisterInitializedCursor(next);
    next.runtime->SetCursorWorldPosition(linalg::Vector3f(128,72,0));
    next.runtime->SetCursorEnter(true);
    // The host cancels old-scene button edges rather than handing them to this scene.
    next.runtime->SetCursorButtons(0,0,0);
    next.runtime->DispatchCursorFrameEvents(false);
    next.runtime->Tick(1.0/60.0);
    EXPECT_TRUE(next.first->Translate().isApprox(linalg::Vector3f(1,0,0)));
    EXPECT_FLOAT_EQ(next.second->Translate().x(),0);
    EXPECT_EQ(next.runtime->scriptErrorCount(),0u);
}
} // namespace
