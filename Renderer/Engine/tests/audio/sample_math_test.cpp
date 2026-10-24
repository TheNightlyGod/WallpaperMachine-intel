#include "Audio/SampleMath.h"

#include <gtest/gtest.h>

#include <array>
#include <limits>

TEST(AudioSampleMathTest, ClampVolumeRejectsInvalidValues) {
    using wallpaper::audio::ClampVolume;

    EXPECT_FLOAT_EQ(ClampVolume(-3.5F), 0.0F);
    EXPECT_FLOAT_EQ(ClampVolume(0.0F), 0.0F);
    EXPECT_FLOAT_EQ(ClampVolume(0.375F), 0.375F);
    EXPECT_FLOAT_EQ(ClampVolume(1.0F), 1.0F);
    EXPECT_FLOAT_EQ(ClampVolume(2.75F), 1.0F);
    EXPECT_FLOAT_EQ(ClampVolume(std::numeric_limits<float>::quiet_NaN()), 1.0F);
    EXPECT_FLOAT_EQ(ClampVolume(std::numeric_limits<float>::infinity()), 1.0F);
    EXPECT_FLOAT_EQ(ClampVolume(-std::numeric_limits<float>::infinity()), 1.0F);
}

TEST(AudioSampleMathTest, ClearInterleavedF32WritesSilence) {
    std::array<float, 7> samples{17.0F, -2.5F, 6.0F, -0.125F, 3.75F, -9.0F, 21.0F};

    wallpaper::audio::ClearInterleavedF32(samples.data() + 1, 5);

    const std::array<float, 7> silent_window{17.0F, 0.0F, 0.0F, 0.0F, 0.0F, 0.0F, 21.0F};
    EXPECT_EQ(samples, silent_window);

    wallpaper::audio::ClearInterleavedF32(samples.data(), 0);
    EXPECT_EQ(samples, silent_window);
}

TEST(AudioSampleMathTest, ApplyVolumeF32ScalesSamplesInPlace) {
    std::array<float, 6> samples{-13.0F, -6.0F, 1.5F, 10.0F, -0.25F, 19.0F};

    wallpaper::audio::ApplyVolumeF32(samples.data() + 1, 4, 0.5F);

    const std::array<float, 6> scaled{-13.0F, -3.0F, 0.75F, 5.0F, -0.125F, 19.0F};
    EXPECT_EQ(samples, scaled);

    wallpaper::audio::ApplyVolumeF32(samples.data() + 2, 0, 0.0F);
    EXPECT_EQ(samples, scaled);

    std::array<float, 3> bounded_gain{-2.0F, 0.25F, 4.0F};
    const auto original = bounded_gain;
    wallpaper::audio::ApplyVolumeF32(bounded_gain.data(), bounded_gain.size(), 1.75F);
    EXPECT_EQ(bounded_gain, original);
    wallpaper::audio::ApplyVolumeF32(bounded_gain.data(), bounded_gain.size(),
                                     std::numeric_limits<float>::quiet_NaN());
    EXPECT_EQ(bounded_gain, original);
    wallpaper::audio::ApplyVolumeF32(bounded_gain.data(), bounded_gain.size(), -0.5F);
    const std::array<float, 3> silence{};
    EXPECT_EQ(bounded_gain, silence);
}

TEST(AudioSampleMathTest, MixInterleavedF32AddsScaledInput) {
    std::array<float, 6> input{23.0F, -3.0F, 2.0F, 0.5F, -4.0F, 29.0F};
    const auto unchanged_input = input;
    std::array<float, 6> output{-31.0F, 1.0F, -1.0F, 2.0F, 0.25F, 37.0F};

    wallpaper::audio::MixInterleavedF32(output.data() + 1, input.data() + 1, 4, 0.5F);

    const std::array<float, 6> mixed{-31.0F, -0.5F, 0.0F, 2.25F, -1.75F, 37.0F};
    EXPECT_EQ(output, mixed);
    EXPECT_EQ(input, unchanged_input);

    wallpaper::audio::MixInterleavedF32(output.data(), input.data(), 0, 1.0F);
    wallpaper::audio::MixInterleavedF32(output.data(), nullptr, output.size(), 1.0F);
    EXPECT_EQ(output, mixed);
    EXPECT_EQ(input, unchanged_input);

    std::array<float, 2> gain_output{1.0F, -2.0F};
    std::array<float, 2> gain_input{3.0F, 4.0F};
    const std::array<float, 2> before_gain{1.0F, -2.0F};
    wallpaper::audio::MixInterleavedF32(gain_output.data(), gain_input.data(), 2, -0.25F);
    EXPECT_EQ(gain_output, before_gain);
    wallpaper::audio::MixInterleavedF32(gain_output.data(), gain_input.data(), 2, 1.5F);
    const std::array<float, 2> full_gain{4.0F, 2.0F};
    EXPECT_EQ(gain_output, full_gain);
    const std::array<float, 2> original_gain_input{3.0F, 4.0F};
    EXPECT_EQ(gain_input, original_gain_input);
}
