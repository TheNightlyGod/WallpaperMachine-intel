#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <cstring>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>
#include "Utils/Linalg.hpp"

#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "Audio/SoundManager.h"
#include "Project/ProjectProperties.hpp"
#include "Particle/ParticleSystem.h"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Runtime/ScriptedDynamicValue.hpp"

#include <cmath>
#include "Scene/SceneCamera.h"
#include "Scene/SceneUpdateDemand.hpp"
#include "Scene/SceneNode.h"
#include "SpecTexs.hpp"
#include "Type.hpp"
#include "WPShaderValueUpdater.hpp"
#include "Scene/Parse/LayerParallax.hpp"
#include "Interface/IShaderValueUpdater.h"
#include "WPSceneParser.hpp"
#include "wpscene/WPImageObject.h"
#include "wpscene/WPMiscObject.hpp"
#include "wpscene/WPParticleObject.h"
#include "Scene/Parse/WPSoundParser.hpp"
#include "wpscene/WPSoundObject.h"
#include "wpscene/WPScene.h"
#include "Utils/Logging.h"
#include "Scripting/ScriptEngine.hpp"

namespace
{
using namespace wallpaper;

} // namespace

// A layer can be attached to its parent after something has already asked for
// its transform — composition layers build their camera and effect chain during
// parsing, and the scene graph is wired afterwards. The world transform has to
// follow the new parent, or the layer and everything under it draws at its own
// local coordinates.
TEST(SceneSchema, AttachingAParentRefreshesAWorldTransformThatWasAlreadyComputed) {
    auto parent = std::make_shared<SceneNode>();
    parent->SetTranslate({ 2560.0f, 1080.0f, 0.0f });
    auto child = std::make_shared<SceneNode>();
    child->SetTranslate({ 0.0f, 5.0f, 0.0f });

    child->UpdateTrans();
    ASSERT_EQ((child->ModelTrans() * linalg::Vector4d(0, 0, 0, 1)).head<3>(),
              linalg::Vector3d(0.0, 5.0, 0.0));

    parent->AppendChild(child);
    child->UpdateTrans();

    EXPECT_EQ((child->ModelTrans() * linalg::Vector4d(0, 0, 0, 1)).head<3>(),
              linalg::Vector3d(2560.0, 1085.0, 0.0));

    // The same has to hold deeper than one level: attaching a grandparent to an
    // already-evaluated subtree re-dirties it through MarkTransDirty's
    // recursion, so every descendant picks the new ancestry up.
    auto grandchild = std::make_shared<SceneNode>();
    grandchild->SetTranslate({ 7.0f, 0.0f, 0.0f });
    child->AppendChild(grandchild);
    grandchild->UpdateTrans();
    EXPECT_EQ((grandchild->ModelTrans() * linalg::Vector4d(0, 0, 0, 1)).head<3>(),
              linalg::Vector3d(2567.0, 1085.0, 0.0));

    auto root = std::make_shared<SceneNode>();
    root->SetTranslate({ 100.0f, 200.0f, 0.0f });
    root->AppendChild(parent);
    grandchild->UpdateTrans();
    EXPECT_EQ((grandchild->ModelTrans() * linalg::Vector4d(0, 0, 0, 1)).head<3>(),
              linalg::Vector3d(2667.0, 1285.0, 0.0));
}

nlohmann::json CameraPathFixture(double x) {
    const auto curve = [](double a, double b) {
        return nlohmann::json::array({{{"frame",0},{"value",a}},{{"frame",30},{"value",b}}});
    };
    return {{"visible",true}, {"options",{{"fps",30},{"length",30},{"mode","single"}}},
            {"eye",{{"c0",curve(x,x+2)},{"c1",curve(0,0)},{"c2",curve(10,10)}}},
            {"center",{{"c0",curve(x,x+2)},{"c1",curve(0,0)},{"c2",curve(0,0)}}},
            {"up",{{"c0",curve(0,0)},{"c1",curve(1,1)},{"c2",curve(0,0)}}},
            {"fov",curve(40,60)}};
}

TEST(SceneSchema, CameraPathsPreserveSteepAndRolledLookAtOrientation) {
    for (const auto& up : { linalg::Vector3d(0, 1, 0), linalg::Vector3d(0.2, 1, 0.3) }) {
        for (const auto& eye : { linalg::Vector3d(0.001, 10, 0.002),
                                linalg::Vector3d(10, 0.001, 0.002) }) {
            auto path = CameraPathFixture(0);
            for (int axis = 0; axis < 3; ++axis) {
                const auto key = "c" + std::to_string(axis);
                path["eye"][key] = {{{"frame",0},{"value",eye[axis]}},
                                    {{"frame",30},{"value",axis == 2 ? -eye[axis] : eye[axis]}}};
                path["center"][key] = {{{"frame",0},{"value",0}}};
                path["up"][key] = {{{"frame",0},{"value",up[axis]}}};
            }
            CameraPathPlayback playback(ParseCameraPaths({{"paths",{path}}}), "sequence");
            auto node = std::make_shared<SceneNode>();
            SceneCamera camera(1, 0.1, 100, 50);
            camera.AttatchNode(node);
            for (int frame = 0; frame < 5; ++frame) {
                playback.Apply(*node, camera);
                const linalg::Vector3d sampled(eye.x(), eye.y(), eye.z() * (1 - frame * 0.4));
                const linalg::Vector3d forward = -sampled.normalized();
                const linalg::Vector3d right = forward.cross(up).normalized();
                EXPECT_TRUE(camera.GetDirection().isApprox(forward, 1e-5));
                EXPECT_TRUE(camera.GetUp().isApprox(right.cross(forward), 1e-5));
                EXPECT_TRUE(camera.GetViewMatrix().allFinite());
                playback.Advance(0.2);
            }
        }
    }
}

