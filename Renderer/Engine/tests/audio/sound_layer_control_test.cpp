#include "WPSoundParser.hpp"
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

using audio::testing::MakeFakeStream;

TEST(SoundLayerControlTest, AFileThatDoesNotOpenIsPassedOverInTheSameRequest) {
    // The first file of the list cannot be opened: the layer goes on to the next file
    // without leaving a request of silence behind, and a list in which nothing opens ends
    // the request in silence instead of spinning.
    auto good = MakeFakeStream({ 1.0f, 2.0f, 3.0f, 4.0f });
    int  bad_calls = 0;
    WPSoundStream stream({ [&bad_calls](const audio::SoundStream::Desc&) {
                             ++bad_calls;
                             return std::shared_ptr<audio::SoundStream> {};
                         },
                           [good](const audio::SoundStream::Desc&) { return good; } },
                         { .mode = PlaybackMode::Loop });
    stream.PassDesc({ .channels = 2, .sampleRate = 48'000 });

    std::array<float, 4> output { 9.0f, 9.0f, 9.0f, 9.0f };
    EXPECT_EQ(stream.NextPcmData(output.data(), 2), 2u);
    EXPECT_EQ(bad_calls, 1);
    EXPECT_FLOAT_EQ(output[0], 1.0f);
    EXPECT_FLOAT_EQ(output[3], 4.0f);

    int           calls = 0;
    WPSoundStream broken({ [&calls](const audio::SoundStream::Desc&) {
                             ++calls;
                             return std::shared_ptr<audio::SoundStream> {};
                         } },
                         { .mode = PlaybackMode::Loop });
    broken.PassDesc({ .channels = 2, .sampleRate = 48'000 });
    output = { 9.0f, 9.0f, 9.0f, 9.0f };
    EXPECT_EQ(broken.NextPcmData(output.data(), 2), 2u);
    EXPECT_LE(calls, 4);
    for (float sample : output) EXPECT_FLOAT_EQ(sample, 0.0f);
}

TEST(SoundLayerControlTest, RandomDelayIsSampleAccurateAcrossCallbackSizes) {
    const auto render = [](const std::vector<uint32_t>& chunks) {
        int next = 0;
        WPSoundStream stream({ [&next](const auto&) {
            return MakeFakeStream({static_cast<float>(++next)});
        } }, { .maxtime = 0.375f, .mintime = 0.375f, .mode = PlaybackMode::Random, .random_seed = 7 });
        stream.PassDesc({ .channels = 1, .sampleRate = 8 });
        std::vector<float> result;
        for (const auto size : chunks) {
            std::vector<float> chunk(size);
            EXPECT_EQ(stream.NextPcmData(chunk.data(), size), size);
            result.insert(result.end(), chunk.begin(), chunk.end());
        }
        return result;
    };
    const std::vector<float> expected {1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0};
    EXPECT_EQ(render({12}), expected);
    EXPECT_EQ(render({1, 2, 4, 5}), expected);
}

TEST(SoundLayerControlTest, PausingPreservesRandomDelayAndStopResetsIt) {
    int next = 0;
    WPSoundStream stream({ [&next](const auto&) {
        return MakeFakeStream({static_cast<float>(++next)});
    } }, { .maxtime = 0.375f, .mintime = 0.375f, .mode = PlaybackMode::Random });
    stream.PassDesc({ .channels = 1, .sampleRate = 8 });
    std::array<float, 2> output {};
    ASSERT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_EQ(output[0], 1.0f);
    ASSERT_EQ(stream.NextPcmData(output.data(), 2), 2u);
    EXPECT_EQ(output, (std::array<float, 2> {0, 0}));
    stream.Pause();
    ASSERT_EQ(stream.NextPcmData(output.data(), 2), 2u);
    EXPECT_EQ(output, (std::array<float, 2> {0, 0}));
    stream.Play();
    ASSERT_EQ(stream.NextPcmData(output.data(), 2), 2u);
    EXPECT_EQ(output, (std::array<float, 2> {0, 2}));
    stream.Stop();
    stream.Play();
    ASSERT_EQ(stream.NextPcmData(output.data(), 1), 1u);
    EXPECT_EQ(output[0], 3.0f);
}

TEST(SoundLayerControlTest, SeededRandomDelaysStayWithinTheAuthoredRange) {
    WPSoundStream stream({ [](const auto&) { return MakeFakeStream({1.0f}); } },
        { .maxtime = 0.625f, .mintime = 0.25f, .mode = PlaybackMode::Random, .random_seed = 17 });
    stream.PassDesc({ .channels = 1, .sampleRate = 8 });
    std::array<float, 256> samples {};
    ASSERT_EQ(stream.NextPcmData(samples.data(), samples.size()), samples.size());
    size_t previous = 0, events = 0;
    for (size_t index = 0; index < samples.size(); ++index) {
        if (samples[index] == 0.0f) continue;
        if (events != 0) {
            EXPECT_GE(index - previous - 1, 2u);
            EXPECT_LE(index - previous - 1, 5u);
        }
        previous = index;
        ++events;
    }
    EXPECT_GT(events, 30u);
}

TEST(SoundLayerControlTest, ParsesWallpaperEnginePlaybackModes) {
    EXPECT_EQ(ParseSoundPlaybackMode("single"), PlaybackMode::OneShot);
    EXPECT_EQ(ParseSoundPlaybackMode("random"), PlaybackMode::Random);
    EXPECT_EQ(ParseSoundPlaybackMode("loop"), PlaybackMode::Loop);
    EXPECT_EQ(ParseSoundPlaybackMode(""), PlaybackMode::Loop);
}

} // namespace
} // namespace wallpaper
