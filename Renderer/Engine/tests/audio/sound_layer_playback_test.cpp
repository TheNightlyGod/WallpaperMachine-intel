// Playback behavior of a scene sound layer (WPSoundStream): start/stop state, volume and
// mute, and what happens when a file runs out under each playback mode. Every stream is
// an in-memory script; nothing here opens an audio device.
#include "Scene/Parse/WPSoundParser.hpp"
#include "support/scripted_sound_stream.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <memory>
#include <vector>

namespace wallpaper
{
namespace
{

using audio::SoundStream;
using audio::testing::MakeFakeStream;
using audio::testing::ScriptedSoundStream;

constexpr SoundStream::Desc kStereo48k { .channels = 2, .sampleRate = 48'000 };

// A layer with a single scripted file. Each time the layer asks for the file, `opened`
// goes up and a fresh stream playing `script` is handed over (recorded in `streams`).
struct OneFileLayer {
    int                                           opened { 0 };
    std::vector<std::shared_ptr<ScriptedSoundStream>> streams;
    std::unique_ptr<WPSoundStream>                layer;

    OneFileLayer(std::vector<float> script, WPSoundStream::Config config)
    {
        std::vector<WPSoundStream::StreamFactory> factories;
        factories.push_back([this, script](const SoundStream::Desc&) -> std::shared_ptr<SoundStream> {
            ++opened;
            streams.push_back(MakeFakeStream(script));
            return streams.back();
        });
        layer = std::make_unique<WPSoundStream>(std::move(factories), config);
        layer->PassDesc(kStereo48k);
    }

    // Reads one stereo frame into a buffer that held `fill` beforehand.
    std::array<float, 2> ReadFrame(float fill, uint64_t* returned = nullptr)
    {
        std::array<float, 2> buffer { fill, fill };
        const uint64_t       got = layer->NextPcmData(buffer.data(), 1);
        if (returned != nullptr) *returned = got;
        return buffer;
    }
};

WPSoundStream::Config SilentStart()
{
    WPSoundStream::Config config;
    config.startsilent = true;
    return config;
}

WPSoundStream::Config WithMode(PlaybackMode mode)
{
    WPSoundStream::Config config;
    config.mode = mode;
    config.mintime = 0.0f;
    config.maxtime = 0.0f;
    return config;
}

using Frame = std::array<float, 2>;

} // namespace

TEST(SoundLayerControlTest, LayerBuiltSilentPlaysNothingAndReadsNothing)
{
    OneFileLayer rig({ 1.0f, -1.0f, 0.5f, -0.5f }, SilentStart());

    std::array<float, 4> buffer { 9.0f, 9.0f, 9.0f, 9.0f };
    const uint64_t       got = rig.layer->NextPcmData(buffer.data(), 2);

    EXPECT_EQ(got, 2u);
    EXPECT_FALSE(rig.layer->IsPlaying());
    for (float sample : buffer) EXPECT_EQ(sample, 0.0f);
    EXPECT_EQ(rig.opened, 0);
    for (const auto& stream : rig.streams) EXPECT_EQ(stream->reads, 0);
}

TEST(SoundLayerControlTest, PlayPauseStopMoveTheLayerThroughItsFile)
{
    OneFileLayer rig({ 1.0f, 2.0f, 3.0f, 4.0f }, SilentStart());
    uint64_t     got = 0;

    rig.layer->Play();
    EXPECT_TRUE(rig.layer->IsPlaying());
    EXPECT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 1.0f, 2.0f }));
    EXPECT_EQ(got, 1u);

    rig.layer->Pause();
    EXPECT_FALSE(rig.layer->IsPlaying());
    EXPECT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 0.0f, 0.0f }));
    EXPECT_EQ(got, 1u);

    // Resuming continues where the file stood; it is not reopened.
    rig.layer->Play();
    EXPECT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 3.0f, 4.0f }));
    EXPECT_EQ(got, 1u);

    rig.layer->Stop();
    EXPECT_FALSE(rig.layer->IsPlaying());

    // After a stop the file starts over, as a newly opened stream.
    rig.layer->Play();
    EXPECT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 1.0f, 2.0f }));
    EXPECT_EQ(got, 1u);
    EXPECT_EQ(rig.opened, 2);
}

TEST(SoundLayerControlTest, VolumeScalesClampsAndMuteKeepsConsumingTheFile)
{
    WPSoundStream::Config config;
    config.volume = 0.5f;
    OneFileLayer rig({ 1.0f, -1.0f, 0.5f, -0.5f }, config);
    uint64_t     got = 0;

    EXPECT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 0.5f, -0.5f }));
    EXPECT_EQ(got, 1u);

    rig.layer->SetVolume(2.0f);
    rig.layer->SetMuted(true);
    EXPECT_EQ(rig.layer->Volume(), 1.0f);
    EXPECT_TRUE(rig.layer->Muted());

    EXPECT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 0.0f, 0.0f }));
    EXPECT_EQ(got, 1u);
    ASSERT_EQ(rig.streams.size(), 1u);
    EXPECT_EQ(rig.streams[0]->consumed(), 4u);
}