TEST(SceneSchema, PerspectiveFallbackCapturesTheCameraAtFirstRegistrationOnly) {
    Scene scene;
    SceneCamera initial(1, 0.1, 100, 50), editor(1, 0.1, 100, 60), shot_camera(1, 0.1, 100, 70);
    scene.activeCamera = &initial;
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    runtime->AttachScene(&scene);
    scene.activeCamera = &editor; // parser chooses the editor camera before registering shots
    auto shot = std::make_shared<SceneNode>();
    shot->SetVisible(false);
    runtime->RegisterPerspectiveCameraShot(shot, &shot_camera, 45, {});
    EXPECT_EQ(scene.activeCamera, &editor);
    shot->SetVisible(true);
    runtime->Tick(0);
    EXPECT_EQ(scene.activeCamera, &shot_camera);
    auto hidden = std::make_shared<SceneNode>();
    hidden->SetVisible(false);
    runtime->RegisterPerspectiveCameraShot(hidden, &shot_camera, 80, {});
    shot->SetVisible(false);
    runtime->Tick(0);
    EXPECT_EQ(scene.activeCamera, &editor); // registration must not capture a selected shot
}

TEST(SceneSchema, RandomCameraPathsStayWithinAuthoredShotsAndBoundCatchup) {
    const auto paths = ParseCameraPaths({{"paths", {CameraPathFixture(0), CameraPathFixture(20)}}});
    CameraPathPlayback playback(paths, "random");
    SceneNode node;
    SceneCamera camera(1.0f, 0.1f, 1000.0f, 50.0f);
    playback.Apply(node, camera);
    const float first = node.Translate().x();
    EXPECT_TRUE(first == 0 || first == 20);
    playback.Advance(1.0);
    playback.Apply(node, camera);
    EXPECT_FLOAT_EQ(node.Translate().x(), first == 0 ? 20 : 0);
    playback.Advance(1e9);
    playback.Apply(node, camera);
    EXPECT_TRUE(node.Translate().allFinite());
    EXPECT_TRUE(node.Translate().x() >= 0 && node.Translate().x() <= 22);
}

// A scene that switches parallax or HDR bloom on and leaves their settings out
// gets Wallpaper Engine's defaults.
TEST(SceneSchema, SceneSettingsLeftOutTakeWallpaperEnginesDefaults) {
    wpscene::WPScene sc;
    sc.FromJson(nlohmann::json::parse(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {"cameraparallax":true, "orthogonalprojection":{"width":640,"height":360}}
    })"));
    EXPECT_TRUE(sc.general.cameraparallax);
    EXPECT_FLOAT_EQ(sc.general.cameraparallaxamount, 0.5f);
    EXPECT_FLOAT_EQ(sc.general.cameraparallaxdelay, 0.1f);
    EXPECT_FLOAT_EQ(sc.general.cameraparallaxmouseinfluence, 0.5f);
    // The ambient and sky light are black.
    for (int i = 0; i < 3; ++i) {
        EXPECT_FLOAT_EQ(sc.general.ambientcolor[i], 0.0f);
        EXPECT_FLOAT_EQ(sc.general.skylightcolor[i], 0.0f);
    }
    // And the HDR bloom keys, likewise.
    EXPECT_FLOAT_EQ(sc.general.bloomhdrstrength, 2.0f);
    EXPECT_FLOAT_EQ(sc.general.bloomhdrthreshold, 1.0f);
    EXPECT_FLOAT_EQ(sc.general.bloomhdrfeather, 0.1f);
    EXPECT_FLOAT_EQ(sc.general.bloomhdrscatter, 1.619f);
    EXPECT_EQ(sc.general.bloomhdriterations, 8);
}

TEST(SceneSchema, ParallaxInheritanceResolvesRootsWithoutDependingOnDeclarationOrder) {
    auto objects = nlohmann::json::parse(R"([
        {"id":3,"parent":2,"parallaxDepth":[9,9]},
        {"id":2,"parent":1,"parallaxDepth":[0,0]},
        {"id":1,"parallaxDepth":[0.75,-0.25]},
        {"id":4,"parent":5,"parallaxDepth":[1,1]},
        {"id":5},
        {"id":6,"parent":99,"parallaxDepth":[0.2,0.4]},
        {"id":7,"parent":8,"parallaxDepth":[2,3]},
        {"id":8,"parent":7,"parallaxDepth":[4,5]},
        {"id":9,"parallaxDepth":[6,7]},
        {"id":9,"parallaxDepth":[8,9]},
        {"id":10,"parent":9,"parallaxDepth":[10,11]}
    ])");
    const auto original = objects;
    for (bool reversed : {false, true}) {
        objects = original;
        if (reversed) std::reverse(objects.begin(), objects.end());
        ResolveLayerParallax(objects);
        if (reversed) std::reverse(objects.begin(), objects.end());
        EXPECT_EQ(objects[0]["parallaxDepth"], original[2]["parallaxDepth"]);
        EXPECT_EQ(objects[1]["parallaxDepth"], original[2]["parallaxDepth"]);
        // A root without a depth has Wallpaper Engine's default, (1, 1).
        EXPECT_EQ(objects[3]["parallaxDepth"], nlohmann::json::array({1, 1}));
        for (std::size_t i : {2u, 4u, 5u, 6u, 7u, 8u, 9u, 10u})
            EXPECT_EQ(objects[i], original[i]);
    }
}

TEST(SceneSchema, ParallaxInheritanceRejectsOutOfRangeIdsWithoutAliasingValidLayers) {
    const auto minimum = std::numeric_limits<int32_t>::min();
    const auto maximum = std::numeric_limits<int32_t>::max();
    const std::vector<std::pair<nlohmann::json, int32_t>> invalid_ids {
        {int64_t(maximum) + 1, minimum}, {int64_t(minimum) - 1, maximum},
        {uint64_t(maximum) + 1, minimum}, {std::numeric_limits<uint64_t>::max(), -1},
        {(int64_t(1) << 32) + 1, 1},
    };
    for (const auto& [invalid, valid] : invalid_ids) {
        SCOPED_TRACE(invalid.dump());
        for (bool include_invalid_id : {false, true}) {
            auto original = nlohmann::json::array({
                {{"id", valid}, {"parallaxDepth", {0.75, -0.25}}},
                {{"id", 2}, {"parent", valid}, {"parallaxDepth", {2, 3}}},
                {{"id", 3}, {"parent", invalid}, {"parallaxDepth", {4, 5}}},
            });
            if (include_invalid_id) original.push_back({{"id", invalid}, {"parallaxDepth", {9, 9}}});
            for (bool reversed : {false, true}) {
                auto objects = original;
                if (reversed) std::reverse(objects.begin(), objects.end());
                ResolveLayerParallax(objects);
                if (reversed) std::reverse(objects.begin(), objects.end());
                EXPECT_EQ(objects[1]["parallaxDepth"], original[0]["parallaxDepth"]);
                EXPECT_EQ(objects[2], original[2]);
                EXPECT_EQ(objects[0], original[0]);
                if (include_invalid_id) EXPECT_EQ(objects[3], original[3]);
            }
        }
    }
}

