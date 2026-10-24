// The AudioToolbox decoder over in-memory files: the format it reports, frames in
// any chunk size, a rewind that starts the sound again, and what it says about
// files that are not audio or have no audio. No file is read from disk and no
// device is opened.
#include "Sound/Apple/AppleDecoder.hpp"

#include "apple_fixture_data.hpp"

#include <gtest/gtest.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace wallpaper::sound
{
namespace
{

void Put16(std::vector<std::uint8_t>& bytes, std::uint32_t value)
{
    bytes.push_back(static_cast<std::uint8_t>(value & 0xffu));
    bytes.push_back(static_cast<std::uint8_t>((value >> 8) & 0xffu));
}

void Put32(std::vector<std::uint8_t>& bytes, std::uint32_t value)
{
    Put16(bytes, value & 0xffffu);
    Put16(bytes, value >> 16);
}

/// A 32-bit float WAV: frame f, channel c holds (f + 1) * 0.0001 + c * 0.25.
std::vector<std::uint8_t> FloatWav(std::uint32_t channels, std::uint32_t rate, std::uint32_t frames)
{
    std::vector<std::uint8_t> bytes;
    const std::uint32_t       data = frames * channels * 4;
    const auto tag = [&](const char* text) { bytes.insert(bytes.end(), text, text + 4); };
    tag("RIFF");
    Put32(bytes, 36 + data);
    tag("WAVE");
    tag("fmt ");
    Put32(bytes, 16);
    Put16(bytes, 3);
    Put16(bytes, channels);
    Put32(bytes, rate);
    Put32(bytes, rate * channels * 4);
    Put16(bytes, channels * 4);
    Put16(bytes, 32);
    tag("data");
    Put32(bytes, data);
    for (std::uint32_t frame = 0; frame < frames; ++frame) {
        for (std::uint32_t channel = 0; channel < channels; ++channel) {
            const float value = static_cast<float>(frame + 1) * 0.0001f + static_cast<float>(channel) * 0.25f;
            std::uint32_t bits;
            std::memcpy(&bits, &value, sizeof bits);
            Put32(bytes, bits);
        }
    }
    return bytes;
}

template<std::size_t N>
std::shared_ptr<media::ByteSource> Memory(const std::uint8_t (&array)[N])
{
    return media::MakeMemoryByteSource(std::vector<std::uint8_t>(array, array + N));
}

std::vector<float> ReadAll(PcmDecoder& decoder, std::size_t chunk)
{
    const auto         channels = decoder.format().channels;
    std::vector<float> all;
    std::vector<float> block(chunk * channels);
    while (true) {
        const auto frames = decoder.read(block.data(), chunk);
        if (frames == 0) break;
        all.insert(all.end(), block.begin(), block.begin() + static_cast<std::ptrdiff_t>(frames * channels));
    }
    return all;
}

TEST(AppleDecoder, ReportsTheFileLayoutAndReturnsEveryFrame)
{
    std::string error;
    auto decoder = OpenAppleDecoder(media::MakeMemoryByteSource(FloatWav(2, 44'100, 3000)), &error);
    ASSERT_NE(decoder, nullptr) << error;
    EXPECT_EQ(decoder->format(), (PcmFormat { 2, 44'100 }));
    for (const std::size_t chunk : { std::size_t { 1 }, std::size_t { 333 }, std::size_t { 4096 } }) {
        ASSERT_TRUE(decoder->rewind());
        const auto samples = ReadAll(*decoder, chunk);
        ASSERT_EQ(samples.size(), 6000u) << "chunk " << chunk;
        for (std::size_t frame = 0; frame < 3000; frame += 97) {
            ASSERT_FLOAT_EQ(samples[2 * frame], static_cast<float>(frame + 1) * 0.0001f);
            ASSERT_FLOAT_EQ(samples[2 * frame + 1], static_cast<float>(frame + 1) * 0.0001f + 0.25f);
        }
        float scratch[8];
        EXPECT_EQ(decoder->read(scratch, 4), 0u);
        EXPECT_FALSE(decoder->failed());
    }
}

TEST(AppleDecoder, ARewindStartsTheSoundAgainFromItsFirstFrame)
{
    auto decoder = OpenAppleDecoder(media::MakeMemoryByteSource(FloatWav(1, 48'000, 1000)), nullptr);
    ASSERT_NE(decoder, nullptr);
    float first[3];
    ASSERT_EQ(decoder->read(first, 3), 3u);
    std::vector<float> rest(2000);
    decoder->read(rest.data(), 997);
    ASSERT_TRUE(decoder->rewind());
    float again[3];
    ASSERT_EQ(decoder->read(again, 3), 3u);
    EXPECT_EQ(std::memcmp(first, again, sizeof first), 0);
}

TEST(AppleDecoder, DecodesTheAudioTrackOfAVideoFile)
{
    std::string error;
    auto decoder = OpenAppleDecoder(Memory(fixtures::kMp4WithAac), &error);
    ASSERT_NE(decoder, nullptr) << error;
    EXPECT_EQ(decoder->format(), (PcmFormat { 1, 44'100 }));
    const auto samples = ReadAll(*decoder, 1024);
    // 0.4 s of audio, give or take the codec's priming.
    EXPECT_GT(samples.size(), 16'000u);
    EXPECT_LT(samples.size(), 19'000u);
    double energy = 0.0;
    for (const float sample : samples) energy += static_cast<double>(sample) * static_cast<double>(sample);
    EXPECT_GT(energy, 100.0);
}

TEST(AppleDecoder, FilesThatAreNotAudioAreRefusedWithAReason)
{
    std::vector<std::uint8_t> noise(4096);
    for (std::size_t index = 0; index < noise.size(); ++index) {
        noise[index] = static_cast<std::uint8_t>((index * 2'654'435'761u) >> 13);
    }
    for (const bool optional : { false, true }) {
        std::string error;
        EXPECT_EQ(OpenAppleDecoder(media::MakeMemoryByteSource(noise), &error, optional), nullptr);
        EXPECT_FALSE(error.empty()) << "unrecognised input is an error even when audio is optional";
    }
    std::string error;
    EXPECT_EQ(OpenAppleDecoder(media::MakeMemoryByteSource({}), &error), nullptr);
    EXPECT_FALSE(error.empty());
    error.clear();
    EXPECT_EQ(OpenAppleDecoder(nullptr, &error), nullptr);
    EXPECT_FALSE(error.empty());
    // A WAV whose header stops before the format is complete.
    auto wav = FloatWav(1, 48'000, 100);
    wav.resize(20);
    error.clear();
    EXPECT_EQ(OpenAppleDecoder(media::MakeMemoryByteSource(wav), &error), nullptr);
    EXPECT_FALSE(error.empty());
}

TEST(AppleDecoder, AVideoWithoutAudioIsSilentWhenAudioIsOptionalAndAnErrorOtherwise)
{
    std::string error;
    EXPECT_EQ(OpenAppleDecoder(Memory(fixtures::kVideoOnlyMp4), &error, false), nullptr);
    EXPECT_FALSE(error.empty());

    error = "stale";
    EXPECT_EQ(OpenAppleDecoder(Memory(fixtures::kVideoOnlyMp4), &error, true), nullptr);
    EXPECT_TRUE(error.empty()) << error;
}

} // namespace
} // namespace wallpaper::sound
