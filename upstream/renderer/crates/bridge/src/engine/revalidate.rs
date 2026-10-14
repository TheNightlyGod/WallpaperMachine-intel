//! The check that confirms scenes present again after the Mac wakes.
//!
//! Nothing here rebuilds anything on a healthy Mac. The check reads what the
//! renderer already publishes, waits a few seconds, reads it again, and asks
//! the engine to repair only the scene whose frame loop did not move. A
//! healthy scene costs two atomic reads and the wait.
//!
//! The signal is `frames_completed`, never a present. A frame that would repeat
//! the picture completes without presenting, so a still scene presents nothing
//! for as long as it likes and a reading built on presents would call it
//! dead. A scene is probed only while it is [`SceneUpdateMode::Continuous`] and
//! its display is not paused: an event-driven scene is idle by design, and a
//! paused or suspended display is somebody's decision, not a fault. A scene
//! that already carries a stop latch needs no waiting and is handed to the
//! engine at once.
//!
//! Repair is the engine's own recovery ladder, so a check cannot loop: the
//! ladder spends the scene's budget for the minute and is refused once it is
//! spent. The check never decides how a surface is rebuilt, only that one has
//! to be.

use std::time::Duration;

use wallpaper_core::{
    DisplaySnapshotEntry, RecoveryOutcome, RecoveryReason, RecoveryStep, SceneUpdateMode,
    SurfaceHealth, SurfaceStopReason, project::SceneHandle,
};

use super::{EngineFacade, SceneRuntimeReport};

/// How long the check waits between its two readings.
///
/// Long enough for a display link that restarts after a wake to deliver
/// several frames at any frame rate the app offers, short enough that a repair
/// follows the wake closely.
pub(crate) const GRACE: Duration = Duration::from_secs(3);

/// Why a scene was not probed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Skip {
    /// The display is paused: the user's choice, power policy, or the display
    /// being covered or asleep.
    Paused,
    /// The scene updates on events or deadlines, or its clock is stopped. Its
    /// frame count standing still is its normal state.
    NotContinuous,
    /// The renderer returned no reading, which is not the same as a healthy
    /// surface.
    Unreadable,
    /// The display's scene was replaced, closed or retargeted while the check
    /// waited, so the reading no longer describes it.
    Changed,
}

impl Skip {
    const fn describe(self) -> &'static str {
        match self {
            Self::Paused => "paused",
            Self::NotContinuous => "not continuously updating",
            Self::Unreadable => "no reading",
            Self::Changed => "changed while waiting",
        }
    }
}

/// What made a scene need repair.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Fault {
    /// The renderer stopped its own frame loop after a failure.
    Stopped(SurfaceStopReason),
    /// A continuous, unpaused scene completed no frame in the whole wait.
    NoFrames,
}

/// What asking the engine to repair a scene came to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Repair {
    Asked(RecoveryOutcome),
    Failed(String),
}

/// What the check concluded about one display's scene.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// The frame loop moved, or the renderer was replaced and began again.
    Drawing,
    Skipped(Skip),
    /// The scene was not drawing and the engine was asked to repair it.
    Faulty { fault: Fault, repair: Repair },
}

/// One display's result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SurfaceCheck {
    pub(crate) display_id: u32,
    pub(crate) verdict: Verdict,
    /// `frames_completed` at the first reading; zero when there was none.
    pub(crate) frames_before: u64,
    /// `frames_completed` at the second reading; the first when there was no
    /// second.
    pub(crate) frames_after: u64,
}