TEST(SceneSchema, ParallaxInheritanceAcceptsSignedBoundariesAndUnsignedInRangeIds) {
    for (const auto& id : std::vector<nlohmann::json> {
             std::numeric_limits<int32_t>::min(), std::numeric_limits<int32_t>::max(),
             uint64_t(std::numeric_limits<int32_t>::max()),
         }) {
        auto objects = nlohmann::json::array({
            {{"id", 1}, {"parent", id}, {"parallaxDepth", {9, 9}}},
            {{"id", id}, {"parallaxDepth", {0.75, -0.25}}},
        });
        ResolveLayerParallax(objects);
        EXPECT_EQ(objects[0]["parallaxDepth"], objects[1]["parallaxDepth"]);
    }
}

TEST(SceneSchema, TheFieldOfViewOfA2DScenesPerspectiveCameraIsReadFromAnyPackageVersion) {
    const auto json = nlohmann::json::parse(R"({"perspectiveoverridefov":70.0,"windenabled":true})");
    // `windenabled` is a package-version-21 key and stays gated; the field of view
    // is read from whatever file carries it.
    wpscene::WPSceneGeneral v9;
    ASSERT_TRUE(v9.FromJson(json, 9));
    EXPECT_FLOAT_EQ(v9.perspectiveoverridefov, 70.0f);
    EXPECT_FALSE(v9.windenabled);
}

#include <array>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <mutex>
#include <thread>
#include "Core/RendererCounters.hpp"
#include "SceneWallpaper.hpp"
#include "Scene/Scene.h"
#if defined(__APPLE__)
#include "Platform/Apple/SceneWallpaperBindings.h"
#endif

namespace {
struct NativePointerObservation {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<bool> values;
    int drops { 0 };
    int first_frames { 0 };
    bool block { false };
    bool released { false };

    void Observe(bool accepts) {
        std::unique_lock lock(mutex);
        values.push_back(accepts);
        changed.notify_all();
        if (block) changed.wait(lock, [&] { return released; });
    }
    void Release() {
        std::lock_guard lock(mutex);
        released = true;
        changed.notify_all();
    }
    bool Wait(std::size_t count, int drop_count = 0) {
        std::unique_lock lock(mutex);
        return changed.wait_for(lock, std::chrono::seconds(5), [&] {
            return values.size() >= count && drops >= drop_count;
        });
    }
    std::vector<bool> Values() {
        std::lock_guard lock(mutex);
        return values;
    }
    int Drops() {
        std::lock_guard lock(mutex);
        return drops;
    }
};

std::shared_ptr<wallpaper::Scene> MakePointerCommitScene(bool accepts) {
    auto scene = std::make_shared<wallpaper::Scene>();
    scene->activeCamera = nullptr;
    scene->sceneGraph.reset();
    scene->accepts_pointer_input = accepts;
    return scene;
}
}

#if defined(__APPLE__)
namespace {
struct NativePointerUserData {
    NativePointerObservation* observation;
};
void NativePointerCallback(void* data, bool accepts) {
    static_cast<NativePointerUserData*>(data)->observation->Observe(accepts);
}
void NativeFirstFrameCallback(void* data) {
    auto& observation = *static_cast<NativePointerUserData*>(data)->observation;
    std::lock_guard lock(observation.mutex);
    ++observation.first_frames;
    observation.changed.notify_all();
}
void NativePointerDrop(void* data) {
    std::unique_ptr<NativePointerUserData> owner(static_cast<NativePointerUserData*>(data));
    auto& observation = *owner->observation;
    std::lock_guard lock(observation.mutex);
    ++observation.drops;
    observation.changed.notify_all();
}
struct NativePointerSceneDeleter {
    void operator()(owe_scene_wallpaper* scene) const { owe_scene_wallpaper_delete(scene); }
};
using NativePointerSceneOwner = std::unique_ptr<owe_scene_wallpaper, NativePointerSceneDeleter>;
struct NativePointerReleaseOnExit {
    NativePointerObservation& observation;
    ~NativePointerReleaseOnExit() { observation.Release(); }
};
int RegisterNativePointer(owe_scene_wallpaper* scene, NativePointerObservation& observation) {
    auto data = std::make_unique<NativePointerUserData>();
    data->observation = &observation;
    const int status = owe_scene_wallpaper_set_pointer_input_callback(
        scene, NativePointerCallback, data.get(), NativePointerDrop);
    if (status == 0) data.release();
    return status;
}
int RegisterNativeFirstFrame(owe_scene_wallpaper* scene, NativePointerObservation& observation) {
    auto data = std::make_unique<NativePointerUserData>();
    data->observation = &observation;
    const int status = owe_scene_wallpaper_set_first_frame_callback(
        scene, NativeFirstFrameCallback, data.get(), NativePointerDrop);
    if (status == 0) data.release();
    return status;
}
}

TEST(SceneSchema, PointerCallbackReplacementAndClearRetainInflightUserData) {
    NativePointerObservation first;
    NativePointerObservation second;
    first.block = true;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    NativePointerReleaseOnExit release { first };
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), first), 0);
    ASSERT_TRUE(first.Wait(1));
    ASSERT_EQ(RegisterNativePointer(scene.get(), second), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_pointer_input_callback(
        scene.get(), nullptr, nullptr, nullptr), 0);
    EXPECT_EQ(first.Drops(), 0);
    EXPECT_EQ(second.Drops(), 0);
    EXPECT_TRUE(second.Values().empty());
    first.Release();
    ASSERT_TRUE(first.Wait(1, 1));
    ASSERT_TRUE(second.Wait(1, 1));
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    scene.reset();
    EXPECT_EQ(first.Values(), (std::vector<bool> { true }));
    EXPECT_EQ(second.Values(), (std::vector<bool> { true }));
    EXPECT_EQ(first.Drops(), 1);
    EXPECT_EQ(second.Drops(), 1);
}

