//! The budget and the ladder for healing a scene surface that stopped drawing.
//!
//! A renderer that failed a frame after it had drawn stops itself and stays on
//! its last picture; nothing in the renderer starts it again. This module only
//! decides *what to try next and when*, never how: it holds no renderer, no
//! window and no clock. Every method takes the current instant, so the whole
//! ladder is exercised with hand-picked instants and no waiting.
//!
//! The ladder is three rungs inside a rolling minute: reconfigure the surface
//! in place after 0.5 s, then rebuild the renderer after 2 s, then rebuild it
//! again after 8 s. The delays grow so a transient fault (a display that is
//! still settling) gets a quick, cheap retry while a persistent one is not
//! hammered. A failure that arrives after a quiet minute starts again at the
//! first rung, and a fourth failure inside one minute gives up, which leaves
//! the scene stopped and visibly so.
//!
//! A renderer that recovery rebuilt reports a failed frame only once it has
//! presented one, so a rebuild that fails its first frame would end the ladder
//! in silence. [`settle`] is how the engine tells such a rebuild from one that
//! worked: it reads the new renderer's health until it has drawn or stopped,
//! and the attempt stays pending meanwhile.

use std::time::{Duration, Instant};

use crate::owe::scene_demand::{SurfaceHealth, SurfaceStopReason};

/// What one recovery attempt does to the scene.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryStep {
    /// Rebuild only the renderer's layer binding under the live scene.
    /// Cheap and keeps the compiled scene, but needs the renderer's device to
    /// still be usable.
    Reconfigure,
    /// Open a new renderer for the same wallpaper and close the old one.
    /// Costs the scene's shaders and textures again, and heals what a
    /// reconfigure cannot, including a lost device.
    Rebuild,
}

impl RecoveryStep {
    /// Words for a log line.
    #[must_use]
    pub const fn describe(self) -> &'static str {
        match self {
            Self::Reconfigure => "a surface reconfigure",
            Self::Rebuild => "a renderer rebuild",
        }
    }
}

/// Why a recovery was asked for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryReason {
    /// The renderer reported a failed frame.
    RenderFailure,
    /// A liveness check found a scene that should be drawing and is not.
    /// Spends the current budget like any other attempt and is refused once it
    /// is spent.
    Stalled,
}

impl RecoveryReason {
    /// Words for a log line.
    #[must_use]
    pub const fn describe(self) -> &'static str {
        match self {
            Self::RenderFailure => "a render failure",
            Self::Stalled => "a stall check",
        }
    }
}

/// What a request for recovery came to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryOutcome {
    /// The surface was rebuilt. `attempt` counts from one inside the budget.
    /// A rebuilt renderer has not necessarily drawn yet: the engine keeps
    /// looking at it and feeds the ladder if it stops first.
    Recovered { step: RecoveryStep, attempt: usize },
    /// An attempt is already scheduled or running; nothing more was started.
    InProgress,
    /// The budget for this minute is spent, so nothing was tried and the scene
    /// stays stopped.
    GaveUp,
    /// No scene is open on that display, or the one that was has been
    /// replaced.
    NoScene,
    /// The surface was already drawing again by the time the attempt ran, so
    /// the attempt would only have interrupted it.
    AlreadyHealthy,
}

/// The rungs, in order: what to do and how long to wait before doing it.
pub const LADDER: [(RecoveryStep, Duration); 3] = [
    (RecoveryStep::Reconfigure, Duration::from_millis(500)),
    (RecoveryStep::Rebuild, Duration::from_secs(2)),
    (RecoveryStep::Rebuild, Duration::from_secs(8)),
];

/// How long an attempt counts against the budget. A scene that runs this long
/// without failing has earned a fresh ladder.
pub const WINDOW: Duration = Duration::from_secs(60);

/// How often a renderer that recovery just rebuilt is looked at, until it has
/// drawn or stopped.
pub const SETTLE_INTERVAL: Duration = Duration::from_secs(1);

