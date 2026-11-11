// Scene file schema, part 7: layers that fail to build, the runtime's node registry, the scene's
// clear colour, the pointer capability a wallpaper reports, particles in a scaled layer, cursor
// hit tests and layers a script makes from a workshop model.
//
// All of it runs without a device or a window.
#include "support/schema_fixtures.hpp"

#include "Particle/ParticleSystem.h"
#include "Runtime/DynamicValue.hpp"
#include "Scene/SceneMesh.h"
#include "Scene/SceneNode.h"
#include "Scene/SceneWallpaper.hpp"
#include "WPPuppet.hpp"

#include <gtest/gtest.h>

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace
{

using namespace we_schema;
using namespace wallpaper;

Json V2(double x, double y) { return Json::array({ x, y }); }
Json V3(double x, double y, double z) { return Json::array({ x, y, z }); }

Json Canvas(Json objects, Json general = Json::object())
{
    if (!general.contains("bloom")) general["bloom"] = false;
    return QuietScene(std::move(objects), general);
}

Json MaterialFile(const std::string& shader)
{
    return { { "passes", Json::array({ { { "blending", "translucent" }, { "cullmode", "nocull" }, { "depthtest", "disabled" },
                                         { "depthwrite", "disabled" }, { "shader", shader }, { "textures", Json::array({ "a.tex" }) } } }) } };
}

// ---- layers whose build fails ----------------------------------------------------------------

constexpr const char* kMinimalVertex   = "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }\n";
constexpr const char* kMinimalFragment = "void main() { gl_FragColor = vec4(1.0, 1.0, 1.0, 1.0); }\n";

// A file set with one healthy shader and one whose shader files do not exist. (A shader that is
// there but does not compile no longer fails its layer: Wallpaper Engine's fallback stage draws
// it, `SceneFailurePolicy.AnEffectWhoseShaderCannotBeCompiledDrawsTheFallbackShader`.)
FileMap BrokenShaderAssets()
{
    FileMap files;
    files["/materials/a.tex.tex"] = "";
    for (const char* stem : { "validimage", "validparticle" }) {
        files[std::string("/shaders/") + stem + ".vert"] = kMinimalVertex;
        files[std::string("/shaders/") + stem + ".frag"] = kMinimalFragment;
    }
    PutJson(files, "/valid_mat.json", MaterialFile("validimage"));
    PutJson(files, "/mat.json", MaterialFile("brokenimage"));
    PutJson(files, "/valid_particle_mat.json", MaterialFile("validparticle"));
    PutJson(files, "/broken_particle_mat.json", MaterialFile("brokenparticle"));
    PutJson(files, "/valid.json", { { "width", 64 }, { "height", 32 }, { "material", "valid_mat.json" } });
    PutJson(files, "/image.json", { { "width", 64 }, { "height", 32 }, { "material", "mat.json" } });
    PutJson(files, "/valid_particle.json",
            { { "emitter", Json::array({ { { "name", "emit" }, { "id", 1 } } }) }, { "material", "valid_particle_mat.json" }, { "maxcount", 4 }, { "starttime", 0 } });
    PutJson(files, "/particle.json",
            { { "emitter", Json::array({ { { "name", "emit" }, { "id", 1 } } }) }, { "material", "broken_particle_mat.json" }, { "maxcount", 4 }, { "starttime", 0 } });
    return files;
}

Json ScriptedOrigin(const Json& value)
{
    return { { "value", value }, { "script", "export function update(value) { return value; }" } };
}

// A scene script: no `update`, an event listener on the scene that hides `layer` when the cursor clicks.
std::string HidingListener(const std::string& layer)
{
    return "thisScene.on('cursorClick', function () { thisScene.getLayer('" + layer + "').visible = false; });";
}

// R-7.01 / B-7.01
TEST(FailedLayerBuilds, AnImageLayerWhoseMaterialCannotBeBuiltLeavesNothingBehind)
{
    ParseRig rig(BrokenShaderAssets());
    auto     scene = rig.Parse(Canvas(Json::array({
        { { "id", 310 }, { "name", "valid scripted image" }, { "image", "valid.json" }, { "origin", ScriptedOrigin(V3(4, 0, 0)) }, { "angles", V3(0, 0, 0) }, { "visible", true } },
        { { "id", 311 }, { "name", "failed dynamic image" }, { "image", "image.json" }, { "origin", ScriptedOrigin(V3(0, 0, 0)) },
          { "scale", { { "value", V3(1, 1, 1) }, { "user", "scaleProperty" } } }, { "angles", V3(0, 0, 0) }, { "visible", true } },
    })), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr) << "a layer that cannot be built does not refuse the scene";
    ASSERT_NE(scene->runtime, nullptr);
    SceneRuntimeContext& rt = *scene->runtime;

    EXPECT_EQ(rt.sceneScriptCount(), 1u) << "only the healthy layer's scripted origin is alive";
    EXPECT_TRUE(rt.HasNodeNamed("valid scripted image"));
    EXPECT_FALSE(rt.HasNodeNamed("failed dynamic image"));

    rt.Tick(1.0 / 60.0);
    EXPECT_EQ(rt.scriptErrorCount(), 0u);

    ProjectProperties change;
    change["scaleProperty"] = RuntimeScalarValue::Float(2.0f);
    rt.ApplyProjectPropertyOverride(change);
    rt.Tick(1.0 / 60.0);
    EXPECT_FALSE(rt.HasNodeNamed("failed dynamic image")) << "a property change does not bring the failed layer back";
}

// R-7.02 / B-7.01
TEST(FailedLayerBuilds, AnImageLayerWhoseMaterialCannotBeBuiltLeavesNoSceneScript)
{
    ParseRig rig(BrokenShaderAssets());
    Json     layer = { { "id", 313 }, { "name", "failed scene-script image" }, { "image", "image.json" }, { "origin", V3(0, 0, 0) },
                       { "scale", V3(1, 1, 1) }, { "angles", V3(0, 0, 0) },
                       { "visible", { { "value", true }, { "script", HidingListener("failed scene-script image") } } } };
    auto     scene = rig.Parse(Canvas(Json::array({ layer })), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->HasNodeNamed("failed scene-script image"));
    EXPECT_EQ(scene->runtime->sceneScriptCount(), 0u);
}

// R-7.04 / B-7.01
TEST(FailedLayerBuilds, AParticleLayerWhoseMaterialCannotBeBuiltLeavesNothingBehind)
{
    ParseRig rig(BrokenShaderAssets());
    auto     scene = rig.Parse(Canvas(Json::array({
        { { "id", 310 }, { "name", "valid scripted particle" }, { "particle", "valid_particle.json" }, { "origin", ScriptedOrigin(V3(4, 0, 0)) }, { "visible", true } },
        { { "id", 312 }, { "name", "failed dynamic particle" }, { "particle", "particle.json" }, { "origin", ScriptedOrigin(V3(0, 0, 0)) },
          { "scale", { { "value", V3(1, 1, 1) }, { "user", "scaleProperty" } } },
          { "visible", { { "value", true }, { "script", HidingListener("failed dynamic particle") } } } },
    })), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneRuntimeContext& rt = *scene->runtime;

    EXPECT_EQ(rt.sceneScriptCount(), 1u) << "the failed layer's origin script and its scene-level script are both gone";
    EXPECT_TRUE(rt.HasNodeNamed("valid scripted particle"));
    EXPECT_FALSE(rt.HasNodeNamed("failed dynamic particle"));
    rt.Tick(1.0 / 60.0);
    EXPECT_EQ(rt.scriptErrorCount(), 0u);
}

// ---- the node registry ----------------------------------------------------------------------

// R-7.03 / B-7.02
TEST(NodeRegistry, ARollbackRestoresOrRemovesOnlyTheNodeItWasAskedAbout)
{
    const std::string key = "runtime target";
    auto              rt  = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(rt, nullptr);
    SceneNode previous(linalg::Vector3f(25, 0, 0), linalg::Vector3f(1, 1, 1), linalg::Vector3f(0, 0, 0), key);
    SceneNode failed(linalg::Vector3f(50, 0, 0), linalg::Vector3f(1, 1, 1), linalg::Vector3f(0, 0, 0), key);

    rt->RegisterNode(key, &previous);
    auto memo = rt->CaptureNodeRegistration(key);
    rt->RegisterNode(key, &failed);
    EXPECT_FLOAT_EQ(rt->NodeTranslate(key).x(), 50.0f);

    // A node that is not the registered one is not touched.
    rt->RollbackNodeRegistration(key, &previous, memo);
    EXPECT_TRUE(rt->HasNodeNamed(key));
    EXPECT_FLOAT_EQ(rt->NodeTranslate(key).x(), 50.0f);

    rt->RollbackNodeRegistration(key, &failed, memo);
    EXPECT_TRUE(rt->HasNodeNamed(key));
    EXPECT_FLOAT_EQ(rt->NodeTranslate(key).x(), 25.0f) << "what stood there before is back";

    rt->RegisterNode(key, &failed);
    rt->RollbackNodeRegistration(key, &failed, nullptr);
    EXPECT_FALSE(rt->HasNodeNamed(key)) << "without a memo the key is simply released";
}

// R-7.05 / B-7.03
TEST(NodeRegistry, AProjectPropertyOfTheBootstrapTableCanBeFound)
{
    SceneRuntimeBootstrap bootstrap;
    bootstrap.project_properties["speed"] = RuntimeScalarValue::Float(2.5f);
    auto rt = CreateSceneRuntimeContext(std::move(bootstrap));
    ASSERT_NE(rt, nullptr);
    DynamicValue* speed = rt->FindPropertyValue("speed");
    ASSERT_NE(speed, nullptr);
    EXPECT_FLOAT_EQ(speed->getFloat(), 2.5f);
    EXPECT_EQ(rt->FindPropertyValue("absent"), nullptr);
}

// ---- clear colour -----------------------------------------------------------------------------

Json BoundClearColour() { return { { "user", "background_color" }, { "value", "0.1 0.2 0.3" } }; }

// R-7.06 / B-7.04
TEST(ClearColour, AColourBoundToAPropertyFollowsItAtLoadAndWhenItChanges)
{
    ParseRig rig(FileMap {});
    rig.properties()["background_color"] = RuntimeScalarValue::String("0.25 0.5 0.75");
    auto scene = rig.Parse(Canvas(Json::array(), { { "clearcolor", BoundClearColour() } }), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FLOAT_EQ(scene->clearColor[0], 0.25f);
    EXPECT_FLOAT_EQ(scene->clearColor[1], 0.5f);
    EXPECT_FLOAT_EQ(scene->clearColor[2], 0.75f);

    ProjectProperties change;
    change["background_color"] = RuntimeScalarValue::String("0.5 0.25 0.125");
    scene->runtime->ApplyProjectPropertyOverride(change);
    EXPECT_FLOAT_EQ(scene->clearColor[0], 0.5f);
    EXPECT_FLOAT_EQ(scene->clearColor[1], 0.25f);
    EXPECT_FLOAT_EQ(scene->clearColor[2], 0.125f);
}

TEST(ClearColour, WithNoPropertySavedTheAuthoredFallbackApplies)
{
    ParseRig rig(FileMap {});
    auto     scene = rig.Parse(Canvas(Json::array(), { { "clearcolor", BoundClearColour() } }), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    EXPECT_FLOAT_EQ(scene->clearColor[0], 0.1f);
    EXPECT_FLOAT_EQ(scene->clearColor[1], 0.2f);
    EXPECT_FLOAT_EQ(scene->clearColor[2], 0.3f);
}

// ---- pointer capability -----------------------------------------------------------------------

// Records what a callback is told, and lets a test wait for it with a bound.
class Recorder {
public:
    void Add(bool value)
    {
        {
            std::lock_guard lock(mutex_);
            values_.push_back(value);
        }
        changed_.notify_all();
    }
    bool WaitForCount(std::size_t count)
    {
        std::unique_lock lock(mutex_);
        return changed_.wait_for(lock, std::chrono::seconds(5), [&] { return values_.size() >= count; });
    }
    std::vector<bool> Values()
    {
        std::lock_guard lock(mutex_);
        return values_;
    }

private:
    std::mutex              mutex_;
    std::condition_variable changed_;
    std::vector<bool>       values_;
};

// R-7.07 / B-7.05
TEST(PointerCapability, EverySceneCommitReportsItAndConfigurationDoesNot)
{
    SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());

    Recorder    first, second;
    std::mutex  frame_mutex;
    int         first_frames = 0;
    auto        watch        = [&](Recorder& into) {
        wallpaper.setPropertyObject(PROPERTY_POINTER_INPUT_CALLBACK, std::make_shared<PointerInputCallback>([&into](bool accepts) { into.Add(accepts); }));
    };

    auto refusing = std::make_shared<Scene>();
    refusing->accepts_pointer_input = false;
    auto video = std::make_shared<Scene>();
    ASSERT_TRUE(video->accepts_pointer_input);
    video->textures["clip"].isVideo = true;

    wallpaper.setPropertyObject(PROPERTY_FIRST_FRAME_CALLBACK, std::make_shared<FirstFrameCallback>([&] {
        std::lock_guard lock(frame_mutex);
        ++first_frames;
    }));

    watch(first);
    ASSERT_TRUE(first.WaitForCount(1));
    EXPECT_EQ(first.Values(), (std::vector<bool> { true })) << "installing replays the current capability";

    SceneWallpaperInputTestAccess::PostScene(wallpaper, refusing);
    ASSERT_TRUE(first.WaitForCount(2));
    EXPECT_EQ(first.Values(), (std::vector<bool> { true, false }));

    wallpaper.setPropertyBool(PROPERTY_FORCE_SHADER_REFRESH, true);
    watch(second);
    ASSERT_TRUE(second.WaitForCount(1));
    EXPECT_EQ(second.Values(), (std::vector<bool> { false }));

    std::size_t expected = 1;
    for (const auto& scene : { video, video, refusing, std::shared_ptr<Scene> {} }) {
        SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
        ASSERT_TRUE(second.WaitForCount(++expected)) << "commit " << expected - 1;
    }

    wallpaper.shutdown();
    EXPECT_EQ(second.Values(), (std::vector<bool> { false, true, true, false, true })) << "reported on every commit, even when nothing changed";
    EXPECT_EQ(first.Values(), (std::vector<bool> { true, false })) << "a replaced callback hears nothing more";
    EXPECT_FALSE(refusing->first_frame_ok);
    EXPECT_FALSE(video->first_frame_ok);
    std::lock_guard lock(frame_mutex);
    EXPECT_EQ(first_frames, 0);
}

// ---- particles in a scaled layer --------------------------------------------------------------

// A particle file with one still emitter at `origin` (and the optional extras), flagged layer-space (0) or world-space (1).
Json StillParticle(int flags, const std::string& origin, const Json& extra = Json::object())
{
    Json emitter = { { "name", "boxrandom" }, { "id", 1 }, { "origin", origin }, { "distancemin", "0 0 0" }, { "distancemax", "0 0 0" },
                     { "speedmin", 0 }, { "speedmax", 0 }, { "rate", 100 }, { "instantaneous", 1 } };
    Json file    = { { "emitter", Json::array({ emitter }) },
                     { "initializer", Json::array({ { { "name", "lifetimerandom" }, { "min", 10 }, { "max", 10 } } }) },
                     { "material", "mat.json" },
                     { "maxcount", 1 },
                     { "starttime", 0 },
                     { "flags", flags } };
    for (const auto& [key, value] : extra.items()) file[key] = value;
    return file;
}

Json ParticleLayer(const std::string& name, const std::string& file, const Json& scale)
{
    return { { "id", 1 }, { "name", name }, { "particle", file }, { "origin", V3(320, 180, 0) }, { "scale", scale }, { "visible", true } };
}

// The drawn position of the first particle after `steps` simulation steps.
std::vector<linalg::Vector3d> DrawnPositions(Scene& scene, const std::string& layer, int steps)
{
    std::vector<linalg::Vector3d> drawn;
    SceneNode* node = FindRootChild(scene, layer);
    EXPECT_NE(node, nullptr);
    EXPECT_NE(scene.paritileSys, nullptr);
    if (node == nullptr || scene.paritileSys == nullptr) return drawn;
    for (int step = 0; step < steps; ++step) {
        scene.frameTime = 1.0 / 60.0;
        scene.paritileSys->Emitt();
        EXPECT_FALSE(scene.paritileSys->subsystems.empty());
        if (scene.paritileSys->subsystems.empty()) return drawn;
        const auto& instances = scene.paritileSys->subsystems.front()->Instances();
        EXPECT_FALSE(instances.empty());
        if (instances.empty()) return drawn;
        const auto particles = instances.front()->Particles();
        EXPECT_FALSE(particles.empty());
        if (particles.empty()) return drawn;
        node->UpdateTrans();
        const linalg::Vector4d at = node->RenderTrans() * linalg::Vector4d(particles[0].position.x(), particles[0].position.y(), particles[0].position.z(), 1.0);
        drawn.emplace_back(at.x(), at.y(), at.z());
    }
    return drawn;
}

FileMap WithParticleFiles(std::initializer_list<std::pair<const char*, Json>> files)
{
    FileMap assets = BasicAssets();
    for (const auto& [path, document] : files) PutJson(assets, path, document);
    return assets;
}

class EmitterOrigin : public testing::TestWithParam<int> {};

// R-7.08 / B-7.06
TEST_P(EmitterOrigin, AnEmitterOriginScalesWithItsLayerUnlessTheParticleFileIsWorldSpace)
{
    const int flags = GetParam();
    ParseRig  rig(WithParticleFiles({ { "/still.json", StillParticle(flags, "0 50 0") } }));
    auto      scene = rig.Parse(Canvas(Json::array({ ParticleLayer("snow", "still.json", V3(2, 2, 1)) })));
    ASSERT_NE(scene, nullptr);
    const auto drawn = DrawnPositions(*scene, "snow", 1);
    ASSERT_EQ(drawn.size(), 1u);
    EXPECT_NEAR(drawn[0].x(), 320.0, 1e-3);
    EXPECT_NEAR(drawn[0].y(), flags == 0 ? 280.0 : 230.0, 1e-3);
}

INSTANTIATE_TEST_SUITE_P(Space, EmitterOrigin, testing::Values(0, 1),
                         [](const testing::TestParamInfo<int>& info) { return info.param == 0 ? "LayerSpace" : "WorldSpace"; });

class StretchedLayer : public testing::TestWithParam<int> {};

// R-7.09 / B-7.07
TEST_P(StretchedLayer, SpawnOffsetsStretchAndSpeedStretchesOnlyInLayerSpace)
{
    const int flags = GetParam();
    const Json extra = { { "operator", Json::array({ { { "name", "movement" }, { "id", 2 } } }) } };
    Json       file  = StillParticle(flags, "0 0 0", extra);
    file["emitter"][0]["directions"]  = "1 1 0";
    file["emitter"][0]["distancemin"] = "5 5 0";
    file["emitter"][0]["distancemax"] = "5 5 0";
    file["emitter"][0]["speedmin"]    = 60;
    file["emitter"][0]["speedmax"]    = 60;

    ParseRig rig(WithParticleFiles({ { "/haze.json", file } }));
    auto     scene = rig.Parse(Canvas(Json::array({ ParticleLayer("haze", "haze.json", V3(24, 1, 1)) })));
    ASSERT_NE(scene, nullptr);
    const auto drawn = DrawnPositions(*scene, "haze", 2);
    ASSERT_EQ(drawn.size(), 2u);

    const double a = 0.7071067811865476;
    const double h = 120.0 / std::hypot(120.0, 5.0);
    const double first_offset = std::abs(drawn[0].x() - 320.0);
    const double step_length  = (drawn[1] - drawn[0]).norm();
    if (flags == 0) {
        EXPECT_NEAR(first_offset, 24.0 * (5.0 + a), 1e-3);
        EXPECT_NEAR(step_length, a * std::hypot(24.0, 1.0), 1e-3);
    } else {
        EXPECT_NEAR(first_offset, 120.0 + h, 1e-3);
        EXPECT_NEAR(step_length, 1.0, 1e-3);
    }
}

INSTANTIATE_TEST_SUITE_P(Space, StretchedLayer, testing::Values(0, 1),
                         [](const testing::TestParamInfo<int>& info) { return info.param == 0 ? "LayerSpace" : "WorldSpace"; });

struct ChildRow {
    const char* type;
    int         parent_flags;
    int         child_flags;
    double      y;
};

class ChildOrigin : public testing::TestWithParam<ChildRow> {};

// R-7.10 / B-7.08
TEST_P(ChildOrigin, AChildSystemsOriginScalesWithTheLayerByTheTypeAndFlagsOfTheTwoFiles)
{
    const ChildRow row = GetParam();
    Json parent = StillParticle(row.parent_flags, "0 0 0");
    parent["children"] = Json::array({ { { "name", "child_particle.json" }, { "type", row.type }, { "maxcount", 1 }, { "origin", "0 50 0" } } });
    ParseRig rig(WithParticleFiles({ { "/snow.json", parent }, { "/child_particle.json", StillParticle(row.child_flags, "0 0 0") } }));
    auto     scene = rig.Parse(Canvas(Json::array({ ParticleLayer("snow", "snow.json", V3(2, 2, 1)) })));
    ASSERT_NE(scene, nullptr);
    SceneNode* layer = FindRootChild(*scene, "snow");
    ASSERT_NE(layer, nullptr);
    ASSERT_EQ(layer->GetChildren().size(), 1u);
    SceneNode* child = layer->GetChildren().front().get();
    ASSERT_NE(child, nullptr);
    ASSERT_NE(scene->paritileSys, nullptr);
    scene->frameTime = 1.0 / 60.0;
    scene->paritileSys->Emitt();
    ASSERT_NE(child->Mesh(), nullptr);
    ASSERT_EQ(child->Mesh()->VertexCount(), 1u);
    ASSERT_GT(child->Mesh()->GetIndexArray(0).DrawIndexCount(), 0u);
    const auto& vertices = child->Mesh()->GetVertexArray(0);
    const float* position = vertices.Data();
    child->UpdateTrans();
    // A world parent's event child draws in its simulation frame. The authored
    // node hierarchy still carries the layer scale, so test the generated
    // particle and its draw matrix, as the renderer consumes them.
    const linalg::Vector4d placed = child->RenderTrans() *
        linalg::Vector4d(position[0], position[1], position[2], 1.0);
    EXPECT_NEAR(placed.x(), 320.0, 1e-3);
    EXPECT_NEAR(placed.y(), row.y, 1e-3);
}

INSTANTIATE_TEST_SUITE_P(Rows, ChildOrigin,
                         testing::Values(ChildRow { "static", 0, 0, 280 }, ChildRow { "static", 0, 1, 230 }, ChildRow { "static", 1, 0, 230 },
                                         ChildRow { "static", 1, 1, 230 }, ChildRow { "eventfollow", 0, 0, 280 }, ChildRow { "eventfollow", 0, 1, 280 },
                                         ChildRow { "eventfollow", 1, 0, 230 }, ChildRow { "eventfollow", 1, 1, 230 }),
                         [](const testing::TestParamInfo<ChildRow>& info) {
                             return std::string(info.param.type) + "Parent" + std::to_string(info.param.parent_flags) + "Child" + std::to_string(info.param.child_flags);
                         });

// ---- a puppet layer whose material fails ------------------------------------------------------

// R-7.11 / B-7.09
TEST(FailedLayerBuilds, APuppetLayerWhoseMaterialCannotBeBuiltLeavesItsAnimationControlsDead)
{
    FileMap files = PuppetAssets();
    files.erase("/shaders/baseimage.frag");
    files.erase("/shaders/baseimage.vert");
    ParseRig rig(files);
    for (const char* name : { "visible", "rate", "blend" }) rig.properties()[name] = name == std::string("visible") ? RuntimeScalarValue::Bool(true) : RuntimeScalarValue::Float(1.0f);

    auto bound = [](const char* property, const Json& value) { return Json { { "value", value }, { "user", property } }; };
    Json layer = { { "id", 300 }, { "name", "puppet image" }, { "image", "puppet_image.json" }, { "origin", V3(0, 0, 0) }, { "scale", V3(1, 1, 1) },
                   { "angles", V3(0, 0, 0) }, { "visible", true }, { "alpha", 0.6 },
                   { "animationlayers", Json::array({ { { "animation", 7 }, { "name", "gesture" }, { "visible", bound("visible", true) },
                                                         { "rate", bound("rate", 1.0) }, { "blend", bound("blend", 1.0) } } }) } };
    auto scene = rig.Parse(Canvas(Json::array({ layer })), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneRuntimeContext& rt = *scene->runtime;
    EXPECT_FALSE(rt.HasNodeNamed("puppet image"));
    EXPECT_EQ(rt.FindPuppetLayer("puppet image"), nullptr);

    ProjectProperties change;
    change["visible"] = RuntimeScalarValue::Bool(false);
    change["rate"]    = RuntimeScalarValue::Float(2.0f);
    change["blend"]   = RuntimeScalarValue::Float(0.25f);
    rt.ApplyProjectPropertyOverride(change);
    rt.Tick(0.01);
    EXPECT_EQ(rt.FindPuppetLayer("puppet image"), nullptr);
    EXPECT_EQ(rt.PuppetAnimationControl("puppet image", "gesture", "exists", 0.0, false), 0.0);
}

// ---- cursor hit tests --------------------------------------------------------------------------

// A texture file with a 4x2 allocation holding a 2x1 picture; the picture's two texels have alpha 15 and 16.
std::string PaddedPictureTexture()
{
    ByteWriter out;
    out.Stamp("TEXV", 5).Stamp("TEXI", 1);
    out.I32(0).U32(0).I32(4).I32(2).I32(2).I32(1).I32(0);
    out.Stamp("TEXB", 3);
    out.I32(1).I32(-1).I32(1);
    out.I32(4).I32(2).I32(0).I32(0).I32(32);
    for (int texel = 0; texel < 8; ++texel) {
        const std::uint8_t alpha = texel == 0 ? 15 : texel == 1 ? 16 : 0;
        out.U8(255).U8(255).U8(255).U8(alpha);
    }
    return out.Take();
}

// R-7.12 / B-7.10
TEST(CursorHitTest, AHitMaskCoversTheAuthoredRegionOfAPaddedTextureOnly)
{
    FileMap files = PuppetAssets();
    PutJson(files, "/puppet_image.json", { { "material", "mat/base.json" }, { "width", 40 }, { "height", 20 } });
    files["/materials/base.tex.tex"] = PaddedPictureTexture();
    ParseRig rig(files);

    const std::string click_hides = "export function cursorClick() { thisLayer.visible = false; }";
    Json layer = { { "id", 300 }, { "name", "puppet image" }, { "image", "puppet_image.json" }, { "origin", V3(100, 100, 0) }, { "scale", V3(1, 1, 1) },
                   { "visible", { { "value", true }, { "script", click_hides } } }, { "alpha", 0.6 } };
    auto scene = rig.Parse(Canvas(Json::array({ layer })), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneRuntimeContext& rt = *scene->runtime;

    rt.Tick(0.0);
    EXPECT_EQ(rt.NodeSize("puppet image").x(), 40.0f);
    EXPECT_EQ(rt.NodeSize("puppet image").y(), 20.0f);
    EXPECT_TRUE(rt.NodeVisible("puppet image"));

    rt.SetCursorEnter(true);
    rt.SetCursorButtons(0, 1, 1);
    rt.SetCursorWorldPosition(linalg::Vector3f(90.0f, 100.0f, 0.0f));
    rt.DispatchCursorFrameEvents(false);
    EXPECT_TRUE(rt.NodeVisible("puppet image")) << "the texel under the cursor is just below the threshold";

    rt.SetCursorWorldPosition(linalg::Vector3f(110.0f, 100.0f, 0.0f));
    rt.DispatchCursorFrameEvents(true);
    EXPECT_FALSE(rt.NodeVisible("puppet image")) << "the next texel is covered, so the click ran";
    EXPECT_EQ(rt.scriptErrorCount(), 0u);
}

// R-7.13 / B-7.11
TEST(CursorHitTest, ALayerThatShrinksWhileHeldStillHearsItsOwnRelease)
{
    const std::string script = R"JS('use strict';
var held = false;
export function update(value) {
    return held ? new Vec3(0.1, 0.1, 1.0) : new Vec3(1, 1, 1);
}
export function cursorDown(event) { held = true; }
export function cursorUp(event) { held = false; }
)JS";
    ParseRig rig(BasicAssets());
    Json     avanti = { { "id", 1 }, { "name", "avanti" }, { "image", "image.json" }, { "origin", V3(200, 150, 0) }, { "size", V2(80, 80) },
                        { "scale", { { "script", script }, { "value", "1.00000 1.00000 1.00000" } } }, { "visible", true } };
    auto scene = rig.Parse(Canvas(Json::array({ avanti }), { { "orthogonalprojection", { { "width", 400 }, { "height", 300 } } } }), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneRuntimeContext& rt = *scene->runtime;

    rt.Tick(0.01);
    rt.SetCursorInput(230.0f / 400.0f, 150.0f / 300.0f);
    rt.SetCursorEnter(true);
    rt.Tick(0.01);
    EXPECT_NEAR(rt.NodeScale("avanti").x(), 1.0f, 0.01f) << "the cursor is inside the button, outside what it shrinks to";

    rt.SetCursorButtons(1, 1, 0);
    rt.DispatchCursorFrameEvents(true);
    rt.SetCursorButtons(1, 0, 0);
    rt.Tick(0.01);
    EXPECT_NEAR(rt.NodeScale("avanti").x(), 0.1f, 0.01f) << "pressed: shrunk away from under the cursor";

    rt.SetCursorButtons(0, 0, 1);
    rt.DispatchCursorFrameEvents(true);
    rt.SetCursorButtons(0, 0, 0);
    rt.Tick(0.01);
    EXPECT_NEAR(rt.NodeScale("avanti").x(), 1.0f, 0.01f) << "released: the press owner is told wherever the cursor is";
    EXPECT_EQ(rt.scriptErrorCount(), 0u);
}

// `CursorEvent.localPosition` is where the cursor is on the program's own layer, measured from
// the corner of its box: 0 to its size on each axis while over it.
TEST(CursorHitTest, ACursorEventSaysWhereOnItsLayerTheCursorIs)
{
    const std::string script = R"JS('use strict';
var at = null;
export function update(value) { return at ? new Vec3(at.x, at.y, 1) : value; }
export function cursorDown(event) { at = event.localPosition; }
)JS";
    ParseRig rig(BasicAssets());
    Json     pad = { { "id", 1 }, { "name", "pad" }, { "image", "image.json" }, { "origin", V3(200, 150, 0) }, { "size", V2(80, 80) },
                     { "scale", { { "script", script }, { "value", "1.00000 1.00000 1.00000" } } }, { "visible", true } };
    auto scene = rig.Parse(Canvas(Json::array({ pad }), { { "orthogonalprojection", { { "width", 400 }, { "height", 300 } } } }), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneRuntimeContext& rt = *scene->runtime;

    rt.Tick(0.01);
    rt.SetCursorInput(230.0f / 400.0f, 150.0f / 300.0f);
    rt.SetCursorEnter(true);
    rt.Tick(0.01);
    rt.SetCursorButtons(1, 1, 0);
    rt.DispatchCursorFrameEvents(true);
    rt.SetCursorButtons(1, 0, 0);
    rt.Tick(0.01);
    EXPECT_NEAR(rt.NodeScale("pad").x(), 70.0f, 0.01f) << "30 right of the centre of an 80-wide box";
    EXPECT_NEAR(rt.NodeScale("pad").y(), 40.0f, 0.01f) << "half way up it";
    EXPECT_EQ(rt.scriptErrorCount(), 0u);
}

// ---- a script-made layer from a workshop model ------------------------------------------------

std::string WhiteTexture(int allocated_w, int allocated_h, int picture_w, int picture_h)
{
    ByteWriter out;
    out.Stamp("TEXV", 5).Stamp("TEXI", 1);
    out.I32(0).U32(0).I32(allocated_w).I32(allocated_h).I32(picture_w).I32(picture_h).I32(0);
    out.Stamp("TEXB", 3);
    out.I32(1).I32(-1).I32(1);
    const int bytes = allocated_w * allocated_h * 4;
    out.I32(allocated_w).I32(allocated_h).I32(0).I32(bytes).I32(bytes);
    for (int i = 0; i < bytes; ++i) out.U8(255);
    return out.Take();
}

// R-7.14 / B-7.12
TEST(ScriptMadeLayers, ACreatedLayerFindsAWorkshopModelByTheScriptsDeclaredItemAndTakesThePicturesSize)
{
    FileMap files = BasicAssets();
    PutJson(files, "/models/workshop/123/bar.json", { { "autosize", true }, { "material", "materials/workshop/123/bar.json" } });
    PutJson(files, "/materials/workshop/123/bar.json",
            { { "passes", Json::array({ { { "blending", "translucent" }, { "cullmode", "nocull" }, { "depthtest", "disabled" }, { "depthwrite", "disabled" },
                                          { "shader", "genericimage" }, { "textures", Json::array({ "workshop/123/bar" }) } } }) } });
    files["/materials/workshop/123/bar.tex"] = WhiteTexture(16, 8, 12, 6);
    ParseRig rig(files);

    const std::string script = R"JS('use strict';
export var __workshopId = '123';
export function init() { thisScene.createLayer('models/bar.json'); }
export function update(value) { return value; }
)JS";
    Json source = { { "id", 1 }, { "name", "source" }, { "image", "models/workshop/123/bar.json" }, { "origin", V3(320, 180, 0) }, { "size", V2(12, 6) }, { "visible", false } };
    Json owner  = { { "id", 2 }, { "name", "owner" }, { "image", "image.json" }, { "origin", V3(320, 180, 0) }, { "visible", { { "value", true }, { "script", script } } } };
    Json document = Canvas(Json::array({ source, owner }));
    document["camera"] = { { "center", V3(0, 0, -1) }, { "eye", V3(0, 0, 0) }, { "up", V3(0, 1, 0) } };
    auto scene = rig.Parse(document, ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    scene->runtime->Tick(1.0 / 60.0);
    scene->runtime->Tick(1.0 / 60.0);

    SceneNode* generated = nullptr;
    for (const auto& child : scene->sceneGraph->GetChildren()) {
        if (child != nullptr && child->Name().rfind("__generated_layer_", 0) == 0) generated = child.get();
    }
    ASSERT_NE(generated, nullptr) << "the model was found through the declared workshop item";
    EXPECT_NE(generated->Mesh(), nullptr);
    EXPECT_TRUE(generated->Visible());
    const linalg::Vector2f size = scene->runtime->NodeSize(generated->Name());
    EXPECT_TRUE(size.isApprox(linalg::Vector2f(12.0f, 6.0f))) << size.x() << " x " << size.y() << ": the picture, not the 16x8 allocation";
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

} // namespace
