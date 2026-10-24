// Counter-examples for demand-driven video pacing.
//
// The failure this guards against is silent: a clock that ticks less often than
// the content changes drops frames while every other signal still looks
// healthy. Each case below is a stream whose declared metadata does not
// describe its real timing, or a playback condition that changes how often the
// wall clock has to wake up.

#include "Video/VideoFramePacing.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <vector>

namespace wallpaper::video
{
namespace
{

constexpr double kMetadata30 = 1.0 / 30.0;

double MetadataPeriod(std::initializer_list<FrameRateRatio> rates)
{
    const std::vector<FrameRateRatio> values(rates);
    return ShortestMetadataPeriodSeconds(values.data(), values.size());
}

/// Feeds `count` frames spaced `period` apart in one continuous run.
void FeedRun(VideoFramePacingEstimator& estimator, double start, double period, int count,
             std::uint64_t loop_index = 0, std::uint64_t seek_ticket = 0)
{
    for (int i = 0; i < count; ++i) {
        estimator.Observe(start + period * i, loop_index, seek_ticket);
    }
}

TEST(VideoFramePacing, ShortestPeriodComesFromTheHighestDeclaredRate) {
    // min(period) must be taken over periods, which is 1/max(fps): a 60 fps
    // estimate next to a 30 fps average has to yield 1/60, not 1/30.
    EXPECT_DOUBLE_EQ(MetadataPeriod({ { 30, 1 }, { 60, 1 } }), 1.0 / 60.0);
    EXPECT_DOUBLE_EQ(MetadataPeriod({ { 60, 1 }, { 30, 1 } }), 1.0 / 60.0);
}

TEST(VideoFramePacing, RationalRatesKeepTheirExactPeriod) {
    // 23.976 and 29.97 are 24000/1001 and 30000/1001. Rounding either to two
    // decimals moves the period enough to miss a frame over a long clip.
    EXPECT_DOUBLE_EQ(MetadataPeriod({ { 24000, 1001 } }), 1001.0 / 24000.0);
    EXPECT_DOUBLE_EQ(MetadataPeriod({ { 30000, 1001 } }), 1001.0 / 30000.0);
    EXPECT_NE(MetadataPeriod({ { 24000, 1001 } }), 1.0 / 24.0);
}

TEST(VideoFramePacing, UnusableDeclaredRatesReportNothing) {
    EXPECT_DOUBLE_EQ(MetadataPeriod({ { 0, 0 } }), 0.0);
    EXPECT_DOUBLE_EQ(MetadataPeriod({ { -30, 1 }, { 30, -1 } }), 0.0);
    EXPECT_DOUBLE_EQ(MetadataPeriod({ { 0, 1 }, { 25, 1 } }), 1.0 / 25.0);
    EXPECT_DOUBLE_EQ(ShortestMetadataPeriodSeconds(nullptr, 2), 0.0);
}

TEST(VideoFramePacing, DeclaredRatesAloneNeverUnlockPacing) {
    // The previous behaviour paced on container metadata the moment the file
    // was probed. Metadata is not evidence about any particular gap, so a
    // freshly opened source must still report unknown.
    VideoFramePacingEstimator estimator;
    estimator.Reset(kMetadata30);
    EXPECT_DOUBLE_EQ(estimator.PeriodSeconds(), 0.0);

    FeedRun(estimator, 0.0, kMetadata30, VideoFramePacingEstimator::kMinimumSamples);
    EXPECT_EQ(estimator.SampleCount(), VideoFramePacingEstimator::kMinimumSamples - 1);
    EXPECT_DOUBLE_EQ(estimator.PeriodSeconds(), 0.0);

    estimator.Observe(kMetadata30 * VideoFramePacingEstimator::kMinimumSamples, 0, 0);
    EXPECT_EQ(estimator.SampleCount(), VideoFramePacingEstimator::kMinimumSamples);
    EXPECT_NEAR(estimator.PeriodSeconds(), kMetadata30, 1e-12);
}

TEST(VideoFramePacing, AVariableRateBurstShortensThePeriodBelowTheAverage) {
    // The counter-example the metadata-only version could not survive: a clip
    // whose average is 10 fps but which contains a 60 fps burst. Pacing on the
    // average would step over five frames of that burst every tick.
    VideoFramePacingEstimator estimator;
    estimator.Reset(0.1);

    double timestamp = 0.0;
    for (int i = 0; i < 10; ++i) {
        estimator.Observe(timestamp, 0, 0);
        timestamp += 0.1;
    }
    ASSERT_NEAR(estimator.PeriodSeconds(), 0.1, 1e-12);

    for (int i = 0; i < 5; ++i) {
        timestamp += 1.0 / 60.0;
        estimator.Observe(timestamp, 0, 0);
    }
    EXPECT_NEAR(estimator.PeriodSeconds(), 1.0 / 60.0, 1e-12);

    // Returning to the sparse cadence must not relax the period again: the
    // burst can recur, and a period that grows back would drop it next time.
    for (int i = 0; i < 10; ++i) {
        timestamp += 0.1;
        estimator.Observe(timestamp, 0, 0);
    }
    EXPECT_NEAR(estimator.PeriodSeconds(), 1.0 / 60.0, 1e-12);
}

TEST(VideoFramePacing, MissingMetadataStillPacesOnObservedTimestamps) {
    VideoFramePacingEstimator estimator;
    estimator.Reset(0.0);
    FeedRun(estimator, 0.0, 0.04, 12);
    EXPECT_DOUBLE_EQ(estimator.MetadataPeriodSeconds(), 0.0);
    EXPECT_NEAR(estimator.PeriodSeconds(), 0.04, 1e-12);
}

TEST(VideoFramePacing, DeclaredRateBoundsAnObservationThatIsTooOptimistic) {
    // A clip whose decoded gaps happen to look uniform at 30 fps but which
    // declares 60 fps has to be paced at 60: the declaration is the tighter
    // bound, and the tighter bound only ever renders more often.
    VideoFramePacingEstimator estimator;
    estimator.Reset(1.0 / 60.0);
    FeedRun(estimator, 0.0, kMetadata30, 12);
    EXPECT_NEAR(estimator.PeriodSeconds(), 1.0 / 60.0, 1e-12);
}

TEST(VideoFramePacing, ANonZeroStartTimestampDoesNotDistortThePeriod) {
    VideoFramePacingEstimator estimator;
    estimator.Reset(kMetadata30);
    FeedRun(estimator, 7.25, kMetadata30, 12);
    EXPECT_NEAR(estimator.PeriodSeconds(), kMetadata30, 1e-12);
}

TEST(VideoFramePacing, RepeatedAndRewoundTimestampsAreNotEvidence) {
    VideoFramePacingEstimator estimator;
    estimator.Reset(0.0);

    for (int i = 0; i < 20; ++i) estimator.Observe(3.0, 0, 0);
    EXPECT_EQ(estimator.SampleCount(), 0u);
    EXPECT_DOUBLE_EQ(estimator.PeriodSeconds(), 0.0);

    for (int i = 0; i < 20; ++i) estimator.Observe(3.0 - 0.01 * i, 0, 0);
    EXPECT_EQ(estimator.SampleCount(), 0u);
    EXPECT_DOUBLE_EQ(estimator.PeriodSeconds(), 0.0);
}

TEST(VideoFramePacing, ANonFiniteTimestampBreaksTheRunInsteadOfSeedingIt) {
    VideoFramePacingEstimator estimator;
    estimator.Reset(0.0);
    estimator.Observe(1.0, 0, 0);
    estimator.Observe(std::nan(""), 0, 0);
    estimator.Observe(1.04, 0, 0);
    EXPECT_EQ(estimator.SampleCount(), 0u);
}

TEST(VideoFramePacing, TheLoopSeamIsNotMeasuredAsAContentGap) {
    // At the seam the gap is duration minus the last timestamp plus the first,
    // which describes the wrap, not the content. Counting it would let a short
    // clip pace itself far faster than it changes.
    VideoFramePacingEstimator estimator;
    estimator.Reset(0.0);
    FeedRun(estimator, 0.0, 0.04, 10, /*loop_index=*/0);
    const double after_first_loop = estimator.PeriodSeconds();
    ASSERT_NEAR(after_first_loop, 0.04, 1e-12);

    // First frame of the next loop lands 1 ms after the previous one.
    estimator.Observe(0.361, 1, 0);
    EXPECT_NEAR(estimator.PeriodSeconds(), 0.04, 1e-12);

    FeedRun(estimator, 0.401, 0.04, 10, /*loop_index=*/1);
    EXPECT_NEAR(estimator.PeriodSeconds(), 0.04, 1e-12);
}

TEST(VideoFramePacing, ASeekDiscontinuityIsNotMeasuredAsAContentGap) {
    VideoFramePacingEstimator estimator;
    estimator.Reset(0.0);
    FeedRun(estimator, 0.0, 0.04, 10, 0, /*seek_ticket=*/0);
    ASSERT_NEAR(estimator.PeriodSeconds(), 0.04, 1e-12);

    // A resume after a seek lands 2 ms past the last decoded frame.
    estimator.Observe(0.362, 0, /*seek_ticket=*/1);
    EXPECT_NEAR(estimator.PeriodSeconds(), 0.04, 1e-12);
}

TEST(VideoFramePacing, ResetForgetsThePreviousStreamsEvidence) {
    VideoFramePacingEstimator estimator;
    estimator.Reset(0.0);
    FeedRun(estimator, 0.0, 1.0 / 120.0, 12);
    ASSERT_NEAR(estimator.PeriodSeconds(), 1.0 / 120.0, 1e-12);

    estimator.Reset(kMetadata30);
    EXPECT_DOUBLE_EQ(estimator.PeriodSeconds(), 0.0);
    EXPECT_EQ(estimator.SampleCount(), 0u);
    FeedRun(estimator, 0.0, kMetadata30, 12);
    EXPECT_NEAR(estimator.PeriodSeconds(), kMetadata30, 1e-12);
}

TEST(VideoFrameSelection, ANewGenerationIsSelectedAndARepeatIsReused) {
    VideoFrameSelectionTracker tracker;

    const auto first = tracker.Observe(1);
    EXPECT_TRUE(first.selected);
    EXPECT_FALSE(first.reused);
    EXPECT_EQ(first.skipped, 0u);

    const auto repeat = tracker.Observe(1);
    EXPECT_FALSE(repeat.selected);
    EXPECT_TRUE(repeat.reused);
    EXPECT_EQ(repeat.skipped, 0u);

    const auto next = tracker.Observe(2);
    EXPECT_TRUE(next.selected);
    EXPECT_EQ(next.skipped, 0u);
}

TEST(VideoFrameSelection, AGapInDisplayedGenerationsIsDecodedWorkThrownAway) {
    // This is the observable that makes a pacing regression falsifiable: the
    // clock ticked too slowly, three decoded frames were superseded, and the
    // count says so even though the picture still moves.
    VideoFrameSelectionTracker tracker;
    ASSERT_TRUE(tracker.Observe(1).selected);

    const auto jump = tracker.Observe(5);
    EXPECT_TRUE(jump.selected);
    EXPECT_EQ(jump.skipped, 3u);
}

TEST(VideoFrameSelection, FramesDecodedBeforeTheFirstDisplayedOneCount) {
    VideoFrameSelectionTracker tracker;
    const auto late = tracker.Observe(4);
    EXPECT_TRUE(late.selected);
    EXPECT_EQ(late.skipped, 3u);
}

TEST(VideoFrameSelection, NoFrameIsNeitherSelectedNorSkipped) {
    VideoFrameSelectionTracker tracker;
    const auto none = tracker.Observe(0);
    EXPECT_FALSE(none.selected);
    EXPECT_FALSE(none.reused);
    EXPECT_EQ(none.skipped, 0u);

    // The absent frame must not become the baseline either.
    const auto first = tracker.Observe(1);
    EXPECT_TRUE(first.selected);
    EXPECT_EQ(first.skipped, 0u);
}

TEST(VideoFrameSelection, ARenumberedSourceDoesNotReportPhantomSkips) {
    VideoFrameSelectionTracker tracker;
    ASSERT_TRUE(tracker.Observe(9).selected);

    const auto restarted = tracker.Observe(1);
    EXPECT_TRUE(restarted.selected);
    EXPECT_EQ(restarted.skipped, 0u);

    tracker.Reset();
    const auto after_reset = tracker.Observe(1);
    EXPECT_TRUE(after_reset.selected);
    EXPECT_EQ(after_reset.skipped, 0u);
}

} // namespace
} // namespace wallpaper::video
