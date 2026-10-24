// PcmPipeline over a synthetic decoder: loops with no gap, ends cleanly,
// refuses to spin on an empty sound, stops a loop when decoding fails, and
// converts to the device layout in either order.
#include "Sound/PcmPipeline.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <optional>
#include <vector>

namespace wallpaper::sound
{
namespace
{

constexpr double kPi = 3.14159265358979323846;

/// Frame f, channel c holds f + 0.001 * c, so order and position are visible.
class RampDecoder final : public PcmDecoder {
public:
    RampDecoder(PcmFormat format, std::size_t frames, std::size_t max_chunk = 1u << 20)
        : m_format(format), m_frames(frames), m_max_chunk(max_chunk)
    {
    }

    PcmFormat format() const override { return m_format; }

    std::size_t read(float* out, std::size_t frames) override
    {
        if (m_fail_after && m_position >= *m_fail_after) {
            m_failed = true;
            return 0;
        }
        std::size_t count = std::min({ frames, m_frames - m_position, m_max_chunk });
        if (m_fail_after) count = std::min(count, *m_fail_after - m_position);
        for (std::size_t frame = 0; frame < count; ++frame) {
            for (std::uint32_t channel = 0; channel < m_format.channels; ++channel) {
                out[frame * m_format.channels + channel] =
                    static_cast<float>(m_position + frame) + 0.001f * static_cast<float>(channel);
            }
        }
        m_position += count;
        return count;
    }

    bool rewind() override
    {
        ++m_rewinds;
        m_position = 0;
        return !m_refuse_rewind;
    }

    bool failed() const override { return m_failed; }

