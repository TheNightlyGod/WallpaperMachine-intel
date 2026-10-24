#include "Video/VideoTextureSource.hpp"

#include <gtest/gtest.h>

#include <array>

namespace {

void ExpectPlaybackStateEquals(const wallpaper::video::VideoPlaybackState& actual,
                               const wallpaper::video::VideoPlaybackState& expected) {
    EXPECT_EQ(actual.paused, expected.paused);
    EXPECT_FLOAT_EQ(actual.rate, expected.rate);
    EXPECT_DOUBLE_EQ(actual.scene_elapsed_seconds, expected.scene_elapsed_seconds);
}

struct PlaybackCompositionCase {
    const char* label;
    wallpaper::video::VideoPlaybackState global;
    wallpaper::video::VideoPlaybackState layer;
    wallpaper::video::VideoPlaybackState expected;
};

}  // namespace

TEST(VideoTextureSubmissionSmoke, MergesGlobalAndLayerVideoPlaybackState) {
    const std::array<PlaybackCompositionCase, 4> cases{{
        {"layer pauses", {false, 0.75F, 41.5}, {true, 2.0F, 7.25}, {true, 1.5F, 7.25}},
        {"global pauses", {true, 1.5F, 111.0}, {false, 0.5F, 3.75}, {true, 0.75F, 3.75}},
        {"both running", {false, 2.0F, 99.0}, {false, 0.25F, 13.125},
         {false, 0.5F, 13.125}},
        {"both paused", {true, 0.5F, 62.0}, {true, 0.5F, 8.5}, {true, 0.25F, 8.5}},
    }};

    for (const auto& example : cases) {
        SCOPED_TRACE(example.label);
        auto global = example.global;
        auto layer = example.layer;

        const auto merged = wallpaper::video::ResolveEffectiveVideoPlaybackState(global, layer);

        ExpectPlaybackStateEquals(merged, example.expected);
        ExpectPlaybackStateEquals(global, example.global);
        ExpectPlaybackStateEquals(layer, example.layer);
    }
}

TEST(VideoTextureSubmissionSmoke, ClampsNegativeVideoPlaybackRates) {
    const std::array<PlaybackCompositionCase, 4> cases{{
        {"negative global", {false, -1.25F, 83.0}, {false, 2.0F, 4.5},
         {false, 0.0F, 4.5}},
        {"negative layer", {true, 1.5F, 27.0}, {false, -0.75F, 6.25},
         {true, 0.0F, 6.25}},
        {"both negative", {false, -2.0F, 51.0}, {true, -3.0F, 9.75},
         {true, 0.0F, 9.75}},
        {"zero rate", {false, 0.0F, 105.0}, {false, 4.0F, 2.125},
         {false, 0.0F, 2.125}},
    }};

    for (const auto& example : cases) {
        SCOPED_TRACE(example.label);
        auto global = example.global;
        auto layer = example.layer;

        const auto merged = wallpaper::video::ResolveEffectiveVideoPlaybackState(global, layer);

        ExpectPlaybackStateEquals(merged, example.expected);
        ExpectPlaybackStateEquals(global, example.global);
        ExpectPlaybackStateEquals(layer, example.layer);
    }
}
