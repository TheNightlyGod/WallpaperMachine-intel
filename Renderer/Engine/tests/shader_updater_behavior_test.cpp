// What the shader value updater hands a draw: pinned sprite frames, the matrices of a compose
// layer, audio-spectrum arrays, per-slot reflection and render-target sizes. Scenes are built
// in memory and the updater is called directly; no device or window is involved.

#include "Audio/include/Audio/AudioResponseService.h"
#include "Runtime/SceneRuntimeContext.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scene/include/Scene/SceneCamera.h"
#include "Scene/include/Scene/SceneMesh.h"
#include "Scene/include/Scene/SceneRenderTarget.h"
#include "Scripting/ScriptEngine.hpp"
#include "SpecTexs.hpp"
#include "SpriteAnimation.hpp"
#include "WPPuppet.hpp"
#include "WPShaderValueUpdater.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <cstring>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

// Declared in no header: the audio library defines it for test builds only.
namespace wallpaper::audio
{
void SetAudioSpectrumSnapshotForTesting(const AudioSpectrumSnapshot& snapshot);
}

namespace wallpaper
{
namespace
{

using Lanes = std::vector<float>;
using Captured = std::map<std::string, Lanes>;
using linalg::Vector3f;

constexpr const char* kMvp = "g_ModelViewProjectionMatrix";
constexpr const char* kModel = "g_ModelMatrix";
constexpr const char* kTime = "g_Time";

Lanes LanesOf(const ShaderValue& value)
{
    Lanes lanes(value.size());
    for (std::size_t i = 0; i < lanes.size(); ++i) lanes[i] = value[i];
    return lanes;
}

// Collects the last value written for every uniform name.
UpdateUniformOp Collect(Captured& into)
{
    return [&into](std::string_view name, const ShaderValue& value) { into[std::string(name)] = LanesOf(value); };
}

ExistsUniformOp Declares(std::vector<std::string> names)
{
    return [names = std::move(names)](std::string_view name) {
        for (const auto& declared : names) {
            if (declared == name) return true;
        }
        return false;
    };
}

// A screen camera, an owning scene and one node with a mesh of `materials` default materials.
struct Stage {
    Scene                       scene;
    std::unique_ptr<SceneCamera> screen = std::make_unique<SceneCamera>(1920, 1080, 0.01f, 1000.0f);
    std::shared_ptr<SceneNode>  node = std::make_shared<SceneNode>();
    std::shared_ptr<SceneMesh>  mesh = std::make_shared<SceneMesh>();
    WPShaderValueUpdater        updater { &scene };
    sprite_map_t                sprites;

    explicit Stage(int materials = 2, bool withRuntime = true)
    {
        scene.activeCamera = screen.get();
        if (withRuntime) {
            scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
            scene.runtime->AttachScene(&scene);
        }
        for (int i = 0; i < materials; ++i) mesh->AddMaterial(SceneMaterial {});
        node->AddMesh(mesh);
        scene.sceneGraph->AppendChild(node);
    }
    ~Stage() { scene.activeCamera = nullptr; }

    Captured Update(uint32_t slot)
    {
        Captured out;
        updater.UpdateUniforms(node.get(), slot, sprites, Collect(out));
        return out;
    }
};

// Light arrays are shared by draws only after simulation, for the duration of one backend draw.
struct LitStage : Stage {
    explicit LitStage() {
        scene.light_config.point = 1;
        scene.light_config.spot = 1;
        scene.light_config.tube = 1;
        scene.light_config.directional = 1;
        for (const auto type : { SceneLightType::Legacy, SceneLightType::Point,
                                 SceneLightType::Point, SceneLightType::Spot,
                                 SceneLightType::Tube, SceneLightType::Directional }) {
            auto light = std::make_unique<SceneLight>(type, Vector3f(1.0f, 0.5f, 0.25f), 10.0f, 2.0f);
            auto place = std::make_shared<SceneNode>();
            place->SetTranslate(Vector3f(0.0f, 0.0f, static_cast<float>(scene.lights.size()) * 10.0f));
            light->setNode(place);
            scene.sceneGraph->AppendChild(place);
            scene.lights.push_back(std::move(light));
        }
        for (uint32_t slot = 0; slot < 2; ++slot)
            updater.InitUniforms(node.get(), slot, Declares({
                "g_LightsPosition", "g_LightsColorPremultiplied", "g_LightsColorRadius",
                "g_LPoint_Origin", "g_LSpot_Origin", "g_LTube_OriginA", "g_LDirectional_Direction" }));
    }
};

void ExpectSameLightBytes(const Captured& actual, const Captured& expected) {
    ASSERT_EQ(actual.size(), expected.size());
    for (const auto& [name, bytes] : expected) {
        const auto found = actual.find(name);
        ASSERT_NE(found, actual.end()) << name;
        ASSERT_EQ(found->second.size(), bytes.size()) << name;
        EXPECT_EQ(std::memcmp(found->second.data(), bytes.data(), bytes.size() * sizeof(float)), 0)
            << name;
    }
}

TEST(ShaderUpdaterLights, OneDrawPacksEachLightFamilyOnceForManyPassesAndReuseKeys) {
    LitStage f;
    const auto expected = f.Update(0);
    const auto expected_hash = f.updater.LightStateHash(f.node.get(), 0);
    const auto uncached_before = f.updater.LightPackingCountsForTests();
    for (unsigned pass = 0; pass < 20; ++pass) {
        ExpectSameLightBytes(f.Update(pass % 2), expected);
        EXPECT_EQ(f.updater.LightStateHash(f.node.get(), pass % 2), expected_hash);
    }
    const auto before = f.updater.LightPackingCountsForTests();
    EXPECT_EQ(before[0] - uncached_before[0], 40u);
    EXPECT_EQ(before[1] - uncached_before[1], 40u);
    f.updater.BeginDraw();
    for (unsigned pass = 0; pass < 20; ++pass) {
        ExpectSameLightBytes(f.Update(pass % 2), expected);
        EXPECT_EQ(f.updater.LightStateHash(f.node.get(), pass % 2), expected_hash);
    }
    f.updater.EndDraw();
    const auto after = f.updater.LightPackingCountsForTests();
    EXPECT_EQ(after[0] - before[0], 1u);
    EXPECT_EQ(after[1] - before[1], 1u);
}

TEST(ShaderUpdaterLights, NextDrawSeesLightAndParentChangesAndDirectCallsAlwaysReadLiveState) {
    LitStage f;
    f.updater.BeginDraw();
    const auto old = f.Update(0);
    const auto old_hash = f.updater.LightStateHash(f.node.get(), 0);
    f.updater.EndDraw();
    f.scene.sceneGraph->SetTranslate(Vector3f(8.0f, 3.0f, -100.0f));
    f.scene.lights[0]->setIntensity(7.0f);
    f.scene.lights[1]->setColor(Vector3f(0.25f, 0.0f, 0.75f));
    f.scene.lights[3]->node()->SetVisible(false);
    const auto expected = f.Update(0);
    EXPECT_NE(old, expected);
    const auto expected_hash = f.updater.LightStateHash(f.node.get(), 0);
    EXPECT_NE(old_hash, expected_hash);
    f.updater.BeginDraw();
    ExpectSameLightBytes(f.Update(1), expected);
    EXPECT_EQ(f.updater.LightStateHash(f.node.get(), 1), expected_hash);
    f.updater.EndDraw();
    f.scene.lights[2]->setIntensity(0.125f);
    EXPECT_NE(f.Update(1), expected) << "without a draw scope, reads must not retain old light values";
}

TEST(ShaderUpdaterLights, ReflectionCameraKeepsItsOwnLightOrderingInsideOneDraw) {
    LitStage f;
    SceneCamera reflected(1920, 1080, 0.01f, 1000.0f);
    auto reflected_node = std::make_shared<SceneNode>();
    reflected_node->SetRotation(Vector3f(0.0f, static_cast<float>(std::acos(-1.0)), 0.0f));
    reflected.AttatchNode(reflected_node);
    const auto ordinary = f.Update(0);
    f.scene.activeCamera = &reflected;
    const auto reflection = f.Update(0);
    ASSERT_NE(ordinary.at("g_LPoint_Origin"), reflection.at("g_LPoint_Origin"));
    const auto reflection_hash = f.updater.LightStateHash(f.node.get(), 0);
    f.updater.BeginDraw();
    ExpectSameLightBytes(f.Update(0), reflection);
    EXPECT_EQ(f.updater.LightStateHash(f.node.get(), 0), reflection_hash);
    f.scene.activeCamera = f.screen.get();
    ExpectSameLightBytes(f.Update(1), ordinary);
    f.scene.activeCamera = &reflected;
    ExpectSameLightBytes(f.Update(1), reflection);
    f.updater.EndDraw();
    f.scene.activeCamera = f.screen.get();
}

TEST(ShaderUpdaterLights, DrawsWithoutLightingDoNoLightPacking) {
    LitStage f;
    f.updater.InitUniforms(f.node.get(), 0, Declares({kTime}));
    f.updater.BeginDraw();
    f.Update(0);
    EXPECT_EQ(f.updater.LightStateHash(f.node.get(), 0), 0u);
    f.updater.EndDraw();
    EXPECT_EQ(f.updater.LightPackingCountsForTests(), (std::array<uint64_t, 2>{0, 0}));
}

// ---- texture animation -------------------------------------------------------------------------

TEST(ShaderUpdaterFrames, AScriptPinsATextureAnimationFrame)
{
    Scene scene;
    scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap { .canvas_width = 1920, .canvas_height = 1080 });
    auto& rt = *scene.runtime;
    rt.AttachScene(&scene);
    SceneNode node;
    rt.RegisterNode("sheet", &node);

