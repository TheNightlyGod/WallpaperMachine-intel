#pragma once

#include "Core/RendererCounters.hpp"
#include "ThreadTimer.hpp"
#include <deque>
#include <limits>

namespace wallpaper
{
class FrameTimer : NoCopy, NoMove {
public:
    FrameTimer(std::function<void()> callback = {});
    ~FrameTimer();

    void SetCallback(const std::function<void()>&);

    void Run();
    void Stop();

    u16    RequiredFps() const;
    bool   Running() const;
    // Smoothed render work duration, excluding time between delivered frames.
    double FrameTime() const;
    // Elapsed delivered-frame time, excluding stopped time.
    double IdeaTime() const;

    void SetRequiredFps(u16);

    /// How often the content itself can change.
    ///
    /// The required FPS is a ceiling chosen by the user and the display; it says
    /// nothing about how often the scene has something new to show. A source
    /// that reports a longer period than the ideal frame time lowers the tick
    /// rate to its own rate, which removes renders that would present identical
    /// pixels. It can never raise the rate above the ceiling, and an absent or
    /// zero period keeps the fixed cadence, so a scene that cannot prove its own
    /// rate is unaffected.
    struct FrameDemand {
        /// What the scene needs from the clock.
        ///
        /// `Continuous` is the safe baseline and the only value a scene that
        /// cannot describe itself ever produces. `Idle` stops the periodic
        /// deadline outright; the clock then ticks only when something asks it
        /// to. `Timed` keeps the clock stopped until one known deadline.
        enum class Kind : uint8_t
        {
            Continuous = 0,
            Idle       = 1,
            Timed      = 2,
        };

        Kind kind { Kind::Continuous };
        /// Zero when the content cannot say how often it changes.
        std::chrono::microseconds content_period { std::chrono::microseconds::zero() };
        /// Only read for `Timed`. Measured on the same clock as the frame
        /// clock, so a deadline already in the past ticks immediately rather
        /// than wrapping into a very long wait.
        std::chrono::steady_clock::time_point deadline {};
    };

    /// Pushed by the owner from the render thread, so the timer thread never
    /// reaches into scene or renderer state to ask.
    void SetFrameDemand(FrameDemand);

    /// Requests exactly one tick, coalescing with any already pending.
    ///
    /// This is how an idle scene is woken: a property change, a resize, a new
    /// resource or a pointer event asks for one frame, and what happens after
    /// that frame is decided by the demand the frame itself produces. Safe to
    /// call from any thread, including while the clock is stopped, in which
    /// case it does nothing rather than resurrecting a paused wallpaper.
    void RequestFrame();

    /// Whether the clock is currently holding no periodic deadline.
    [[nodiscard]] bool Idle() const;

    /// Interval the next tick will use, for diagnostics and tests.
    [[nodiscard]] std::chrono::microseconds TickInterval() const;

    /// Gap above which a frame boundary is read as the process having been
    /// suspended rather than as the content simply not having changed yet.
    ///
    /// A fixed threshold silently collides with content pacing: a scene paced
    /// at the clamp would have every ordinary tick misread as a resume, its
    /// elapsed time replaced by one ideal frame, and its playback would fall
    /// behind by the difference every frame. The threshold therefore scales
    /// with the interval the clock is actually using, and never drops below the
    /// fixed floor.
    [[nodiscard]] std::chrono::microseconds SuspensionThreshold() const;

    /// Counters are owned by the scene and outlive the timer. Install before
    /// `Run`; the timer thread only reads the pointer.
    void SetCounters(RendererCounters* counters);

    void FrameBegin();
    void FrameEnd();

private:
    friend struct TimerAdmissionTestAccess;

    void AddFrametime(std::chrono::microseconds);
    void UpdateFrametime();
    void FrameBegin(std::chrono::steady_clock::time_point now);
    void FrameEnd(std::chrono::steady_clock::time_point now);
    std::chrono::microseconds ResolveInterval();
    /// The thread timer's tick, on the timer thread: asks for a draw unless one is in flight.
    void OnTick();

    std::atomic<RendererCounters*>        m_counters { nullptr };

    std::atomic<u16>                        m_req_fps;
    std::atomic<std::chrono::microseconds> m_ideatime;
    std::atomic<std::chrono::microseconds> m_elapsed_frametime;
    std::atomic<std::chrono::microseconds> m_tick_interval;
    /// Zero means unknown, which keeps the fixed cadence.
    std::atomic<std::chrono::microseconds> m_content_period { std::chrono::microseconds::zero() };
    std::atomic<FrameDemand::Kind>         m_demand_kind { FrameDemand::Kind::Continuous };
    std::atomic<std::chrono::steady_clock::time_point> m_demand_deadline {};
    std::atomic<bool>                      m_reset_frame_clock { true };
    /// A frame someone asked for that no draw has produced yet.
    ///
    /// Distinct from the thread timer's one-shot latch, which is cleared by
    /// the tick it fires even when that tick produces no draw. This is cleared
    /// only by a draw actually being posted, so a request cannot be consumed
    /// by a tick that a still-running draw suppressed.
    std::atomic<bool>                      m_frame_requested { false };
    std::atomic<i32>                       m_frame_busy_count;
    /// Moment of a tick a still-running draw suppressed, or `kNoOwedTick`.
    static constexpr int64_t               kNoOwedTick { std::numeric_limits<int64_t>::min() };
    std::atomic<int64_t>                   m_owed_tick_ns { kNoOwedTick };

    /// The cost of the last five draws, and their mean in `m_frame_cost`.
    mutable std::mutex                     m_costs_mutex;
    std::deque<std::chrono::microseconds>  m_costs;
    std::atomic<std::chrono::microseconds> m_frame_cost;

    std::function<void()> m_draw;

    ThreadTimer m_timer;

    std::chrono::time_point<std::chrono::steady_clock> m_clock;
};
} // namespace wallpaper
