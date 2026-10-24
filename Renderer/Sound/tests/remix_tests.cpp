// ChannelRemix: the default downmix and upmix coefficients.
#include "Sound/ChannelRemix.hpp"

#include <gtest/gtest.h>

#include <vector>

namespace wallpaper::sound
{
namespace
{

constexpr float kSqrtHalf = 0.70710678f;

TEST(ChannelRemix, SameCountIsAnIdentityCopy)
{
    for (const std::uint32_t channels : { 1u, 2u, 6u, 9u }) {
        const ChannelRemix remix(channels, channels);
        EXPECT_TRUE(remix.isIdentity());
        std::vector<float> in(channels * 3), out(in.size());
        for (std::size_t index = 0; index < in.size(); ++index) in[index] = static_cast<float>(index) + 1.0f;
        remix.apply(in.data(), out.data(), 3);
        EXPECT_EQ(in, out);
    }
}

TEST(ChannelRemix, MonoToStereoAndBackAreMinusThreeDecibels)
{
    const ChannelRemix up(1, 2);
    EXPECT_FLOAT_EQ(up.coefficient(0, 0), kSqrtHalf);
    EXPECT_FLOAT_EQ(up.coefficient(1, 0), kSqrtHalf);
    const ChannelRemix down(2, 1);
    EXPECT_FLOAT_EQ(down.coefficient(0, 0), kSqrtHalf);
    EXPECT_FLOAT_EQ(down.coefficient(0, 1), kSqrtHalf);
}

TEST(ChannelRemix, FiveDotOneFoldsToStereoWithoutTheLowFrequencyChannel)
{
    // Order: FL FR FC LFE SL SR.
    const ChannelRemix remix(6, 2);
    EXPECT_FLOAT_EQ(remix.coefficient(0, 0), 1.0f);
    EXPECT_FLOAT_EQ(remix.coefficient(0, 1), 0.0f);
    EXPECT_FLOAT_EQ(remix.coefficient(0, 2), kSqrtHalf);
    EXPECT_FLOAT_EQ(remix.coefficient(0, 3), 0.0f);
    EXPECT_FLOAT_EQ(remix.coefficient(0, 4), kSqrtHalf);
    EXPECT_FLOAT_EQ(remix.coefficient(0, 5), 0.0f);
    EXPECT_FLOAT_EQ(remix.coefficient(1, 1), 1.0f);
    EXPECT_FLOAT_EQ(remix.coefficient(1, 2), kSqrtHalf);
    EXPECT_FLOAT_EQ(remix.coefficient(1, 3), 0.0f);
    EXPECT_FLOAT_EQ(remix.coefficient(1, 5), kSqrtHalf);
}

TEST(ChannelRemix, StereoToFiveDotOneFillsOnlyFrontLeftAndRight)
{
    const ChannelRemix remix(2, 6);
    for (std::uint32_t out = 0; out < 6; ++out) {
        for (std::uint32_t in = 0; in < 2; ++in) {
            EXPECT_FLOAT_EQ(remix.coefficient(out, in), out == in ? 1.0f : 0.0f) << out << "," << in;
        }
    }
}

TEST(ChannelRemix, ALayoutWithoutAKnownOrderCopiesChannelsInOrder)
{
    const ChannelRemix remix(9, 2);
    EXPECT_FLOAT_EQ(remix.coefficient(0, 0), 1.0f);
    EXPECT_FLOAT_EQ(remix.coefficient(1, 1), 1.0f);
    EXPECT_FLOAT_EQ(remix.coefficient(0, 2), 0.0f);
}

TEST(ChannelRemix, ApplyMixesEveryFrame)
{
    const ChannelRemix remix(2, 1);
    const std::vector<float> in { 1.0f, 0.0f, 0.0f, 1.0f, 0.5f, 0.5f };
    std::vector<float> out(3);
    remix.apply(in.data(), out.data(), 3);
    EXPECT_NEAR(out[0], kSqrtHalf, 1e-6f);
    EXPECT_NEAR(out[1], kSqrtHalf, 1e-6f);
    EXPECT_NEAR(out[2], kSqrtHalf, 1e-6f);
}

} // namespace
} // namespace wallpaper::sound
