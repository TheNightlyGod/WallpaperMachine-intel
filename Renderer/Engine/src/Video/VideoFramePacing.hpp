#pragma once

#include <cstddef>
#include <cstdint>

namespace wallpaper::video
{

/// A container's declared frame rate, as a rational, exactly as it is stored.
/// `23.976` and `29.97` are `24000/1001` and `30000/1001`; keeping
/// the ratio avoids rounding a rate that was never a terminating decimal.
struct FrameRateRatio {
    std::int64_t num { 0 };
    std::int64_t den { 0 };
};

/// Shortest period any of the declared rates implies, in seconds, or 0 when
/// none of them is usable.
///
/// The shortest period is the safe one: pacing on a longer period skips the
/// frames inside a tighter gap, while pacing on a shorter one only renders more
/// often than needed. `avg_frame_rate` is an average and `r_frame_rate` is an
/// estimate, so neither is evidence about a specific gap — this value is a
/// bound to combine with observed timestamps, never a promise on its own.
[[nodiscard]] double ShortestMetadataPeriodSeconds(const FrameRateRatio* rates, std::size_t count);

/// Shortest gap actually observed between decoded frames.
///
/// Container metadata cannot prove how far apart two particular frames are. A
/// variable-frame-rate clip, a clip with broken metadata and a clip with a
/// non-zero start timestamp all report rates that do not describe their local
/// timing. This accumulates evidence from the decoder's real presentation
/// timestamps and reports nothing until it has enough of it, so an unproven
/// stream keeps the fixed cadence instead of being paced on a guess.
class VideoFramePacingEstimator {
public:
    /// Deltas needed before a period is reported at all. Below this the answer
    /// is "unknown", which the frame clock reads as "keep the fixed cadence".
    static constexpr std::uint64_t kMinimumSamples = 8;

    void Reset(double metadata_period_seconds);

    /// Records one decoded frame. `loop_index` and `seek_ticket` identify the
    /// continuous run the frame belongs to: a delta measured across a loop seam
    /// or a seek describes the seam, not the content, and is discarded.
    void Observe(double absolute_seconds, std::uint64_t loop_index, std::uint64_t seek_ticket);

    /// Period to pace on, in seconds, or 0 when the content cannot prove one.
    /// Never longer than the shortest declared or observed gap, and
    /// monotonically non-increasing for as long as the source lives.
    [[nodiscard]] double PeriodSeconds() const;

    [[nodiscard]] double ObservedPeriodSeconds() const { return m_observed_period; }
    [[nodiscard]] double MetadataPeriodSeconds() const { return m_metadata_period; }
    [[nodiscard]] std::uint64_t SampleCount() const { return m_samples; }

private:
    double        m_metadata_period { 0.0 };
    double        m_observed_period { 0.0 };
    std::uint64_t m_samples { 0 };
    bool          m_has_previous { false };
    double        m_previous_absolute { 0.0 };
    std::uint64_t m_previous_loop { 0 };
    std::uint64_t m_previous_seek_ticket { 0 };
};

struct VideoFrameSelection {
    /// A newer decoded frame became the displayed frame.
    bool selected { false };
    /// The frame already on screen was served again.
    bool reused { false };
    /// Decoded frames that were superseded before they were ever displayed.
    std::uint64_t skipped { 0 };
};

/// Turns the sequence of displayed frame generations into the three outcomes a
/// pacing change can produce. Generations are assigned in decode order, so a
/// gap between two displayed generations is exactly the number of decoded
/// frames that never reached the screen — which is the failure a demand-driven
/// clock has to be falsifiable against.
class VideoFrameSelectionTracker {
public:
    VideoFrameSelection Observe(std::uint64_t generation);
    void                Reset();

private:
    std::uint64_t m_last_generation { 0 };
    bool          m_has_last { false };
};

} // namespace wallpaper::video