    const char* source = R"js(
        export function update(value) {
            var animation = thisLayer.getTextureAnimation();
            animation.setFrame(1);
            return animation.getFrame();
        }
    )js";
    ScriptHostContext host {};
    auto program = rt.scriptEngine().CreatePropertyScriptProgram(&rt, source, "sheet", {}, DynamicValue(0.0f), host);
    ASSERT_NE(program, nullptr);
    ASSERT_TRUE(program->Valid());

    for (int frame = 0; frame < 120; ++frame) {
        host.runtime_seconds = frame / 60.0;
        const auto result = program->Evaluate(host, DynamicValue(0.0f));
        ASSERT_NE(result, nullptr) << "frame " << frame;
        ASSERT_FLOAT_EQ(result->getFloat(), 1.0f) << "frame " << frame;
    }
    EXPECT_TRUE(node.SheetDetached());
    EXPECT_EQ(rt.NodeTextureAnimationFrame("sheet"), 1.0);
    EXPECT_EQ(rt.scriptErrorCount(), 0u);

    // Pinning frame zero reads back zero.
    SceneNode zeroNode;
    rt.RegisterNode("zero", &zeroNode);
    auto zero = rt.scriptEngine().CreatePropertyScriptProgram(
        &rt, "export function update(value) { var a = thisLayer.getTextureAnimation(); a.setFrame(0); return a.getFrame(); }",
        "zero", {}, DynamicValue(1.0f), host);
    ASSERT_NE(zero, nullptr);
    const auto result = zero->Evaluate(host, DynamicValue(1.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 0.0f);
}

TEST(ShaderUpdaterFrames, ASpriteTableShowsACommandedFrameAndClampsTheIndex)
{
    SpriteAnimation animation;
    animation.AppendFrame(SpriteFrame { .imageId = 0, .frametime = 0.1f });
    animation.AppendFrame(SpriteFrame { .imageId = 1, .frametime = 0.1f });

    animation.Command(1, false, 1);
    EXPECT_EQ(animation.GetCurFrame().imageId, 1);
    animation.Command(2, false, -1);
    EXPECT_EQ(animation.GetCurFrame().imageId, 0) << "below the first frame shows the first";
    animation.Command(3, false, 100);
    EXPECT_EQ(animation.GetCurFrame().imageId, 1) << "beyond the table shows the last";
    animation.Command(3, false, 0);
    EXPECT_EQ(animation.GetCurFrame().imageId, 1) << "a command is applied once";

    // After a frame command the layer's own frame runs a full frame from there.
    animation.Command(4, false, 0);
    EXPECT_EQ(animation.Present(0.05, true, 0.05).imageId, 0);
    EXPECT_EQ(animation.Present(0.1, true, 0.1).imageId, 1);
}

// ---- compose layer matrices --------------------------------------------------------------------

// Applies a column-major 4x4 to a point.
std::vector<float> Transform(const Lanes& m, float x, float y, float z)
{
    std::vector<float> out(4);
    const float in[4] = { x, y, z, 1.0f };
    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) out[row] += m[col * 4 + row] * in[col];
    }
    return out;
}

struct ComposeFixture {
    Scene                        scene;
    std::unique_ptr<SceneCamera> screen = std::make_unique<SceneCamera>(640, 360, -1.0f, 1.0f);
    std::shared_ptr<SceneNode>   parent = std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode>   child = std::make_shared<SceneNode>();
    std::shared_ptr<SceneMesh>   mesh = std::make_shared<SceneMesh>();
    WPShaderValueUpdater         updater { &scene };
    sprite_map_t                 sprites;

    explicit ComposeFixture(const char* materialName = "composelayer")
    {
        scene.activeCamera = screen.get();
        scene.cameras["effect-test"] = std::make_shared<SceneCamera>(64, 32, -1.0f, 1.0f);
        parent->SetTranslate({ 200.0f, 100.0f, 0.0f });
        child->SetTranslate({ 10.0f, 20.0f, 0.0f });
        child->SetScale({ -0.3f, 0.2f, 1.0f });
        child->SetCamera("effect-test");
        child->SetRenderTransformOverride(linalg::Matrix4d::Identity());
        SceneMaterial material;
        material.name = materialName;
        mesh->AddMaterial(std::move(material));
        child->AddMesh(mesh);
        parent->AppendChild(child);
        scene.sceneGraph->AppendChild(parent);
        updater.InitUniforms(child.get(), Declares({ kMvp }));
    }
    ~ComposeFixture() { scene.activeCamera = nullptr; }

    Lanes Mvp()
    {
        Captured out;
        updater.UpdateUniforms(child.get(), sprites, Collect(out));
        EXPECT_TRUE(out.contains(kMvp));
        return out[kMvp];
    }

    // The matrix a compose layer should be given: the screen camera and the node's full model.
    Lanes Expected()
    {
        child->UpdateTrans();
        return LanesOf(ShaderValue::fromMatrix(
            linalg::Matrix4d(screen->GetViewProjectionMatrix() * child->ModelTrans())));
    }
};

void ExpectClose(const Lanes& actual, const Lanes& expected, float tolerance)
{
    ASSERT_EQ(actual.size(), expected.size());
    for (std::size_t i = 0; i < actual.size(); ++i) EXPECT_NEAR(actual[i], expected[i], tolerance) << "lane " << i;
}

