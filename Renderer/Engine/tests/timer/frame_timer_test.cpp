#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <memory>
#include <vector>

#define private public
#include "Timer/FrameTimer.hpp"
#include "Timer/ThreadTimer.hpp"
#undef private

#include <gtest/gtest.h>

namespace wallpaper
{
namespace
{

using namespace std::chrono_literals;


TEST(FrameTimerTest, DeliveredFramesIncludeDroppedTickIntervals) {
    int draws = 0;
    FrameTimer timer([&]() { ++draws; });
    timer.SetRequiredFps(30);
    const auto start = std::chrono::steady_clock::time_point(1s);

    // A 40 ms draw misses every other tick of a 33.333 ms scheduler.
    // Drive those ticks and delivered-frame timestamps without wall-clock sleeps.
    for (int frame = 0; frame < 6; ++frame) {
        const auto begin = start + frame * 66666us;
        timer.m_timer.m_callback();
        ASSERT_EQ(draws, frame + 1);
        timer.FrameBegin(begin);
        EXPECT_DOUBLE_EQ(timer.IdeaTime(), frame == 0 ? 0.033333 : 0.066666);

        timer.m_timer.m_callback();
        EXPECT_EQ(draws, frame + 1);
        timer.FrameEnd(begin + 40ms);
    }

    // Rendering cost remains distinct from animation time.
    EXPECT_DOUBLE_EQ(timer.FrameTime(), 0.04);
}

TEST(FrameTimerTest, RestartExcludesPausedTimeButRunningAgainPreservesElapsedTime) {
    FrameTimer timer;
    timer.SetRequiredFps(20);
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.Run();
    timer.FrameBegin(start);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.05);
    timer.FrameEnd(start + 10ms);

    timer.Run();
    timer.FrameBegin(start + 100ms);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.1);
    timer.FrameEnd(start + 110ms);
    timer.Stop();

    // Use a pause shorter than the long-frame cutoff so only Run's reset can
    // exclude it. The following frame must use elapsed time normally again.
    timer.Run();
    timer.FrameBegin(start + 2s);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.05);
    timer.FrameEnd(start + 2010ms);
    timer.FrameBegin(start + 2100ms);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.1);
    timer.FrameEnd(start + 2110ms);
    timer.Stop();
}

TEST(FrameTimerTest, FpsChangePreservesInFlightDrawAndElapsedTime) {
    int draws = 0;
    FrameTimer timer([&]() { ++draws; });
    timer.SetRequiredFps(20);
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.m_timer.m_callback();
    timer.FrameBegin(start);
    timer.SetRequiredFps(40);
    timer.m_timer.m_callback();
    EXPECT_EQ(draws, 1);
    timer.FrameEnd(start + 60ms);

    timer.m_timer.m_callback();
    EXPECT_EQ(draws, 2);
    timer.FrameBegin(start + 75ms);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.075);
    timer.FrameEnd(start + 85ms);
}

TEST(FrameTimerTest, LongDeliveryGapDoesNotCatchUpSuspendedTime) {
    FrameTimer timer;
    timer.SetRequiredFps(20);
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.FrameBegin(start);
    timer.FrameEnd(start + 10ms);
    timer.FrameBegin(start + 8h);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.05);
    timer.FrameEnd(start + 8h + 10ms);
    timer.FrameBegin(start + 8h + 100ms);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.1);
    timer.FrameEnd(start + 8h + 110ms);
}

TEST(FrameTimerTest, ContentThatChangesLessOftenLowersTheTickRate) {
    FrameTimer timer;
    timer.SetRequiredFps(60);
    EXPECT_EQ(timer.TickInterval(), 16666us) << "no demand keeps the configured cadence";

    // A 30 fps video behind a 60 fps ceiling: rendering 60 times a second would
    // present every decoded frame twice.
    timer.SetFrameDemand({ .content_period = 33333us });
    EXPECT_EQ(timer.TickInterval(), 33333us);

    // Raising the ceiling does not raise the content's rate.
    timer.SetRequiredFps(120);
    EXPECT_EQ(timer.TickInterval(), 33333us);
}