impl SurfaceCheck {
    /// The stable name the host reads: `ok`, `repaired`, `recovery_pending`,
    /// `gave_up`, `recovery_failed`, or `skipped_` followed by the reason.
    pub(crate) fn outcome(&self) -> &'static str {
        match &self.verdict {
            Verdict::Drawing => "ok",
            Verdict::Skipped(Skip::Paused) => "skipped_paused",
            Verdict::Skipped(Skip::NotContinuous) => "skipped_not_continuous",
            Verdict::Skipped(Skip::Unreadable) => "skipped_unreadable",
            Verdict::Skipped(Skip::Changed) => "skipped_changed",
            Verdict::Faulty { repair: Repair::Failed(_), .. } => "recovery_failed",
            Verdict::Faulty { repair: Repair::Asked(outcome), .. } => match outcome {
                RecoveryOutcome::Recovered { .. } => "repaired",
                RecoveryOutcome::InProgress => "recovery_pending",
                RecoveryOutcome::GaveUp => "gave_up",
                // The scene was gone or already drawing by the time the engine
                // looked: there was nothing left to repair.
                RecoveryOutcome::NoScene => "skipped_changed",
                RecoveryOutcome::AlreadyHealthy => "ok",
            },
        }
    }
}

/// What one display looked like at a reading.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Reading {
    Skip(Skip),
    /// A stop latch is set.
    Stopped { frames: u64, reason: SurfaceStopReason },
    /// Continuous, unpaused and readable: its `frames_completed`.
    Watch { frames: u64 },
}

fn read(entry: &DisplaySnapshotEntry, reports: &[SceneRuntimeReport]) -> Reading {
    if entry.paused {
        return Reading::Skip(Skip::Paused);
    }
    let Some(report) = entry
        .handle
        .and_then(|handle| reports.iter().find(|report| report.handle == handle.raw()))
    else {
        return Reading::Skip(Skip::Unreadable);
    };
    let Some(SurfaceHealth { frames_completed: frames, stop, .. }) = report.surface else {
        return Reading::Skip(Skip::Unreadable);
    };
    if let Some(reason) = stop {
        return Reading::Stopped { frames, reason };
    }
    match report.update_mode {
        Some(SceneUpdateMode::Continuous) => Reading::Watch { frames },
        None => Reading::Skip(Skip::Unreadable),
        Some(_) => Reading::Skip(Skip::NotContinuous),
    }
}

async fn repair<E: EngineFacade>(engine: &E, display_id: u32) -> Repair {
    match engine.recover_surface(display_id, RecoveryReason::Stalled).await {
        Ok(outcome) => Repair::Asked(outcome),
        Err(error) => Repair::Failed(error.to_string()),
    }
}

/// Verifies that every scene that should be drawing still is, and has the
/// engine repair the ones that are not.
///
/// Reads the displays and scene reports, repairs any scene whose stop latch is
/// set, waits `grace`, reads again, and repairs any continuous, unpaused scene
/// whose `frames_completed` did not move. A counter that went backwards names a
/// renderer that was replaced in the meantime, which is a healthy scene. The
/// result has one row for every display with a scene open.
///
/// Must run on a Tokio runtime, because it waits.
pub(crate) async fn revalidate_presentation<E: EngineFacade>(
    engine: &E,
    grace: Duration,
) -> Vec<SurfaceCheck> {
    let displays = engine.display_snapshot();
    let reports = engine.scene_runtime_reports();
    let mut checks: Vec<Option<SurfaceCheck>> = Vec::new();
    let mut watching: Vec<(usize, u32, SceneHandle, u64)> = Vec::new();

    for entry in displays.iter().filter(|entry| entry.handle.is_some()) {
        let display_id = entry.desc.display_id;
        let reading = read(entry, &reports);
        let frames_before = match reading {
            Reading::Watch { frames } | Reading::Stopped { frames, .. } => frames,
            Reading::Skip(_) => 0,
        };
        let verdict = match reading {
            Reading::Skip(skip) => Some(Verdict::Skipped(skip)),
            Reading::Stopped { reason, .. } => {
                let fault = Fault::Stopped(reason);
                Some(Verdict::Faulty { fault, repair: repair(engine, display_id).await })
            }
            Reading::Watch { frames } => {
                if let Some(handle) = entry.handle {
                    watching.push((checks.len(), display_id, handle, frames));
                }
                None
            }
        };
        let check = verdict.map(|verdict| SurfaceCheck {
            display_id,
            verdict,
            frames_before,
            frames_after: frames_before,
        });
        if let Some(check) = &check {
            note(check, grace);
        }
        checks.push(check);
    }

    if !watching.is_empty() {
        tokio::time::sleep(grace).await;
        let displays = engine.display_snapshot();
        let reports = engine.scene_runtime_reports();
        for (index, display_id, handle, before) in watching {
            let check = judge(engine, &displays, &reports, display_id, handle, before).await;
            note(&check, grace);
            checks[index] = Some(check);
        }
    }
    checks.into_iter().flatten().collect()
}