TEST(ShaderUpdaterMatrices, AComposeLayerReadsTheScreenThroughTheScreenCameraAndItsFullModelMatrix)
{
    ComposeFixture f;
    const Lanes first = f.Mvp();
    ExpectClose(first, f.Expected(), 1e-5f);

    // World (210, 120): clip x 210/320, y 120/180.
    auto origin = Transform(first, 0, 0, 0);
    EXPECT_NEAR(origin[0], 0.65625f, 1e-4f);
    EXPECT_NEAR(origin[1], 0.666667f, 1e-4f);
    EXPECT_NEAR(origin[2], 0.5f, 1e-4f);
    EXPECT_NEAR(origin[3], 1.0f, 1e-4f);
    // The child's scale puts model (100, 50) at world (180, 130).
    auto offset = Transform(first, 100, 50, 0);
    EXPECT_NEAR(offset[0], 0.5625f, 1e-4f);
    EXPECT_NEAR(offset[1], 0.722222f, 1e-4f);

    // The matrix is rebuilt on every update: move the parent and the screen camera.
    f.parent->SetTranslate({ 260.0f, 80.0f, 0.0f });
    auto cameraNode = std::make_shared<SceneNode>();
    cameraNode->SetTranslate({ 30.0f, 0.0f, 0.0f });
    f.screen->AttatchNode(cameraNode);
    const Lanes moved = f.Mvp();
    ExpectClose(moved, f.Expected(), 1e-5f);
    auto movedOrigin = Transform(moved, 0, 0, 0);
    EXPECT_NEAR(movedOrigin[0], 0.75f, 1e-4f);
    EXPECT_NEAR(movedOrigin[1], 0.555556f, 1e-4f);

    // A layer-local draw camera changes nothing for a compose layer.
    auto local = std::make_shared<SceneCamera>(64, 32, -1.0f, 1.0f);
    local->SetLayerLocal(true);
    f.scene.cameras["effect-test"] = local;
    const Lanes withLocalCamera = f.Mvp();
    ExpectClose(withLocalCamera, f.Expected(), 1e-5f);
    auto localOrigin = Transform(withLocalCamera, 0, 0, 0);
    EXPECT_NEAR(localOrigin[0], 0.75f, 1e-4f);
    EXPECT_NEAR(localOrigin[1], 0.555556f, 1e-4f);
}

TEST(ShaderUpdaterMatrices, AnotherMaterialNameUsesTheNodesOwnCameraAndRenderTransform)
{
    ComposeFixture compose;
    const Lanes composed = compose.Mvp();
    ComposeFixture plain("plain");
    const Lanes ordinary = plain.Mvp();
    ASSERT_EQ(composed.size(), ordinary.size());
    float widest = 0.0f;
    for (std::size_t i = 0; i < composed.size(); ++i) widest = std::max(widest, std::abs(composed[i] - ordinary[i]));
    EXPECT_GT(widest, 1e-5f);
}

TEST(ShaderUpdaterMatrices, DisplayFramingKeepsComposeSamplingAndItsInverseTogether)
{
    ComposeFixture f;
    f.scene.cameras.at("effect-test")->SetLayerLocal(true);
    f.scene.display_framed = true;
    f.scene.display_clip = {1.5, 2.0, 0.2, -0.3};
    f.scene.display_clip_generation = 1;
    f.updater.InitUniforms(f.child.get(), Declares({kMvp, std::string(G_MVPI)}));
    const auto authored = f.screen->GetViewProjectionMatrix();
    const auto verify = [&] {
        Captured out;
        f.updater.UpdateUniforms(f.child.get(), f.sprites, Collect(out));
        ASSERT_TRUE(out.contains(kMvp));
        ASSERT_TRUE(out.contains(std::string(G_MVPI)));
        const auto base = Transform(f.Expected(), 0, 0, 0);
        const auto actual = Transform(out.at(kMvp), 0, 0, 0);
        EXPECT_NEAR(actual[0], base[0]*1.5 + f.scene.display_clip[2]*base[3], 1e-5);
        EXPECT_NEAR(actual[1], base[1]*2.0 - 0.3*base[3], 1e-5);
        const linalg::Matrix4f forward = linalg::Map<const linalg::Matrix4f>(out.at(kMvp).data());
        const linalg::Matrix4f inverse = linalg::Map<const linalg::Matrix4f>(out.at(std::string(G_MVPI)).data());
        EXPECT_LT((forward*inverse-linalg::Matrix4f::Identity()).norm(),1e-4);
    };
    verify();
    EXPECT_TRUE(f.screen->GetViewProjectionMatrix().isApprox(authored));
    f.scene.display_clip[2] = -0.25;
    ++f.scene.display_clip_generation;
    verify();
    auto eye = std::make_shared<SceneNode>();
    eye->SetTranslate({30,0,0});
    f.screen->AttatchNode(eye);
    verify();
}

TEST(ShaderUpdaterMatrices, LocalGeometryStaysLocalWhileEffectScreenCoordinatesAreFramed)
{
    ComposeFixture f("plain");
    auto local = f.scene.cameras.at("effect-test");
    local->SetLayerLocal(true);
    f.scene.cameras["effect"] = local;
    f.child->SetCamera("effect");
    f.scene.display_framed = true;
    f.scene.display_clip = {1.5,2.0,0.2,-0.3};
    f.scene.display_clip_generation = 1;
    WPShaderValueData data;
    data.effect_owner = f.child.get();
    data.effect_extent = {64,32};
    f.updater.SetNodeData(f.child.get(),data);
    f.updater.InitUniforms(f.child.get(),Declares({kMvp,std::string(G_EFFECTMVP),
        std::string(G_EFFECTMVPI),std::string(G_ETVP),std::string(G_ETVPI)}));
    Captured out;
    f.updater.UpdateUniforms(f.child.get(),f.sprites,Collect(out));
    ExpectClose(out.at(kMvp),LanesOf(ShaderValue::fromMatrix(local->GetViewProjectionMatrix())),1e-6f);
    const auto base = Transform(f.Expected(),0,0,0);
    for (const auto name : {G_EFFECTMVP,G_ETVP}) {
        const auto actual = Transform(out.at(std::string(name)),0,0,0);
        EXPECT_NEAR(actual[0],base[0]*1.5+0.2*base[3],1e-5);
        EXPECT_NEAR(actual[1],base[1]*2.0-0.3*base[3],1e-5);
    }
    for (const auto pair : {std::pair{G_EFFECTMVP,G_EFFECTMVPI},std::pair{G_ETVP,G_ETVPI}}) {
        const linalg::Matrix4f forward=linalg::Map<const linalg::Matrix4f>(out.at(std::string(pair.first)).data());
        const linalg::Matrix4f inverse=linalg::Map<const linalg::Matrix4f>(out.at(std::string(pair.second)).data());
        EXPECT_LT((forward*inverse-linalg::Matrix4f::Identity()).norm(),1e-4);
    }
}

TEST(ShaderUpdaterMatrices, ExplicitShadowProjectionKeepsItsOwnViewport)
{
    Stage f(1,false);
    f.scene.display_framed=true;
    f.scene.display_clip={2,3,0.4,-0.6};
    f.scene.display_clip_generation=1;
    auto shadow=linalg::Matrix4d::Identity().eval();
    shadow(0,0)=0.25;shadow(1,3)=0.75;
    f.screen->SetViewProjectionOverride(shadow);
    f.updater.InitUniforms(f.node.get(),Declares({std::string(G_VP)}));
    ExpectClose(f.Update(0).at(std::string(G_VP)),LanesOf(ShaderValue::fromMatrix(shadow)),1e-6f);
}

