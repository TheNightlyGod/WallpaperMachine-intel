#pragma once

#include <algorithm>

// What a video source decides about a seek it has asked for and that has not yet
// delivered a frame. Pure arithmetic, so it can be tested without a decoder.
//
// A seek asked for again restarts the decode from the keyframe and drops what the
// last one had decoded. A source that asks on every draw while the frame it shows
// lags the clock never gets a seek to land, and one that asks again whenever the
// clock has run a fixed time past the target never lands a seek that takes longer
// than that time: the clock keeps running while the seek is made, so a seek that
// takes seconds lands seconds behind the clock it was asked for.

namespace wallpaper::video
{

/// How far a clock that runs at `clock_rate` times real time goes in `wall_seconds`,
/// counting it as no slower than real time: what waiting for a seek explains of the
/// clock's distance from the seek's target.
[[nodiscard]] inline double ClockRunOnSeconds(double wall_seconds, double clock_rate)
{
    return std::max(0.0, wall_seconds) * std::max(1.0, clock_rate);
}

/// How far behind the clock a source lets its frames fall before it seeks to catch
/// up instead of decoding on: a second, or twice the span its frame queue holds at
/// its own frame rate when that is longer, and the lateness of its last landing.
///
/// `landing_lag_seconds` is `ClockRunOnSeconds` of the time that seek took. A seek
/// that took that long delivered a frame that far behind the clock, which decoding
/// on catches up at many times the pace the clip plays; a seek asked for because of
/// it would land as late again.
[[nodiscard]] inline double ForwardResyncSeconds(double frame_duration_seconds,
                                                 double queued_frames,
                                                 double landing_lag_seconds)
{
    return std::max(1.0, frame_duration_seconds * queued_frames * 2.0) +
           std::max(0.0, landing_lag_seconds);
}

/// Whether a seek that is on its way is still fetching what the clock wants.
///
/// The clock must not have gone back before the seek's target by more than
/// `backward_slack_seconds`, nor have run on past it by more than
/// `forward_slack_seconds` plus what the wait so far explains. A clock that has only
/// run on while the seek was made is where it should be; one that has jumped is not,
/// and gets a seek of its own.
[[nodiscard]] inline bool SeekOnItsWayCoversClock(double target_seconds, double clock_seconds,
                                                  double wall_seconds_since_request,
                                                  double clock_rate,
                                                  double backward_slack_seconds,
                                                  double forward_slack_seconds)
{
    return target_seconds <= clock_seconds + backward_slack_seconds &&
           clock_seconds <= target_seconds + forward_slack_seconds +
                                ClockRunOnSeconds(wall_seconds_since_request, clock_rate);
}

} // namespace wallpaper::video