TEST(FrameTimerTest, TheConfiguredFpsStaysTheCeiling) {
    FrameTimer timer;
    timer.SetRequiredFps(30);

    // A 60 fps video must not make a 30 fps wallpaper render at 60: the user's
    // and the display's limit wins.
    timer.SetFrameDemand({ .content_period = 16666us });
    EXPECT_EQ(timer.TickInterval(), 33333us);

    // A period equal to the ideal frame time changes nothing either.
    timer.SetFrameDemand({ .content_period = 33333us });
    EXPECT_EQ(timer.TickInterval(), 33333us);
}

TEST(FrameTimerTest, AnUnknownOrAbsurdPeriodCannotStallTheScene) {
    FrameTimer timer;
    timer.SetRequiredFps(30);

    // Zero is how a source says it does not know its own rate.
    timer.SetFrameDemand({ .content_period = 0us });
    EXPECT_EQ(timer.TickInterval(), 33333us);
    timer.SetFrameDemand({ .content_period = -5s });
    EXPECT_EQ(timer.TickInterval(), 33333us) << "a negative period is not a licence to stop";

    // A wildly long period is clamped to the longest gap the frame clock still
    // treats as continuous playback, so the scene keeps a heartbeat.
    timer.SetFrameDemand({ .content_period = 1h });
    EXPECT_EQ(timer.TickInterval(), 5s);
}

TEST(FrameTimerTest, DroppingTheDemandRestoresTheFixedCadence) {
    FrameTimer timer;
    timer.SetRequiredFps(60);
    timer.SetFrameDemand({ .content_period = 500ms });
    EXPECT_EQ(timer.TickInterval(), 500ms);

    // Switching to a scene that cannot prove its rate must go back to ticking
    // at the configured rate rather than inheriting the previous scene's.
    timer.SetFrameDemand({});
    EXPECT_EQ(timer.TickInterval(), 16666us);
}

TEST(FrameTimerTest, ContentPacingKeepsTheSingleDrawInFlightLimit) {
    int  draws { 0 };
    FrameTimer timer([&draws]() {
        draws++;
    });
    timer.SetRequiredFps(60);
    timer.SetFrameDemand({ .content_period = 100ms });
    const auto start = std::chrono::steady_clock::time_point(1s);

    // Pacing changes when a draw is posted, never how many may be outstanding.
    timer.m_timer.m_callback();
    EXPECT_EQ(draws, 1);
    timer.m_timer.m_callback();
    EXPECT_EQ(draws, 1) << "a frame still in flight must not be joined by another";

    timer.FrameBegin(start);
    timer.FrameEnd(start + 10ms);
    timer.m_timer.m_callback();
    EXPECT_EQ(draws, 2);
    EXPECT_EQ(timer.TickInterval(), 100ms);
}

TEST(FrameTimerTest, AContentWaitAtTheClampIsNotMistakenForASuspension) {
    // The regression this pins: the pacing clamp and the suspension cutoff were
    // the same 5 s constant, so a scene paced at the clamp had every ordinary
    // frame boundary read as a resume. Its elapsed time was replaced by one
    // ideal frame, and a video driven by that clock fell further behind on
    // every frame instead of playing at its own rate.
    FrameTimer timer;
    timer.SetRequiredFps(30);
    timer.SetFrameDemand({ .content_period = 5s });
    ASSERT_EQ(timer.TickInterval(), 5s);

    const auto start = std::chrono::steady_clock::time_point(1s);
    timer.FrameBegin(start);
    timer.FrameEnd(start + 10ms);

    // Exactly one interval later, and then one interval plus ordinary
    // scheduling delay later. Both are the content waiting, not a suspension.
    timer.FrameBegin(start + 5s);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 5.0);
    timer.FrameEnd(start + 5s + 10ms);

    timer.FrameBegin(start + 10s + 120ms);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 5.12);
    timer.FrameEnd(start + 10s + 130ms);

    // Several low-frequency updates in a row must keep reporting real time, or
    // the playback clock drifts a little further behind with each one.
    auto moment = start + 10s + 120ms;
    for (int i = 0; i < 4; ++i) {
        moment += 5s + 40ms;
        timer.FrameBegin(moment);
        EXPECT_DOUBLE_EQ(timer.IdeaTime(), 5.04) << "low-frequency update " << i;
        timer.FrameEnd(moment + 10ms);
    }
}