/// How long a rebuilt renderer is given to present its first frame. A scene
/// with a great deal to load can take a while, so one that has neither drawn
/// nor stopped by then is reported and left alone, not rebuilt again.
pub const SETTLE_LIMIT: Duration = Duration::from_secs(30);

/// What a renderer that recovery rebuilt had become when it was looked at.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Settled {
    /// It has presented a frame and is not stopped: the rebuild worked.
    Drawing,
    /// It stopped itself, because its first frames or the graph under them
    /// failed. The renderer does not call back for this, so it counts as the
    /// failure it is.
    Stopped(SurfaceStopReason),
    /// Not drawing yet and not stopped; look again.
    Waiting,
    /// Neither drawing nor stopped after [`SETTLE_LIMIT`], or no reading could
    /// be taken that long. Nothing says it failed, so it is left as it is.
    Unconfirmed,
}

/// Tells a rebuilt renderer that drew from one that stopped or has yet to do
/// either, `waited` after the rebuild. A stop outranks a presented frame: a
/// renderer that drew once and then failed has failed. A reading that could not
/// be taken is not evidence of anything and is waited out.
#[must_use]
pub fn settle(health: Option<SurfaceHealth>, waited: Duration) -> Settled {
    if let Some(health) = health {
        if let Some(reason) = health.stop {
            return Settled::Stopped(reason);
        }
        if health.frames_presented > 0 {
            return Settled::Drawing;
        }
    }
    if waited >= SETTLE_LIMIT {
        Settled::Unconfirmed
    } else {
        Settled::Waiting
    }
}

/// What to do about a failure.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Wait `delay`, then do `step`. `number` counts from one.
    Attempt {
        step: RecoveryStep,
        delay: Duration,
        number: usize,
    },
    /// An attempt is already on its way; this failure adds nothing to it.
    Pending,
    /// The budget is spent: leave the scene stopped.
    GiveUp,
}

/// One renderer's recovery state. A new renderer for a *different* wallpaper
/// starts with a fresh one; a rebuild done by recovery itself keeps it, or the
/// ladder would never get past its second rung.
#[derive(Debug, Default)]
pub struct SurfaceRecovery {
    /// When each attempt inside the rolling window started.
    attempts: Vec<Instant>,
    /// An attempt has been handed out and has not finished.
    pending: bool,
    /// The last decision was to give up, and the window has not yet cleared.
    exhausted: bool,
}

impl SurfaceRecovery {
    /// The renderer reported a failed frame at `now`.
    pub fn on_failure(&mut self, now: Instant) -> Decision {
        self.prune(now);
        if self.pending {
            return Decision::Pending;
        }
        self.next_rung(now, false)
    }

    /// Recovery was asked for from outside the renderer's own report, by a
    /// stall check. The rung is the next one on the ladder and is attempted
    /// without waiting, since the caller is waiting for it.
    ///
    /// It spends the current budget like a reported failure does, and does
    /// nothing once the budget is spent. Only the window clearing, or a new
    /// renderer for a different wallpaper (which the user gets by reloading
    /// the wallpaper), starts a fresh one.
    pub fn on_forced(&mut self, now: Instant) -> Decision {
        if self.pending {
            return Decision::Pending;
        }
        self.prune(now);
        self.next_rung(now, true)
    }

    /// The attempt handed out has finished, whatever it came to.
    pub fn mark_done(&mut self) {
        self.pending = false;
    }

    /// Whether the budget is spent. Stays true until the window clears, so a
    /// caller can tell the first give-up from the rest.
    #[must_use]
    pub fn exhausted(&self) -> bool {
        self.exhausted
    }

    /// Attempts counted against the current window.
    #[cfg(test)]
    #[must_use]
    pub fn attempts_used(&self) -> usize {
        self.attempts.len()
    }