TEST(SceneSchema, PointerCallbackShutdownStopsDeliveryAndReleasesOwnershipOnDelete) {
    NativePointerObservation observation;
    NativePointerObservation rejected;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), observation), 0);
    ASSERT_TRUE(observation.Wait(1));
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    EXPECT_NE(RegisterNativePointer(scene.get(), rejected), 0);
    EXPECT_EQ(rejected.Drops(), 0);
    EXPECT_TRUE(rejected.Values().empty());
    scene.reset();
    EXPECT_EQ(observation.Values(), (std::vector<bool> { true }));
    EXPECT_EQ(observation.Drops(), 1);
    EXPECT_EQ(rejected.Drops(), 0);
}

TEST(SceneSchema, NativeCallbackRegistrationFailureDoesNotConsumeUserData) {
    NativePointerObservation pointer;
    NativePointerObservation first_frame;
    EXPECT_NE(RegisterNativePointer(nullptr, pointer), 0);
    EXPECT_NE(RegisterNativeFirstFrame(nullptr, first_frame), 0);
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    EXPECT_NE(RegisterNativePointer(scene.get(), pointer), 0);
    EXPECT_NE(RegisterNativeFirstFrame(scene.get(), first_frame), 0);
    scene.reset();
    EXPECT_EQ(pointer.Drops(), 0);
    EXPECT_EQ(first_frame.Drops(), 0);
    EXPECT_TRUE(pointer.Values().empty());
    EXPECT_EQ(first_frame.first_frames, 0);
}

TEST(SceneSchema, FirstFrameCallbackReplacementClearAndShutdownDropExactlyOnce) {
    NativePointerObservation first;
    NativePointerObservation second;
    NativePointerObservation barrier;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativeFirstFrame(scene.get(), first), 0);
    ASSERT_EQ(RegisterNativeFirstFrame(scene.get(), second), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_first_frame_callback(
        scene.get(), nullptr, nullptr, nullptr), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), barrier), 0);
    ASSERT_TRUE(barrier.Wait(1));
    ASSERT_TRUE(first.Wait(0, 1));
    ASSERT_TRUE(second.Wait(0, 1));
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    scene.reset();
    EXPECT_EQ(first.Drops(), 1);
    EXPECT_EQ(second.Drops(), 1);
    EXPECT_EQ(barrier.Drops(), 1);
    EXPECT_EQ(first.first_frames, 0);
    EXPECT_EQ(second.first_frames, 0);
}

TEST(SceneSchema, MouseButtonBaselineReconcilesLevelsWithoutInventingOrClearingEdges) {
    using Access = wallpaper::SceneWallpaperInputTestAccess;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    auto& native = Access::FromNative(*scene);
    const auto expect_buttons = [&](uint32_t down, uint32_t pressed, uint32_t released) {
        const auto snapshot = Access::ConsumeMouseButtons(native);
        EXPECT_EQ(snapshot.down, down);
        EXPECT_EQ(snapshot.pressed, pressed);
        EXPECT_EQ(snapshot.released, released);
    };

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 31, true), 0);
    EXPECT_NE(owe_scene_wallpaper_set_mouse_button_baseline(nullptr, 0), 0);
    EXPECT_NE(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(0x80000000u, 0x80000000u, 0);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(0, 0, 0);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 1), 0);
    expect_buttons(1, 1, 1);
    expect_buttons(1, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    expect_buttons(0, 0, 1);

    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 1), 0);
    expect_buttons(1, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    expect_buttons(0, 0, 1);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 2, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    EXPECT_NE(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(4, 4, 0);
}

TEST(SceneSchema, MouseButtonCommitBaselineKeepsVideoGatingFromStickingNativeLatch) {
    using Access = wallpaper::SceneWallpaperInputTestAccess;
    NativePointerObservation observation;
    owe_scene_wallpaper* raw = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&raw), 0);
    NativePointerSceneOwner scene(raw);
    auto& native = Access::FromNative(*scene);
    ASSERT_EQ(owe_scene_wallpaper_init(scene.get()), 0);
    ASSERT_EQ(RegisterNativePointer(scene.get(), observation), 0);
    ASSERT_TRUE(observation.Wait(1));
    const auto expect_buttons = [&](uint32_t down, uint32_t pressed, uint32_t released) {
        const auto snapshot = Access::ConsumeMouseButtons(native);
        EXPECT_EQ(snapshot.down, down);
        EXPECT_EQ(snapshot.pressed, pressed);
        EXPECT_EQ(snapshot.released, released);
    };
    auto interactive = MakePointerCommitScene(true);
    auto video = MakePointerCommitScene(false);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    Access::PostScene(native, interactive);
    ASSERT_TRUE(observation.Wait(2));
    expect_buttons(0, 1, 1);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    Access::PostScene(native, MakePointerCommitScene(true));
    ASSERT_TRUE(observation.Wait(3));
    expect_buttons(1, 1, 0);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, false), 0);
    Access::PostScene(native, video);
    ASSERT_TRUE(observation.Wait(4));
    expect_buttons(1, 0, 0);
    // The release observed during video was intentionally not sent to native.
    Access::PostScene(native, interactive);
    ASSERT_TRUE(observation.Wait(5));
    expect_buttons(1, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 0), 0);
    expect_buttons(0, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, true), 0);
    expect_buttons(1, 1, 0);

    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    Access::PostScene(native, video);
    ASSERT_TRUE(observation.Wait(6));
    expect_buttons(0, 0, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 1, false), 0);
    Access::PostScene(native, MakePointerCommitScene(true));
    ASSERT_TRUE(observation.Wait(7));
    expect_buttons(0, 0, 0);
    // Post-commit edges survive the held-level seed from the new sample.
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 2, true), 0);
    ASSERT_EQ(owe_scene_wallpaper_set_mouse_button_baseline(scene.get(), 5), 0);
    expect_buttons(5, 4, 0);
    ASSERT_EQ(owe_scene_wallpaper_mouse_button(scene.get(), 0, false), 0);
    expect_buttons(4, 0, 1);
    ASSERT_EQ(owe_scene_wallpaper_shutdown(scene.get()), 0);
    EXPECT_FALSE(interactive->first_frame_ok);
    EXPECT_FALSE(video->first_frame_ok);
}
#endif