TEST(FrameTimerTest, ARealSuspensionIsStillDetectedAtAPacedInterval) {
    FrameTimer timer;
    timer.SetRequiredFps(30);
    timer.SetFrameDemand({ .content_period = 5s });
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.FrameBegin(start);
    timer.FrameEnd(start + 10ms);

    // Far beyond any plausible content wait at this interval: the scene must
    // not be handed eight hours of simulation to catch up on.
    timer.FrameBegin(start + 8h);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.033333);
}

TEST(FrameTimerTest, TheSuspensionThresholdFollowsTheIntervalAndNeverDropsBelowTheFloor) {
    FrameTimer timer;
    timer.SetRequiredFps(30);
    EXPECT_EQ(timer.SuspensionThreshold(), 5s) << "an unpaced clock keeps the fixed floor";

    timer.SetFrameDemand({ .content_period = 100ms });
    EXPECT_EQ(timer.SuspensionThreshold(), 5s) << "a short period must not shorten the floor";

    timer.SetFrameDemand({ .content_period = 4s });
    EXPECT_EQ(timer.SuspensionThreshold(), 12s);
}

TEST(FrameTimerTest, StoppingWithADrawPendingDoesNotReplayTheStoppedTime) {
    int        draws { 0 };
    FrameTimer timer([&draws]() { draws++; });
    timer.SetRequiredFps(30);
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.Run();
    timer.m_timer.m_callback();
    ASSERT_EQ(draws, 1);
    timer.FrameBegin(start);
    // The draw is still in flight when the clock stops.
    timer.Stop();
    timer.FrameEnd(start + 5ms);

    timer.Run();
    timer.FrameBegin(start + 30s);
    EXPECT_DOUBLE_EQ(timer.IdeaTime(), 0.033333);
    EXPECT_EQ(timer.m_frame_busy_count.load(), 0)
        << "restarting must not inherit a draw that will never complete";
    timer.Stop();
}

TEST(FrameTimerTest, CountersRecordWhatTheProductionSchedulerDid) {
    RendererCounters counters;
    RendererCounters::SetEnabled(true);

    int        draws { 0 };
    FrameTimer timer([&draws]() { draws++; });
    timer.SetCounters(&counters);
    timer.SetRequiredFps(30);
    const auto start = std::chrono::steady_clock::time_point(1s);

    timer.m_timer.m_callback();
    timer.FrameBegin(start);
    // A second tick while the first draw is outstanding: a wakeup happened, no
    // work was requested, and the difference has to be readable.
    timer.m_timer.m_callback();
    timer.FrameEnd(start + 10ms);
    timer.m_timer.m_callback();

    EXPECT_EQ(counters.Get(OWE_RC_TIMER_WAKEUPS), 3u);
    EXPECT_EQ(counters.Get(OWE_RC_DRAW_REQUESTS), 2u);
    EXPECT_EQ(counters.Get(OWE_RC_DRAW_TICKS_SUPPRESSED), 1u);
    EXPECT_EQ(draws, 2);
    EXPECT_EQ(counters.Get(OWE_RC_TICK_INTERVAL_MICROS), 33333u);
    EXPECT_EQ(counters.Get(OWE_RC_CONTENT_PERIOD_MICROS), 0u);

    timer.SetFrameDemand({ .content_period = 100ms });
    EXPECT_EQ(counters.Get(OWE_RC_TICK_INTERVAL_MICROS), 100000u);
    EXPECT_EQ(counters.Get(OWE_RC_CONTENT_PERIOD_MICROS), 100000u);

    RendererCounters::SetEnabled(false);
}

TEST(FrameTimerTest, CountingIsOffUntilItIsTurnedOn) {
    RendererCounters counters;
    ASSERT_FALSE(RendererCounters::Enabled());

    FrameTimer timer([]() {});
    timer.SetCounters(&counters);
    timer.SetRequiredFps(30);
    timer.m_timer.m_callback();

    EXPECT_EQ(counters.Get(OWE_RC_TIMER_WAKEUPS), 0u);
    EXPECT_EQ(counters.Get(OWE_RC_DRAW_REQUESTS), 0u);
}

