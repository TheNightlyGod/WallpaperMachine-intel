// Scene file schema, part 11 (audio): when a scene says it needs system audio, and how a
// wallpaper host hears of it: once per scene, lowered by a replacement, ignoring late reports of
// a scene that is gone.
#include "support/schema_fixtures.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/SceneWallpaper.hpp"

#include <gtest/gtest.h>

#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace wallpaper;

// BasicAssets plus an image whose material turns audio processing on and a particle emitter
// that processes audio.
FileMap AudioAssets()
{
    FileMap files = BasicAssets();
    PutJson(files, "/audio_image.json", { { "width", 64 }, { "height", 32 }, { "material", "audio_mat.json" } });
    PutJson(files, "/audio_mat.json",
            { { "passes", Json::array({ { { "blending", "translucent" },
                                          { "cullmode", "nocull" },
                                          { "depthtest", "disabled" },
                                          { "depthwrite", "disabled" },
                                          { "shader", "genericimage" },
                                          { "textures", Json::array({ "a.tex" }) },
                                          { "combos", { { "AUDIOPROCESSING", 1 } } } } }) } });
    PutJson(files, "/audio_particle.json",
            { { "emitter", Json::array({ { { "name", "boxrandom" }, { "id", 1 }, { "audioprocessingmode", 1 } } }) },
              { "material", "mat.json" },
              { "maxcount", 4 },
              { "starttime", 0 } });
    return files;
}

Json PlainImage()
{
    return Json::array({ { { "id", 1 }, { "name", "plain" }, { "image", "image.json" }, { "visible", true } } });
}

std::shared_ptr<Scene> ParseObjects(ParseRig& rig, Json objects)
{
    return rig.Parse(QuietScene(std::move(objects), { { "bloom", false } }), { .live = true });
}

// ---- what a scene needs --------------------------------------------------------------------------------

// R-11.05 / B-11.05
TEST(SceneAudioRequirement, OnlyContentThatReadsAudioRaisesIt)
{
    ParseRig rig(AudioAssets());
    {
        SCOPED_TRACE("plain image");
        auto scene = ParseObjects(rig, PlainImage());
        ASSERT_NE(scene, nullptr);
        ASSERT_NE(scene->runtime, nullptr);
        EXPECT_FALSE(scene->runtime->SceneRequiresAudioResponse());
        scene->runtime->Tick(0.5);
        EXPECT_FALSE(scene->runtime->SceneRequiresAudioResponse()) << "running does not invent a need";
    }
    {
        SCOPED_TRACE("image with audio processing");
        auto scene = ParseObjects(rig, Json::array({ { { "id", 1 }, { "name", "audio" }, { "image", "audio_image.json" }, { "visible", true } } }));
        ASSERT_NE(scene, nullptr);
        ASSERT_NE(scene->runtime, nullptr);
        EXPECT_TRUE(scene->runtime->SceneRequiresAudioResponse());
    }
    {
        SCOPED_TRACE("audio-processing particle");
        auto scene = ParseObjects(rig, Json::array({ { { "id", 1 },
                                                       { "name", "sparks" },
                                                       { "particle", "audio_particle.json" },
                                                       { "origin", Json::array({ 0, 0, 0 }) },
                                                       { "scale", Json::array({ 1, 1, 1 }) },
                                                       { "angles", Json::array({ 0, 0, 0 }) },
                                                       { "visible", true } } }));
        ASSERT_NE(scene, nullptr);
        ASSERT_NE(scene->runtime, nullptr);
        EXPECT_TRUE(scene->runtime->SceneRequiresAudioResponse());
    }
    {
        SCOPED_TRACE("a script asks for the audio buffers");
        Json objects = PlainImage();
        objects[0]["origin"] = { { "value", Json::array({ 0, 0, 0 }) },
                                 { "script", "export function update(value) { engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16); return value; }" } };
        auto scene = ParseObjects(rig, objects);
        ASSERT_NE(scene, nullptr);
        ASSERT_NE(scene->runtime, nullptr);
        EXPECT_FALSE(scene->runtime->SceneRequiresAudioResponse()) << "a script reads audio only once it asks";
        scene->runtime->Tick(0.5);
        EXPECT_TRUE(scene->runtime->SceneRequiresAudioResponse());
        EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
    }
}