    fn next_rung(&mut self, now: Instant, immediately: bool) -> Decision {
        let used = self.attempts.len();
        let Some(&(step, delay)) = LADDER.get(used) else {
            self.exhausted = true;
            return Decision::GiveUp;
        };
        self.attempts.push(now);
        self.pending = true;
        Decision::Attempt {
            step,
            delay: if immediately { Duration::ZERO } else { delay },
            number: used + 1,
        }
    }

    /// Forgets attempts older than the window. A window with nothing left in
    /// it is a quiet minute: the budget is whole again, and an attempt that
    /// never reported back is not waited for any longer.
    fn prune(&mut self, now: Instant) {
        self.attempts
            .retain(|started| now.saturating_duration_since(*started) < WINDOW);
        if self.attempts.is_empty() {
            self.exhausted = false;
            self.pending = false;
        }
    }
}

/// Whether the surface already draws again, so an attempt would only interrupt
/// it. A reading the renderer could not take is not evidence of health.
#[must_use]
pub fn is_healthy(health: Option<SurfaceHealth>) -> bool {
    health.is_some_and(|health| health.stop.is_none())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::owe::scene_demand::SurfaceStopReason;

    fn at(seconds: u64) -> Instant {
        // Instants cannot be built from nothing, so every test measures from
        // one origin taken here; only the differences matter.
        static ORIGIN: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        *ORIGIN.get_or_init(Instant::now) + Duration::from_secs(seconds)
    }

    fn attempt(decision: Decision) -> (RecoveryStep, Duration, usize) {
        match decision {
            Decision::Attempt { step, delay, number } => (step, delay, number),
            other => panic!("expected an attempt, got {other:?}"),
        }
    }

    #[test]
    fn the_ladder_is_reconfigure_then_two_rebuilds_with_growing_delays() {
        let mut recovery = SurfaceRecovery::default();

        let first = attempt(recovery.on_failure(at(0)));
        recovery.mark_done();
        let second = attempt(recovery.on_failure(at(1)));
        recovery.mark_done();
        let third = attempt(recovery.on_failure(at(3)));
        recovery.mark_done();

        assert_eq!(first, (RecoveryStep::Reconfigure, Duration::from_millis(500), 1));
        assert_eq!(second, (RecoveryStep::Rebuild, Duration::from_secs(2), 2));
        assert_eq!(third, (RecoveryStep::Rebuild, Duration::from_secs(8), 3));
    }

    #[test]
    fn a_failure_after_a_stable_minute_starts_the_ladder_again() {
        let mut recovery = SurfaceRecovery::default();
        attempt(recovery.on_failure(at(0)));
        recovery.mark_done();
        attempt(recovery.on_failure(at(1)));
        recovery.mark_done();

        // Sixty seconds after the first attempt and fifty-nine after the
        // second: the first has aged out and the second has not, so this is
        // the second rung again, not a fresh ladder and not the third.
        let rolling = attempt(recovery.on_failure(at(60)));
        recovery.mark_done();
        assert_eq!(rolling.2, 2, "the window rolls; it does not reset in one step");

        let mut quiet = SurfaceRecovery::default();
        attempt(quiet.on_failure(at(0)));
        quiet.mark_done();
        let again = attempt(quiet.on_failure(at(61)));
        assert_eq!(again, (RecoveryStep::Reconfigure, Duration::from_millis(500), 1));
        assert_eq!(quiet.attempts_used(), 1);
    }

    #[test]
    fn the_budget_is_spent_after_three_attempts_inside_the_window_and_gives_up_without_scheduling() {
        let mut recovery = SurfaceRecovery::default();
        for second in [0, 1, 3] {
            attempt(recovery.on_failure(at(second)));
            recovery.mark_done();
        }
        assert!(!recovery.exhausted());

        assert_eq!(recovery.on_failure(at(12)), Decision::GiveUp);
        assert!(recovery.exhausted());
        assert_eq!(recovery.attempts_used(), 3, "giving up must not spend another attempt");

        // Nothing is pending after a give-up, so the next failure is judged on
        // its own and gives up again rather than waiting for an attempt that
        // was never scheduled.
        assert_eq!(recovery.on_failure(at(13)), Decision::GiveUp);
    }

    #[test]
    fn a_failure_while_an_attempt_is_pending_is_ignored() {
        let mut recovery = SurfaceRecovery::default();
        attempt(recovery.on_failure(at(0)));

        assert_eq!(recovery.on_failure(at(0)), Decision::Pending);
        assert_eq!(
            recovery.on_forced(at(0)),
            Decision::Pending,
            "a stall check does not start a second attempt beside the one on its way"
        );
        assert_eq!(recovery.attempts_used(), 1, "an ignored failure must not spend the budget");

        recovery.mark_done();
        assert_eq!(attempt(recovery.on_failure(at(1))).2, 2);
    }

    #[test]
    fn a_stalled_check_does_not_buy_back_a_spent_budget() {
        let mut recovery = SurfaceRecovery::default();
        for second in [0, 1, 3] {
            attempt(recovery.on_failure(at(second)));
            recovery.mark_done();
        }
        assert_eq!(recovery.on_failure(at(12)), Decision::GiveUp);

        assert_eq!(
            recovery.on_forced(at(20)),
            Decision::GiveUp,
            "a stall check must not buy a spent budget back"
        );
        assert!(recovery.exhausted());
        assert_eq!(recovery.attempts_used(), 3, "a refused check spends nothing");
    }

    #[test]
    fn a_stalled_check_spends_the_budget_without_a_delay_and_is_refused_once_it_is_spent() {
        let mut recovery = SurfaceRecovery::default();

        let first = attempt(recovery.on_forced(at(0)));
        recovery.mark_done();
        assert_eq!(first, (RecoveryStep::Reconfigure, Duration::ZERO, 1));

        // A failure the renderer reports counts against the same budget.
        assert_eq!(attempt(recovery.on_failure(at(1))).2, 2);
        recovery.mark_done();
        assert_eq!(
            attempt(recovery.on_forced(at(2))),
            (RecoveryStep::Rebuild, Duration::ZERO, 3)
        );
        recovery.mark_done();
        assert_eq!(recovery.on_forced(at(3)), Decision::GiveUp);
    }

    #[test]
    fn a_stalled_check_after_a_quiet_minute_gets_a_fresh_ladder() {
        let mut recovery = SurfaceRecovery::default();
        for second in [0, 1, 3] {
            attempt(recovery.on_failure(at(second)));
            recovery.mark_done();
        }
        assert_eq!(recovery.on_failure(at(12)), Decision::GiveUp);

        // A wake an hour later is not the same minute.
        let later = attempt(recovery.on_forced(at(3_600)));
        assert_eq!(later.2, 1);
        assert!(!recovery.exhausted());
    }

    #[test]
    fn an_attempt_that_never_reported_back_does_not_block_recovery_forever() {
        let mut recovery = SurfaceRecovery::default();
        attempt(recovery.on_failure(at(0)));
        // No mark_done: the message that carried the attempt was lost.
        assert_eq!(recovery.on_failure(at(30)), Decision::Pending);

        let after_the_window = attempt(recovery.on_failure(at(61)));
        assert_eq!(after_the_window.2, 1, "a lost attempt ages out with the rest of the window");
    }

    fn reading(presented: u64, stop: Option<SurfaceStopReason>) -> Option<SurfaceHealth> {
        Some(SurfaceHealth {
            frames_completed: presented,
            frames_presented: presented,
            failed_frames: u64::from(stop.is_some()),
            last_present_age: None,
            stop,
        })
    }

    #[test]
    fn a_rebuilt_renderer_is_settled_by_what_it_has_drawn_or_how_it_stopped() {
        let soon = Duration::from_secs(1);
        assert_eq!(settle(reading(1, None), soon), Settled::Drawing);
        assert_eq!(
            settle(reading(0, Some(SurfaceStopReason::FrameFailed)), soon),
            Settled::Stopped(SurfaceStopReason::FrameFailed),
            "a first frame that failed is the failure the renderer never calls back about"
        );
        assert_eq!(
            settle(reading(0, Some(SurfaceStopReason::GraphFailed)), soon),
            Settled::Stopped(SurfaceStopReason::GraphFailed)
        );
        assert_eq!(
            settle(reading(7, Some(SurfaceStopReason::FrameFailed)), soon),
            Settled::Stopped(SurfaceStopReason::FrameFailed),
            "a renderer that drew and then failed has failed"
        );
        assert_eq!(settle(reading(0, None), soon), Settled::Waiting);
        assert_eq!(settle(None, soon), Settled::Waiting, "no reading is not a healthy one");
    }

    #[test]
    fn a_renderer_that_neither_draws_nor_stops_is_left_alone_after_the_limit() {
        let just_before = SETTLE_LIMIT - Duration::from_millis(1);
        assert_eq!(settle(reading(0, None), just_before), Settled::Waiting);
        assert_eq!(settle(reading(0, None), SETTLE_LIMIT), Settled::Unconfirmed);
        assert_eq!(settle(None, SETTLE_LIMIT), Settled::Unconfirmed);
        // Late evidence still counts: a stop or a frame is never hidden by the limit.
        assert_eq!(settle(reading(1, None), SETTLE_LIMIT), Settled::Drawing);
        assert_eq!(
            settle(reading(0, Some(SurfaceStopReason::GraphFailed)), SETTLE_LIMIT),
            Settled::Stopped(SurfaceStopReason::GraphFailed)
        );
    }

    #[test]
    fn a_rebuild_that_stops_before_drawing_walks_the_ladder_to_the_end() {
        // The renderer calls back for no failure before its first frame, so the
        // engine's look at each rebuild is what feeds the ladder.
        let mut recovery = SurfaceRecovery::default();
        attempt(recovery.on_failure(at(0)));
        recovery.mark_done(); // the in-place reconfigure worked, then the scene failed again
        let second = attempt(recovery.on_failure(at(1)));
        assert_eq!(second, (RecoveryStep::Rebuild, Duration::from_secs(2), 2));

        // The rebuild succeeded and stays pending while it is watched; a
        // failure reported meanwhile is not a second attempt.
        assert_eq!(recovery.on_failure(at(3)), Decision::Pending);

        // The look finds it stopped: the attempt is over and the next rung is due.
        assert_eq!(
            settle(reading(0, Some(SurfaceStopReason::FrameFailed)), SETTLE_INTERVAL),
            Settled::Stopped(SurfaceStopReason::FrameFailed)
        );
        recovery.mark_done();
        let third = attempt(recovery.on_failure(at(4)));
        assert_eq!(third, (RecoveryStep::Rebuild, Duration::from_secs(8), 3));

        // The last rebuild fails the same way and the ladder ends, once.
        recovery.mark_done();
        assert_eq!(recovery.on_failure(at(13)), Decision::GiveUp);
        assert!(recovery.exhausted());
        assert_eq!(recovery.attempts_used(), 3);
    }

    #[test]
    fn only_a_surface_the_renderer_reports_as_running_counts_as_healthy() {
        let health = |stop| {
            Some(SurfaceHealth {
                frames_completed: 10,
                frames_presented: 10,
                failed_frames: 0,
                last_present_age: None,
                stop,
            })
        };
        assert!(is_healthy(health(None)));
        assert!(!is_healthy(health(Some(SurfaceStopReason::FrameFailed))));
        assert!(!is_healthy(health(Some(SurfaceStopReason::GraphFailed))));
        assert!(
            !is_healthy(None),
            "a reading that could not be taken is not evidence that the surface recovered"
        );
    }
}