namespace {
/// A scene whose only content is a script that reveals a node when something
/// is playing, which is the shape this wallpaper's cover group has.
std::shared_ptr<wallpaper::Scene> MakeMediaProbeScene(std::shared_ptr<wallpaper::SceneNode>& probe) {
    auto scene = std::make_shared<wallpaper::Scene>();
    scene->activeCamera = nullptr;
    scene->sceneGraph.reset();
    scene->runtime = wallpaper::CreateSceneRuntimeContext(wallpaper::SceneRuntimeBootstrap {});
    if (scene->runtime == nullptr) return scene;
    probe = std::make_shared<wallpaper::SceneNode>();
    probe->SetVisible(false);
    scene->runtime->RegisterNode("probe", probe.get());
    scene->runtime->RegisterSceneScript(
        R"JS(
scene.on('mediaPlaybackChanged', function(event) {
  if (event.state === MediaPlaybackEvent.PLAYBACK_PLAYING) {
    scene.getObject('probe').visible = true;
  }
});
)JS",
        "");
    return scene;
}

/// Returns once both loopers have handled everything posted before the call:
/// a render-looper round trip, a main-looper round trip (installing a pointer
/// callback replays the current capability from the main looper), and a
/// render-looper round trip again for whatever the main looper forwarded.
///
/// Shutting down stops the loopers without draining them, so a test that
/// posts a scene and shuts down straight away otherwise measures whether the
/// render thread happened to get there first.
void WaitForPostedWork(wallpaper::SceneWallpaper& wallpaper) {
    ASSERT_TRUE(wallpaper.beginSurfaceReconfigure());
    struct Replay {
        std::mutex              mutex;
        std::condition_variable changed;
        bool                    seen { false };
    };
    auto replay = std::make_shared<Replay>();
    wallpaper.setPropertyObject(wallpaper::PROPERTY_POINTER_INPUT_CALLBACK,
                                std::make_shared<wallpaper::PointerInputCallback>([replay](bool) {
                                    std::scoped_lock lock(replay->mutex);
                                    replay->seen = true;
                                    replay->changed.notify_all();
                                }));
    {
        std::unique_lock lock(replay->mutex);
        ASSERT_TRUE(replay->changed.wait_for(lock, std::chrono::seconds(5),
                                             [&] { return replay->seen; }));
    }
    ASSERT_TRUE(wallpaper.beginSurfaceReconfigure());
}
} // namespace

TEST(SceneSchema, MediaStateSurvivesTheSceneItArrivedBefore) {
    // The host submits what is playing whenever it learns it, and a wallpaper
    // being rebuilt -- a property change reloads the scene on the same object,
    // a wallpaper switch builds a new one -- has no runtime to receive it for
    // as long as the parse takes. Dropping it there left a scene whose cover
    // group is revealed by `mediaPlaybackChanged` blank until the user pressed
    // pause and play again.
    wallpaper::SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    wallpaper.setPropertyBool(wallpaper::PROPERTY_MEDIA_INTEGRATION_ENABLED, true);
    wallpaper.setPropertyString(wallpaper::PROPERTY_MEDIA_EVENT_JSON,
                                R"({"type":"mediaPlaybackChanged","state":1})");

    std::shared_ptr<wallpaper::SceneNode> probe;
    auto scene = MakeMediaProbeScene(probe);
    ASSERT_NE(scene->runtime, nullptr);
    ASSERT_NE(probe, nullptr);
    ASSERT_FALSE(scene->runtime->NodeVisible("probe"));

    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    WaitForPostedWork(wallpaper);
    wallpaper.shutdown();

    EXPECT_TRUE(scene->runtime->NodeVisible("probe"))
        << "a scene attached after the event never learned what was playing";
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

#if defined(__APPLE__)
TEST(SceneSchema, MediaArtworkClearCrossesTheNativeBoundaryAndReplacesPendingPixels) {
    struct NativeOwner {
        owe_scene_wallpaper* value {nullptr};
        ~NativeOwner() { if (value != nullptr) owe_scene_wallpaper_delete(value); }
    } native;
    ASSERT_EQ(owe_scene_wallpaper_new(&native.value), 0);
    auto& wallpaper = wallpaper::SceneWallpaperInputTestAccess::FromNative(*native.value);
    ASSERT_TRUE(wallpaper.init());
    wallpaper.setPropertyBool(wallpaper::PROPERTY_MEDIA_INTEGRATION_ENABLED, true);
    const std::array<uint8_t, 4> cover {20, 80, 140, 255}, empty {};
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 1, 1, cover.data(), cover.size()), 0);
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 0, 0, nullptr, 0), 0);
    std::shared_ptr<wallpaper::SceneNode> probe;
    auto scene = MakeMediaProbeScene(probe);
    scene->imageParser = std::make_unique<wallpaper::RuntimeImageSource>(nullptr);
    auto* images = static_cast<wallpaper::RuntimeImageSource*>(scene->imageParser.get());
    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    WaitForPostedWork(wallpaper);
    EXPECT_TRUE(images->MatchesRgba("$mediaThumbnail", 1, 1, empty.data(), empty.size()));
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 1, 1, cover.data(), cover.size()), 0);
    WaitForPostedWork(wallpaper);
    EXPECT_TRUE(images->MatchesRgba("$mediaThumbnail", 1, 1, cover.data(), cover.size()));
    const auto covered_version = images->Version("$mediaThumbnail");
    EXPECT_NE(owe_scene_wallpaper_apply_system_media_artwork(native.value, 0, 1, nullptr, 0), 0);
    EXPECT_NE(owe_scene_wallpaper_apply_system_media_artwork(native.value, 2, 2, cover.data(), cover.size()), 0);
    EXPECT_EQ(images->Version("$mediaThumbnail"), covered_version);
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 0, 0, nullptr, 0), 0);
    WaitForPostedWork(wallpaper);
    EXPECT_TRUE(images->MatchesRgba("$mediaThumbnail", 1, 1, empty.data(), empty.size()));
    EXPECT_TRUE(images->MatchesRgba("$mediaPreviousThumbnail", 1, 1, empty.data(), empty.size()));
    const auto cleared_version = images->Version("$mediaThumbnail");
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 0, 0, nullptr, 0), 0);
    WaitForPostedWork(wallpaper);
    EXPECT_EQ(images->Version("$mediaThumbnail"), cleared_version);
    ASSERT_EQ(owe_scene_wallpaper_apply_system_media_artwork(native.value, 1, 1, cover.data(), cover.size()), 0);
    WaitForPostedWork(wallpaper);
    EXPECT_TRUE(images->MatchesRgba("$mediaThumbnail", 1, 1, cover.data(), cover.size()));
    wallpaper.shutdown();
}
#endif

