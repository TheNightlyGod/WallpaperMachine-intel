// How long a present holds the frame on screen so a ceiling below the display's rate reaches it
// an even number of refreshes apart. The hold's arithmetic, the frame clock that publishes it,
// and a model of a display that honours it (`presentDrawable:afterMinimumDuration:` shows the
// frame at the first refresh at least the hold after the previous frame was shown). The model
// is not the display: a layer no window owns is never shown, so the headless Metal test
// (`MetalSceneDraw.APresentHoldsTheFrameOnlyWhilePacing`) checks only what the present asks for.

#include "Core/PresentFeedback.hpp"
#include "Timer/FrameTimer.hpp"
#include "Timer/PresentPacing.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <vector>

using namespace wallpaper;
using namespace std::chrono_literals;
using std::chrono::nanoseconds;

namespace
{

/// `DisplayRefreshPeriod` of a mode reporting `hertz`: rounded up to the nanosecond.
nanoseconds RefreshOf(double hertz) { return nanoseconds(static_cast<int64_t>(std::ceil(1e9 / hertz))); }

/// The frame clock's ceiling period for `fps` on a display refreshing every `refresh`.
nanoseconds CeilingOf(unsigned fps, nanoseconds refresh) {
    const auto period = nanoseconds((1'000'000'000 + fps - 1) / fps);
    return std::max(period, refresh);
}

} // namespace

// 60 fps on 120 Hz: two refreshes less a quarter, which ends between the first refresh after
// the shown frame and the second, so the frame shows at the second.
TEST(PresentPacingTest, TheHoldEndsAQuarterRefreshBeforeTheRefreshTheCadenceAimsAt) {
    const auto refresh = RefreshOf(120.0);
    const auto hold    = PresentHoldFor(CeilingOf(60, refresh), refresh);
    EXPECT_EQ(hold, 2 * refresh - refresh / 4);
    EXPECT_GT(hold, refresh + refresh / 2) << "a ProMotion half-step after one refresh would come first";
    EXPECT_LT(hold, 2 * refresh);

    // Four refreshes at 30 on 120, two at 30 on 60, and the whole refreshes a period that is not
    // a multiple covers: 24 on 60 is two and a half, shown two or three apart, never fewer.
    EXPECT_EQ(PresentHoldFor(CeilingOf(30, refresh), refresh), 4 * refresh - refresh / 4);
    const auto sixty = RefreshOf(60.0);
    EXPECT_EQ(PresentHoldFor(CeilingOf(30, sixty), sixty), 2 * sixty - sixty / 4);
    EXPECT_EQ(PresentHoldFor(CeilingOf(24, sixty), sixty), 2 * sixty - sixty / 4);
    EXPECT_EQ(PresentHoldFor(CeilingOf(50, refresh), refresh), 2 * refresh - refresh / 4);
}

// A ceiling at or above the display's rate is a plain present: one refresh is the least any
// frame waits, so a hold could only ever halve the rate.
TEST(PresentPacingTest, ACeilingAtTheDisplaysRateIsPresentedAtTheNextRefresh) {
    for (const double hertz : { 60.0, 120.0, 59.94, 144.0 }) {
        const auto refresh = RefreshOf(hertz);
        for (const unsigned fps : { 60u, 90u, 120u, 144u, 240u }) {
            if (fps < hertz * 0.99) continue;
            EXPECT_EQ(PresentHoldFor(CeilingOf(fps, refresh), refresh), 0ns) << fps << " fps on " << hertz << " Hz";
        }
    }
    // 90 on 120 spans one and a third refreshes: still a plain present.
    EXPECT_EQ(PresentHoldFor(CeilingOf(90, RefreshOf(120.0)), RefreshOf(120.0)), 0ns);
    // No display, or one that reports no fixed rate.
    EXPECT_EQ(PresentHoldFor(16'666'667ns, 0ns), 0ns);
    EXPECT_EQ(PresentHoldFor(16'666'667ns, -1ns), 0ns);
    EXPECT_EQ(PresentHoldFor(0ns, RefreshOf(120.0)), 0ns);
}

// For every ceiling on every common rate the hold asks for no more refreshes than the period
// covers, so frames shown this way keep up with the clock and never queue up behind the display.
TEST(PresentPacingTest, TheHoldNeverAsksForMoreRefreshesThanTheFramePeriodCovers) {
    for (const double hertz : { 24.0, 48.0, 50.0, 59.94, 60.0, 75.0, 90.0, 100.0, 119.88, 120.0, 144.0, 165.0, 240.0 }) {
        const auto refresh = RefreshOf(hertz);
        for (unsigned fps = 1; fps <= 240; ++fps) {
            const auto period = CeilingOf(fps, refresh);
            const auto hold   = PresentHoldFor(period, refresh);
            if (hold == 0ns) {
                EXPECT_LT(period, 2 * refresh + 1us) << fps << " fps on " << hertz << " Hz";
                continue;
            }
            const auto refreshes = (hold + refresh - 1ns) / refresh; // the refresh the hold ends in
            EXPECT_LE(refreshes * refresh, period + 1us) << fps << " fps on " << hertz << " Hz";
            EXPECT_GE(refreshes, 2) << fps << " fps on " << hertz << " Hz";
            EXPECT_EQ(hold, refreshes * refresh - refresh / 4) << fps << " fps on " << hertz << " Hz";
        }
    }
}

// The frame clock publishes the hold of its ceiling on its display, and follows both.
TEST(PresentPacingTest, TheFrameClockHoldsForItsCeilingOnItsDisplay) {
    FrameTimer timer;
    timer.SetRequiredFps(60);
    EXPECT_EQ(timer.PresentHold(), 0ns) << "no display is known yet";
    timer.SetDisplayRefreshPeriod(RefreshOf(120.0));
    EXPECT_EQ(timer.PresentHold(), PresentHoldFor(16'666'667ns, RefreshOf(120.0)));
    timer.SetRequiredFps(120);
    EXPECT_EQ(timer.PresentHold(), 0ns);
    timer.SetRequiredFps(30);
    EXPECT_EQ(timer.PresentHold(), PresentHoldFor(33'333'334ns, RefreshOf(120.0)));
    timer.SetDisplayRefreshPeriod(RefreshOf(60.0));
    EXPECT_EQ(timer.PresentHold(), PresentHoldFor(33'333'334ns, RefreshOf(60.0)));
    EXPECT_GT(timer.PresentHold(), 0ns);
    // Two refreshes of 59.94 Hz are longer than a 30 fps frame: holding for them would show
    // frames more slowly than the clock makes them, so the present is plain.
    timer.SetDisplayRefreshPeriod(RefreshOf(59.94));
    EXPECT_EQ(timer.PresentHold(), 0ns);
    timer.SetRequiredFps(60);
    EXPECT_EQ(timer.PresentHold(), 0ns) << "60 fps on 59.94 Hz runs at the display's own rate";

    // Content pacing lengthens the cadence, not the hold: a frame an event asks for may come
    // one ceiling period after the last.
    timer.SetDisplayRefreshPeriod(RefreshOf(120.0));
    timer.SetFrameDemand({ .content_period = 50ms });
    EXPECT_EQ(timer.TickInterval(), 50ms);
    EXPECT_EQ(timer.PresentHold(), PresentHoldFor(16'666'667ns, RefreshOf(120.0)));
}

namespace
{

/// When a display shows frames that are ready at `ready`: at the first moment on its grid
/// (`step` apart) at least `min_gap` after the previous frame was shown and at or after the
/// frame is ready, and, with a hold, at least `hold` after the previous one. A fixed-rate panel
/// has `step == min_gap == refresh`; a ProMotion panel refreshes no sooner than one refresh
/// after the last but on a grid of half refreshes.
std::vector<int64_t> ShownGaps(const std::vector<int64_t>& ready, int64_t step, int64_t min_gap, int64_t hold) {
    std::vector<int64_t> gaps;
    int64_t              previous = -1;
    for (const int64_t at : ready) {
        int64_t earliest = at;
        if (previous >= 0) earliest = std::max({ earliest, previous + min_gap, previous + hold });
        const int64_t shown = (earliest + step - 1) / step * step;
        if (previous >= 0) gaps.push_back(shown - previous);
        previous = shown;
    }
    return gaps;
}

/// A 60 fps cadence whose frames are ready close to a refresh boundary: each lands 0 to 2 ms
/// after the cadence tick (the encode and GPU time's jitter), and the tick sits 1 ms before
/// a refresh of a 120 Hz grid. A deterministic sequence, so the test cannot flake.
std::vector<int64_t> ReadyNearARefreshBoundary(int64_t refresh, int frames) {
    std::vector<int64_t> ready;
    uint32_t             state = 12345;
    for (int frame = 0; frame < frames; ++frame) {
        state                = state * 1664525u + 1013904223u;
        const int64_t jitter = static_cast<int64_t>(state >> 8) % 2'000'000;
        ready.push_back(10 * refresh - 1'000'000 + frame * 2 * refresh + jitter);
    }
    return ready;
}

} // namespace

// The judder the hold removes, in the present feedback's own buckets: without it the frames
// of a 60 fps cadence near a refresh boundary reach a 120 Hz panel one and three refreshes
// apart; with it every gap after the first late frame is two.
TEST(PresentPacingTest, HeldFramesReachAFixedRatePanelTwoRefreshesApart) {
    const int64_t refresh = RefreshOf(120.0).count();
    const int64_t hold    = PresentHoldFor(CeilingOf(60, RefreshOf(120.0)), RefreshOf(120.0)).count();
    const auto    ready   = ReadyNearARefreshBoundary(refresh, 600);

    const auto count = [&](const std::vector<int64_t>& gaps, PresentFeedback::Gap kind) {
        return std::count_if(gaps.begin(), gaps.end(), [&](int64_t gap) {
            return PresentFeedback::Classify(gap * 1e-9, refresh * 1e-9) == kind;
        });
    };
    const auto plain = ShownGaps(ready, refresh, refresh, 0);
    EXPECT_GT(count(plain, PresentFeedback::Gap::OneRefresh), 50);
    EXPECT_GT(count(plain, PresentFeedback::Gap::Longer), 50);

    const auto held = ShownGaps(ready, refresh, refresh, hold);
    EXPECT_EQ(count(held, PresentFeedback::Gap::OneRefresh), 0);
    EXPECT_LE(count(held, PresentFeedback::Gap::Longer), 1) << "only the first late frame moves the phase";
    EXPECT_GE(count(held, PresentFeedback::Gap::TwoRefreshes), 598);
}

// A ProMotion panel can refresh every half refresh once a whole one has passed, so a plain
// present lands 12.5, 16.7 or 20.8 ms after the last; the quarter-refresh margin of the hold
// still ends after the 12.5 ms step, and every held gap is 16.7 ms.
TEST(PresentPacingTest, HeldFramesReachAProMotionPanelAtTheFramePeriod) {
    const int64_t refresh = RefreshOf(120.0).count();
    const int64_t step    = refresh / 2;
    const int64_t hold    = PresentHoldFor(CeilingOf(60, RefreshOf(120.0)), RefreshOf(120.0)).count();
    const auto    ready   = ReadyNearARefreshBoundary(refresh, 600);

    const auto uneven = [&](const std::vector<int64_t>& gaps) {
        return std::count_if(gaps.begin(), gaps.end(), [&](int64_t gap) { return std::llabs(gap - 2 * refresh) > 2; });
    };
    EXPECT_GT(uneven(ShownGaps(ready, step, refresh, 0)), 50);
    EXPECT_LE(uneven(ShownGaps(ready, step, refresh, hold)), 1);
    // Half a refresh of margin (1/fps - 0.5/refresh, 12.5 ms) paces a fixed-rate panel but
    // still lets a ProMotion one show an early frame at the 12.5 ms step.
    EXPECT_GT(uneven(ShownGaps(ready, step, refresh, 2 * refresh - refresh / 2)), 50);
    EXPECT_LE(uneven(ShownGaps(ready, refresh, refresh, 2 * refresh - refresh / 2)), 1);
}