TEST(SceneAudioRequirement, TheListenerIsToldOnlyWhenTheRequirementFirstRises)
{
    ParseRig rig(AudioAssets());
    auto     scene = ParseObjects(rig, PlainImage());
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    int   heard   = 0;
    runtime.SetAudioRequirementListener([&heard] { ++heard; });
    runtime.Tick(0.1);
    EXPECT_EQ(heard, 0);
    runtime.MarkSceneRequiresAudioResponse();
    EXPECT_EQ(heard, 1);
    EXPECT_TRUE(runtime.SceneRequiresAudioResponse());
    runtime.MarkSceneRequiresAudioResponse();
    runtime.MarkSceneRequiresAudioResponse();
    EXPECT_EQ(heard, 1) << "later marks are silent";
    runtime.SetAudioRequirementListener({});
}

TEST(SceneAudioRequirement, AnEmitterOutsideTheAudioModesDoesNotRaiseIt)
{
    FileMap files = AudioAssets();
    PutJson(files, "/quiet_particle.json",
            { { "emitter", Json::array({ { { "name", "boxrandom" }, { "id", 1 }, { "audioprocessingmode", 0 } } }) },
              { "material", "mat.json" },
              { "maxcount", 4 },
              { "starttime", 0 } });
    ParseRig rig(std::move(files));
    auto     scene = ParseObjects(rig, Json::array({ { { "id", 1 },
                                                       { "name", "sparks" },
                                                       { "particle", "quiet_particle.json" },
                                                       { "origin", Json::array({ 0, 0, 0 }) },
                                                       { "scale", Json::array({ 1, 1, 1 }) },
                                                       { "angles", Json::array({ 0, 0, 0 }) },
                                                       { "visible", true } } }));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->SceneRequiresAudioResponse());
}

// ---- how the host hears of it ----------------------------------------------------------------------------

#if defined(WESCENE_BUILD_TESTS)

// Records what a headless SceneWallpaper reports. Every scene commit sends exactly one pointer
// report right after its audio-requirement report on the same looper, and installing the pointer
// callback replays the current capability at once; waiting for one more pointer report is
// therefore a barrier behind every audio report posted before it. The absence of an event is
// shown by such a barrier, never by sleeping.
class HostProbe {
    // (helpers first: the public functions below use them)
    template <typename Fn>
    auto Locked(Fn fn) const
    {
        std::scoped_lock lock(mutex_);
        return fn();
    }
    template <typename Predicate>
    bool WaitFor(Predicate predicate)
    {
        std::unique_lock lock(mutex_);
        return changed_.wait_for(lock, std::chrono::seconds(5), predicate);
    }

public:
    HostProbe()
    {
        EXPECT_TRUE(wallpaper_.init());
        audio_   = std::make_shared<AudioRequirementCallback>([this](bool required) {
            std::scoped_lock lock(mutex_);
            audio_values_.push_back(required);
            changed_.notify_all();
        });
        pointer_ = std::make_shared<PointerInputCallback>([this](bool) {
            std::scoped_lock lock(mutex_);
            ++pointer_reports_;
            changed_.notify_all();
        });
    }
    ~HostProbe() { wallpaper_.shutdown(); }