// A `PRELIGHTING` pass lights through the Alt matrices: the draw's world model,
// its normal matrix (normalised axes, vec4 columns) and its view projection.
TEST(ShaderUpdaterMatrices, AltMatricesAreTheDrawsWorldNormalAndViewProjection)
{
    Stage stage(1, false);
    stage.node->SetTranslate(Vector3f(10.0f, 20.0f, 30.0f));
    stage.node->SetRotation(Vector3f(0.0f, 0.0f, static_cast<float>(M_PI / 2.0)));
    stage.node->SetScale(Vector3f(2.0f, 2.0f, 2.0f));
    stage.updater.InitUniforms(stage.node.get(),
                               Declares({ "g_AltModelMatrix", "g_AltNormalModelMatrix", "g_AltViewProjectionMatrix" }));
    const Captured out = stage.Update(0);
    ASSERT_TRUE(out.contains("g_AltNormalModelMatrix"));
    ASSERT_TRUE(out.contains("g_AltViewProjectionMatrix"));
    const Lanes& normal = out.at("g_AltNormalModelMatrix");
    ASSERT_EQ(normal.size(), 12u);
    const float expected[12] = { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0 };
    for (std::size_t i = 0; i < 12; ++i) {
        if (i % 4 == 3) continue;
        EXPECT_NEAR(normal[i], expected[i], 1e-5f) << i;
    }
    const Lanes vp = LanesOf(ShaderValue::fromMatrix(stage.screen->GetViewProjectionMatrix()));
    EXPECT_EQ(out.at("g_AltViewProjectionMatrix"), vp);
}

// ---- audio spectrum ---------------------------------------------------------------------------

// Resets the audio service when a test ends, however it ends.
struct AudioServiceGuard {
    ~AudioServiceGuard() { audio::ResetAudioResponseServiceForTesting(); }
};

struct SpectrumOffsets {
    float left16, right16, left32, right32, left64, right64;
};

audio::AudioSpectrumSnapshot SnapshotWith(const SpectrumOffsets& o)
{
    audio::AudioSpectrumSnapshot snapshot;
    snapshot.generation = 17;
    for (std::size_t i = 0; i < 16; ++i) {
        snapshot.left16[i] = o.left16 + i / 128.0f;
        snapshot.right16[i] = o.right16 + i / 128.0f;
    }
    for (std::size_t i = 0; i < 32; ++i) {
        snapshot.left32[i] = o.left32 + i / 128.0f;
        snapshot.right32[i] = o.right32 + i / 128.0f;
    }
    for (std::size_t i = 0; i < 64; ++i) {
        snapshot.left64[i] = o.left64 + i / 128.0f;
        snapshot.right64[i] = o.right64 + i / 128.0f;
    }
    return snapshot;
}

const std::vector<std::string>& SpectrumNames()
{
    static const std::vector<std::string> names = {
        "g_AudioSpectrum16Left", "g_AudioSpectrum16Right", "g_AudioSpectrum32Left",
        "g_AudioSpectrum32Right", "g_AudioSpectrum64Left", "g_AudioSpectrum64Right",
    };
    return names;
}

// Expects six vec4 arrays that hold `snapshot` (or silence when `expected` is null), one band per element.
void ExpectSpectrum(const Captured& out, const audio::AudioSpectrumSnapshot* expected)
{
    ASSERT_EQ(out.size(), 6u);
    auto check = [&](const char* name, const float* bands, std::size_t count) {
        ASSERT_TRUE(out.contains(name)) << name;
        const Lanes& lanes = out.at(name);
        ASSERT_EQ(lanes.size(), count * 4) << name;
        for (std::size_t i = 0; i < count; ++i) {
            EXPECT_FLOAT_EQ(lanes[4 * i], expected != nullptr ? bands[i] : 0.0f) << name << " band " << i;
            for (std::size_t pad = 1; pad < 4; ++pad) EXPECT_FLOAT_EQ(lanes[4 * i + pad], 0.0f) << name << " band " << i;
        }
    };
    const audio::AudioSpectrumSnapshot& s = expected != nullptr ? *expected : audio::AudioSpectrumSnapshot {};
    check("g_AudioSpectrum16Left", s.left16.data(), 16);
    check("g_AudioSpectrum16Right", s.right16.data(), 16);
    check("g_AudioSpectrum32Left", s.left32.data(), 32);
    check("g_AudioSpectrum32Right", s.right32.data(), 32);
    check("g_AudioSpectrum64Left", s.left64.data(), 64);
    check("g_AudioSpectrum64Right", s.right64.data(), 64);
}

TEST(ShaderUpdaterAudio, SpectrumArraysAreVec4ElementsAreLiveAndAreGatedOnTheRuntime)
{
    AudioServiceGuard guard;
    const auto positive = SnapshotWith({ 0.125f, 0.25f, 0.375f, 0.5f, 0.625f, 0.75f });
    const auto negative = SnapshotWith({ -0.125f, -0.25f, -0.375f, -0.5f, -0.625f, -0.75f });
    audio::SetAudioSpectrumSnapshotForTesting(positive);

    Stage f;
    f.scene.runtime->SetAudioResponseEnabled(true);
    f.updater.InitUniforms(f.node.get(), 0, Declares(SpectrumNames()));
    f.updater.InitUniforms(f.node.get(), 1, Declares(SpectrumNames()));

    // S1: the six arrays, one band at the start of each vec4.
    ExpectSpectrum(f.Update(0), &positive);

    // S2: a replaced snapshot (same generation) is seen at once, through the other slot.
    audio::SetAudioSpectrumSnapshotForTesting(negative);
    ExpectSpectrum(f.Update(1), &negative);

    // S3: initialising a slot again does not change what it reads.
    f.updater.InitUniforms(f.node.get(), 0, Declares(SpectrumNames()));
    ExpectSpectrum(f.Update(0), &negative);

    // S4: with the response disabled the arrays keep their size and carry silence.
    f.scene.runtime->SetAudioResponseEnabled(false);
    ExpectSpectrum(f.Update(1), nullptr);

    // S5: an all-zero snapshot reads as silence.
    f.scene.runtime->SetAudioResponseEnabled(true);
    audio::SetAudioSpectrumSnapshotForTesting(audio::AudioSpectrumSnapshot {});
    ExpectSpectrum(f.Update(0), nullptr);

    // S6: without a runtime there is no audio.
    audio::SetAudioSpectrumSnapshotForTesting(negative);
    f.scene.runtime.reset();
    ExpectSpectrum(f.Update(1), nullptr);
}

TEST(ShaderUpdaterAudio, EachBandLandsInItsOwnVec4)
{
    AudioServiceGuard guard;
    audio::AudioSpectrumSnapshot snapshot;
    snapshot.generation = 3;
    snapshot.left16[3] = 0.9f;
    audio::SetAudioSpectrumSnapshotForTesting(snapshot);

    Stage f;
    f.scene.runtime->SetAudioResponseEnabled(true);
    f.updater.InitUniforms(f.node.get(), 0, Declares({ "g_AudioSpectrum16Left" }));
    const auto out = f.Update(0);
    ASSERT_TRUE(out.contains("g_AudioSpectrum16Left"));
    const Lanes& lanes = out.at("g_AudioSpectrum16Left");
    ASSERT_EQ(lanes.size(), 64u);
    EXPECT_FLOAT_EQ(lanes[12], 0.9f);
    EXPECT_FLOAT_EQ(lanes[13], 0.0f);
    EXPECT_FLOAT_EQ(lanes[14], 0.0f);
    EXPECT_FLOAT_EQ(lanes[15], 0.0f);
    EXPECT_FLOAT_EQ(lanes[0], 0.0f);
}

