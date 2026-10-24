// What the shader value updater hands a draw: pinned sprite frames, the matrices of a compose
// layer, audio-spectrum arrays, per-slot reflection and render-target sizes. Scenes are built
// in memory and the updater is called directly; no device or window is involved.

#include "Audio/include/Audio/AudioResponseService.h"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scene/include/Scene/SceneCamera.h"
#include "Scene/include/Scene/SceneMesh.h"
#include "Scene/include/Scene/SceneRenderTarget.h"
#include "Scripting/ScriptEngine.hpp"
#include "SpecTexs.hpp"
#include "SpriteAnimation.hpp"
#include "WPShaderValueUpdater.hpp"

#include <gtest/gtest.h>

#include <cmath>
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
    ASSERT_TRUE(node.TextureFrame().has_value());
    EXPECT_EQ(*node.TextureFrame(), 1.0);
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

TEST(ShaderUpdaterFrames, ASpriteTablePinsAFrameAndClampsTheIndex)
{
    auto sheet = [] {
        SpriteAnimation animation;
        animation.AppendFrame(SpriteFrame { .imageId = 0, .frametime = 0.1f });
        animation.AppendFrame(SpriteFrame { .imageId = 1, .frametime = 0.1f });
        return animation;
    };

    SpriteAnimation animation = sheet();
    EXPECT_EQ(animation.SetFrame(1).imageId, 1);
    EXPECT_EQ(animation.SetFrame(-1).imageId, 0) << "below the first frame pins the first";
    EXPECT_EQ(animation.SetFrame(100).imageId, 1) << "beyond the table pins the last";
    EXPECT_EQ(animation.SetFrame(std::numeric_limits<double>::quiet_NaN()).imageId, 0);
    EXPECT_EQ(animation.SetFrame(1.9).imageId, 1) << "fractions floor";
    EXPECT_EQ(animation.SetFrame(0.9).imageId, 0);

    // After pinning, the clock starts a frame's full length from there.
    animation.SetFrame(0);
    EXPECT_EQ(animation.GetAnimateFrame(0.05).imageId, 0);
    EXPECT_EQ(animation.GetAnimateFrame(0.1).imageId, 1);
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

} // namespace
} // namespace wallpaper
