// A layer a script made and then destroyed leaves nothing of the script's behind: its wrapper
// object and the animation-ended callbacks registered on it (and on the layers made below it)
// are dropped, so the closures are released and a stale listener can never fire.
//
// Scenes load for their runtime only (support/script_scene.hpp). The layers a script creates have
// no puppet of their own, so the test gives each one a single-shot animation stack and plays it
// out by hand, which is what the renderer's pose update does every frame.
#include "support/script_scene.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "WPPuppet.hpp"

#include <gtest/gtest.h>

#include <memory>
#include <string>

using namespace we_test;
using namespace wallpaper;

namespace
{

// A one-bone puppet with one single-shot animation of ten frames at ten frames per second.
std::shared_ptr<WPPuppet> OneShotPuppet()
{
    auto puppet = std::make_shared<WPPuppet>();
    WPPuppet::Bone bone;
    bone.name = "root";
    puppet->bones.push_back(bone);
    WPPuppet::Animation animation;
    animation.id         = 1;
    animation.fps        = 10.0;
    animation.length     = 10;
    animation.mode       = WPPuppet::PlayMode::Single;
    animation.name       = "shot";
    animation.max_time   = 1.0;
    animation.frame_time = 0.1;
    WPPuppet::Animation::BoneTrack track;
    track.bone_index = 0;
    for (int frame = 0; frame < 10; ++frame) {
        WPPuppet::BoneFrame pose;
        pose.position   = { 0.0f, 0.0f, 0.0f };
        pose.angle      = { 0.0f, 0.0f, 0.0f };
        pose.scale      = { 1.0f, 1.0f, 1.0f };
        pose.quaternion = linalg::Quaterniond::Identity();
        track.frames.push_back(pose);
    }
    animation.bone_tracks.push_back(track);
    puppet->anims.push_back(animation);
    puppet->prepared();
    return puppet;
}

WPPuppetLayer OneShotLayer()
{
    WPPuppetLayer layer(OneShotPuppet());
    WPPuppetLayer::AnimationLayer entry;
    entry.id       = 1;
    entry.layer_id = 0;
    entry.name     = "shot";
    entry.rate     = 1.0;
    entry.playing  = false;
    std::vector<WPPuppetLayer::AnimationLayer> stack { entry };
    layer.prepared(stack);
    return layer;
}

// The driver layer's script is a small state machine ticked once per frame; the test sets up the
// puppets between steps, because the layers do not exist before step 1.
//
//  step 1  makes layer "made" and, below it, "kid"
//  step 2  registers an animation-ended callback on each and keeps a weak reference to each
//          callback's closure
//  step 3  nothing
//  step 4  destroys "made"
// The colour reports: r = callbacks that ran, g = closures still alive plus ten for every layer wrapper
// still alive (-1 when the engine has no weak references), b = the step.
const char kDriver[] = R"(
var step = 0, ran = 0, probes = [], wrappers = [], haveWeak = (typeof WeakRef === 'function');
export function update(value) {
  step++;
  if (step === 1) {
    var made = thisScene.createLayer({ image: 'models/tpl.json', name: 'made' });
    thisScene.createLayer({ image: 'models/tpl.json', name: 'kid', parent: made });
  } else if (step === 2) {
    ['made', 'kid'].forEach(function (name) {
      var layer = thisScene.getLayer(name);
      var payload = { big: new Array(1000).fill(name) };
      var fn = function () { ran++; return payload.big.length; };
      if (haveWeak) probes.push(new WeakRef(fn));
      if (haveWeak) wrappers.push(new WeakRef(layer));
      layer.getAnimationLayer(0).addEndedCallback(fn);
    });
  } else if (step === 4) {
    thisScene.destroyLayer('made');
  }
  var alive = 0;
  if (haveWeak) probes.forEach(function (p) { if (p.deref() !== undefined) alive++; });
  wrappers.forEach(function (p) { if (p.deref() !== undefined) alive += 10; });
  return new Vec3(ran, haveWeak ? alive : -1, step);
}
)";

struct Fixture {
    ScenePackage package;
    std::unique_ptr<ScriptScene> scene;

    Fixture()
    {
        const auto tpl    = package.AddImageModel("tpl");
        const auto driver = package.AddImageModel("driver");
        ImageLayer layer;
        layer.id    = 1;
        layer.name  = "driver";
        layer.model = driver;
        layer.color = ScriptedValue(kDriver, "0 0 0");
        ImageLayer templateLayer;
        templateLayer.id      = 2;
        templateLayer.name    = "template";
        templateLayer.model   = tpl;
        templateLayer.visible = false;
        package.SetProject();
        package.SetScene(SceneJson({}, { ImageLayerJson(layer), ImageLayerJson(templateLayer) }));
        scene = std::make_unique<ScriptScene>(package);
    }

