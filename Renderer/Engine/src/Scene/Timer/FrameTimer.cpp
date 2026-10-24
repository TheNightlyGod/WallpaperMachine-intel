// Clean-room implementation from the WallpaperMachine spec e2-runtime-animation.md; written without access to the original source.
#include "FrameTimer.hpp"
#include "Utils//Logging.h"

#include <algorithm>
#include <numeric>

using namespace wallpaper;
using micros = std::chrono::microseconds;
using namespace std::chrono;

namespace
{
constexpr auto MAX_FRAME_DURATION = seconds(5);
/// Multiple of the tick interval that still counts as ordinary scheduling
/// jitter. A content-paced clock ticks at its own interval by design, so the
/// suspension threshold has to be expressed relative to that interval; three
/// intervals leaves room for a late wakeup without letting a genuine process
/// suspension feed hours into scene simulation.
constexpr i32  SUSPENSION_INTERVAL_SLACK { 3 };
constexpr u16  DEFAULT_REQUIRED_FPS { 30 };
/// How many draws the render-cost statistic averages.
constexpr std::size_t COST_WINDOW { 5 };
}

FrameTimer::FrameTimer(std::function<void()> cb)
    : m_draw(std::move(cb)), m_timer([this] { OnTick(); }) {
    m_req_fps  = DEFAULT_REQUIRED_FPS;
    m_ideatime = microseconds(1'000'000 / DEFAULT_REQUIRED_FPS);
    m_elapsed_frametime = m_ideatime.load();
    m_frame_busy_count  = 0;
    m_frame_cost        = m_ideatime.load();
    m_costs.assign(COST_WINDOW, m_ideatime.load());
    m_timer.SetMinInterval(m_ideatime.load());
    m_timer.SetInterval(ResolveInterval());
}

FrameTimer::~FrameTimer() { m_timer.Stop(); }

u16 FrameTimer::RequiredFps() const { return m_req_fps.load(); }

double FrameTimer::FrameTime() const {
    return duration_cast<duration<double>>(m_frame_cost.load()).count();
}

double FrameTimer::IdeaTime() const {
    return duration_cast<duration<double>>(m_elapsed_frametime.load()).count();
}

void FrameTimer::UpdateFrametime() {
    std::lock_guard lock(m_costs_mutex);
    if (m_costs.empty()) return;
    const auto sum = std::accumulate(m_costs.begin(), m_costs.end(), micros::zero());
    m_frame_cost.store(sum / static_cast<micros::rep>(m_costs.size()));
}

void FrameTimer::AddFrametime(micros t) {
    std::lock_guard lock(m_costs_mutex);
    m_costs.push_back(t);
    while (m_costs.size() > COST_WINDOW) m_costs.pop_front();
}

void FrameTimer::SetRequiredFps(u16 value) {
    m_req_fps  = value > 0 ? value : DEFAULT_REQUIRED_FPS;
    m_ideatime = microseconds(1'000'000 / m_req_fps.load());
    // The ceiling is a hard floor on the gap between frames, separate from the
    // cadence: content pacing lengthens the cadence past the ceiling, and a
    // one-shot request has no cadence at all, so both would otherwise be
    // unbounded from below.
    m_timer.SetMinInterval(m_ideatime.load());
    // An FPS change must not discard an in-flight draw or its elapsed time.
    m_timer.SetInterval(ResolveInterval());
}

void FrameTimer::SetFrameDemand(FrameDemand demand) {
    const auto period = demand.content_period > microseconds::zero() ? demand.content_period
                                                                     : microseconds::zero();
    const auto previous_kind   = m_demand_kind.exchange(demand.kind);
    const bool period_changed  = m_content_period.exchange(period) != period;
    const bool kind_changed    = previous_kind != demand.kind;

    switch (demand.kind) {
    case FrameDemand::Kind::Idle:
        // The interval is left as it was: leaving idle has to restore a
        // cadence, and recomputing it from a stale ideal frame time at the
        // moment of the wake would make the first frame after a long sleep
        // arrive at the wrong rate.
        m_timer.SetIdle(true);
        break;
    case FrameDemand::Kind::Timed: {
        const auto deadline = demand.deadline;
        m_demand_deadline.store(deadline);
        const auto now = steady_clock::now();
        if (deadline <= now) {
            // A deadline already past is a frame that is owed, not a very long
            // wait. It has to be taken through the idle path: a one-shot
            // request is honoured immediately only while idle, so leaving the
            // clock running would defer this owed frame by a full cadence
            // interval instead of taking it now. After that frame runs, its own
            // demand decides what happens next.
            m_timer.SetIdle(true);
            m_timer.WakeOnce();
            break;
        }
        m_timer.SetIdle(true);
        m_timer.WakeAt(deadline);
        break;
    }
    case FrameDemand::Kind::Continuous:
        m_timer.SetIdle(false);
        if (period_changed || kind_changed) m_timer.SetInterval(ResolveInterval());
        break;
    }
}

void FrameTimer::RequestFrame() {
    // A stopped clock stays stopped. Waking a paused wallpaper because a
    // property changed would override the user's own decision; the frame is
    // taken when the clock is next run.
    if (! Running()) return;
    // Recorded here and cleared only by a draw. The thread timer's own latch
    // is cleared by the tick it fires, which is not the same thing: a tick
    // suppressed by an in-flight draw would otherwise consume the request
    // without drawing anything, and if that draw then leaves the scene idle
    // there is no later tick to notice.
    m_frame_requested.store(true);
    m_timer.WakeOnce();
}

bool FrameTimer::Idle() const { return m_timer.Idle(); }

std::chrono::microseconds FrameTimer::TickInterval() const { return m_tick_interval.load(); }