TEST(ShaderUpdaterAudio, ReadingAudioInOneSlotDoesNotChangeAnotherSlotsUniforms)
{
    AudioServiceGuard guard;
    audio::AudioSpectrumSnapshot snapshot;
    snapshot.generation = 5;
    snapshot.left64.fill(0.5f);
    audio::SetAudioSpectrumSnapshotForTesting(snapshot);

    Stage f;
    f.scene.elapsingTime = 2.0;
    f.scene.runtime->SetAudioResponseEnabled(true);
    f.updater.InitUniforms(f.node.get(), 0, Declares({ kTime }));
    f.updater.InitUniforms(f.node.get(), 0, Declares({ kTime }));
    EXPECT_FALSE(f.scene.runtime->AudioResponseActive()) << "nothing reads audio yet";
    EXPECT_FALSE(f.scene.runtime->SceneRequiresAudioResponse());

    auto first = f.Update(0);
    ASSERT_EQ(first.size(), 1u);
    ASSERT_TRUE(first.contains(kTime));
    ASSERT_EQ(first[kTime].size(), 1u);
    EXPECT_FLOAT_EQ(first[kTime][0], 2.0f);

    f.updater.InitUniforms(f.node.get(), 1, Declares({ "g_AudioSpectrum64Left" }));
    EXPECT_TRUE(f.scene.runtime->SceneRequiresAudioResponse());
    EXPECT_TRUE(f.scene.runtime->AudioResponseActive());

    auto again = f.Update(0);
    ASSERT_EQ(again.size(), 1u);
    EXPECT_TRUE(again.contains(kTime));

    auto second = f.Update(1);
    ASSERT_EQ(second.size(), 1u);
    ASSERT_TRUE(second.contains("g_AudioSpectrum64Left"));
    const Lanes& lanes = second["g_AudioSpectrum64Left"];
    ASSERT_EQ(lanes.size(), 256u);
    for (std::size_t i = 0; i < 64; ++i) {
        EXPECT_FLOAT_EQ(lanes[4 * i], 0.5f) << i;
        EXPECT_FLOAT_EQ(lanes[4 * i + 1], 0.0f) << i;
        EXPECT_FLOAT_EQ(lanes[4 * i + 2], 0.0f) << i;
        EXPECT_FLOAT_EQ(lanes[4 * i + 3], 0.0f) << i;
    }
}

// Wallpaper Engine gives a frame one spectrum. The analysis publishes 30 a second on a thread of
// its own, so passes, particle operators and scripts that each took the newest one could draw
// some bars of a frame from one window and the rest from the next. The first read of a frame
// takes the spectrum for the whole frame; the next frame takes the newest again.
TEST(ShaderUpdaterAudio, AFrameReadsOneSpectrumWhateverTheAnalysisPublishesMeanwhile)
{
    AudioServiceGuard guard;
    auto first = SnapshotWith({ 0.125f, 0.25f, 0.375f, 0.5f, 0.625f, 0.75f });
    auto second = SnapshotWith({ 0.875f, 0.75f, 0.625f, 0.5f, 0.375f, 0.25f });
    first.generation = 17;
    second.generation = 18;
    audio::SetAudioSpectrumSnapshotForTesting(first);

    Stage f;
    auto& runtime = *f.scene.runtime;
    runtime.SetAudioResponseEnabled(true);
    f.updater.InitUniforms(f.node.get(), 0, Declares(SpectrumNames()));
    f.updater.InitUniforms(f.node.get(), 1, Declares(SpectrumNames()));
    auto script = runtime.scriptEngine().CreatePropertyScriptProgram(
        &runtime, "const b = engine.registerAudioBuffers(16); export function update() { return b.left[0]; }",
        "", {}, DynamicValue(0.0f), runtime.hostContext());
    ASSERT_NE(script, nullptr);
    ASSERT_TRUE(script->Valid());
    const auto script_reads = [&] {
        const auto value = script->Evaluate(runtime.hostContext(), DynamicValue(0.0f));
        return value != nullptr ? value->getFloat() : -1.0f;
    };

    f.updater.FrameBegin();
    ExpectSpectrum(f.Update(0), &first);
    // The analysis publishes a newer spectrum while the frame is being drawn.
    audio::SetAudioSpectrumSnapshotForTesting(second);
    ExpectSpectrum(f.Update(1), &first);
    EXPECT_FLOAT_EQ(script_reads(), first.left16[0]) << "a script read another spectrum than the passes";
    EXPECT_EQ(runtime.CurrentAudioSpectrumSnapshot().generation, 17u)
        << "what particle operators read is another spectrum than the passes'";

    f.updater.FrameBegin();
    EXPECT_FLOAT_EQ(script_reads(), second.left16[0]);
    ExpectSpectrum(f.Update(0), &second);
    ExpectSpectrum(f.Update(1), &second);

    // Turning audio response off takes effect with the next frame, for every reader at once.
    runtime.SetAudioResponseEnabled(false);
    ExpectSpectrum(f.Update(0), &second);
    f.updater.FrameBegin();
    ExpectSpectrum(f.Update(0), nullptr);
    EXPECT_FLOAT_EQ(script_reads(), 0.0f);
}

// The reuse cache redraws an audio pass exactly when what its uniforms carry changed, so the
// hash must follow every band of every array the material binds, and only those, and must
// never vouch for a spectrum the uniforms of the same frame might not have been given.
TEST(ShaderUpdaterAudio, TheAudioStateHashFollowsExactlyTheArraysTheMaterialBinds)
{
    AudioServiceGuard guard;
    audio::AudioSpectrumSnapshot spectrum;
    spectrum.generation = 3;
    spectrum.left64.fill(0.25f);
    audio::SetAudioSpectrumSnapshotForTesting(spectrum);

    Stage f;
    auto& runtime = *f.scene.runtime;
    runtime.SetAudioResponseEnabled(true);
    f.updater.InitUniforms(f.node.get(), 0, Declares({ "g_AudioSpectrum64Left", "g_AudioSpectrum16Right" }));
    f.updater.InitUniforms(f.node.get(), 1, Declares({ kTime }));

    // Before the host's first frame, reads are not held to one spectrum.
    EXPECT_FALSE(f.updater.AudioStateHash(f.node.get(), 0).has_value());
    struct Untracked final : IShaderValueUpdater {
        using IShaderValueUpdater::InitUniforms;
        using IShaderValueUpdater::UpdateUniforms;
        void FrameBegin() override {}
        void InitUniforms(SceneNode*, const ExistsUniformOp&) override {}
        void UpdateUniforms(SceneNode*, sprite_map_t&, const UpdateUniformOp&) override {}
        void FrameEnd() override {}
        void MouseInput(double, double) override {}
        void SetTexelSize(float, float) override {}
        void SetScreenSize(i32, i32) override {}
    };
    EXPECT_FALSE(Untracked {}.AudioStateHash(f.node.get(), 0).has_value())
        << "an updater that does not track audio must not vouch for a spectrum";

    const auto hash_of_frame = [&](const audio::AudioSpectrumSnapshot& next) {
        audio::SetAudioSpectrumSnapshotForTesting(next);
        f.updater.FrameBegin();
        (void)f.Update(0);
        const auto hash = f.updater.AudioStateHash(f.node.get(), 0);
        EXPECT_TRUE(hash.has_value());
        return hash.value_or(0);
    };
    const auto first = hash_of_frame(spectrum);
    EXPECT_EQ(hash_of_frame(spectrum), first) << "the same bands on the next frame";
    EXPECT_EQ(f.updater.AudioStateHash(f.node.get(), 1), std::optional<uint64_t>(0))
        << "a material that binds no spectrum";

    auto changed = spectrum;
    changed.left64[63] = 0.5f;
    EXPECT_NE(hash_of_frame(changed), first) << "the last band of a bound array";
    changed = spectrum;
    changed.right16[0] = 0.5f;
    EXPECT_NE(hash_of_frame(changed), first) << "the first band of the other bound array";
    changed = spectrum;
    changed.right64.fill(0.75f);
    changed.left16.fill(0.75f);
    changed.average64.fill(0.75f);
    changed.generation = 99;
    EXPECT_EQ(hash_of_frame(changed), first) << "only arrays the material does not bind changed";

    // A frame reads the spectrum it began with, whatever the analysis publishes meanwhile.
    audio::SetAudioSpectrumSnapshotForTesting(spectrum);
    f.updater.FrameBegin();
    (void)f.Update(0);
    changed = spectrum;
    changed.left64[0] = 1.0f;
    audio::SetAudioSpectrumSnapshotForTesting(changed);
    EXPECT_EQ(f.updater.AudioStateHash(f.node.get(), 0), std::optional<uint64_t>(first));

    // Silence, whether audio response is off or the spectrum is all zeros, is one spectrum.
    runtime.SetAudioResponseEnabled(false);
    const auto off = hash_of_frame(spectrum);
    runtime.SetAudioResponseEnabled(true);
    EXPECT_EQ(hash_of_frame(audio::AudioSpectrumSnapshot {}), off);
    EXPECT_NE(off, first);
}

