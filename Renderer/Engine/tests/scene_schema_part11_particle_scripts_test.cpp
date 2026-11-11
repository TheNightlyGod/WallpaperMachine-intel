// Scene file schema, part 11 (particle scripts): what a script reaches through a particle layer,
// as Wallpaper Engine's IParticleSystem documents it: `emitParticles(count)` emits at once even
// while emission is paused or stopped, `pause()` stops new particles and keeps the live ones,
// `stop()` also clears them, `play()` resumes (or starts again once stopped), `isPlaying()`
// answers whether anything is still emitted or simulated, and `instance` reaches the layer's
// instance overrides (`count`, `size`, `controlpointN`, ...), as a property binding does.
#include "support/schema_fixtures.hpp"

#include "Particle/ParticleSystem.h"
#include "Runtime/SceneRuntimeContext.hpp"

#include <gtest/gtest.h>

#include <memory>
#include <string>

namespace
{

using namespace we_schema;
using namespace wallpaper;

// A box emitter at `rate` particles a second whose particles live long enough to be counted.
FileMap ParticleAssets(double rate)
{
    FileMap files = BasicAssets();
    PutJson(files, "/sparks.json",
            { { "emitter", Json::array({ { { "name", "boxrandom" }, { "id", 1 }, { "rate", rate } } }) },
              { "initializer", Json::array({ { { "name", "lifetimerandom" }, { "min", 100 }, { "max", 100 } } }) },
              { "material", "mat.json" },
              { "maxcount", 200 },
              { "starttime", 0 } });
    return files;
}

// Like ParticleAssets, with a timetable: emission starts after `delay` seconds, and each
// particle lives `lifetime` seconds.
FileMap DelayedParticleAssets(double rate, double delay, double lifetime)
{
    FileMap files = BasicAssets();
    PutJson(files, "/sparks.json",
            { { "emitter", Json::array({ { { "name", "boxrandom" }, { "id", 1 }, { "rate", rate }, { "delay", delay } } }) },
              { "initializer",
                Json::array({ { { "name", "lifetimerandom" }, { "min", lifetime }, { "max", lifetime } } }) },
              { "material", "mat.json" },
              { "maxcount", 200 },
              { "starttime", 0 } });
    return files;
}

struct ParticleStage {
    explicit ParticleStage(double rate) : ParticleStage(ParticleAssets(rate)) {}
    explicit ParticleStage(FileMap files) : rig(std::move(files))
    {
        scene = rig.Parse(QuietScene(Json::array({ { { "id", 1 },
                                                     { "name", "sparks" },
                                                     { "particle", "sparks.json" },
                                                     { "origin", Json::array({ 0, 0, 0 }) },
                                                     { "scale", Json::array({ 1, 1, 1 }) },
                                                     { "angles", Json::array({ 0, 0, 0 }) },
                                                     { "visible", true } } }),
                                       { { "bloom", false } }),
                          { .live = true });
    }

    bool ok() const { return scene != nullptr && scene->runtime != nullptr && scene->paritileSys != nullptr &&
                             ! scene->paritileSys->subsystems.empty(); }
    SceneRuntimeContext& rt() { return *scene->runtime; }

    // One frame of `seconds`: the particles step, then the scripts run.
    void Frame(double seconds = 0.1)
    {
        scene->frameTime = seconds;
        scene->paritileSys->Emitt();
        scene->runtime->Tick(seconds);
    }

    // Particles alive in the layer's system now.
    std::size_t Alive() const
    {
        const auto& instances = scene->paritileSys->subsystems.front()->Instances();
        std::size_t n         = 0;
        for (const auto& instance : instances) {
            for (const auto& particle : instance->Particles()) n += particle.lifetime > 0.0f ? 1 : 0;
        }
        return n;
    }

    // Runs `body` once, in the next frame's script pass, as a scene script.
    void Run(const std::string& body)
    {
        rt().RegisterSceneScript("var ran = false;\nfunction update() { if (ran) return; ran = true;\n" + body + "\n}", "");
    }

    ParseRig               rig;
    std::shared_ptr<Scene> scene;
};

} // namespace

TEST(ParticleScripts, EmitParticlesEmitsAtOnceEvenWithNoRateOfItsOwn)
{
    ParticleStage stage(0.0);
    ASSERT_TRUE(stage.ok());
    stage.Frame();
    EXPECT_EQ(stage.Alive(), 0u);
    stage.Run("thisScene.getLayer('sparks').emitParticles(5);");
    stage.Frame();  // the script asks
    stage.Frame();  // the system emits
    EXPECT_EQ(stage.Alive(), 5u);
    stage.Frame();
    EXPECT_EQ(stage.Alive(), 5u) << "the request is spent once";
    EXPECT_EQ(stage.rt().scriptErrorCount(), 0u);
}