TEST(SceneSchema, WithdrawingConsentDropsWhatWasRetained) {
    // Turning the setting back on must not resurrect what was playing when it
    // was last on. Retaining without clearing would replay a stale event here,
    // which is the only way this sequence can reveal the probe -- while the
    // setting is off both the replay and the runtime refuse to dispatch, so a
    // test that never re-enables pins nothing.
    wallpaper::SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    wallpaper.setPropertyBool(wallpaper::PROPERTY_MEDIA_INTEGRATION_ENABLED, true);
    wallpaper.setPropertyString(wallpaper::PROPERTY_MEDIA_EVENT_JSON,
                                R"({"type":"mediaPlaybackChanged","state":1})");
    wallpaper.setPropertyBool(wallpaper::PROPERTY_MEDIA_INTEGRATION_ENABLED, false);
    wallpaper.setPropertyBool(wallpaper::PROPERTY_MEDIA_INTEGRATION_ENABLED, true);

    std::shared_ptr<wallpaper::SceneNode> probe;
    auto scene = MakeMediaProbeScene(probe);
    ASSERT_NE(scene->runtime, nullptr);

    wallpaper::SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    WaitForPostedWork(wallpaper);
    wallpaper.shutdown();

    EXPECT_FALSE(scene->runtime->NodeVisible("probe"))
        << "consent was withdrawn and what was playing then was replayed anyway";
}

TEST(SceneSchema, NoFrameClockRunsWithoutAScene) {
    // A surface still parsing, or one whose load failed, has nothing to draw.
    // Its frame clock used to start with the renderer and tick at 30 fps for as
    // long as the surface lived, posting draws that found no scene.
    wallpaper::RendererCounters::SetEnabled(true);
    wallpaper::SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    const auto wakeups = [&] {
        std::array<uint64_t, OWE_RC_COUNT> values {};
        wallpaper.counters(values.data(), values.size());
        return values[OWE_RC_TIMER_WAKEUPS];
    };
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    EXPECT_EQ(wakeups(), 0u) << "the frame clock ticked before any scene existed";

    // Asked to play a source that yields no scene, the clock still has nothing
    // to drive, so only the missing scene can be what keeps it stopped.
    wallpaper::SceneWallpaperConfig config;
    config.source = (std::filesystem::temp_directory_path() / "owe-no-such-project" /
                     "project.json")
                        .string();
    config.fps    = 60;
    config.paused = false;
    wallpaper.applyConfig(config);
    WaitForPostedWork(wallpaper);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    EXPECT_EQ(wakeups(), 0u) << "the frame clock ran for a load that produced no scene";
    wallpaper.shutdown();
    wallpaper::RendererCounters::SetEnabled(false);
}

TEST(SceneSchema, ASoundFollowsTheSliderValueTheUserActuallyHas) {
    // scene.json carries the author's number beside the binding. Reading only
    // that number gives a sound whose volume is whatever the wallpaper shipped
    // with, so the user's own slider changes nothing. The binding names the
    // property; the property is where the user's value lives.
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "buttonsvolume", RuntimeScalarValue::Float(0.9f) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    wpscene::WPSoundObject object;
    fs::VFS               vfs;
    const auto            json = nlohmann::json::parse(R"({
      "name": "button_press",
      "sound": ["sounds/button_press.ogg"],
      "playbackmode": "single",
      "volume": {"user": "buttonsvolume", "value": 0.3}
    })");
    ASSERT_TRUE(object.FromJson(json, vfs));
    EXPECT_FLOAT_EQ(object.volume, 0.3f) << "the author's number is still read";
    EXPECT_EQ(object.volume_user, "buttonsvolume");

    // Parse mounts the layer, which would open a system output device.
    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    WPSoundParser::Parse(object, vfs, sound_manager, runtime.get());

    ASSERT_TRUE(runtime->HasSoundLayer("button_press"));
    EXPECT_FLOAT_EQ(runtime->SoundLayerVolume("button_press"), 0.9f)
        << "the sound kept the number scene.json shipped with instead of the user's slider";
}

TEST(SceneSchema, ASoundWithNoBindingKeepsTheAuthorsVolume) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    wpscene::WPSoundObject object;
    fs::VFS               vfs;
    const auto            json = nlohmann::json::parse(R"({
      "name": "click", "sound": ["a.ogg"], "volume": 0.75
    })");
    ASSERT_TRUE(object.FromJson(json, vfs));
    EXPECT_TRUE(object.volume_user.empty());

    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    WPSoundParser::Parse(object, vfs, sound_manager, runtime.get());
    EXPECT_FLOAT_EQ(runtime->SoundLayerVolume("click"), 0.75f);
}

TEST(SceneSchema, AButtonSoundStartsSilentAndPlaysWhenAsked) {
    // These sounds ship `startsilent`, so they are registered not playing and
    // stay that way until a click asks for them. A click that reached the
    // runtime but left the stream silent is the shape of the reported symptom,
    // so both halves are pinned: quiet at rest, playing after the ask.
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    wpscene::WPSoundObject object;
    fs::VFS               vfs;
    const auto            json = nlohmann::json::parse(R"({
      "name": "button_press",
      "sound": ["sounds/button_press.ogg"],
      "playbackmode": "single",
      "startsilent": true,
      "volume": {"user": "buttonsvolume", "value": 0.3}
    })");
    ASSERT_TRUE(object.FromJson(json, vfs));
    EXPECT_TRUE(object.startsilent);

    audio::SoundManager sound_manager(audio::SoundManager::OutputBackend::Null);
    WPSoundParser::Parse(object, vfs, sound_manager, runtime.get());

    ASSERT_TRUE(runtime->HasSoundLayer("button_press"))
        << "the click handler asks for this by name and would find nothing";
    EXPECT_FALSE(runtime->SoundLayerPlaying("button_press"))
        << "a sound that starts silent was already running";

    EXPECT_TRUE(runtime->PlaySoundLayer("button_press"));
    EXPECT_TRUE(runtime->SoundLayerPlaying("button_press"))
        << "the click reached the runtime and the sound stayed silent";
}