// ---- puppet bone alpha --------------------------------------------------------------------------

// A shader that declares `g_BonesAlpha` gets one opacity per bone of the node's puppet.
TEST(ShaderUpdaterPuppet, BonesAlphaCarriesOneOpacityPerBone)
{
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.resize(3);
    puppet->bone_alpha = true; // the first mesh's flag word bit 4 (SKINNING_ALPHA)
    WPPuppet::Animation anim {};
    anim.id = 1;
    anim.fps = 1;
    anim.length = 1;
    anim.mode = WPPuppet::PlayMode::Loop;
    anim.blend_curves.resize(3);
    anim.blend_curves[1].values = { 0.25f, 0.25f };
    puppet->anims.push_back(anim);
    puppet->prepared();
    WPPuppetLayer layer(puppet);
    WPPuppetLayer::AnimationLayer spec;
    spec.id = 1;
    std::vector<WPPuppetLayer::AnimationLayer> stack { spec };
    layer.prepared(stack);

    Stage f;
    WPShaderValueData data;
    data.puppet_layer = layer;
    f.updater.SetNodeData(f.node.get(), 0, data);
    f.updater.InitUniforms(f.node.get(), 0, Declares({ "g_BonesAlpha" }));
    f.Update(0);
    f.scene.elapsingTime = 0.5;
    const auto written = f.Update(0);
    ASSERT_TRUE(written.contains("g_BonesAlpha"));
    const auto& alphas = written.at("g_BonesAlpha");
    ASSERT_EQ(alphas.size(), 3u);
    EXPECT_FLOAT_EQ(alphas[0], 1.0f);
    EXPECT_FLOAT_EQ(alphas[1], 0.25f);
    EXPECT_FLOAT_EQ(alphas[2], 1.0f);
}

// ---- per-slot reflection ------------------------------------------------------------------------

TEST(ShaderUpdaterSlots, ReflectionIsRecordedPerMaterialSlot)
{
    Stage f;
    f.scene.elapsingTime = 2.0;
    f.updater.InitUniforms(f.node.get(), 0, Declares({ kModel }));
    f.updater.InitUniforms(f.node.get(), 1, Declares({ kTime }));

    const auto zero = f.Update(0);
    const auto one = f.Update(1);
    EXPECT_TRUE(zero.contains(kModel));
    EXPECT_FALSE(zero.contains(kTime));
    EXPECT_FALSE(one.contains(kModel));
    EXPECT_TRUE(one.contains(kTime));
    ASSERT_EQ(one.at(kTime).size(), 1u);
    EXPECT_FLOAT_EQ(one.at(kTime)[0], 2.0f);
    EXPECT_EQ(zero.size(), 1u);
    EXPECT_EQ(zero.at(kModel).size(), 16u);
}

TEST(ShaderUpdaterSlots, ASlotStillUpdatesWhenSlotZeroHasNoMaterial)
{
    Stage f(0);
    f.mesh->MaterialSlots().push_back(nullptr);
    f.mesh->AddMaterial(SceneMaterial {});
    f.updater.InitUniforms(f.node.get(), 1, Declares({ kTime }));

    EXPECT_TRUE(f.Update(1).contains(kTime));
    EXPECT_TRUE(f.Update(0).empty()) << "the hole writes nothing";
    EXPECT_TRUE(f.Update(5).empty()) << "a slot past the list writes nothing";

    // A slot with no record of its own uses slot zero's.
    Stage g;
    g.updater.InitUniforms(g.node.get(), 0, Declares({ kTime }));
    EXPECT_TRUE(g.Update(1).contains(kTime));
}

// ---- render targets -----------------------------------------------------------------------------

struct TargetStage : Stage {
    TargetStage()
    {
        SceneRenderTarget first {};
        first.width = 64;
        first.height = 32;
        first.mipmap_level = 2;
        SceneRenderTarget second {};
        second.width = 128;
        second.height = 96;
        second.mipmap_level = 4;
        scene.renderTargets["first"] = first;
        scene.renderTargets["second"] = second;
    }

    void Bind(uint32_t slot, std::size_t textureSlot, const std::string& target)
    {
        WPShaderValueData data;
        data.renderTargets = { { textureSlot, target } };
        updater.SetNodeData(node.get(), slot, data);
    }
};

TEST(ShaderUpdaterTargets, EachSlotReportsTheSizeAndMipLevelOfItsOwnTarget)
{
    TargetStage f;
    f.Bind(0, 0, "first");
    f.Bind(1, 0, "second");
    const auto names = Declares({ "g_Texture0Resolution", "g_Texture0MipMapInfo", "g_Texture0Texel" });
    f.updater.InitUniforms(f.node.get(), 0, names);
    f.updater.InitUniforms(f.node.get(), 1, names);

    const auto zero = f.Update(0);
    const auto one = f.Update(1);
    ASSERT_TRUE(zero.contains("g_Texture0Resolution"));
    ASSERT_TRUE(one.contains("g_Texture0Resolution"));
    EXPECT_EQ(zero.at("g_Texture0Resolution"), (Lanes { 64, 32, 64, 32 }));
    EXPECT_EQ(one.at("g_Texture0Resolution"), (Lanes { 128, 96, 128, 96 }));
    EXPECT_EQ(zero.at("g_Texture0MipMapInfo"), (Lanes { 2 }));
    EXPECT_EQ(one.at("g_Texture0MipMapInfo"), (Lanes { 4 }));
    ASSERT_EQ(zero.at("g_Texture0Texel").size(), 4u);
    EXPECT_FLOAT_EQ(zero.at("g_Texture0Texel")[0], 1.0f / 64.0f);
    EXPECT_FLOAT_EQ(zero.at("g_Texture0Texel")[1], 1.0f / 32.0f);
    EXPECT_FLOAT_EQ(zero.at("g_Texture0Texel")[2], 64.0f);
    EXPECT_FLOAT_EQ(zero.at("g_Texture0Texel")[3], 32.0f);
    ASSERT_EQ(one.at("g_Texture0Texel").size(), 4u);
    EXPECT_FLOAT_EQ(one.at("g_Texture0Texel")[0], 1.0f / 128.0f);
    EXPECT_FLOAT_EQ(one.at("g_Texture0Texel")[1], 1.0f / 96.0f);
    EXPECT_FLOAT_EQ(one.at("g_Texture0Texel")[2], 128.0f);
    EXPECT_FLOAT_EQ(one.at("g_Texture0Texel")[3], 96.0f);
}

TEST(ShaderUpdaterTargets, OnlyTheBoundTextureSlotAndKnownTargetsAreWritten)
{
    TargetStage f;
    f.Bind(0, 2, "first");
    f.updater.InitUniforms(f.node.get(), 0, Declares({ "g_Texture0Resolution", "g_Texture2Resolution" }));
    const auto bound = f.Update(0);
    EXPECT_TRUE(bound.contains("g_Texture2Resolution"));
    EXPECT_FALSE(bound.contains("g_Texture0Resolution"));

    TargetStage missing;
    missing.Bind(0, 0, "no such target");
    missing.updater.InitUniforms(missing.node.get(), 0, Declares({ "g_Texture0Resolution" }));
    EXPECT_TRUE(missing.Update(0).empty());
}