TEST(FrameTimerTest, ContentPacingChangesHowOftenTheRealSchedulerPostsDraws) {
    // Not the arithmetic: the running thread timer, at the interval the
    // production clock resolved, delivering to the production callback.
    RendererCounters::SetEnabled(true);

    const auto run_for = [](std::chrono::microseconds period) {
        RendererCounters counters;
        std::atomic<int> draws { 0 };
        FrameTimer       timer([&draws]() { draws.fetch_add(1); });
        timer.SetCounters(&counters);
        timer.SetRequiredFps(240);
        if (period > 0us) timer.SetFrameDemand({ .content_period = period });
        timer.Run();
        // The callback only posts work; completing the frame is the owner's
        // job, so the busy flag is cleared the way the render thread does it.
        const auto deadline = std::chrono::steady_clock::now() + 300ms;
        while (std::chrono::steady_clock::now() < deadline) {
            timer.FrameBegin();
            timer.FrameEnd();
            std::this_thread::sleep_for(1ms);
        }
        timer.Stop();
        return counters.Get(OWE_RC_DRAW_REQUESTS);
    };

    const auto unpaced = run_for(0us);
    const auto paced   = run_for(50ms);

    EXPECT_GT(unpaced, paced * 2)
        << "a 50 ms content period must post far fewer draws than a 240 fps ceiling";
    EXPECT_GT(paced, 0u) << "pacing must not stop the scene";

    RendererCounters::SetEnabled(false);
}

/// Waits until `predicate` holds or the budget runs out, and reports how long
/// that took. No busy spin: the callback signals.
template<typename Predicate>
std::chrono::milliseconds WaitFor(std::mutex&              mutex,
                                  std::condition_variable& condition,
                                  Predicate                predicate,
                                  std::chrono::milliseconds budget) {
    const auto start = std::chrono::steady_clock::now();
    std::unique_lock<std::mutex> lock(mutex);
    condition.wait_for(lock, budget, predicate);
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start);
}

TEST(FrameTimerTest, AShortenedIntervalDoesNotSleepOutTheOldOne) {
    // The scheduling half of the pacing promise. A clock paced to slow content
    // is inside a long wait; something then asks it to run faster — a content
    // rate that turned out to be tighter, or the user raising the target FPS.
    // If that wait cannot be cut short, every frame the content produced during
    // it is superseded before it is ever displayed.
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };
    FrameTimer timer([&]() {
        std::lock_guard<std::mutex> guard(mutex);
        ++draws;
        condition.notify_all();
    });
    timer.SetRequiredFps(60);
    timer.SetFrameDemand({ .content_period = 2s });
    timer.Run();
    // Let the timer thread get into the two-second wait.
    std::this_thread::sleep_for(60ms);
    ASSERT_EQ(draws, 0);

    timer.SetFrameDemand({ .content_period = 20ms });
    const auto waited = WaitFor(
        mutex, condition, [&]() { return draws > 0; }, 600ms);
    timer.Stop();

    EXPECT_GT(draws, 0) << "the shortened interval never took effect";
    EXPECT_LT(waited.count(), 400)
        << "a tighter content rate must not wait out the previous period";
}

TEST(FrameTimerTest, RaisingTheTargetFpsInterruptsAPacedWait) {
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };
    FrameTimer timer([&]() {
        std::lock_guard<std::mutex> guard(mutex);
        ++draws;
        condition.notify_all();
    });
    timer.SetRequiredFps(1);
    timer.SetFrameDemand({ .content_period = 2s });
    timer.Run();
    std::this_thread::sleep_for(60ms);
    ASSERT_EQ(draws, 0);

    // The user's own setting must not be held hostage by the content's period.
    timer.SetRequiredFps(60);
    timer.SetFrameDemand({});
    const auto waited = WaitFor(
        mutex, condition, [&]() { return draws > 0; }, 600ms);
    timer.Stop();

    EXPECT_GT(draws, 0);
    EXPECT_LT(waited.count(), 400);
}

