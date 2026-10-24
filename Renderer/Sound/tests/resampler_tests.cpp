// Resampler: exact output lengths, no latency, a clean tone, an anti-alias
// cut, and the same output however the input is chunked.
#include "Sound/Resampler.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace wallpaper::sound
{
namespace
{

constexpr double kPi = 3.14159265358979323846;

std::vector<float> Tone(double frequency, double rate, std::size_t frames, std::uint32_t channels = 1)
{
    std::vector<float> samples(frames * channels);
    for (std::size_t frame = 0; frame < frames; ++frame) {
        for (std::uint32_t channel = 0; channel < channels; ++channel) {
            samples[frame * channels + channel] = static_cast<float>(
                0.5 * std::sin(2.0 * kPi * (frequency + 100.0 * channel) * static_cast<double>(frame) / rate));
        }
    }
    return samples;
}

std::vector<float> Resample(Resampler& resampler, const std::vector<float>& input, std::size_t chunk)
{
    const std::uint32_t channels = resampler.channels();
    std::vector<float>  out;
    for (std::size_t at = 0; at < input.size() / channels; at += chunk) {
        const std::size_t count = std::min(chunk, input.size() / channels - at);
        resampler.push(input.data() + at * channels, count, out);
    }
    resampler.flush(out);
    return out;
}

double MaxError(const std::vector<float>& out, double frequency, double rate, std::size_t skip)
{
    double worst = 0.0;
    for (std::size_t frame = skip; frame + skip < out.size(); ++frame) {
        const double ideal = 0.5 * std::sin(2.0 * kPi * frequency * static_cast<double>(frame) / rate);
        worst = std::max(worst, std::fabs(static_cast<double>(out[frame]) - ideal));
    }
    return worst;
}

TEST(Resampler, AWholePassIsTheCeilingOfTheRatioInFrames)
{
    for (const auto [in_rate, out_rate] : { std::pair { 44'100u, 48'000u }, std::pair { 48'000u, 44'100u },
                                            std::pair { 8'000u, 48'000u }, std::pair { 96'000u, 44'100u },
                                            std::pair { 44'100u, 47'999u }, std::pair { 22'050u, 48'000u } }) {
        for (const std::size_t frames : { std::size_t { 1 }, std::size_t { 2 }, std::size_t { 99 }, std::size_t { 1000 },
                                          std::size_t { 4097 }, std::size_t { 20'000 } }) {
            SCOPED_TRACE(::testing::Message() << in_rate << " -> " << out_rate << ", " << frames << " frames");
            Resampler resampler(1, in_rate, out_rate);
            const auto out = Resample(resampler, Tone(440, in_rate, frames), 333);
            const std::uint64_t expected = (static_cast<std::uint64_t>(frames) * out_rate + in_rate - 1) / in_rate;
            EXPECT_EQ(out.size(), expected);
        }
    }
}

TEST(Resampler, TheOutputDoesNotDependOnHowTheInputIsChunked)
{
    const auto input = Tone(440, 44'100, 5000, 2);
    Resampler  whole(2, 44'100, 48'000);
    const auto reference = Resample(whole, input, 5000);
    for (const std::size_t chunk : { std::size_t { 1 }, std::size_t { 7 }, std::size_t { 4096 }, std::size_t { 4999 } }) {
        Resampler resampler(2, 44'100, 48'000);
        EXPECT_EQ(Resample(resampler, input, chunk), reference) << "chunk " << chunk;
    }
}

TEST(Resampler, APassAfterResetIsIdenticalToTheFirst)
{
    const auto input = Tone(1000, 48'000, 3000);
    Resampler  resampler(1, 48'000, 44'100);
    const auto first  = Resample(resampler, input, 500);
    const auto second = Resample(resampler, input, 777);
    EXPECT_EQ(first, second);
}

TEST(Resampler, TheToneComesOutCleanAndWithoutLatency)
{
    struct Case {
        std::uint32_t in_rate, out_rate;
        double        frequency;
    };
    for (const auto [in_rate, out_rate, frequency] :
         { Case { 44'100, 48'000, 440 }, Case { 48'000, 44'100, 1000 }, Case { 22'050, 48'000, 440 },
           Case { 48'000, 16'000, 440 }, Case { 8'000, 48'000, 440 }, Case { 44'100, 96'000, 3000 },
           // 47999 has too many phases to be exact: the interpolated table.
           Case { 44'100, 47'999, 1000 }, Case { 47'999, 44'100, 1000 } }) {
        SCOPED_TRACE(::testing::Message() << in_rate << " -> " << out_rate);
        Resampler resampler(1, in_rate, out_rate);
        const auto out = Resample(resampler, Tone(frequency, in_rate, in_rate), 1000);
        EXPECT_LT(MaxError(out, frequency, out_rate, 200), 1e-4);
        // The first and last frames, where the filter runs out of input, are
        // close to the tone but not exact; a delay would put them far off.
        EXPECT_LT(MaxError(out, frequency, out_rate, 0), 0.05);
    }
}

TEST(Resampler, ADcLevelPassesWithUnitGain)
{
    for (const auto [in_rate, out_rate] :
         { std::pair { 44'100u, 48'000u }, std::pair { 48'000u, 16'000u }, std::pair { 44'100u, 47'999u } }) {
        Resampler resampler(1, in_rate, out_rate);
        const std::vector<float> input(in_rate / 2, 0.5f);
        const auto out = Resample(resampler, input, 4096);
        for (std::size_t frame = 300; frame + 300 < out.size(); ++frame) {
            ASSERT_NEAR(out[frame], 0.5f, 1e-5f) << in_rate << " -> " << out_rate << " frame " << frame;
        }
    }
}

TEST(Resampler, FrequenciesAboveTheNewNyquistAreRemovedAndBelowItKept)
{
    // 48 kHz to 16 kHz: Nyquist is 8 kHz. A 5 kHz tone survives, a 12 kHz tone
    // (which would alias to 4 kHz) is cut by more than 60 dB.
    const auto rms = [](const std::vector<float>& samples) {
        double sum = 0.0;
        for (std::size_t frame = 500; frame + 500 < samples.size(); ++frame) {
            sum += static_cast<double>(samples[frame]) * static_cast<double>(samples[frame]);
        }
        return std::sqrt(sum / static_cast<double>(samples.size() - 1000));
    };
    Resampler low(1, 48'000, 16'000);
    Resampler high(1, 48'000, 16'000);
    const double kept    = rms(Resample(low, Tone(5000, 48'000, 48'000), 1000));
    const double removed = rms(Resample(high, Tone(12'000, 48'000, 48'000), 1000));
    EXPECT_NEAR(kept, 0.5 / std::sqrt(2.0), 0.01);
    EXPECT_LT(removed, kept / 1000.0);
}

TEST(Resampler, SilenceStaysSilent)
{
    Resampler resampler(2, 44'100, 48'000);
    const auto out = Resample(resampler, std::vector<float>(2 * 3000, 0.0f), 1000);
    ASSERT_FALSE(out.empty());
    EXPECT_TRUE(std::all_of(out.begin(), out.end(), [](float s) { return s == 0.0f; }));
}

TEST(Resampler, ChannelsAreFilteredIndependently)
{
    const auto input = Tone(440, 44'100, 4000, 2);
    Resampler  stereo(2, 44'100, 48'000);
    const auto both = Resample(stereo, input, 1000);
    std::vector<float> left(4000), right(4000);
    for (std::size_t frame = 0; frame < 4000; ++frame) {
        left[frame]  = input[2 * frame];
        right[frame] = input[2 * frame + 1];
    }
    Resampler one(1, 44'100, 48'000);
    Resampler two(1, 44'100, 48'000);
    const auto l = Resample(one, left, 1000);
    const auto r = Resample(two, right, 1000);
    ASSERT_EQ(both.size(), 2 * l.size());
    for (std::size_t frame = 0; frame < l.size(); ++frame) {
        ASSERT_NEAR(both[2 * frame], l[frame], 1e-6f);
        ASSERT_NEAR(both[2 * frame + 1], r[frame], 1e-6f);
    }
}

TEST(Resampler, OnlyRatiosWithAReasonableFilterAreSupported)
{
    EXPECT_TRUE(Resampler::Supports(44100, 48000));
    EXPECT_TRUE(Resampler::Supports(48000, 44100));
    EXPECT_TRUE(Resampler::Supports(8000, 768000));
    EXPECT_TRUE(Resampler::Supports(768000, 48000));
    EXPECT_FALSE(Resampler::Supports(4'000'000'001u, 48000));
    EXPECT_FALSE(Resampler::Supports(768000, 8000));
    EXPECT_FALSE(Resampler::Supports(0, 48000));
    EXPECT_FALSE(Resampler::Supports(48000, 0));
}

TEST(Resampler, AWideRatioGivesTheSameOutputWhateverTheChunkSize)
{
    // 768 kHz down to 16 kHz skips 48 input frames per output frame, more than a
    // one-frame push brings.
    const auto input = Tone(1000.0, 768000.0, 20'000);
    Resampler  a(1, 768000, 16000);
    Resampler  b(1, 768000, 16000);
    const auto whole   = Resample(a, input, input.size());
    const auto trickle = Resample(b, input, 1);
    ASSERT_EQ(whole.size(), 417u); // ceil(20000 * 16000 / 768000)
    EXPECT_EQ(whole, trickle);
}

TEST(Resampler, AnUnsupportedRatioDoesNotGrowTheFilterWithoutBound)
{
    // Callers check Supports first; if one does not, the table stays small and the
    // resampler still runs (at its narrowest filter) instead of asking for gigabytes.
    Resampler resampler(2, 4'000'000'001u, 48000);
    std::vector<float> out;
    const std::vector<float> input(2 * 4096, 0.25f);
    resampler.push(input.data(), 4096, out);
    resampler.flush(out);
    EXPECT_LT(out.size(), 64u);
}

} // namespace
} // namespace wallpaper::sound
