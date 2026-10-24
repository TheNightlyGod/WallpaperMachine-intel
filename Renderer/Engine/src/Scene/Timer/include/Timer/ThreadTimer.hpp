#pragma once

#include "Core/Literals.hpp"
#include "Core/NoCopyMove.hpp"

#include <mutex>
#include <condition_variable>
#include <thread>
#include <atomic>

#include <functional>
#include <chrono>
#include <optional>

namespace wallpaper
{

class ThreadTimer : NoCopy, NoMove {
public:
    ThreadTimer(std::function<void()> callback);
    ~ThreadTimer();

    void Start();
    void Stop();

    bool Running() const;

    void SetInterval(std::chrono::microseconds);

    /// Shortest gap allowed between two callbacks, whatever asked for them.
    ///
    /// `SetInterval` is the cadence, and content pacing is free to make it
    /// *longer* than the user's frame ceiling. That leaves the ceiling itself
    /// unrepresented, so every non-cadence path into the callback — a one-shot
    /// request, an appointment, an appointment already past — had nothing to
    /// clamp it and could drive the scene as fast as events arrived. This is
    /// that ceiling, expressed where every path has to pass it: the earliest
    /// moment a callback may run is always `last tick + min interval`, where the
    /// last tick is the moment that callback was due. A callback that woke late
    /// is followed by one sooner by at most that lateness, which is what keeps
    /// the average at the ceiling; measuring from the late wake instead added
    /// every wake's slack to the period (a 60 fps ceiling delivered about 50).
    /// `FireNow` follows a tick that was itself due a whole period after the
    /// last callback, so it is bounded the same way.
    ///
    /// Zero disables the floor, which is the behaviour of a timer whose owner
    /// never states a ceiling.
    void SetMinInterval(std::chrono::microseconds);

    /// Suspends the periodic deadline entirely.
    ///
    /// While idle the thread waits on its condition variable with no timeout,
    /// so the scene costs no wakeups at all. This is deliberately not "a very
    /// long interval": a long interval still wakes, and a wallpaper that has
    /// nothing to draw should not wake to decide that again. Leaving idle
    /// restarts the cadence from the moment of the call rather than from the
    /// stale deadline the thread was holding.
    void SetIdle(bool idle);

    [[nodiscard]] bool Idle() const;

    /// Runs the callback once at the earliest moment the frame ceiling allows,
    /// whether idle or waiting on a deadline, and without disturbing the
    /// cadence.
    ///
    /// The request is a latch, not a notification: it is recorded under the
    /// same mutex the waiter re-checks, so a wake that lands between the
    /// decision to idle and the wait itself still produces a tick instead of
    /// being lost. The latch also survives a wait: a burst of requests
    /// coalesces into one tick at the ceiling rather than one tick each.
    void WakeOnce();

    /// Schedules exactly one tick at `when` while idle, replacing any deadline
    /// already scheduled.
    ///
    /// This is for content that knows when it next changes — a clock layer
    /// that redraws on the minute — and it is a single appointment, not a
    /// cadence: after the tick the thread is idle again unless the frame that
    /// ran asks for another. `when` in the past ticks at the next moment the
    /// frame ceiling allows, which is immediately after a long idle and one
    /// full frame period after a tick — an owed frame is not a licence to spin.
    void WakeAt(std::chrono::steady_clock::time_point when);

    /// Runs the callback now and restarts the cadence from this tick.
    ///
    /// For a tick the owner had to drop because its previous frame was still
    /// running and finished just after: the owner calls this only when that
    /// frame ended within a small fraction of an interval of the dropped tick,
    /// which already lies a whole ceiling after the last frame that ran, so it
    /// cannot drive the scene faster than the ceiling.
    void FireNow();

private:
    friend struct TimerAdmissionTestAccess;

    using Clock = std::chrono::steady_clock;

    void Loop();

    // Named for the tests, which call it as the timer's tick.
    std::function<void()> m_callback;

    // Start and Stop are serialised by this one.
    std::mutex m_control_mutex;
    std::thread m_thread;
    std::atomic<bool> m_running { false };

    // Everything below is guarded by `m_mutex`, the lock the waiting thread re-checks.
    mutable std::mutex      m_mutex;
    std::condition_variable m_wake;
    std::chrono::microseconds m_interval { 33'333 };
    std::chrono::microseconds m_min_interval { 0 };
    bool                      m_idle { false };
    // One-shot request: a latch, with the moment the first request of the batch was made.
    bool                      m_request { false };
    Clock::time_point         m_request_time {};
    std::optional<Clock::time_point> m_appointment;
    bool                      m_fire_now { false };
    // The cadence is a grid anchored to due times: the next cadence tick is `anchor + interval`.
    Clock::time_point         m_cadence_anchor {};
    // The due moment of the last tick; the ceiling is measured from it.
    Clock::time_point         m_last_due {};
};

} // namespace wallpaper