/// A running clock must not be driven past its configured rate by frame
/// requests.
///
/// This is the default path: on-demand updating is off, and the FPS ceiling is
/// then the only thing bounding how often a scene draws. A pointer-reactive
/// wallpaper calls `RequestFrame` once per pointer sample, so a request that
/// jumped the interval would make the mouse set the frame rate.
TEST(FrameTimerTest, FrameRequestsDoNotPushARunningClockPastItsInterval)
{
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };

    FrameTimer timer([&]() {
        {
            std::scoped_lock lock(mutex);
            ++draws;
        }
        condition.notify_all();
        timer.FrameEnd();
    });
    timer.SetRequiredFps(10); // 100 ms between ticks.
    timer.Run();

    // Far more requests than the interval could ever honour.
    const auto started = std::chrono::steady_clock::now();
    while (std::chrono::steady_clock::now() - started < 200ms) {
        timer.RequestFrame();
        std::this_thread::sleep_for(1ms);
    }
    timer.Stop();

    int observed = 0;
    {
        std::scoped_lock lock(mutex);
        observed = draws;
    }
    // 200 ms at 10 FPS is two ticks, plus one for the immediate first tick and
    // one for scheduling slack. Anything near the ~200 requests made would mean
    // the ceiling was bypassed.
    EXPECT_LE(observed, 4) << "requests drove " << observed
                           << " frames in 200ms at a 10 FPS ceiling";
}

/// A request made while the clock is running is not thrown away: it survives
/// into idle and produces exactly one frame there, at the ceiling rather than
/// at the cadence.
///
/// Without this, closing the rate hole above would reopen the lost-event race
/// the latch exists to prevent. The cadence here is long because the *content*
/// is slow, not because the user asked for a low frame rate — the two are
/// separate numbers, and only the second may delay an event.
TEST(FrameTimerTest, AFrameRequestMadeWhileRunningSurvivesIntoIdle)
{
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };

    FrameTimer timer([&]() {
        {
            std::scoped_lock lock(mutex);
            ++draws;
        }
        condition.notify_all();
        timer.FrameEnd();
    });
    timer.SetRequiredFps(60); // ~17 ms ceiling.
    timer.Run();

    // Let the first tick land, then pace the clock to content that changes
    // once every five seconds. The test never waits for that cadence.
    WaitFor(
        mutex, condition, [&]() { return draws > 0; }, 500ms);
    timer.SetFrameDemand({ .content_period = 5s });
    std::this_thread::sleep_for(50ms);

    int before = 0;
    {
        std::scoped_lock lock(mutex);
        before = draws;
    }

    timer.RequestFrame();
    timer.SetFrameDemand({ .kind = FrameTimer::FrameDemand::Kind::Idle });

    const auto waited = WaitFor(
        mutex, condition, [&]() { return draws > before; }, 500ms);
    timer.Stop();

    int after = 0;
    {
        std::scoped_lock lock(mutex);
        after = draws;
    }
    EXPECT_GT(after, before) << "a request made before idling was lost";
    EXPECT_LT(waited.count(), 400) << "the request waited for a cadence that was stopped";
}

