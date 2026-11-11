#pragma once

#include "Core/RendererCounters.hpp"

#include <cmath>
#include <cstdint>
#include <mutex>

namespace wallpaper
{

/// What the display did with the frames one surface asked to present.
///
/// A present request is only a request. The drawable reports afterwards when it
/// was shown, or that it never was (`presentedTime` 0: replaced or discarded
/// before any refresh showed it). This turns those reports into counters: frames
/// shown, frames dropped, and the time from one shown frame to the next in
/// display refreshes.
///
/// The reports arrive on a thread the graphics framework owns, possibly after
/// the renderer that presented the frame is gone, so a report never touches the
/// renderer: it holds this object, and this object holds the counters only
/// between `Restart` and `Detach`. `Detach` waits for a report in progress, so
/// once it returns no report can reach counters about to be destroyed.
class PresentFeedback {
public:
    enum class Gap : uint8_t { OneRefresh, TwoRefreshes, Longer };

    /// The gap between two shown frames rounded to whole refreshes of a display
    /// that refreshes every `refresh_period` seconds. Shorter than one and a
    /// half refreshes is one (a variable-rate display may show a frame early),
    /// shorter than two and a half is two, anything longer is longer.
    static Gap Classify(double gap_seconds, double refresh_period) noexcept {
        const double refreshes = gap_seconds / refresh_period;
        if (refreshes < 1.5) return Gap::OneRefresh;
        if (refreshes < 2.5) return Gap::TwoRefreshes;
        return Gap::Longer;
    }

    /// Starts a new sequence into `counters`: the next shown frame has no
    /// predecessor to measure a gap from, so a gap never spans a time nothing
    /// was counted. `refresh_period` is in seconds; 0 when the display's is not
    /// known, and gaps are then not counted at all rather than guessed.
    /// Returns the new sequence's number, which a report names (`Record`) so that a
    /// drawable presented under an earlier sequence never counts in this one.
    uint64_t Restart(RendererCounters* counters, double refresh_period) noexcept {
        std::scoped_lock lock(m_mutex);
        ++m_sequence;
        m_counters        = counters;
        m_refresh_period  = refresh_period > 0.0 && std::isfinite(refresh_period) ? refresh_period : 0.0;
        m_previous_shown  = 0.0;
        if (m_counters != nullptr) {
            m_counters->Set(OWE_RC_VSYNC_PERIOD_MICROS,
                            static_cast<uint64_t>(std::llround(m_refresh_period * 1e6)));
        }
        return m_sequence;
    }

    /// The current sequence's number, for a drawable about to be presented.
    uint64_t Sequence() noexcept {
        std::scoped_lock lock(m_mutex);
        return m_sequence;
    }

    /// No report counts from here on. Called before the counters it was given
    /// are destroyed or replaced.
    void Detach() noexcept {
        std::scoped_lock lock(m_mutex);
        m_counters = nullptr;
    }

    /// One drawable's report: the host time it was shown at, 0 when it never was.
    /// `sequence` is the number the drawable was presented under; a report from an
    /// earlier sequence (counters detached and attached again, another display) is
    /// left out. 0 reports into the current sequence.
    void Record(double presented_time, uint64_t sequence = 0) noexcept {
        std::scoped_lock lock(m_mutex);
        if (m_counters == nullptr) return;
        if (sequence != 0 && sequence != m_sequence) return;
        if (! (presented_time > 0.0)) {
            m_counters->Add(OWE_RC_PRESENTS_DROPPED);
            return;
        }
        m_counters->Add(OWE_RC_PRESENTED_FRAMES);
        // Reports normally arrive in presentation order; one that does not has
        // no gap to the newest shown frame and does not move it back.
        if (m_previous_shown > 0.0 && presented_time > m_previous_shown && m_refresh_period > 0.0) {
            switch (Classify(presented_time - m_previous_shown, m_refresh_period)) {
            case Gap::OneRefresh: m_counters->Add(OWE_RC_PRESENT_GAPS_1_VSYNC); break;
            case Gap::TwoRefreshes: m_counters->Add(OWE_RC_PRESENT_GAPS_2_VSYNC); break;
            case Gap::Longer: m_counters->Add(OWE_RC_PRESENT_GAPS_3PLUS_VSYNC); break;
            }
        }
        if (presented_time > m_previous_shown) m_previous_shown = presented_time;
    }

private:
    std::mutex        m_mutex;
    RendererCounters* m_counters { nullptr };
    double            m_refresh_period { 0.0 };
    double            m_previous_shown { 0.0 };
    uint64_t          m_sequence { 0 };
};

} // namespace wallpaper