TEST(ShaderUpdaterPointerHash, ACurrentPointerInputTracksOnlyThePositionItReads)
{
    Stage f;
    f.updater.InitUniforms(f.node.get(), 0, Declares({ "g_PointerPosition" }));
    f.updater.InitUniforms(f.node.get(), 1, Declares({ kTime }));
    const auto initial = f.updater.PointerStateHash(f.node.get(), 0, "");
    ASSERT_NE(initial, 0u);
    EXPECT_EQ(f.updater.PointerStateHash(f.node.get(), 1, ""), 0u);
    f.updater.MouseInput(0.7, 0.2);
    f.updater.FrameBegin();
    const auto moved = f.updater.PointerStateHash(f.node.get(), 0, "");
    EXPECT_NE(moved, initial);
    f.updater.FrameBegin();
    EXPECT_EQ(f.updater.PointerStateHash(f.node.get(), 0, ""), moved);
    f.updater.MouseButtonsInput(1);
    EXPECT_EQ(f.updater.PointerStateHash(f.node.get(), 0, ""), moved);
}

TEST(ShaderUpdaterPointerHash, PreviousPositionAndButtonEdgesHaveTheirOwnVersions)
{
    Stage f;
    f.updater.InitUniforms(f.node.get(), 0, Declares({ "g_PointerPositionLast" }));
    f.updater.InitUniforms(f.node.get(), 1, Declares({ "g_PointerState" }));
    const auto initial = f.updater.PointerStateHash(f.node.get(), 0, "");
    f.updater.MouseInput(0.7, 0.2);
    f.updater.FrameBegin();
    const auto pending = f.updater.PointerStateHash(f.node.get(), 0, "");
    EXPECT_NE(pending, initial);
    f.updater.FrameBegin();
    const auto caught_up = f.updater.PointerStateHash(f.node.get(), 0, "");
    EXPECT_NE(caught_up, pending);
    f.updater.FrameBegin();
    EXPECT_EQ(f.updater.PointerStateHash(f.node.get(), 0, ""), caught_up);

    const auto released = f.updater.PointerStateHash(f.node.get(), 1, "");
    f.updater.MouseButtonsInput(1);
    const auto pressed = f.updater.PointerStateHash(f.node.get(), 1, "");
    EXPECT_NE(pressed, released);
    f.updater.MouseButtonsInput(1);
    const auto held = f.updater.PointerStateHash(f.node.get(), 1, "");
    EXPECT_NE(held, pressed);
    f.updater.MouseButtonsInput(1);
    EXPECT_EQ(f.updater.PointerStateHash(f.node.get(), 1, ""), held);
    f.updater.MouseButtonsInput(0);
    EXPECT_EQ(f.updater.PointerStateHash(f.node.get(), 1, ""), released);
}

TEST(ShaderUpdaterPointerHash, DisabledParallaxIgnoresCursorMotion)
{
    Stage f;
    f.updater.InitUniforms(f.node.get(), 0, Declares({ "g_ParallaxPosition" }));
    f.updater.SetCameraParallax({ .enable = true, .amount = 1.0f, .mouseinfluence = 0.7f });
    f.updater.SetUserMouseParallax(false);
    const auto disabled = f.updater.PointerStateHash(f.node.get(), 0, "");
    f.updater.MouseInput(0.7, 0.2);
    f.updater.FrameBegin();
    EXPECT_EQ(f.updater.PointerStateHash(f.node.get(), 0, ""), disabled);
    f.updater.SetUserMouseParallax(true);
    EXPECT_NE(f.updater.PointerStateHash(f.node.get(), 0, ""), disabled);
}

TEST(ShaderUpdaterPointerHash, ModelParallaxIsIncludedWithoutAPointerUniform)
{
    Stage f;
    f.updater.InitUniforms(f.node.get(), 0, Declares({ kMvp }));
    WPShaderValueData data;
    data.parallaxDepth = { 0.2f, 0.3f };
    f.updater.SetNodeData(f.node.get(), 0, data);
    f.updater.SetCameraParallax({ .enable = true, .amount = 1.0f, .mouseinfluence = 0.7f });
    const auto initial = f.updater.PointerStateHash(f.node.get(), 0, "");
    ASSERT_NE(initial, 0u);
    f.updater.MouseInput(0.7, 0.2);
    f.updater.FrameBegin();
    EXPECT_NE(f.updater.PointerStateHash(f.node.get(), 0, ""), initial);
    f.updater.SetUserMouseParallax(false);
    EXPECT_EQ(f.updater.PointerStateHash(f.node.get(), 0, ""), 0u);
}

TEST(ShaderUpdaterPointerHash, ADelayedLastPositionReaderIdlesAfterBothVersionsCatchUp)
{
    Stage f;
    f.updater.InitUniforms(f.node.get(), 0, Declares({ "g_PointerPositionLast" }));
    render::StaticSubgraphCache cache;
    render::StaticPassDesc reader;
    reader.target = "reader";
    reader.inputs = { "source" };
    render::StaticPassDesc source;
    source.target = "source";
    source.dynamic_reasons = static_cast<uint32_t>(render::DynamicReason::PointerUniform);
    cache.Compile(std::vector { reader, source });
    cache.SetExecutionOrder(std::vector<std::size_t> { 0, 1 });
    const auto frame = [&] {
        f.updater.FrameBegin();
        const std::array<render::StaticPassSample, 2> samples {
            render::StaticPassSample {},
            render::StaticPassSample { .hash = f.updater.PointerStateHash(f.node.get(), 0, "") },
        };
        std::array<uint8_t, 2> skip {};
        cache.Plan(samples, skip);
        return cache.HasPendingDelayedInputs();
    };
    EXPECT_TRUE(frame());
    EXPECT_FALSE(frame());
    f.updater.MouseInput(0.7, 0.2);
    EXPECT_TRUE(frame()) << "the last-position uniform still has its old value";
    EXPECT_TRUE(frame()) << "the retained reader still has the uniform's old value";
    EXPECT_FALSE(frame());
}

// ---- what a reuse sample folds ----------------------------------------------------------------

// A layer under a moving parent, its card drawn through a layer-local camera, one effect pass of it
// drawn through the effect camera, and a perspective scene camera that can shake.
struct ChainFixture {
    Scene                        scene;
    std::shared_ptr<SceneCamera> screen = std::make_shared<SceneCamera>(16.0f / 9.0f, 0.01f, 1000.0f, 50.0f);
    std::shared_ptr<SceneNode>   parent = std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode>   layer  = std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode>   pass   = std::make_shared<SceneNode>();
    WPShaderValueUpdater         updater { &scene };
    sprite_map_t                 sprites;

    explicit ChainFixture(const char* cardMaterial = "card")
    {
        scene.activeCamera = screen.get();
        scene.cameras["global"] = screen;
        auto local = std::make_shared<SceneCamera>(64, 32, -1.0f, 1.0f);
        local->SetLayerLocal(true);
        scene.cameras["layer-local"] = local;
        scene.cameras["effect"] = std::make_shared<SceneCamera>(2, 2, -1.0f, 1.0f);
        parent->SetTranslate({ 200.0f, 100.0f, 0.0f });
        layer->SetTranslate({ 10.0f, 20.0f, 0.0f });
        layer->SetCamera("layer-local");
        layer->SetRenderTransformOverride(linalg::Matrix4d::Identity());
        pass->SetCamera("effect");
        for (auto* node : { layer.get(), pass.get() }) {
            auto          mesh = std::make_shared<SceneMesh>();
            SceneMaterial material;
            material.name = node == layer.get() ? cardMaterial : "pass";
            mesh->AddMaterial(std::move(material));
            node->AddMesh(mesh);
        }
        parent->AppendChild(layer);
        scene.sceneGraph->AppendChild(parent);
        scene.sceneGraph->AppendChild(pass);
        WPShaderValueData data;
        data.effect_owner   = layer.get();
        data.effect_extent  = { 64.0f, 32.0f };
        data.parallax_layer = layer.get();
        updater.SetNodeData(pass.get(), data);
    }
    ~ChainFixture() { scene.activeCamera = nullptr; }