    /// Plays the layer's one animation to its end; `runtime_name` is the layer's runtime name.
    bool PlayOut(const std::string& runtime_name)
    {
        auto* puppet = scene->runtime().FindPuppetLayer(runtime_name);
        if (puppet == nullptr) return false;
        puppet->play(0);
        // The first pose only learns where the clock is; the later ones advance it past the end.
        puppet->genFrame(0.0);
        puppet->genFrame(0.5);
        puppet->genFrame(2.0);
        return true;
    }
};

} // namespace

TEST(ScriptLayerRelease, TheScenesLoadsAndTheDriverMakesTheLayers)
{
    Fixture f;
    ASSERT_TRUE(f.scene->ok()) << f.scene->error();
    f.scene->Tick(1);
    EXPECT_EQ(f.scene->Color("driver")[2], 1.0f);
    EXPECT_FALSE(f.scene->runtime().ResolveLayerName("made").empty());
    EXPECT_FALSE(f.scene->runtime().ResolveLayerName("kid").empty());
    EXPECT_TRUE(f.scene->ScriptErrors().empty());
}

TEST(ScriptLayerRelease, LiveLayersHearTheirAnimationsEnd)
{
    Fixture f;
    ASSERT_TRUE(f.scene->ok()) << f.scene->error();
    f.scene->Tick(1);
    auto& runtime = f.scene->runtime();
    runtime.RegisterPuppetLayer(runtime.ResolveLayerName("made"), OneShotLayer());
    runtime.RegisterPuppetLayer(runtime.ResolveLayerName("kid"), OneShotLayer());
    f.scene->Tick(1); // step 2 registers the callbacks
    ASSERT_TRUE(f.PlayOut(runtime.ResolveLayerName("made")));
    ASSERT_TRUE(f.PlayOut(runtime.ResolveLayerName("kid")));
    f.scene->Tick(1); // step 3
    EXPECT_EQ(f.scene->Color("driver")[0], 2.0f) << "both callbacks run while the layers exist";
}

TEST(ScriptLayerRelease, ADestroyedLayersAndItsChildrensCallbacksNeverRun)
{
    Fixture f;
    ASSERT_TRUE(f.scene->ok()) << f.scene->error();
    f.scene->Tick(1);
    auto& runtime = f.scene->runtime();
    const auto made = runtime.ResolveLayerName("made");
    const auto kid  = runtime.ResolveLayerName("kid");
    ASSERT_FALSE(made.empty());
    ASSERT_FALSE(kid.empty());
    runtime.RegisterPuppetLayer(made, OneShotLayer());
    runtime.RegisterPuppetLayer(kid, OneShotLayer());
    f.scene->Tick(2); // step 2 registers the callbacks, step 3 changes nothing
    f.scene->Tick(1); // step 4 destroys "made" and "kid" with it
    ASSERT_EQ(f.scene->Color("driver")[2], 4.0f);

    // An animation that would have ended after the destruction plays out while the layers'
    // puppets (should the runtime still hold them, or hold them again under the same names) are
    // asked for their finished layers on every tick.
    runtime.RegisterPuppetLayer(made, OneShotLayer());
    runtime.RegisterPuppetLayer(kid, OneShotLayer());
    ASSERT_TRUE(f.PlayOut(made));
    ASSERT_TRUE(f.PlayOut(kid));
    f.scene->Tick(5);
    EXPECT_EQ(f.scene->Color("driver")[0], 0.0f) << "no callback of a destroyed layer may run";
    EXPECT_TRUE(f.scene->ScriptErrors().empty());
}

TEST(ScriptLayerRelease, TheClosuresOfADestroyedLayerAreCollected)
{
    Fixture f;
    ASSERT_TRUE(f.scene->ok()) << f.scene->error();
    f.scene->Tick(1);
    auto& runtime = f.scene->runtime();
    runtime.RegisterPuppetLayer(runtime.ResolveLayerName("made"), OneShotLayer());
    runtime.RegisterPuppetLayer(runtime.ResolveLayerName("kid"), OneShotLayer());
    f.scene->Tick(1); // step 2
    // The script host creates a full quickjs-ng context, which provides WeakRef; a build without
    // it must fail here instead of passing without checking anything.
    ASSERT_GE(f.scene->Color("driver")[1], 0.0f) << "the script engine must provide weak references";
    EXPECT_EQ(f.scene->Color("driver")[1], 22.0f) << "both closures and both wrappers are alive while registered";
    f.scene->Tick(2); // step 4 destroys; the weak references are read after it
    EXPECT_EQ(f.scene->Color("driver")[1], 0.0f)
        << "the closures and the wrapper objects of a destroyed layer are released";
}