/// The second reading of a scene that was drawing at the first.
async fn judge<E: EngineFacade>(
    engine: &E,
    displays: &[DisplaySnapshotEntry],
    reports: &[SceneRuntimeReport],
    display_id: u32,
    handle: SceneHandle,
    before: u64,
) -> SurfaceCheck {
    let row = |verdict, after| SurfaceCheck {
        display_id,
        verdict,
        frames_before: before,
        frames_after: after,
    };
    // The same scene on the same display, or nothing the first reading can be
    // compared with.
    let Some(entry) = displays
        .iter()
        .find(|entry| entry.desc.display_id == display_id && entry.handle == Some(handle))
    else {
        return row(Verdict::Skipped(Skip::Changed), before);
    };
    match read(entry, reports) {
        Reading::Skip(skip) => row(Verdict::Skipped(skip), before),
        Reading::Stopped { frames, reason } => row(
            Verdict::Faulty {
                fault: Fault::Stopped(reason),
                repair: repair(engine, display_id).await,
            },
            frames,
        ),
        // A counter that went backwards began again from zero: the renderer was
        // replaced, and a new renderer is not a stalled one.
        Reading::Watch { frames } if frames != before => row(Verdict::Drawing, frames),
        Reading::Watch { frames } => row(
            Verdict::Faulty {
                fault: Fault::NoFrames,
                repair: repair(engine, display_id).await,
            },
            frames,
        ),
    }
}

/// One log line for one display.
fn note(check: &SurfaceCheck, grace: Duration) {
    let display = check.display_id;
    let frames = format!("frames {} -> {}", check.frames_before, check.frames_after);
    match &check.verdict {
        Verdict::Drawing => {
            log::info!("[wallpaper-bridge power] wake check: display {display} ok ({frames})");
        }
        Verdict::Skipped(skip) => log::info!(
            "[wallpaper-bridge power] wake check: display {display} skipped ({})",
            skip.describe()
        ),
        Verdict::Faulty { fault, repair } => {
            let what = match fault {
                Fault::Stopped(reason) => format!("stopped drawing ({})", reason.as_str()),
                Fault::NoFrames => {
                    format!("stalled (no frames in {:.1} s, {frames})", grace.as_secs_f64())
                }
            };
            let did = match repair {
                Repair::Asked(RecoveryOutcome::Recovered { step, attempt }) => {
                    let how = match step {
                        RecoveryStep::Reconfigure => "reconfigured the surface",
                        RecoveryStep::Rebuild => "rebuilt the renderer",
                    };
                    format!("{how} (attempt {attempt})")
                }
                Repair::Asked(RecoveryOutcome::InProgress) => {
                    "a repair is already under way".to_owned()
                }
                Repair::Asked(RecoveryOutcome::GaveUp) => {
                    "not repaired: this minute's recovery attempts are spent".to_owned()
                }
                Repair::Asked(RecoveryOutcome::NoScene) => {
                    "not repaired: the scene had gone".to_owned()
                }
                Repair::Asked(RecoveryOutcome::AlreadyHealthy) => {
                    "drawing again by the time it was repaired".to_owned()
                }
                Repair::Failed(error) => format!("repair failed: {error}"),
            };
            log::warn!("[wallpaper-bridge power] wake check: display {display} {what}; {did}");
        }
    }
}
