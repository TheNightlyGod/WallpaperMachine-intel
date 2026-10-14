// Counter-examples for the always-on surface health reading.
//
// The failure this guards against is silent: a surface whose draw failed stops
// rendering and, with renderer counting off, looks exactly like a paused one.
// The opposite mistake is as harmful for whoever acts on the reading: a still
// scene that is healthy but presents nothing must not look stalled. Time is
// passed in, so none of this depends on a clock or a GPU.

#include "Core/SurfaceHealth.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <limits>

namespace wallpaper
{
namespace
{

constexpr std::uint64_t kMs = 1'000'000;

TEST(SurfaceHealth, ANewSurfaceReportsNothingDrawnAndNothingStopped) {
    SurfaceHealth health;

    const auto snapshot = health.Snapshot(5000 * kMs);

    EXPECT_EQ(snapshot.frames_completed, 0u);
    EXPECT_EQ(snapshot.frames_presented, 0u);
    EXPECT_EQ(snapshot.failed_frames, 0u);
    EXPECT_EQ(snapshot.stop_reason, SurfaceStopReason::Running);
}

TEST(SurfaceHealth, CompletedAndPresentedFramesAdvanceIndependently) {
    // A frame that repeats the picture completes without presenting. The count
    // that proves a clock is alive must therefore keep moving while the
    // presented count stays flat.
    SurfaceHealth health;

    health.NoteFrameCompleted();
    health.NoteFrameCompleted();
    health.NotePresented(100 * kMs);
    health.NoteFrameCompleted();
    health.NoteFrameCompleted();

    auto snapshot = health.Snapshot(100 * kMs);
    EXPECT_EQ(snapshot.frames_completed, 4u);
    EXPECT_EQ(snapshot.frames_presented, 1u);

    health.NoteFrameCompleted();
    health.NoteFrameCompleted();
    health.NoteFrameCompleted();

    snapshot = health.Snapshot(900 * kMs);
    EXPECT_EQ(snapshot.frames_completed, 7u);
    EXPECT_EQ(snapshot.frames_presented, 1u)
        << "frames that were completed but not presented must not count as presents";
    EXPECT_EQ(snapshot.stop_reason, SurfaceStopReason::Running)
        << "a still scene that stopped presenting is healthy";
}

TEST(SurfaceHealth, TheLastPresentAgeIsUnknownUntilSomethingIsPresented) {
    SurfaceHealth health;
    health.NoteFrameCompleted();

    EXPECT_EQ(health.Snapshot(10'000 * kMs).last_present_age_ms,
              SurfaceHealthSnapshot::kNeverPresented)
        << "a completed frame is not a present, so there is no age to report";

    health.NotePresented(2'000 * kMs);

    EXPECT_EQ(health.Snapshot(2'000 * kMs).last_present_age_ms, 0u);
    EXPECT_EQ(health.Snapshot(2'750 * kMs).last_present_age_ms, 750u);
}

TEST(SurfaceHealth, ThePresentAgeNeverGoesNegativeWhenTheClockReadsEarlier) {
    SurfaceHealth health;
    health.NotePresented(5'000 * kMs);

    EXPECT_EQ(health.Snapshot(4'000 * kMs).last_present_age_ms, 0u);
}

TEST(SurfaceHealth, ThePresentTimeStaysDistinctFromNeverEvenWhenTheClockReadsZero) {
    SurfaceHealth health;
    health.NotePresented(0);

    EXPECT_NE(health.Snapshot(3 * kMs).last_present_age_ms,
              SurfaceHealthSnapshot::kNeverPresented);
}

TEST(SurfaceHealth, AFrameFailureAndAGraphFailureLatchDifferentReasons) {
    SurfaceHealth frame;
    frame.NoteFrameFailed();
    EXPECT_EQ(frame.Snapshot().stop_reason, SurfaceStopReason::FrameFailed);

    SurfaceHealth graph;
    graph.NoteGraphFailed();
    EXPECT_EQ(graph.Snapshot().stop_reason, SurfaceStopReason::GraphFailed);

    EXPECT_EQ(frame.Snapshot().failed_frames, 1u);
    EXPECT_EQ(graph.Snapshot().failed_frames, 0u)
        << "a graph that could not be built is not a frame that failed to draw";
}

TEST(SurfaceHealth, AFrameFailureDoesNotHideAGraphFailureNotedBeforeIt) {
    // A native fallback rebuilds the graph and draws again inside one frame. If
    // the rebuild failed, the draw's own failure is a consequence and must not
    // turn "the graph is gone" into "retry the frame".
    SurfaceHealth health;

    health.NoteGraphFailed();
    health.NoteFrameFailed();

    EXPECT_EQ(health.Snapshot().stop_reason, SurfaceStopReason::GraphFailed);
    EXPECT_EQ(health.Snapshot().failed_frames, 1u)
        << "the frame still failed; only the reason keeps its more fundamental value";
}

TEST(SurfaceHealth, AGraphFailureReplacesAFrameFailure) {
    SurfaceHealth health;

    health.NoteFrameFailed();
    health.NoteGraphFailed();

    EXPECT_EQ(health.Snapshot().stop_reason, SurfaceStopReason::GraphFailed);
}

TEST(SurfaceHealth, ClearingTheStopKeepsTheFailureAndFrameCounts) {
    SurfaceHealth health;
    health.NoteFrameCompleted();
    health.NotePresented(10 * kMs);
    health.NoteFrameFailed();
    health.NoteFrameFailed();

    health.ClearStop();

    const auto snapshot = health.Snapshot(20 * kMs);
    EXPECT_EQ(snapshot.stop_reason, SurfaceStopReason::Running);
    EXPECT_EQ(snapshot.failed_frames, 2u)
        << "a surface that failed once must stay distinguishable from one that never did";
    EXPECT_EQ(snapshot.frames_completed, 1u);
    EXPECT_EQ(snapshot.frames_presented, 1u);
}

TEST(SurfaceHealth, AFailureAfterARecoveryLatchesAgain) {
    SurfaceHealth health;
    health.NoteFrameFailed();
    health.ClearStop();

    health.NoteFrameFailed();

    EXPECT_EQ(health.Snapshot().stop_reason, SurfaceStopReason::FrameFailed);
    EXPECT_EQ(health.Snapshot().failed_frames, 2u);
}

TEST(SurfaceHealth, TheDefaultClockIsMonotonicAndAgesAFreshPresentAsRecent) {
    SurfaceHealth health;

    health.NotePresented();

    // Seconds, not milliseconds, of slack: this only proves the default clock
    // is the same one on both sides, not how fast the host is.
    EXPECT_LT(health.Snapshot().last_present_age_ms, 5'000u);
}

} // namespace
} // namespace wallpaper
