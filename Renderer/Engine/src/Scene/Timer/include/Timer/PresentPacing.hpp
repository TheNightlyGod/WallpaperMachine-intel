#pragma once

#include <chrono>

namespace wallpaper
{

/// How long the frame on screen should stay before the next one replaces it, so frames made
/// every `frame_period` reach a display refreshing every `refresh_period` at an even number of
/// refreshes apart. Zero means "show at the next refresh" (a plain present).
///
/// A frame clock that is not driven by the display ticks a whole number of refreshes apart
/// only on average: a 60 fps cadence on a 120 Hz panel lands within a millisecond or two of a
/// refresh boundary for long stretches, and the render time's jitter then shows neighbouring
/// frames one and three refreshes apart instead of two and two. Holding each frame until a
/// little before the refresh the cadence aims at removes the short gap; a frame that is late
/// still shows at the next refresh, and the frames after it are held from that one, so a late
/// frame costs one longer gap instead of a run of uneven ones.
///
/// The hold is the whole refreshes the frame period spans, less a quarter refresh. The
/// quarter is the margin on both kinds of panel: a fixed-rate display shows the frame at the
/// refresh the hold ends in, and a ProMotion panel, which can refresh every half period
/// (`NSScreen.displayUpdateGranularity` is 4.17 ms at 120 Hz), at the half-step after it, which
/// is the same moment. Counting whole refreshes rounds down, so the hold never asks for more
/// refreshes than the frame period covers: a display shown frames this way keeps up with the
/// clock, and a ceiling at or above the display's rate (one refresh or less) is never halved.
/// The microsecond of tolerance absorbs the nanosecond rounding of both periods (60 fps is
/// 16 666 667 ns, two refreshes of 120 Hz 16 666 668 ns).
constexpr std::chrono::nanoseconds PresentHoldFor(std::chrono::nanoseconds frame_period,
                                                  std::chrono::nanoseconds refresh_period) {
    using std::chrono::nanoseconds;
    if (refresh_period <= nanoseconds::zero() || frame_period <= nanoseconds::zero()) {
        return nanoseconds::zero();
    }
    constexpr nanoseconds tolerance { 1'000 };
    const auto refreshes = (frame_period + tolerance) / refresh_period;
    if (refreshes < 2) return nanoseconds::zero();
    return refresh_period * refreshes - refresh_period / 4;
}

} // namespace wallpaper