TEST(SoundLayerControlTest, EmptyLoopingFileGivesSilenceWithoutSpinningOrStopping)
{
    OneFileLayer rig({}, WithMode(PlaybackMode::Loop));

    std::array<float, 4> buffer { 9.0f, 9.0f, 9.0f, 9.0f };
    const uint64_t       got = rig.layer->NextPcmData(buffer.data(), 2);

    EXPECT_EQ(got, 2u);
    EXPECT_TRUE(rig.layer->IsPlaying());
    EXPECT_GE(rig.opened, 2);
    EXPECT_LE(rig.opened, 4);
    for (float sample : buffer) EXPECT_EQ(sample, 0.0f);
}

TEST(SoundLayerControlTest, ScriptStartedOneShotEndsWhenItsAudioRunsOut)
{
    OneFileLayer rig({ 1.0f, -1.0f }, SilentStart());
    uint64_t     got = 0;

    rig.layer->Play();
    EXPECT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 1.0f, -1.0f }));
    EXPECT_EQ(got, 1u);
    EXPECT_TRUE(rig.layer->IsPlaying());

    EXPECT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 0.0f, 0.0f }));
    EXPECT_EQ(got, 1u);
    EXPECT_FALSE(rig.layer->IsPlaying());
    EXPECT_EQ(rig.opened, 1);
}

TEST(SoundLayerControlTest, FinishedOneShotPlaysAgainFromTheStart)
{
    OneFileLayer rig({ 0.75f, -0.75f }, SilentStart());
    uint64_t     got = 0;

    rig.layer->Play();
    ASSERT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 0.75f, -0.75f }));
    ASSERT_EQ(got, 1u);
    ASSERT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 0.0f, 0.0f }));
    ASSERT_FALSE(rig.layer->IsPlaying());
    ASSERT_EQ(rig.opened, 1);

    rig.layer->Play();
    EXPECT_EQ(rig.ReadFrame(0.0f, &got), (Frame { 0.75f, -0.75f }));
    EXPECT_EQ(got, 1u);
    EXPECT_TRUE(rig.layer->IsPlaying());
    EXPECT_EQ(rig.opened, 2);
}

TEST(SoundLayerControlTest, FinishedOneShotOverSeveralFilesReplaysFromTheFirstFile)
{
    // Two files: after the first one ends the one-shot is over, and playing it again has
    // to begin at the first file rather than carry on with the second.
    int                              first_opened  = 0;
    int                              second_opened = 0;
    std::vector<WPSoundStream::StreamFactory> factories;
    factories.push_back([&](const SoundStream::Desc&) -> std::shared_ptr<SoundStream> {
        ++first_opened;
        return MakeFakeStream({ 0.75f, -0.75f });
    });
    factories.push_back([&](const SoundStream::Desc&) -> std::shared_ptr<SoundStream> {
        ++second_opened;
        return MakeFakeStream({ 0.5f, -0.5f });
    });
    WPSoundStream::Config config = SilentStart();
    WPSoundStream         layer(std::move(factories), config);
    layer.PassDesc(kStereo48k);

    const auto read_frame = [&layer](float fill) {
        Frame frame { fill, fill };
        layer.NextPcmData(frame.data(), 1);
        return frame;
    };

    layer.Play();
    ASSERT_EQ(read_frame(9.0f), (Frame { 0.75f, -0.75f }));
    ASSERT_EQ(read_frame(9.0f), (Frame { 0.0f, 0.0f }));
    ASSERT_FALSE(layer.IsPlaying());

    layer.Play();
    EXPECT_EQ(read_frame(0.0f), (Frame { 0.75f, -0.75f }));
    EXPECT_TRUE(layer.IsPlaying());
    EXPECT_EQ(first_opened, 2);
    EXPECT_EQ(second_opened, 0);
}

TEST(SoundLayerControlTest, LoopModeReopensTheFileAfterItEnds)
{
    OneFileLayer rig({ 0.25f, -0.25f }, WithMode(PlaybackMode::Loop));
    uint64_t     got = 0;

    for (int pass = 0; pass < 2; ++pass) {
        EXPECT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 0.25f, -0.25f })) << "read " << pass;
        EXPECT_EQ(got, 1u);
        EXPECT_TRUE(rig.layer->IsPlaying());
    }
    EXPECT_EQ(rig.opened, 2);
}

TEST(SoundLayerControlTest, RandomModeWithNoDelayRestartsLikeALoop)
{
    OneFileLayer rig({ 0.125f, -0.125f }, WithMode(PlaybackMode::Random));
    uint64_t     got = 0;

    for (int pass = 0; pass < 2; ++pass) {
        EXPECT_EQ(rig.ReadFrame(9.0f, &got), (Frame { 0.125f, -0.125f })) << "read " << pass;
        EXPECT_EQ(got, 1u);
        EXPECT_TRUE(rig.layer->IsPlaying());
    }
    EXPECT_EQ(rig.opened, 2);
}

} // namespace wallpaper