void FrameTimer::SetCounters(RendererCounters* counters) {
    m_counters.store(counters, std::memory_order_relaxed);
}

std::chrono::microseconds FrameTimer::SuspensionThreshold() const {
    const auto floor    = duration_cast<microseconds>(MAX_FRAME_DURATION);
    const auto relative = m_tick_interval.load() * SUSPENSION_INTERVAL_SLACK;
    return std::max(floor, relative);
}

std::chrono::microseconds FrameTimer::ResolveInterval() {
    const auto ideal  = m_ideatime.load();
    const auto period = m_content_period.load();
    auto       interval = ideal;
    if (period > ideal) {
        // Bounded on both sides: never faster than the ceiling the user and the
        // display set, and never slower than the longest gap the frame clock
        // treats as continuous playback, so a bad period cannot stall the scene.
        interval = std::min(period, duration_cast<microseconds>(MAX_FRAME_DURATION));
    }
    m_tick_interval.store(interval);
    auto* counters = m_counters.load(std::memory_order_relaxed);
    if (counters != nullptr) {
        counters->Set(OWE_RC_TICK_INTERVAL_MICROS, static_cast<u64>(interval.count()));
        counters->Set(OWE_RC_CONTENT_PERIOD_MICROS, static_cast<u64>(period.count()));
    }
    return interval;
}

void FrameTimer::FrameBegin() { FrameBegin(steady_clock::now()); }
void FrameTimer::FrameBegin(steady_clock::time_point now) {
    const auto elapsed = duration_cast<microseconds>(now - m_clock);
    // The first frame after Run has no active predecessor. A gap far longer
    // than the interval this clock is pacing at is the process having been
    // suspended, not the content waiting, and must not feed hours into scene
    // simulation. The threshold follows the interval precisely so that a scene
    // paced to its content is not mistaken for a resume on every frame.
    const bool reset = m_reset_frame_clock.exchange(false);
    m_elapsed_frametime.store(reset || elapsed > SuspensionThreshold()
                                 ? m_ideatime.load()
                                 : elapsed);
    m_clock = now;
}
void FrameTimer::FrameEnd() { FrameEnd(steady_clock::now()); }
void FrameTimer::FrameEnd(steady_clock::time_point now) {
    const auto cost = duration_cast<microseconds>(now - m_clock);
    if (cost > MAX_FRAME_DURATION) {
        // The process was suspended inside this frame: its length says nothing about the cost
        // of drawing, and the next frame starts afresh.
        {
            std::lock_guard lock(m_costs_mutex);
            m_costs.assign(COST_WINDOW, m_ideatime.load());
        }
        UpdateFrametime();
        m_elapsed_frametime.store(m_ideatime.load());
        m_reset_frame_clock.store(true);
    } else {
        AddFrametime(cost);
        UpdateFrametime();
    }

    // One draw less in flight, never below none.
    auto busy = m_frame_busy_count.load();
    while (busy > 0 && ! m_frame_busy_count.compare_exchange_weak(busy, busy - 1)) {}

    // A tick that was dropped because this draw was still running is owed, and taken now when
    // the draw ended soon after it was due: a frame that overruns by a millisecond does not
    // halve the rate. The dropped tick was itself a whole interval after the last one, so this
    // cannot outrun the ceiling.
    const auto owed = m_owed_tick_ns.exchange(kNoOwedTick);
    if (owed != kNoOwedTick) {
        const auto late = now.time_since_epoch() - nanoseconds(owed);
        if (late >= nanoseconds::zero() && late <= m_tick_interval.load() / 4) {
            m_timer.FireNow();
            return;
        }
    }
    if (m_frame_requested.load() && m_timer.Running()) m_timer.WakeOnce();
}

void FrameTimer::SetCallback(const std::function<void()>& cb) {
    if (! m_timer.Running()) m_draw = cb;
}

void FrameTimer::Run() {
    if (m_timer.Running()) return;
    // A start is a fresh clock: the first frame counts one ideal interval, nothing inherits a
    // draw that will never complete, and no tick is owed.
    const auto ideal = m_ideatime.load();
    {
        std::lock_guard lock(m_costs_mutex);
        m_costs.assign(COST_WINDOW, ideal);
    }
    UpdateFrametime();
    m_elapsed_frametime.store(ideal);
    m_reset_frame_clock.store(true);
    m_frame_busy_count.store(0);
    m_owed_tick_ns.store(kNoOwedTick);
    m_timer.SetInterval(ResolveInterval());
    m_timer.Start();
}

void FrameTimer::Stop() { m_timer.Stop(); }

bool FrameTimer::Running() const { return m_timer.Running(); }

void FrameTimer::OnTick() {
    // Claim the single draw slot first; every other effect of the tick follows from whether the
    // claim succeeded.
    const bool has_draw = static_cast<bool>(m_draw);
    bool       admitted = false;
    if (has_draw) {
        i32 none_in_flight = 0;
        admitted           = m_frame_busy_count.compare_exchange_strong(none_in_flight, 1);
    }

    if (admitted) {
        m_frame_requested.store(false);
        m_owed_tick_ns.store(kNoOwedTick);
    } else if (has_draw) {
        m_owed_tick_ns.store(steady_clock::now().time_since_epoch().count());
    }

    if (auto* sink = m_counters.load(std::memory_order_relaxed); sink != nullptr) {
        sink->Add(OWE_RC_TIMER_WAKEUPS);
        sink->Add(admitted ? OWE_RC_DRAW_REQUESTS : OWE_RC_DRAW_TICKS_SUPPRESSED);
    }
    m_timer.SetInterval(ResolveInterval());

    if (admitted) m_draw();
}