    // Installs the audio callback, which replays the current state at once, and waits for that.
    void InstallAudio()
    {
        wallpaper_.setPropertyObject(PROPERTY_AUDIO_REQUIREMENT_CALLBACK, audio_);
        ASSERT_TRUE(WaitFor([this] { return !audio_values_.empty(); }));
        Barrier();
    }
    // Everything posted to the host's looper before this call has been delivered when it returns.
    void Barrier()
    {
        const auto target = Locked([this] { return pointer_reports_ + 1; });
        wallpaper_.setPropertyObject(PROPERTY_POINTER_INPUT_CALLBACK, pointer_);
        ASSERT_TRUE(WaitFor([&] { return pointer_reports_ >= target; })) << "the host did not reach its barrier";
    }
    // Commits `scene` and waits until the host has heard everything the commit says.
    void Commit(std::shared_ptr<Scene> scene)
    {
        const auto target = Locked([this] { return pointer_reports_ + 1; });
        SceneWallpaperInputTestAccess::PostScene(wallpaper_, std::move(scene));
        ASSERT_TRUE(WaitFor([&] { return pointer_reports_ >= target; })) << "the commit was not reported";
    }
    std::vector<bool> Values() const
    {
        return Locked([this] { return audio_values_; });
    }
    SceneWallpaper& wallpaper() { return wallpaper_; }

private:
    SceneWallpaper                            wallpaper_;
    mutable std::mutex                        mutex_;
    std::condition_variable                   changed_;
    std::vector<bool>                         audio_values_;
    std::size_t                               pointer_reports_ { 0 };
    std::shared_ptr<AudioRequirementCallback> audio_;
    std::shared_ptr<PointerInputCallback>     pointer_;
};

using Values = std::vector<bool>;

std::shared_ptr<Scene> PlainScene(ParseRig& rig)
{
    return ParseObjects(rig, PlainImage());
}
std::shared_ptr<Scene> AudioScene(ParseRig& rig)
{
    return ParseObjects(rig, Json::array({ { { "id", 1 }, { "name", "audio" }, { "image", "audio_image.json" }, { "visible", true } } }));
}

// R-11.06 / B-11.06
TEST(SceneAudioReport, TheHostHearsTheRequirementOncePerSceneAndTheReplacementResetsIt)
{
    ParseRig  rig(AudioAssets());
    HostProbe host;
    auto      plain = PlainScene(rig);
    auto      audio = AudioScene(rig);
    ASSERT_NE(plain, nullptr);
    ASSERT_NE(audio, nullptr);
    ASSERT_TRUE(audio->runtime->SceneRequiresAudioResponse());

    host.InstallAudio();
    ASSERT_EQ(host.Values(), (Values { false })) << "installing replays the current state";

    host.Commit(plain);
    ASSERT_EQ(host.Values(), (Values { false })) << "a scene that reads no audio never raises it";

    host.Commit(audio);
    ASSERT_EQ(host.Values(), (Values { false, true }));

    audio->runtime->MarkSceneRequiresAudioResponse();
    host.Barrier();
    ASSERT_EQ(host.Values(), (Values { false, true })) << "one report per scene";

    auto fresh = PlainScene(rig);
    ASSERT_NE(fresh, nullptr);
    host.Commit(fresh);
    ASSERT_EQ(host.Values(), (Values { false, true, false })) << "a replacement lowers it";

    audio->runtime->MarkSceneRequiresAudioResponse();
    host.Barrier();
    ASSERT_EQ(host.Values(), (Values { false, true, false })) << "the replaced scene has no say";

    fresh->runtime->MarkSceneRequiresAudioResponse();
    fresh->runtime->MarkSceneRequiresAudioResponse();
    host.Barrier();
    ASSERT_EQ(host.Values(), (Values { false, true, false, true })) << "a scene that raises it twice is heard once";

    host.Commit(nullptr);
    EXPECT_EQ(host.Values(), (Values { false, true, false, true, false })) << "no scene, no requirement";
}

TEST(SceneAudioReport, ALateMarkOfAReplacedUnmarkedSceneIsDropped)
{
    ParseRig  rig(AudioAssets());
    HostProbe host;
    auto      first  = PlainScene(rig);
    auto      second = PlainScene(rig);
    ASSERT_NE(first, nullptr);
    ASSERT_NE(second, nullptr);

    host.InstallAudio();
    host.Commit(first);
    host.Commit(second);
    ASSERT_EQ(host.Values(), (Values { false }));

    first->runtime->MarkSceneRequiresAudioResponse();
    host.Barrier();
    EXPECT_EQ(host.Values(), (Values { false })) << "a report of a scene since replaced says nothing about the one showing";

    second->runtime->MarkSceneRequiresAudioResponse();
    host.Barrier();
    EXPECT_EQ(host.Values(), (Values { false, true })) << "the scene on show still can";
}

#endif // WESCENE_BUILD_TESTS

} // namespace
