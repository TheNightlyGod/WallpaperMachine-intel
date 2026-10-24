// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
mod frame;

#[cfg(test)]
mod clock_tests {
    use super::PlaybackClock;

    #[test]
    fn finite_advances_cannot_overflow_a_looping_clock() {
        let mut clock = PlaybackClock::new(f64::MAX, true);
        let delta = f64::MAX * 0.75;
        clock.advance(delta);
        assert_eq!(clock.position_seconds(), delta);
        clock.advance(delta);
        let expected = delta - (f64::MAX - delta);
        assert!(clock.position_seconds().is_finite());
        assert_eq!(clock.position_seconds(), expected);
        assert!(clock.position_seconds() < f64::MAX);
    }

    #[test]
    fn ordinary_wraps_negative_clamping_and_nonfinite_deltas_are_preserved() {
        let mut clock = PlaybackClock::new(10.0, true);
        clock.advance(27.0);
        assert_eq!(clock.position_seconds(), 7.0);
        clock.advance(8.0);
        assert_eq!(clock.position_seconds(), 5.0);
        for delta in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            clock.advance(delta);
            assert_eq!(clock.position_seconds(), 5.0);
        }
        clock.advance(-2.0);
        assert_eq!(clock.position_seconds(), 3.0);
        clock.advance(-f64::MAX);
        assert_eq!(clock.position_seconds(), 0.0);
        clock.advance(f64::MAX);
        assert!(clock.position_seconds().is_finite());
        assert!((0.0..10.0).contains(&clock.position_seconds()));
    }

    #[test]
    fn finite_looping_positions_stay_in_range_at_float_extremes() {
        for duration in [
            f64::from_bits(1),
            f64::MIN_POSITIVE,
            1e-300,
            1.0,
            10.0,
            f64::MAX,
        ] {
            let mut clock = PlaybackClock::new(duration, true);
            for delta in [
                duration * 0.5,
                duration * 0.75,
                f64::MAX,
                0.1,
                -f64::MAX,
                0.0,
            ] {
                clock.advance(delta);
                assert!(clock.position_seconds().is_finite());
                assert!((0.0..duration).contains(&clock.position_seconds()));
            }
        }
        let mut rounded = PlaybackClock::new(1.0, true);
        rounded.advance(0.5);
        rounded.advance(0.5 - f64::EPSILON / 4.0);
        assert_eq!(rounded.position_seconds(), 0.0);
    }

    #[test]
    fn nonlooping_saturates_and_zero_duration_stays_zero() {
        let mut clock = PlaybackClock::new(f64::MAX, false);
        clock.advance(f64::MAX * 0.75);
        clock.advance(f64::MAX * 0.75);
        assert_eq!(clock.position_seconds(), f64::MAX);
        clock.advance(-f64::MAX);
        assert_eq!(clock.position_seconds(), 0.0);
        for looping in [false, true] {
            let mut zero = PlaybackClock::new(0.0, looping);
            for delta in [f64::MAX, -f64::MAX, 0.0, f64::NAN] {
                zero.advance(delta);
                assert_eq!(zero.position_seconds(), 0.0);
            }
        }
    }
}

pub use frame::{VideoFrame, VideoFrameUploadFormat};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PlaybackClock {
    duration_seconds: f64,
    looping: bool,
    position_seconds: f64,
}

impl PlaybackClock {
    #[must_use]
    pub fn new(duration_seconds: f64, looping: bool) -> Self {
        let duration_seconds = if duration_seconds.is_finite() && duration_seconds > 0.0 {
            duration_seconds
        } else {
            0.0
        };
        Self {
            duration_seconds,
            looping,
            position_seconds: 0.0,
        }
    }

    pub fn advance(&mut self, delta_seconds: f64) {
        if !delta_seconds.is_finite() {
            return;
        }
        self.position_seconds =
            if self.looping && self.duration_seconds > 0.0 && delta_seconds >= 0.0 {
                // Reduce before adding, then subtract the distance to the boundary
                // when wrapping. Neither branch adds two potentially huge values.
                let delta = delta_seconds % self.duration_seconds;
                let remaining = self.duration_seconds - self.position_seconds;
                if delta >= remaining {
                    delta - remaining
                } else {
                    // Rounding an addition up to exactly the duration still wraps.
                    (self.position_seconds + delta) % self.duration_seconds
                }
            } else {
                // Negative deltas clamp at zero rather than wrapping backwards;
                // overflow in the nonlooping positive case saturates at the duration.
                (self.position_seconds + delta_seconds)
                    .max(0.0)
                    .min(self.duration_seconds)
            };
    }

    #[must_use]
    pub fn position_seconds(&self) -> f64 {
        self.position_seconds
    }
}