/// Idle means no ticks at all, not a long interval.
///
/// This is the whole point of on-demand updating, and it is the one property
/// that distinguishes it from simply lowering the frame rate. A "very long
/// interval" implementation would pass every other test in this file and still
/// wake the machine forever.
TEST(FrameTimerTest, AnIdleClockProducesNoTicksUntilOneIsRequested)
{
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };

    FrameTimer timer([&]() {
        {
            std::scoped_lock lock(mutex);
            ++draws;
        }
        condition.notify_all();
        timer.FrameEnd();
    });
    timer.SetRequiredFps(60); // ~17 ms; 300 ms of cadence would be ~18 ticks.
    timer.Run();
    WaitFor(
        mutex, condition, [&]() { return draws > 0; }, 500ms);

    timer.SetFrameDemand({ .kind = FrameTimer::FrameDemand::Kind::Idle });
    // Let any tick already in flight land before the count is latched.
    std::this_thread::sleep_for(50ms);
    int quiescent = 0;
    {
        std::scoped_lock lock(mutex);
        quiescent = draws;
    }

    std::this_thread::sleep_for(300ms);
    {
        std::scoped_lock lock(mutex);
        EXPECT_EQ(draws, quiescent)
            << "an idle clock ticked " << (draws - quiescent) << " times in 300ms at 60 FPS";
    }

    // Still responsive: one request produces exactly one frame.
    timer.RequestFrame();
    const auto waited = WaitFor(
        mutex, condition, [&]() { return draws > quiescent; }, 500ms);
    EXPECT_LT(waited.count(), 400) << "an idle clock did not answer a frame request";

    std::this_thread::sleep_for(200ms);
    timer.Stop();
    {
        std::scoped_lock lock(mutex);
        EXPECT_EQ(draws, quiescent + 1)
            << "one request produced " << (draws - quiescent) << " frames";
    }
}

/// A deadline that has already passed is a frame the scene is owed, and it has
/// to arrive at the frame ceiling rather than after a full content cadence.
///
/// "Owed" is not "unbounded": an appointment that keeps being re-armed in the
/// past must not be able to tick faster than the user's FPS, which is why this
/// separates the two numbers instead of lowering the FPS to make the cadence
/// long.
TEST(FrameTimerTest, ADeadlineAlreadyPastIsTakenAtTheCeilingNotTheCadence)
{
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };

    FrameTimer timer([&]() {
        {
            std::scoped_lock lock(mutex);
            ++draws;
        }
        condition.notify_all();
        timer.FrameEnd();
    });
    timer.SetRequiredFps(60); // ~17 ms ceiling, far shorter than the bound below.
    timer.Run();
    WaitFor(
        mutex, condition, [&]() { return draws > 0; }, 2s);
    timer.SetFrameDemand({ .content_period = 5s });
    std::this_thread::sleep_for(50ms);

    int before = 0;
    {
        std::scoped_lock lock(mutex);
        before = draws;
    }

    timer.SetFrameDemand({
        .kind     = FrameTimer::FrameDemand::Kind::Timed,
        .deadline = std::chrono::steady_clock::now() - 1s,
    });
    const auto waited = WaitFor(
        mutex, condition, [&]() { return draws > before; }, 900ms);
    timer.Stop();

    EXPECT_GT(draws, before) << "an owed frame never arrived";
    EXPECT_LT(waited.count(), 500)
        << "an owed frame waited " << waited.count() << "ms, i.e. for the cadence";
}

/// Idling must not be the hole that events set the frame rate through.
///
/// A running clock already refuses to be pushed past its interval. An idle
/// clock has no interval, and every request used to be taken the moment it
/// arrived, so a pointer-reactive wallpaper drew one frame per pointer sample —
/// the ceiling the user configured bounded nothing at all.
TEST(FrameTimerTest, EventsCannotOutrunTheCeilingWhileIdle)
{
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };

    FrameTimer timer([&]() {
        {
            std::scoped_lock lock(mutex);
            ++draws;
        }
        condition.notify_all();
        timer.FrameEnd();
    });
    timer.SetRequiredFps(10); // 100 ms between frames.
    timer.Run();
    WaitFor(
        mutex, condition, [&]() { return draws > 0; }, 500ms);
    timer.SetFrameDemand({ .kind = FrameTimer::FrameDemand::Kind::Idle });
    std::this_thread::sleep_for(50ms);

    int before = 0;
    {
        std::scoped_lock lock(mutex);
        before = draws;
    }

    const auto started = std::chrono::steady_clock::now();
    while (std::chrono::steady_clock::now() - started < 300ms) {
        timer.RequestFrame();
        std::this_thread::sleep_for(2ms);
    }
    timer.Stop();

    std::scoped_lock lock(mutex);
    const int produced = draws - before;
    // ~150 requests over 300 ms at a 10 FPS ceiling is three frames, plus one
    // for scheduling slack. Anything near the request count means the ceiling
    // was bypassed.
    EXPECT_LE(produced, 4) << produced << " frames from ~150 requests in 300ms at 10 FPS";
    EXPECT_GT(produced, 0) << "requests were dropped instead of paced";
}

