#include "Video/VideoFramePacing.hpp"

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <string_view>

namespace wallpaper::video
{

double ShortestMetadataPeriodSeconds(const FrameRateRatio* rates, std::size_t count)
{
    if (rates == nullptr) return 0.0;
    double shortest = 0.0;
    for (std::size_t i = 0; i < count; ++i) {
        const FrameRateRatio& rate = rates[i];
        if (rate.num <= 0 || rate.den <= 0) continue;
        const double period =
            static_cast<double>(rate.den) / static_cast<double>(rate.num);
        if (! std::isfinite(period) || ! (period > 0.0)) continue;
        if (shortest == 0.0 || period < shortest) shortest = period;
    }
    return shortest;
}

void VideoFramePacingEstimator::Reset(double metadata_period_seconds)
{
    m_metadata_period = std::isfinite(metadata_period_seconds) && metadata_period_seconds > 0.0
                            ? metadata_period_seconds
                            : 0.0;
    m_observed_period = 0.0;
    m_samples = 0;
    m_has_previous = false;
    m_previous_absolute = 0.0;
    m_previous_loop = 0;
    m_previous_seek_ticket = 0;
}

void VideoFramePacingEstimator::Observe(double        absolute_seconds,
                                        std::uint64_t loop_index,
                                        std::uint64_t seek_ticket)
{
    if (! std::isfinite(absolute_seconds)) {
        // An unusable timestamp breaks the run rather than seeding a bogus
        // delta into the next one.
        m_has_previous = false;
        return;
    }

    const bool same_run = m_has_previous && loop_index == m_previous_loop &&
                          seek_ticket == m_previous_seek_ticket;
    if (same_run) {
        const double delta = absolute_seconds - m_previous_absolute;
        // A repeated or rewound timestamp says nothing about how often the
        // content changes, so it is not counted as evidence either way.
        if (std::isfinite(delta) && delta > 0.0) {
            if (m_observed_period == 0.0 || delta < m_observed_period) m_observed_period = delta;
            ++m_samples;
        }
    }

    m_has_previous = true;
    m_previous_absolute = absolute_seconds;
    m_previous_loop = loop_index;
    m_previous_seek_ticket = seek_ticket;
}

double VideoFramePacingEstimator::PeriodSeconds() const
{
    if (m_samples < kMinimumSamples) return 0.0;
    if (! (m_observed_period > 0.0)) return 0.0;
    if (m_metadata_period > 0.0 && m_metadata_period < m_observed_period) {
        return m_metadata_period;
    }
    return m_observed_period;
}

VideoFrameSelection VideoFrameSelectionTracker::Observe(std::uint64_t generation)
{
    // Generation 0 is "no frame"; nothing was selected, reused or skipped.
    if (generation == 0) return {};

    VideoFrameSelection selection {};
    if (! m_has_last) {
        selection.selected = true;
        // Generations start at 1, so anything decoded before the first
        // displayed frame was decoded and thrown away.
        selection.skipped = generation - 1;
    } else if (generation == m_last_generation) {
        selection.reused = true;
        return selection;
    } else if (generation > m_last_generation) {
        selection.selected = true;
        selection.skipped = generation - m_last_generation - 1;
    } else {
        // A restarted source renumbers from the beginning. The gap cannot be
        // attributed, so it is not reported as skipped work.
        selection.selected = true;
    }

    m_last_generation = generation;
    m_has_last = true;
    return selection;
}

void VideoFrameSelectionTracker::Reset()
{
    m_last_generation = 0;
    m_has_last = false;
}

} // namespace wallpaper::video