TEST(SceneSchema, TheProgressFillFollowsAPublishedTimeline) {
    // The bar this wallpaper draws is not draggable and never was: nothing on
    // it reads the cursor. It is a fill whose origin a script moves, driven
    // only by what the host publishes, so a bar that never moves means the
    // events never arrived rather than that a drag was lost.
    //
    // The author's arithmetic is self-consistent -- `updatePosition` stores
    // milliseconds and the placement divides them back out -- so the fill is
    // pinned at a position the formula makes exact:
    //   -637 + (30 / 300) * 620 = -575
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    // `thisLayer.origin = ...` is a layer write, not this value's result: it
    // lands on the runtime's node translate, which is what the scene draws.
    SceneNode node;
    runtime->RegisterNodeTranslate("Solid", &node,
                                   std::make_unique<DynamicValue>(
                                       linalg::Vector3f(0.0F, 700.0F, 0.0F)));

    ScriptedDynamicValue fill(*runtime, R"JS('use strict';

var lastTitle = null;
var lastPosition = -1;
var displayPosition = -1;
var lastUpdateTime = Date.now();
var isPlaying = false;
var pauseStartTime = null;
var dur = ""; // Variabile per la durata della canzone

export function mediaTimelineChanged(event) {
    var position = event.position;
    updatePosition(position);
    dur = event.duration; // Aggiorna la durata quando la timeline cambia
    console.log("Durata della canzone:", dur);
}

/*
Reset timer to 0 when song title changes
*/
export function mediaPropertiesChanged(event) {
    if (lastTitle !== event.title) {
        lastTitle = event.title;
        lastPosition = -1;
        displayPosition = 0;
        lastUpdateTime = Date.now();
    }
}

export function mediaPlaybackChanged(event) {
    if (event.state === MediaPlaybackEvent.PLAYBACK_PAUSED || event.state === MediaPlaybackEvent.PLAYBACK_STOPPED) {
        isPlaying = false;
        pauseStartTime = Date.now();
    } else {
        isPlaying = true;
        if (pauseStartTime !== null) {
            lastUpdateTime += Date.now() - pauseStartTime;
            pauseStartTime = null;
        }
    }
}

export function update(event) {
    if (!isPlaying || dur === "") {
        return;
    }

    var currentTime = Date.now();
    var elapsedSeconds = currentTime - lastUpdateTime;
    if (elapsedSeconds >= 1000) {
        displayPosition += elapsedSeconds;
        var lengthOfYourBar = 620; // Imposta la lunghezza totale della barra
        var startingXCoordinateOfYourBar = -637; // Coordinata X di partenza della barra
        var YCoordinateOfYourBar = 0; // Coordinata Y della barra

        // Calcola la posizione della barra in base alla durata
        thisLayer.origin = new Vec3(startingXCoordinateOfYourBar + (Math.round(displayPosition / 1000) / dur) * lengthOfYourBar, YCoordinateOfYourBar, 0);
        lastUpdateTime = currentTime;
    }
}

function updatePosition(position) {
    if (position !== lastPosition) {
        lastPosition = position;
        displayPosition = position * 1000;
        var lengthOfYourBar = 620; // Imposta la lunghezza totale della barra
        var startingXCoordinateOfYourBar = -637; // Coordinata X di partenza della barra
        var YCoordinateOfYourBar = 0; // Coordinata Y della barra

        // Calcola la posizione della barra in base alla durata
        thisLayer.origin = new Vec3(startingXCoordinateOfYourBar + (Math.round(displayPosition / 1000) / dur) * lengthOfYourBar, YCoordinateOfYourBar, 0);
        lastUpdateTime = Date.now();
    }
}

export function getDuration() {
    return dur; // Restituisce la durata della canzone
}
)JS", "Solid", {},
                              DynamicValue(linalg::Vector3f(0.0F, 700.0F, 0.0F)));

    // The author places the fill before recording the duration it divides by,
    // so the very first event divides by an unset `dur` and puts the layer at
    // infinity. That is this wallpaper's own ordering, reproduced here rather
    // than papered over, because it is why the bar can start out misplaced.
    fill.DispatchMediaEventJson(
        R"({"type":"mediaTimelineChanged","position":30.0,"duration":300.0})");
    EXPECT_FALSE(std::isfinite(runtime->NodeTranslate("Solid").x()))
        << "the author's first-event ordering was silently corrected";

    // From the next event on the mapping is exact, which is what the bar
    // advancing at all depends on: -637 + (150 / 300) * 620 = -327.
    fill.DispatchMediaEventJson(
        R"({"type":"mediaTimelineChanged","position":150.0,"duration":300.0})");
    EXPECT_NEAR(runtime->NodeTranslate("Solid").x(), -327.0F, 0.5F)
        << "a published timeline did not move the fill";

    // Repeating a position carries no new information and must not jitter.
    fill.DispatchMediaEventJson(
        R"({"type":"mediaTimelineChanged","position":150.0,"duration":300.0})");
    EXPECT_NEAR(runtime->NodeTranslate("Solid").x(), -327.0F, 0.5F);

    // And it keeps tracking rather than latching on whatever arrived first.
    fill.DispatchMediaEventJson(
        R"({"type":"mediaTimelineChanged","position":300.0,"duration":300.0})");
    EXPECT_NEAR(runtime->NodeTranslate("Solid").x(), -17.0F, 0.5F);
}