/// A slow draw that the scene runs on its own thread, the way the render
/// looper does: the tick posts the draw and returns, and `FrameEnd` lands
/// later. Nothing here reaches into the scheduler's own state.
class DeferredDraw {
public:
    explicit DeferredDraw(FrameTimer& timer, std::chrono::milliseconds duration)
        : m_timer(timer), m_duration(duration) {}
    ~DeferredDraw() { join(); }

    /// Call after `FrameTimer::Stop`, before the timer goes out of scope: a
    /// draw still running holds a reference to it.
    void join() {
        for (auto& worker : m_workers)
            if (worker.joinable()) worker.join();
        m_workers.clear();
    }

    /// Runs on the timer thread, like the production callback. `during` fires
    /// at the *start* of the draw, so every tick the draw outlasts is one it
    /// suppresses.
    void post(const std::function<void()>& during) {
        m_workers.emplace_back([this, during]() {
            m_timer.FrameBegin();
            if (during) during();
            std::this_thread::sleep_for(m_duration);
            m_timer.FrameEnd();
        });
    }

private:
    FrameTimer&                m_timer;
    std::chrono::milliseconds  m_duration;
    std::vector<std::thread>   m_workers;
};

/// An update that lands while a draw is in flight still has to be drawn.
///
/// The one-draw-in-flight rule drops the tick carrying it. A running clock has
/// a next cadence tick that covers the loss; an idle clock has none, so the
/// state change would never reach the screen and the wallpaper would sit on
/// stale pixels until something unrelated asked for a frame.
TEST(FrameTimerTest, AnEventThatArrivesDuringADrawIsStillDrawn)
{
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };
    std::unique_ptr<DeferredDraw> slow;

    FrameTimer timer([&]() {
        int index = 0;
        {
            std::scoped_lock lock(mutex);
            index = ++draws;
        }
        condition.notify_all();
        // The first draw is slow and an event arrives in the middle of it.
        slow->post(index == 1 ? std::function<void()>([&]() { timer.RequestFrame(); })
                              : std::function<void()> {});
    });
    slow = std::make_unique<DeferredDraw>(timer, 120ms);
    timer.SetRequiredFps(20); // 50 ms ceiling, well under the draw.
    timer.Run();
    WaitFor(
        mutex, condition, [&]() { return draws > 0; }, 500ms);
    // The scene goes quiet while its first draw is still running.
    timer.SetFrameDemand({ .kind = FrameTimer::FrameDemand::Kind::Idle });

    const auto waited = WaitFor(
        mutex, condition, [&]() { return draws > 1; }, 1s);
    timer.Stop();
    slow->join();

    std::scoped_lock lock(mutex);
    EXPECT_GT(draws, 1) << "the update that arrived during a draw was lost";
    EXPECT_LT(waited.count(), 800) << "the owed frame did not arrive at the ceiling";
}

/// The handover itself: a request whose tick was suppressed by a continuous
/// draw, where that same draw is the one that leaves the scene idle.
///
/// The clock is still running when the tick is suppressed, so nothing there
/// can re-arm it; by the time the scene is idle the request is gone. Only the
/// end of the draw sees both facts.
TEST(FrameTimerTest, ARequestSuppressedByAContinuousDrawSurvivesGoingIdle)
{
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };
    std::unique_ptr<DeferredDraw> slow;

    FrameTimer timer([&]() {
        int index = 0;
        {
            std::scoped_lock lock(mutex);
            index = ++draws;
        }
        condition.notify_all();
        // Mid-draw: an event arrives, its tick is suppressed because this draw
        // is still running, and then this draw is the one that leaves the
        // scene idle — exactly what `refreshFrameDemand` does after `FrameEnd`.
        slow->post(index == 1 ? std::function<void()>([&]() { timer.RequestFrame(); })
                              : std::function<void()> {});
    });
    slow = std::make_unique<DeferredDraw>(timer, 150ms);
    timer.SetRequiredFps(30); // ~33 ms cadence; several ticks fall inside the draw.
    timer.Run();
    WaitFor(
        mutex, condition, [&]() { return draws > 0; }, 500ms);
    std::this_thread::sleep_for(100ms);
    timer.SetFrameDemand({ .kind = FrameTimer::FrameDemand::Kind::Idle });

    const auto waited = WaitFor(
        mutex, condition, [&]() { return draws > 1; }, 1s);
    timer.Stop();
    slow->join();

    std::scoped_lock lock(mutex);
    EXPECT_GT(draws, 1) << "a request suppressed by a continuous draw was lost when the scene idled";
    EXPECT_LT(waited.count(), 800) << "the owed frame did not arrive at the ceiling";
}