TEST(ParticleScripts, PauseKeepsTheLiveParticlesStopClearsThemAndPlayResumes)
{
    ParticleStage stage(100.0);
    ASSERT_TRUE(stage.ok());
    stage.Frame();
    stage.Frame();
    const std::size_t before = stage.Alive();
    ASSERT_GT(before, 0u);

    // As Wallpaper Engine's IParticleSystem answers: a paused system is not playing, though
    // its live particles still age and move.
    stage.Run("var s = thisScene.getLayer('sparks'); s.pause(); "
              "if (s.isPlaying()) throw new Error('a paused system reports that it plays');");
    stage.Frame();
    const std::size_t paused = stage.Alive();
    stage.Frame();
    stage.Frame();
    EXPECT_EQ(stage.Alive(), paused) << "a paused system emits nothing new";
    EXPECT_GE(paused, before);

    stage.Run("var s = thisScene.getLayer('sparks'); s.emitParticles(3);");
    stage.Frame();
    stage.Frame();
    EXPECT_EQ(stage.Alive(), paused + 3) << "emitParticles works while paused";

    stage.Run("thisScene.getLayer('sparks').stop();");
    stage.Frame();
    stage.Frame();
    EXPECT_EQ(stage.Alive(), 0u) << "stop clears the particles";
    stage.Run("if (thisScene.getLayer('sparks').isPlaying()) throw new Error('a stopped system is not playing');");
    stage.Frame();

    stage.Run("var s = thisScene.getLayer('sparks'); s.play(); "
              "if (!s.isPlaying()) throw new Error('playing again');");
    stage.Frame();
    stage.Frame();
    EXPECT_GT(stage.Alive(), 0u) << "play emits again";
    for (const auto& error : stage.rt().scriptErrors()) ADD_FAILURE() << error;
}

TEST(ParticleScripts, TheInstanceReachesTheOverridesAPropertyWouldBind)
{
    ParticleStage stage(10.0);
    ASSERT_TRUE(stage.ok());
    stage.Run("var i = thisScene.getLayer('sparks').instance;\n"
              "if (i.count !== 1 || i.size !== 1 || i.alpha !== 1) throw new Error('neutral by default');\n"
              "i.count = 3; i.size = 2;\n"
              "i.controlpoint2 = new Vec3(4, 5, 6);\n"
              "if (i.count !== 3 || i.size !== 2) throw new Error('reads what was set');\n"
              "var p = i.controlpoint2; if (p.x !== 4 || p.y !== 5 || p.z !== 6) throw new Error('control point');");
    stage.Frame();
    stage.Frame();
    const std::size_t first = stage.Alive();
    stage.Frame(1.0);
    const std::size_t one_second = stage.Alive() - first;
    EXPECT_GE(one_second, 25u) << "count 3 emits three times the authored rate of 10";
    EXPECT_LE(one_second, 35u);
    const auto points = stage.scene->paritileSys->subsystems.front()->Controlpoints();
    EXPECT_DOUBLE_EQ(points[2].base_offset.x(), 4.0);
    EXPECT_DOUBLE_EQ(points[2].base_offset.z(), 6.0);
    for (const auto& error : stage.rt().scriptErrors()) ADD_FAILURE() << error;
}

// A pause is not a stop: once the live particles have died during it, play() goes on emitting
// at once, without replaying the emitter's start delay.
TEST(ParticleScripts, PlayAfterAPauseResumesEvenOnceTheParticlesHaveDied)
{
    ParticleStage stage(DelayedParticleAssets(100.0, 1.0, 0.2));
    ASSERT_TRUE(stage.ok());
    for (int i = 0; i < 12; i++) stage.Frame();
    ASSERT_GT(stage.Alive(), 0u) << "emitting once the delay is over";

    stage.Run("thisScene.getLayer('sparks').pause();");
    for (int i = 0; i < 5; i++) stage.Frame();
    ASSERT_EQ(stage.Alive(), 0u) << "the paused system's particles have died";

    stage.Run("thisScene.getLayer('sparks').play();");
    stage.Frame();
    stage.Frame();
    EXPECT_GT(stage.Alive(), 0u) << "play resumes; the start delay is not replayed";
    for (const auto& error : stage.rt().scriptErrors()) ADD_FAILURE() << error;
}