    DrawTransformInputs Inputs(SceneNode* node, std::vector<std::string> reads, const std::string& camera = "")
    {
        return updater.TransformInputs(node, 0, camera, Declares(std::move(reads)));
    }
};

constexpr DrawTransformInputs kNothingMoving { .node_transform = false, .active_camera = false, .owner = nullptr };

TEST(ShaderUpdaterSignatures, ALayerLocalCardReadingItsOwnMatricesDependsOnNothingThatMoves)
{
    ChainFixture f;
    // Through the layer-local camera the model matrix is the identity and the view projection is
    // that camera's, which every sample folds anyway.
    EXPECT_EQ(f.Inputs(f.layer.get(), { kMvp, kModel, "g_ModelMatrixInverse", "g_ViewProjectionMatrix",
                                        "g_ModelViewProjectionMatrixInverse", kTime, "g_Texture0Resolution",
                                        "g_Screen", "g_TexelSize", "g_Color4" }),
              kNothingMoving);
    // Through the effect camera the model matrix is the pass node's own transform.
    EXPECT_EQ(f.Inputs(f.pass.get(), { "g_ViewProjectionMatrix", "g_Texture0Resolution" }), kNothingMoving);
    EXPECT_EQ(f.Inputs(f.pass.get(), { kMvp }),
              (DrawTransformInputs { .node_transform = true, .active_camera = false, .owner = nullptr }));
    EXPECT_EQ(f.Inputs(f.pass.get(), { kModel }),
              (DrawTransformInputs { .node_transform = true, .active_camera = false, .owner = nullptr }));
}

TEST(ShaderUpdaterSignatures, AnEffectPassReadingItsLayersMatricesFoldsTheLayerAndTheCamera)
{
    ChainFixture f;
    for (const char* name : { "g_EffectModelViewProjectionMatrix", "g_EffectModelViewProjectionMatrixInverse",
                              "g_EffectModelMatrix", "g_LayerModelMatrix", "g_EffectTextureProjectionMatrix",
                              "g_EffectTextureProjectionMatrixInverse" }) {
        SCOPED_TRACE(name);
        EXPECT_EQ(f.Inputs(f.pass.get(), { name }),
                  (DrawTransformInputs { .node_transform = false, .active_camera = true, .owner = f.layer.get() }));
        // A card has no effect owner: its own transform is the layer's.
        EXPECT_EQ(f.Inputs(f.layer.get(), { name }),
                  (DrawTransformInputs { .node_transform = true, .active_camera = true, .owner = nullptr }));
    }
}

TEST(ShaderUpdaterSignatures, EverythingElseAboutTheWorldOrTheCameraKeepsTheWholeSample)
{
    ChainFixture              f;
    const DrawTransformInputs all {};
    // The eye and view axes, particle orientation, the lights, puppets and the cursor.
    for (const char* name : { "g_EyePosition", "g_ViewForward", "g_ViewUp", "g_ViewRight", "g_OrientationUp",
                              "g_OrientationRight", "g_OrientationForward", "g_LightsPosition",
                              "g_LightsColorPremultiplied", "g_LightsColorRadius", "g_LPoint_Origin",
                              "g_LFeature_ShadowProjection", "g_Bones", "g_BonesAlpha", "g_MorphWeights",
                              "g_BlendMap", "g_PointerPosition", "g_PointerPositionLast", "g_PointerState",
                              "g_ParallaxPosition" }) {
        SCOPED_TRACE(name);
        EXPECT_EQ(f.Inputs(f.layer.get(), { kMvp, name }), all);
        EXPECT_EQ(f.Inputs(f.pass.get(), { name }), all);
    }
    // A draw through a scene camera is placed by its transform, the camera and parallax.
    EXPECT_EQ(f.Inputs(f.layer.get(), { kMvp }, "global"), all);
    f.pass->SetCamera("global");
    EXPECT_EQ(f.Inputs(f.pass.get(), { "g_Texture0Resolution" }), all);
    // A volumetric light's pass is written from the light.
    SceneVolumetricLight volume;
    WPShaderValueData    lit;
    lit.volumetric_light = &volume;
    f.updater.SetNodeData(f.layer.get(), lit);
    EXPECT_EQ(f.Inputs(f.layer.get(), { kMvp }), all);
    // Nothing known about what the program reads is no evidence that it reads nothing.
    EXPECT_EQ(f.updater.TransformInputs(f.layer.get(), 0, "", ExistsUniformOp {}), all);
}

TEST(ShaderUpdaterSignatures, AComposeLayersFirstPassKeepsTheWholeSample)
{
    // It reads the screen behind the layer through its full model matrix and the scene camera.
    ChainFixture f("composelayer");
    EXPECT_EQ(f.Inputs(f.layer.get(), { kMvp }), DrawTransformInputs {});
    EXPECT_EQ(f.Inputs(f.layer.get(), {}), DrawTransformInputs {});
}

// The drift guard: every uniform `UpdateUniforms` writes for a chain draw changes, when a node or
// the camera moves, only if the sample `TransformInputs` asks for folds what moved. A uniform added
// later that derives from a transform or the camera without being taught to `TransformInputs`
// fails here rather than on a wallpaper.
TEST(ShaderUpdaterSignatures, EveryWrittenUniformThatMovesIsOneTheSampleFolds)
{
    ChainFixture f;
    const auto   every = [](std::string_view) { return true; };
    for (auto* node : { f.layer.get(), f.pass.get() }) f.updater.InitUniforms(node, every);

    enum class Moved { Parent, PassNode, Camera };
    struct Move {
        Moved                 what;
        const char*           name;
        std::function<void()> apply;
        std::function<void()> undo;
    };
    const std::vector<Move> moves {
        { Moved::Parent, "the layer's parent", [&] { f.parent->SetTranslate({ 260.0f, 80.0f, 5.0f }); },
          [&] { f.parent->SetTranslate({ 200.0f, 100.0f, 0.0f }); } },
        { Moved::PassNode, "the pass node", [&] { f.pass->SetTranslate({ 3.0f, -4.0f, 1.0f }); },
          [&] { f.pass->SetTranslate({ 0.0f, 0.0f, 0.0f }); } },
        { Moved::Camera, "the camera shake", [&] { f.screen->SetShakeOffset({ 7.0, -3.0, 2.0 }); },
          [&] { f.screen->SetShakeOffset({ 0.0, 0.0, 0.0 }); } },
    };
    std::size_t written = 0;
    std::size_t moved   = 0;
    for (auto* node : { f.layer.get(), f.pass.get() }) {
        const bool card = node == f.layer.get();
        for (const auto& move : moves) {
            Captured before, after;
            f.updater.UpdateUniforms(node, f.sprites, Collect(before));
            move.apply();
            f.updater.UpdateUniforms(node, f.sprites, Collect(after));
            move.undo();
            written = std::max(written, before.size());
            for (const auto& [name, value] : before) {
                if (after.at(name) == value) continue;
                ++moved;
                SCOPED_TRACE(std::string(card ? "card " : "pass ") + name + " moved with " + move.name);
                const auto inputs = f.updater.TransformInputs(node, 0, "", Declares({ name }));
                switch (move.what) {
                case Moved::Camera: EXPECT_TRUE(inputs.active_camera); break;
                case Moved::Parent:
                    // The card is the layer; an effect pass reads the layer as its owner.
                    EXPECT_TRUE(card ? inputs.node_transform : inputs.owner == f.layer.get());
                    break;
                case Moved::PassNode: EXPECT_TRUE(! card && inputs.node_transform); break;
                }
            }
        }
    }
    EXPECT_GT(written, 30u) << "the updater wrote fewer uniforms than it knows";
    EXPECT_GT(moved, 0u) << "nothing moved: the guard checked nothing";
}

} // namespace
} // namespace wallpaper