TEST(SceneSchema, APressedTransportButtonComesBackWhenItIsReleased) {
    // The reported symptom is a transport button stuck flattened after one
    // press. This wallpaper's own scale script shrinks a held button to the
    // `hoScale` its scene ships -- a tenth of its size -- and only restores it
    // from `cursorUp`. Drive that script directly: the press must shrink it and
    // the release must bring it back, because a release that never arrives
    // leaves the button in exactly the state that was reported.
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    std::map<std::string, DynamicValueUniquePtr> script_properties;
    script_properties["hoScale"] = std::make_unique<DynamicValue>(0.1F);
    script_properties["speed"]   = std::make_unique<DynamicValue>(25.0F);
    script_properties["whY"]     = std::make_unique<DynamicValue>(0.0F);

    ScriptedDynamicValue scale(*runtime, R"JS('use strict';

import * as WEMath from 'WEMath';

export var scriptProperties = createScriptProperties()
.addSlider({
		name: 'whY',
		label: 'Scale',
		value: 0.0,
		min: -0.25,
		max: 0.25,
		integer: false
	})
	.addSlider({
		name: 'hoScale',
		label: 'Hover over scale multiplier',
		value: 0.9,
		min: 0.1,
		max: 2,
		integer: false
	})
	.addSlider({
		name: 'speed',
		label: 'Scale change speed',
		value: 100,
		min: 1,
		max: 100,
		integer: false
	})
	.finish();

let initScale, newScale, hover = false, propertyCheck = true, speed;

export function update(value) {
	if (hover) 
	{
		value = new Vec3((WEMath.mix(value.x, newScale.x, speed) + scriptProperties.whY), (WEMath.mix(value.y, newScale.y, speed) + scriptProperties.whY), (WEMath.mix(value.z, newScale.z, speed) + scriptProperties.whY));
	}
	else
	{
		value = new Vec3((WEMath.mix(value.x, initScale.x, speed) + scriptProperties.whY), (WEMath.mix(value.y, initScale.y, speed) + scriptProperties.whY), (WEMath.mix(value.z, initScale.z, speed) + scriptProperties.whY));
	}
	return value;
}

export function init(value) {
	initScale = value;
	return value;
}

export function cursorDown(event) {
	hover = true;
}

export function cursorUp(event) {
	hover = false;
}

export function applyUserProperties(changedUserProperties) {
	if (scriptProperties.hoScale != undefined && propertyCheck)
	{
		newScale = new Vec3(initScale.multiply(scriptProperties.hoScale));
		speed = scriptProperties.speed/100;
		propertyCheck = false;
	}
	
}
)JS", "avanti",
                               std::move(script_properties),
                               DynamicValue(linalg::Vector3f(1.0F, 1.0F, 1.0F)));
    const ScriptHostContext host {};

    scale.reevaluate();
    EXPECT_NEAR(scale.getVec3().y(), 1.0F, 0.01F) << "the button was not its own size at rest";

    scale.DispatchCursorDown(host);
    for (int frame = 0; frame < 40; ++frame) scale.reevaluate();
    const float pressed = scale.getVec3().y();
    EXPECT_LT(pressed, 0.5F) << "the press did not shrink the button, so nothing is being tested";
    EXPECT_GT(pressed, 0.0F);

    scale.DispatchCursorUp(host);
    for (int frame = 0; frame < 40; ++frame) scale.reevaluate();
    EXPECT_NEAR(scale.getVec3().y(), 1.0F, 0.01F)
        << "the button stayed shrunk after release, which is the reported stuck button";
}

// ---------------------------------------------------------------------------
// SceneScript API parity: what needs the parser's own state.
// ---------------------------------------------------------------------------

namespace {

nlohmann::json ScriptParityScene(nlohmann::json objects) {
    return {
        { "camera", { { "center", { 0, 0, -1 } }, { "eye", { 0, 0, 0 } }, { "up", { 0, 1, 0 } } } },
        { "general",
          { { "ambientcolor", { 0, 0, 0 } },
            { "skylightcolor", { 0, 0, 0 } },
            { "clearcolor", { 0, 0, 0 } },
            { "cameraparallax", false },
            { "orthogonalprojection", { { "width", 640 }, { "height", 360 } } } } },
        { "objects", std::move(objects) },
    };
}

std::shared_ptr<Scene> ParseScriptParityScene(fs::VFS& vfs, const nlohmann::json& source) {
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    return parser.Parse(SceneParseRequest {
        .scene_id = "script-parity", .project_properties = &properties,
    }, source.dump(), vfs, sound_manager);
}

void WaitForTextLayoutToSettle(SceneRuntimeContext& runtime, const std::string& layer) {
    for (int attempt = 0; attempt < 400 && runtime.NodeTextDirty(layer); ++attempt) {
        runtime.PumpTextLayerCache();
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

} // namespace

namespace {

// A file system that says whether it was asked while it still existed.
struct FsProbe {
    std::atomic<int>  asked_alive { 0 };
    std::atomic<int>  asked_after_death { 0 };
    std::atomic<bool> dead { false };
};

class ProbeFs final : public fs::Fs {
public:
    explicit ProbeFs(std::shared_ptr<FsProbe> probe): m_probe(std::move(probe)) {}
    ~ProbeFs() override { m_probe->dead = true; }

    bool Contains(std::string_view) const override {
        (m_probe->dead ? m_probe->asked_after_death : m_probe->asked_alive)++;
        return false;
    }
    std::shared_ptr<fs::IBinaryStream>  Open(std::string_view) override { return nullptr; }
    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::shared_ptr<FsProbe> m_probe;
};

} // namespace

TEST(SceneSchema, IntegerSettingsOutsideTheirRangeTakeTheNearestValue) {
    wpscene::WPMaterial material;
    ASSERT_TRUE(material.FromJson(nlohmann::json::parse(
        R"({"passes":[{"shader":"s","combos":{"HIGH":1e30,"LOW":-1e30,"PLAIN":3.9}}]})")));
    EXPECT_EQ(material.combos.at("HIGH"), std::numeric_limits<int32_t>::max());
    EXPECT_EQ(material.combos.at("LOW"), std::numeric_limits<int32_t>::lowest());
    EXPECT_EQ(material.combos.at("PLAIN"), 3);

    int32_t id = 7;
    EXPECT_TRUE(wpscene::ReadNumberSetting(nlohmann::json::parse("1e30"), id));
    EXPECT_EQ(id, std::numeric_limits<int32_t>::max());
    uint32_t count = 7;
    EXPECT_TRUE(wpscene::ReadNumberSetting(nlohmann::json::parse("-5"), count));
    EXPECT_EQ(count, 0u);
}