    void failAfter(std::size_t frames) { m_fail_after = frames; }
    void refuseRewind() { m_refuse_rewind = true; }
    int  rewinds() const { return m_rewinds; }

private:
    PcmFormat                  m_format;
    std::size_t                m_frames;
    std::size_t                m_max_chunk;
    std::size_t                m_position { 0 };
    std::optional<std::size_t> m_fail_after;
    bool                       m_failed { false };
    bool                       m_refuse_rewind { false };
    int                        m_rewinds { 0 };
};

std::vector<float> ReadAll(PcmPipeline& pipeline, std::uint32_t channels, std::size_t chunk,
                           std::size_t max_frames = 1u << 20)
{
    std::vector<float> all;
    std::vector<float> block(chunk * channels);
    while (all.size() / channels < max_frames) {
        const auto frames = pipeline.read(block.data(), chunk);
        all.insert(all.end(), block.begin(), block.begin() + static_cast<std::ptrdiff_t>(frames * channels));
        if (frames < chunk) break;
    }
    return all;
}

TEST(PcmPipeline, SameLayoutPassesTheDecodedFramesThrough)
{
    PcmPipeline pipeline(std::make_unique<RampDecoder>(PcmFormat { 2, 48'000 }, 10'000), { 2, 48'000 }, false);
    const auto  out = ReadAll(pipeline, 2, 777);
    ASSERT_EQ(out.size(), 20'000u);
    for (std::size_t frame = 0; frame < 10'000; ++frame) {
        ASSERT_EQ(out[2 * frame], static_cast<float>(frame));
        ASSERT_EQ(out[2 * frame + 1], static_cast<float>(frame) + 0.001f);
    }
    float scratch[8] {};
    EXPECT_EQ(pipeline.read(scratch, 4), 0u);
    EXPECT_EQ(pipeline.read(scratch, 4), 0u);
}

TEST(PcmPipeline, ALayoutThatCannotBeConvertedIsNotSupported)
{
    EXPECT_TRUE(PcmPipeline::Supports({ 2, 48'000 }, { 2, 48'000 }));
    EXPECT_TRUE(PcmPipeline::Supports({ 1, 44'100 }, { 2, 48'000 }));
    EXPECT_TRUE(PcmPipeline::Supports({ 2, 768'000 }, { 2, 48'000 }));
    EXPECT_FALSE(PcmPipeline::Supports({ 2, 4'000'000'001u }, { 2, 48'000 }));
    EXPECT_FALSE(PcmPipeline::Supports({ 0, 48'000 }, { 2, 48'000 }));
    EXPECT_FALSE(PcmPipeline::Supports({ 2, 48'000 }, { 0, 48'000 }));
}

TEST(PcmPipeline, ADecoderThatReturnsTinyChunksStillFillsEveryRead)
{
    PcmPipeline pipeline(std::make_unique<RampDecoder>(PcmFormat { 1, 48'000 }, 5000, 3), { 1, 48'000 }, false);
    EXPECT_EQ(ReadAll(pipeline, 1, 1000).size(), 5000u);
}

TEST(PcmPipeline, ALoopRepeatsTheSoundWithNoGapAtTheSeam)
{
    auto decoder = std::make_unique<RampDecoder>(PcmFormat { 1, 48'000 }, 1000);
    auto* raw    = decoder.get();
    PcmPipeline pipeline(std::move(decoder), { 1, 48'000 }, true);
    const auto  out = ReadAll(pipeline, 1, 333, 3500);
    ASSERT_GE(out.size(), 3500u);
    for (std::size_t frame = 0; frame < out.size(); ++frame) {
        ASSERT_EQ(out[frame], static_cast<float>(frame % 1000)) << frame;
    }
    EXPECT_GE(raw->rewinds(), 3);
}

TEST(PcmPipeline, AResampledLoopRepeatsOnePassIncludingItsTail)
{
    PcmPipeline once(std::make_unique<RampDecoder>(PcmFormat { 1, 44'100 }, 1001), { 2, 48'000 }, false);
    PcmPipeline loop(std::make_unique<RampDecoder>(PcmFormat { 1, 44'100 }, 1001), { 2, 48'000 }, true);
    const auto  pass = ReadAll(once, 2, 97);
    ASSERT_EQ(pass.size() / 2, (1001u * 48'000u + 44'099u) / 44'100u);
    const auto cycles = ReadAll(loop, 2, 89, pass.size() / 2 * 3);
    ASSERT_GE(cycles.size(), pass.size() * 3);
    for (std::size_t index = 0; index < pass.size() * 3; ++index) {
        ASSERT_EQ(cycles[index], pass[index % pass.size()]) << index;
    }
}

TEST(PcmPipeline, ASoundWithNoFramesEndsEvenWhenLooping)
{
    PcmPipeline pipeline(std::make_unique<RampDecoder>(PcmFormat { 2, 48'000 }, 0), { 2, 48'000 }, true);
    float       out[8] {};
    EXPECT_EQ(pipeline.read(out, 4), 0u);
    PcmPipeline resampled(std::make_unique<RampDecoder>(PcmFormat { 2, 44'100 }, 0), { 2, 48'000 }, true);
    EXPECT_EQ(resampled.read(out, 4), 0u);
}

TEST(PcmPipeline, ALoopEndsWhenTheDecoderCannotRewind)
{
    auto decoder = std::make_unique<RampDecoder>(PcmFormat { 1, 48'000 }, 100);
    decoder->refuseRewind();
    PcmPipeline pipeline(std::move(decoder), { 1, 48'000 }, true);
    // The refused rewind leaves the position at 0 in this fake, so a second pass
    // would be heard if the pipeline ignored the refusal; it must stop after one.
    EXPECT_EQ(ReadAll(pipeline, 1, 64).size(), 100u);
}

TEST(PcmPipeline, ADecoderFailureEndsTheSoundAndTheLoop)
{
    auto decoder = std::make_unique<RampDecoder>(PcmFormat { 1, 48'000 }, 1000);
    decoder->failAfter(400);
    auto*       raw = decoder.get();
    PcmPipeline pipeline(std::move(decoder), { 1, 48'000 }, true);
    EXPECT_EQ(ReadAll(pipeline, 1, 100).size(), 400u);
    EXPECT_TRUE(raw->failed());
    EXPECT_EQ(raw->rewinds(), 0);
}

TEST(PcmPipeline, MonoToStereoAtAnotherRateMixesAfterResampling)
{
    // Resampling at one channel and mixing up must equal mixing up first.
    const auto make = [](double rate, std::size_t frames) {
        class Tone final : public PcmDecoder {
        public:
            Tone(double r, std::size_t n): m_rate(r), m_frames(n) {}
            PcmFormat format() const override { return { 1, static_cast<std::uint32_t>(m_rate) }; }
            std::size_t read(float* out, std::size_t frames) override
            {
                const std::size_t count = std::min(frames, m_frames - m_position);
                for (std::size_t i = 0; i < count; ++i) {
                    out[i] = static_cast<float>(
                        0.5 * std::sin(2.0 * kPi * 440.0 * static_cast<double>(m_position + i) / m_rate));
                }
                m_position += count;
                return count;
            }
            bool rewind() override { m_position = 0; return true; }
        private:
            double m_rate;
            std::size_t m_frames, m_position { 0 };
        };
        return std::make_unique<Tone>(rate, frames);
    };
    PcmPipeline pipeline(make(44'100, 44'100), { 2, 48'000 }, false);
    const auto  out = ReadAll(pipeline, 2, 500);
    ASSERT_EQ(out.size(), 2u * 48'000u);
    for (std::size_t frame = 200; frame + 200 < 48'000; ++frame) {
        const double ideal = 0.5 * std::sin(2.0 * kPi * 440.0 * static_cast<double>(frame) / 48'000.0) * 0.70710678;
        ASSERT_NEAR(out[2 * frame], ideal, 1e-4);
        ASSERT_EQ(out[2 * frame], out[2 * frame + 1]);
    }
}

TEST(PcmPipeline, StereoToMonoAtAnotherRateMixesBeforeResampling)
{
    PcmPipeline pipeline(std::make_unique<RampDecoder>(PcmFormat { 2, 48'000 }, 2000), { 1, 44'100 }, false);
    const auto  out = ReadAll(pipeline, 1, 311);
    EXPECT_EQ(out.size(), (2000u * 44'100u + 47'999u) / 48'000u);
}

} // namespace
} // namespace wallpaper::sound