/// Pointer movement asks for a frame on every sample. At the ceiling those
/// asks are absorbed by the tick that is already scheduled, so a burst of them
/// produces about one callback per period, not one per ask.
TEST(FrameTimerTest, ABurstOfWakeOnceAtTheCeilingDoesNotAddCallbacks)
{
    std::mutex              mutex;
    std::condition_variable condition;
    int                     draws { 0 };

    FrameTimer timer([&]() {
        {
            std::scoped_lock lock(mutex);
            ++draws;
        }
        condition.notify_all();
        timer.FrameEnd();
    });
    timer.SetRequiredFps(30);
    timer.Run();
    WaitFor(mutex, condition, [&]() { return draws > 0; }, 500ms);
    int baseline = 0;
    {
        std::scoped_lock lock(mutex);
        baseline = draws;
    }

    const auto started = std::chrono::steady_clock::now();
    while (std::chrono::steady_clock::now() - started < 1s) {
        timer.RequestFrame();
        std::this_thread::sleep_for(5ms);
    }
    timer.Stop();

    int observed = 0;
    {
        std::scoped_lock lock(mutex);
        observed = draws - baseline;
    }
    // 1 s at 30 fps is about 30 callbacks. 200 asks must not become 200 callbacks.
    EXPECT_GE(observed, 20) << "the ceiling stopped producing frames";
    EXPECT_LE(observed, 40) << "200 WakeOnce calls produced " << observed
                            << " callbacks in 1s at 30 fps";
}

TEST(ThreadTimerTest, CadenceKeepsItsPeriodDespiteWakeSlack) {
    // Each wait wakes a few milliseconds late. Anchoring the next deadline to
    // the wake time added that slack to every period: a 10 ms cadence ran at
    // about 12-14 ms and a 60 fps ceiling delivered about 50 frames a second.
    std::atomic<int> ticks { 0 };
    ThreadTimer timer([&]() { ticks.fetch_add(1); });
    timer.SetInterval(10ms);
    timer.SetMinInterval(10ms);
    timer.Start();
    std::this_thread::sleep_for(600ms);
    timer.Stop();

    EXPECT_GE(ticks.load(), 54) << "a 10 ms cadence produced " << ticks.load() << " ticks in 600 ms";
    EXPECT_LE(ticks.load(), 62) << "a late wake must not burst to catch up";
}

TEST(ThreadTimerTest, RequestsAfterALongWaitStillRespectTheCeiling) {
    // A content-paced clock (200 ms) with a 10 ms ceiling. A request after a
    // long wait is due at once, and the tick it runs must not become an anchor
    // in the past that lets the next requests through back to back.
    std::atomic<int> ticks { 0 };
    ThreadTimer timer([&]() { ticks.fetch_add(1); });
    timer.SetInterval(200ms);
    timer.SetMinInterval(10ms);
    timer.Start();
    std::this_thread::sleep_for(150ms);
    const int before = ticks.load();
    const auto until = std::chrono::steady_clock::now() + 50ms;
    while (std::chrono::steady_clock::now() < until) {
        timer.WakeOnce();
        std::this_thread::sleep_for(1ms);
    }
    const int during = ticks.load() - before;
    timer.Stop();

    EXPECT_LE(during, 50 / 10 + 1) << during << " ticks in 50 ms under a 10 ms ceiling";
    EXPECT_GE(during, 3) << "requests must still be answered at the ceiling";
}


} // namespace
} // namespace wallpaper
