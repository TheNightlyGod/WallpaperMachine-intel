// What the display did with presented frames, from the drawables' own reports:
// shown or dropped, and the gap between shown frames in display refreshes.
// Synthetic report sequences; the drawable side is covered by
// metal_scene_draw_smoke.

#include "Core/PresentFeedback.hpp"

#include <gtest/gtest.h>

using namespace wallpaper;

namespace
{

constexpr double kRefresh120 = 1.0 / 120.0;

class PresentFeedbackTest : public ::testing::Test {
protected:
    void SetUp() override { RendererCounters::SetEnabled(true); }
    void TearDown() override { RendererCounters::SetEnabled(false); }

    uint64_t Gaps() const {
        return counters.Get(OWE_RC_PRESENT_GAPS_1_VSYNC) + counters.Get(OWE_RC_PRESENT_GAPS_2_VSYNC) +
               counters.Get(OWE_RC_PRESENT_GAPS_3PLUS_VSYNC);
    }

    RendererCounters counters;
    PresentFeedback  feedback;
};

} // namespace

TEST_F(PresentFeedbackTest, GapsAreRoundedToWholeRefreshes)
{
    using Gap = PresentFeedback::Gap;
    EXPECT_EQ(PresentFeedback::Classify(kRefresh120, kRefresh120), Gap::OneRefresh);
    // A variable-rate panel can show a frame a little early or late.
    EXPECT_EQ(PresentFeedback::Classify(0.6 * kRefresh120, kRefresh120), Gap::OneRefresh);
    EXPECT_EQ(PresentFeedback::Classify(1.49 * kRefresh120, kRefresh120), Gap::OneRefresh);
    EXPECT_EQ(PresentFeedback::Classify(1.5 * kRefresh120, kRefresh120), Gap::TwoRefreshes);
    EXPECT_EQ(PresentFeedback::Classify(1.0 / 60.0, kRefresh120), Gap::TwoRefreshes);
    EXPECT_EQ(PresentFeedback::Classify(2.49 * kRefresh120, kRefresh120), Gap::TwoRefreshes);
    EXPECT_EQ(PresentFeedback::Classify(2.5 * kRefresh120, kRefresh120), Gap::Longer);
    EXPECT_EQ(PresentFeedback::Classify(1.0, kRefresh120), Gap::Longer);
}

TEST_F(PresentFeedbackTest, A60FpsSceneOnA120HzPanelShowsEveryOtherRefresh)
{
    feedback.Restart(&counters, kRefresh120);
    EXPECT_EQ(counters.Get(OWE_RC_VSYNC_PERIOD_MICROS), 8333u);

    double time = 1000.0;
    for (int frame = 0; frame < 60; ++frame) {
        feedback.Record(time);
        time += 2 * kRefresh120;
    }
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTED_FRAMES), 60u);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTS_DROPPED), 0u);
    // The first shown frame has nothing before it to measure from.
    EXPECT_EQ(counters.Get(OWE_RC_PRESENT_GAPS_2_VSYNC), 59u);
    EXPECT_EQ(Gaps(), 59u);
}

TEST_F(PresentFeedbackTest, DroppedFramesAndUnevenGapsAreCountedApart)
{
    feedback.Restart(&counters, kRefresh120);
    const double start = 50.0;
    feedback.Record(start);
    feedback.Record(start + kRefresh120);       // one refresh
    feedback.Record(0.0);                       // replaced before any refresh showed it
    feedback.Record(start + 3 * kRefresh120);   // two refreshes: the drop left a hole
    feedback.Record(0.0);
    feedback.Record(start + 7 * kRefresh120);   // four refreshes
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTED_FRAMES), 4u);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTS_DROPPED), 2u);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENT_GAPS_1_VSYNC), 1u);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENT_GAPS_2_VSYNC), 1u);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENT_GAPS_3PLUS_VSYNC), 1u);
}

TEST_F(PresentFeedbackTest, AReportOutOfOrderHasNoGapAndDoesNotMoveTheClockBack)
{
    feedback.Restart(&counters, kRefresh120);
    feedback.Record(10.0);
    feedback.Record(10.0 + 2 * kRefresh120);
    feedback.Record(10.0 + kRefresh120);  // late report of an earlier frame
    feedback.Record(10.0 + 3 * kRefresh120);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTED_FRAMES), 4u);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENT_GAPS_2_VSYNC), 1u);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENT_GAPS_1_VSYNC), 1u)
        << "the last frame is one refresh after the newest shown, not two after a late one";
    EXPECT_EQ(Gaps(), 2u);
}

TEST_F(PresentFeedbackTest, ARestartNeverMeasuresAGapAcrossTimeNothingWasCounted)
{
    feedback.Restart(&counters, kRefresh120);
    feedback.Record(5.0);
    feedback.Restart(&counters, kRefresh120);
    feedback.Record(5.0 + kRefresh120);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTED_FRAMES), 2u);
    EXPECT_EQ(Gaps(), 0u);
}

TEST_F(PresentFeedbackTest, AnUnknownRefreshCountsShownFramesButGuessesNoGap)
{
    feedback.Restart(&counters, 0.0);
    feedback.Record(1.0);
    feedback.Record(1.0 + kRefresh120);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTED_FRAMES), 2u);
    EXPECT_EQ(counters.Get(OWE_RC_VSYNC_PERIOD_MICROS), 0u);
    EXPECT_EQ(Gaps(), 0u);
}

TEST_F(PresentFeedbackTest, NothingIsCountedBeforeARestartOrAfterADetach)
{
    feedback.Record(1.0);
    feedback.Record(0.0);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTED_FRAMES) + counters.Get(OWE_RC_PRESENTS_DROPPED), 0u);

    feedback.Restart(&counters, kRefresh120);
    feedback.Record(2.0);
    feedback.Detach();
    // Reports of frames presented before the counters went away still arrive.
    feedback.Record(2.0 + kRefresh120);
    feedback.Record(0.0);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTED_FRAMES), 1u);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTS_DROPPED), 0u);
    EXPECT_EQ(Gaps(), 0u);
}

TEST_F(PresentFeedbackTest, CountingOffRecordsNothing)
{
    feedback.Restart(&counters, kRefresh120);
    RendererCounters::SetEnabled(false);
    feedback.Record(3.0);
    feedback.Record(3.0 + kRefresh120);
    feedback.Record(0.0);
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTED_FRAMES) + counters.Get(OWE_RC_PRESENTS_DROPPED) + Gaps(), 0u);
}

TEST_F(PresentFeedbackTest, AReportFromAnEarlierSequenceCountsNowhere)
{
    const uint64_t first = feedback.Restart(&counters, kRefresh120);
    feedback.Record(1000.0, first);
    RendererCounters next;
    feedback.Detach();
    const uint64_t second = feedback.Restart(&next, kRefresh120);
    EXPECT_NE(second, first);
    // A drawable presented before the counters changed reports late.
    feedback.Record(1000.0 + 2 * kRefresh120, first);
    EXPECT_EQ(next.Get(OWE_RC_PRESENTED_FRAMES), 0u);
    feedback.Record(1001.0, second);
    feedback.Record(1001.0 + 2 * kRefresh120, second);
    EXPECT_EQ(next.Get(OWE_RC_PRESENTED_FRAMES), 2u);
    EXPECT_EQ(next.Get(OWE_RC_PRESENT_GAPS_2_VSYNC), 1u) << "the late report must not open a gap";
    EXPECT_EQ(counters.Get(OWE_RC_PRESENTED_FRAMES), 1u);
}
