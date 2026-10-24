// Clean-room implementation from the WallpaperMachine spec e2-runtime-animation.md; written without access to the original source.
#include "ThreadTimer.hpp"

#include "Utils/Logging.h"

#include <algorithm>
#include <cassert>
#include <pthread.h>

using namespace wallpaper;
using micros = std::chrono::microseconds;

ThreadTimer::ThreadTimer(std::function<void()> cb) : m_callback(std::move(cb)) {}

ThreadTimer::~ThreadTimer() { Stop(); }

bool ThreadTimer::Running() const { return m_running.load(std::memory_order_acquire); }

void ThreadTimer::SetInterval(micros v) {
    {
        std::lock_guard lock(m_mutex);
        m_interval = std::max(v, micros(1));
    }
    // The wait in progress was computed from the old period.
    m_wake.notify_all();
}

void ThreadTimer::SetMinInterval(micros v) {
    {
        std::lock_guard lock(m_mutex);
        m_min_interval = std::max(v, micros::zero());
    }
    m_wake.notify_all();
}

void ThreadTimer::SetIdle(bool idle) {
    {
        std::lock_guard lock(m_mutex);
        if (m_idle == idle) return;
        m_idle = idle;
        if (! idle) {
            // Back from idle the cadence starts afresh from this moment: no burst to catch up
            // with the time spent waiting, and an appointment made for the idle time is moot.
            m_cadence_anchor = Clock::now();
            m_appointment.reset();
        }
    }
    m_wake.notify_all();
}

bool ThreadTimer::Idle() const {
    std::lock_guard lock(m_mutex);
    return m_idle;
}

void ThreadTimer::WakeOnce() {
    bool notify = false;
    {
        std::lock_guard lock(m_mutex);
        if (! m_request) m_request_time = Clock::now();
        m_request = true;
        // A cadence that already ticks at the ceiling takes the request with its next tick, so
        // the thread need not be woken for it.
        notify = m_idle || m_interval > m_min_interval;
    }
    if (notify) m_wake.notify_all();
}

void ThreadTimer::WakeAt(std::chrono::steady_clock::time_point when) {
    {
        std::lock_guard lock(m_mutex);
        m_appointment = when;
    }
    m_wake.notify_all();
}

void ThreadTimer::FireNow() {
    {
        std::lock_guard lock(m_mutex);
        m_fire_now = true;
    }
    m_wake.notify_all();
}

void ThreadTimer::Start() {
    std::lock_guard control(m_control_mutex);
    if (m_running.load()) return;
    if (m_thread.joinable()) m_thread.join();
    {
        std::lock_guard lock(m_mutex);
        const auto now   = Clock::now();
        m_cadence_anchor = now;
        // No tick has happened yet, so the first request is honoured at once.
        m_last_due       = now - m_min_interval;
        m_fire_now       = false;
        m_running.store(true, std::memory_order_release);
    }
    m_thread = std::thread([this] {
        pthread_setname_np("wp-frame-timer");
        Loop();
    });
}

void ThreadTimer::Stop() {
    std::lock_guard control(m_control_mutex);
    {
        std::lock_guard lock(m_mutex);
        m_running.store(false, std::memory_order_release);
    }
    m_wake.notify_all();
    if (! m_thread.joinable()) return;
    if (m_thread.get_id() == std::this_thread::get_id()) {
        // The tick asked for its own timer to stop: the loop ends once the tick returns.
        m_thread.detach();
        return;
    }
    m_thread.join();
}

// Each pass works out the earliest moment something may run, sleeps until then (or until
// something changes the answer) and runs the callback once.
void ThreadTimer::Loop() {
    std::unique_lock lock(m_mutex);
    while (m_running.load(std::memory_order_acquire)) {
        const auto now   = Clock::now();
        const auto floor = m_last_due + m_min_interval;

        std::optional<Clock::time_point> cadence;
        if (! m_idle) cadence = std::max(m_cadence_anchor + m_interval, floor);
        const bool absorbed = ! m_idle && m_interval <= m_min_interval;

        std::optional<Clock::time_point> other;
        if (m_request && ! absorbed) other = std::max(m_request_time, floor);
        if (m_appointment) {
            const auto appointed = std::max(*m_appointment, floor);
            other                = other ? std::min(*other, appointed) : appointed;
        }

        std::optional<Clock::time_point> due;
        if (m_fire_now) {
            due = now;
        } else if (cadence) {
            due = other ? std::min(*cadence, *other) : *cadence;
        } else {
            due = other;
        }

        if (! due) {
            m_wake.wait(lock);
            continue;
        }
        if (*due > now) {
            m_wake.wait_until(lock, *due);
            continue;
        }

        // Run a tick. One that woke late by less than a whole step is counted as having
        // happened when it was due, so scheduling slack does not pile up into the period; one
        // later than that restarts from now instead of firing a burst.
        const auto step = m_interval;
        if (m_fire_now) {
            m_fire_now       = false;
            m_last_due       = now;
            m_cadence_anchor = now;
        } else {
            m_last_due = now - *due > step ? now : *due;
            if (cadence && *cadence <= now) {
                m_cadence_anchor =
                    now - *cadence > step ? now : m_cadence_anchor + m_interval;
            }
            if (m_appointment && *m_appointment <= now) m_appointment.reset();
        }
        m_request = false;

        lock.unlock();
        if (m_callback) {
            try {
                m_callback();
            } catch (const std::exception& error) {
                LOG_ERROR("ThreadTimer: tick failed: %s", error.what());
            } catch (...) {
                LOG_ERROR("ThreadTimer: tick failed");
            }
        }
        lock.lock();
    }
}
